import XCTest
import Network
import PortviewProtocol
import PortviewTransport

@testable import PortviewClient

/// Pure presentation helpers behind the Glass HUD: Deck Home tile reachability and the
/// telemetry readout that feeds the live rail + quality panel. These format real
/// `QualityDiagnostics` values — the design's "42 ms latency" is not a measured metric, so it is
/// deliberately absent here rather than fabricated.
final class GlassMappingTests: XCTestCase {
    private func saved(name: String = "Roshar") -> SavedHost {
        SavedHost(name: name, host: "10.0.0.5", port: 7443, pinHex: String(repeating: "a", count: 64))
    }

    private func discovered(_ name: String) -> DiscoveredHost {
        DiscoveredHost(
            id: name, name: name,
            endpoint: .service(name: name, type: "_portview._udp", domain: "local.", interface: nil))
    }

    // MARK: - Deck Home tile reachability

    func testSavedHostIsOnNetworkWhenNameMatchesDiscovered() {
        XCTAssertTrue(saved().isOnNetwork(among: [discovered("Other"), discovered("Roshar")]))
    }

    func testSavedHostIsOffNetworkWithoutNameMatch() {
        XCTAssertFalse(saved().isOnNetwork(among: [discovered("Other")]))
        XCTAssertFalse(saved().isOnNetwork(among: []))
    }

    // MARK: - Telemetry readout

    func testReadoutShowsDashesWithoutData() {
        let readout = TelemetryReadout(QualityDiagnostics())
        XCTAssertEqual(readout.link, "—")
        XCTAssertEqual(readout.frame, "—")
        XCTAssertEqual(readout.decode, "—")
        XCTAssertEqual(readout.encode, "—")
        XCTAssertFalse(readout.hasData)
    }

    func testReadoutFormatsReceivedMetricsOnceStreaming() {
        var diagnostics = QualityDiagnostics()
        diagnostics.frameWidth = 1512
        diagnostics.frameHeight = 982
        diagnostics.receivedMbps = 8.42
        diagnostics.receivedFPS = 59.6
        diagnostics.averageDecodeMs = 4.23

        let readout = TelemetryReadout(diagnostics)
        XCTAssertTrue(readout.hasData)
        XCTAssertEqual(readout.link, "8.4")
        XCTAssertEqual(readout.frame, "60")
        XCTAssertEqual(readout.decode, "4.2")
        // No host stats yet → encode unavailable, not fabricated.
        XCTAssertEqual(readout.encode, "—")
    }

    func testReadoutFormatsHostEncodeMsWhenPresent() {
        var diagnostics = QualityDiagnostics()
        diagnostics.frameWidth = 100
        diagnostics.frameHeight = 100
        diagnostics.host = QualityStats(
            displayID: 1, encoderWidth: 100, encoderHeight: 100, configuredBitrate: 1,
            encodedMbpsX100: 840, fpsX100: 6000, averageFrameBytes: 1000, keyframes: 1,
            averageEncodeMsX100: 310, viewportX: 0, viewportY: 0, viewportW: 65535, viewportH: 65535)

        XCTAssertEqual(TelemetryReadout(diagnostics).encode, "3.1")
    }

    // MARK: - Mid-session reconnect candidates

    /// A live Bonjour host matching by name comes first (re-resolves the current IP after a LAN
    /// change), then the endpoint we were connected to as the fallback.
    func testReconnectCandidatesPrefersDiscoveredThenFallback() {
        let fallback = NWEndpoint.hostPort(host: "10.0.0.5", port: 7443)
        let match = discovered("Roshar")
        let result = SessionViewModel.reconnectCandidates(
            name: "Roshar", fallback: fallback, discovered: [discovered("Other"), match])
        XCTAssertEqual(result, [match.endpoint, fallback])
    }

    /// No matching discovered host → only the fallback endpoint.
    func testReconnectCandidatesFallbackOnlyWithoutMatch() {
        let fallback = NWEndpoint.hostPort(host: "10.0.0.5", port: 7443)
        let result = SessionViewModel.reconnectCandidates(
            name: "Roshar", fallback: fallback, discovered: [discovered("Other")])
        XCTAssertEqual(result, [fallback])
    }

    /// When the fallback IS the rediscovered service endpoint, don't try it twice.
    func testReconnectCandidatesDedupesFallbackEqualToDiscovered() {
        let service = discovered("Roshar")
        let result = SessionViewModel.reconnectCandidates(
            name: "Roshar", fallback: service.endpoint, discovered: [service])
        XCTAssertEqual(result, [service.endpoint])
    }
}
