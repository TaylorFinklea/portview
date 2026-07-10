// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import CoreMedia
import CoreVideo
@testable import PortviewMedia

@Suite struct PipelineLatencyTests {
    /// Loopback pipeline-latency harness for the <50ms motion-to-photon goal: times the
    /// encode → serialize → deserialize → decode path per stage without a live display,
    /// using persistent encoder/decoder sessions like the production host/client. PTS is
    /// load-bearing: the input presentation time must survive the hardware encode (in the
    /// real pipeline it then travels out-of-band as `VideoFrame.ptsMicros`; the deserialized
    /// sample buffer carries `.zero` by design). Timings are REPORTED, not asserted — the
    /// <50ms confirmation on hardware is a separate human-gated check; wall-clock thresholds
    /// flake under parallel suite load. Only a generous sanity bound is enforced.
    @Test func loopbackPipelinePreservesPTSAndReportsStageLatency() async throws {
        let width = 1280, height = 720
        let warmupFrames = 2   // after the cold frame, before measurement
        let measuredFrames = 10
        let totalFrames = 1 + warmupFrames + measuredFrames

        let encoder = try VideoEncoder(width: width, height: height)
        let decoder = VideoDecoder()
        // Two solid frames with different colours so warm P-frames carry a real full-frame delta.
        let inputs = [
            makeSolidBGRA(width: width, height: height, b: 10, g: 20, r: 200),
            makeSolidBGRA(width: width, height: height, b: 200, g: 20, r: 10),
        ]
        let clock = ContinuousClock()

        var cold: StageTimings?
        var warm: [StageTimings] = []

        for index in 0..<totalFrames {
            let pts = CMTime(value: CMTimeValue(index) * 16_667, timescale: 1_000_000) // ~60fps spacing
            let input = inputs[index % inputs.count]

            // Stage 1: hardware HEVC encode (keyframe only on the first frame, like the host).
            var stageStart = clock.now
            let encoded = try await encoder.encode(input, presentationTime: pts, forceKeyframe: index == 0)
            let encodeTime = clock.now - stageStart

            // THE load-bearing assertion: the input PTS is recovered from the encoded sample.
            #expect(CMSampleBufferGetPresentationTimeStamp(encoded) == pts)

            // Stage 2: serialize to the transport byte blob (what `VideoFrame.data` carries).
            stageStart = clock.now
            let sample = try VideoSampleSerializer.serialize(encoded)
            let payload = sample.serialized()
            let serializeTime = clock.now - stageStart

            if index == 0 { #expect(sample.isKeyframe) }

            // Stage 3: deserialize the byte blob back into a decodable sample buffer.
            stageStart = clock.now
            let received = try EncodedVideoSample(serialized: payload)
            let rebuilt = try VideoSampleSerializer.deserialize(received)
            let deserializeTime = clock.now - stageStart

            #expect(received == sample) // byte-exact round trip through the wire format

            // Stage 4: hardware HEVC decode back to a BGRA pixel buffer.
            stageStart = clock.now
            let output = try await decoder.decode(rebuilt)
            let decodeTime = clock.now - stageStart

            #expect(CVPixelBufferGetWidth(output) == width)
            #expect(CVPixelBufferGetHeight(output) == height)

            let timings = StageTimings(
                encode: encodeTime, serialize: serializeTime,
                deserialize: deserializeTime, decode: decodeTime
            )
            // Generous sanity bound only — never a tight wall-clock assert (see doc comment).
            #expect(timings.total < .seconds(5))

            if index == 0 {
                cold = timings
            } else if index > warmupFrames {
                warm.append(timings)
            }
        }

        let coldTimings = try #require(cold)
        #expect(warm.count == measuredFrames)
        print("[PipelineLatency] \(width)x\(height) HEVC loopback, encode → serialize → deserialize → decode")
        print("  cold  (frame 0: session setup + keyframe): \(coldTimings.formatted())")
        print("  warm  (\(warm.count) measured P-frames after \(warmupFrames) warm-up):")
        for (label, stage) in [
            ("encode", \StageTimings.encode), ("serialize", \StageTimings.serialize),
            ("deserialize", \StageTimings.deserialize), ("decode", \StageTimings.decode),
        ] {
            print("    \(label.padding(toLength: 12, withPad: " ", startingAt: 0))\(summary(of: warm.map { $0[keyPath: stage] }))")
        }
        print("    \("total".padding(toLength: 12, withPad: " ", startingAt: 0))\(summary(of: warm.map(\.total)))")
    }
}

/// Per-stage elapsed time for one frame through the loopback pipeline.
private struct StageTimings {
    var encode: Duration
    var serialize: Duration
    var deserialize: Duration
    var decode: Duration
    var total: Duration { encode + serialize + deserialize + decode }

    func formatted() -> String {
        "encode \(ms(encode)) serialize \(ms(serialize)) deserialize \(ms(deserialize)) "
            + "decode \(ms(decode)) total \(ms(total))"
    }
}

/// min / median / max of a set of stage durations, formatted in milliseconds.
private func summary(of durations: [Duration]) -> String {
    let sorted = durations.sorted()
    let median = sorted[sorted.count / 2]
    return "min \(ms(sorted.first!))  median \(ms(median))  max \(ms(sorted.last!))"
}

private func ms(_ duration: Duration) -> String {
    let millis = Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1e15
    return String(format: "%.2fms", millis)
}
