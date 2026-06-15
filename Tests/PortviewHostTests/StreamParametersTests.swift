import Testing
@testable import PortviewHostCore

/// The host now honors the client's requested capture fps + encoder bitrate (`StartSession`), within
/// safe clamps. Previously both were ignored (hardcoded 60 fps + a width·height heuristic).
@Suite struct StreamParametersTests {
    @Test func captureFPSDefaultsTo60WhenUnset() {
        #expect(StreamParameters.captureFPS(requested: 0) == 60)
    }

    @Test func captureFPSHonorsRequestWithinRange() {
        #expect(StreamParameters.captureFPS(requested: 30) == 30)
        #expect(StreamParameters.captureFPS(requested: 60) == 60)
    }

    @Test func captureFPSClampsOutOfRange() {
        #expect(StreamParameters.captureFPS(requested: 5) == 10)
        #expect(StreamParameters.captureFPS(requested: 240) == 60)
    }

    @Test func encoderBitrateNilWhenUnset() {
        // 0 → fall back to the host's width·height heuristic (encoder default).
        #expect(StreamParameters.encoderBitrate(requested: 0) == nil)
    }

    @Test func encoderBitrateHonorsRequestWithinRange() {
        #expect(StreamParameters.encoderBitrate(requested: 25_000_000) == 25_000_000)
    }

    @Test func encoderBitrateClampsOutOfRange() {
        #expect(StreamParameters.encoderBitrate(requested: 1_000) == 2_000_000)
        #expect(StreamParameters.encoderBitrate(requested: 999_000_000) == 120_000_000)
    }
}
