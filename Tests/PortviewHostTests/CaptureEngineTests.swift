import Testing
@testable import PortviewHostCore

@Suite struct CaptureEngineTests {
    @Test func concurrentSetViewportCallsWithoutStartReturnWithoutCrashing() async {
        // No start() call, so `config`/`stream` are never assigned — this exercises the
        // configLock-guarded reads from many tasks at once and asserts they all return cleanly
        // (no crash, no deadlock) rather than any particular viewport outcome.
        let engine = CaptureEngine(width: 1920, height: 1080)

        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<200 {
                let nx = Double(i % 10) / 10
                group.addTask {
                    await engine.setViewport(normalizedX: nx, normalizedY: 0, normalizedW: 0.5, normalizedH: 0.5)
                }
            }
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            #expect(results.count == 200)
            #expect(results.allSatisfy { $0 == false })
        }
    }

    @Test func requestKeyframeIsHonoredAndConsumedExactlyOnce() async {
        // Routes a client `.requestKeyframe` wire message: set the keyframe flag without a re-crop,
        // then the video pump consumes it once to force the next frame to a keyframe.
        let engine = CaptureEngine(width: 1920, height: 1080)
        #expect(await engine.consumeKeyframeRequest() == false)
        await engine.requestKeyframe()
        #expect(await engine.consumeKeyframeRequest() == true)
        #expect(await engine.consumeKeyframeRequest() == false)
    }
}
