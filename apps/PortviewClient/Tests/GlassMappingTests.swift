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

    // MARK: - Client quality settings → handshake params

    func testDefaultClientSettings() {
        let settings = ClientSettings()
        XCTAssertEqual(settings.bitrateMbps, 25)
        XCTAssertEqual(settings.fps, 60)
        XCTAssertEqual(settings.targetBitrate, 25_000_000)
        XCTAssertEqual(settings.maxFPS, 60)
    }

    func testClientSettingsClampsBitrate() {
        XCTAssertEqual(ClientSettings(bitrateMbps: 200, fps: 60).targetBitrate, 80_000_000)
        XCTAssertEqual(ClientSettings(bitrateMbps: 1, fps: 60).targetBitrate, 4_000_000)
        XCTAssertEqual(ClientSettings(bitrateMbps: 40, fps: 60).targetBitrate, 40_000_000)
    }

    func testClientSettingsNormalizesFPS() {
        XCTAssertEqual(ClientSettings(bitrateMbps: 25, fps: 30).maxFPS, 30)
        XCTAssertEqual(ClientSettings(bitrateMbps: 25, fps: 45).maxFPS, 60)
    }

    // MARK: - Resolved endpoint → host:port (for persisting discovered Macs)

    func testHostPortFromResolvedHostPortEndpoint() {
        let result = SessionViewModel.hostPort(from: .hostPort(host: "192.168.1.42", port: 7443))
        XCTAssertEqual(result?.host, "192.168.1.42")
        XCTAssertEqual(result?.port, 7443)
    }

    func testHostPortNilForServiceEndpoint() {
        let service = NWEndpoint.service(name: "Roshar", type: "_portview._udp", domain: "local.", interface: nil)
        XCTAssertNil(SessionViewModel.hostPort(from: service))
    }

    func testHostPortNilForNilEndpoint() {
        XCTAssertNil(SessionViewModel.hostPort(from: nil))
    }

    // MARK: - Saved-host upsert (refresh by name; add by new name)

    func testUpsertRefreshesSameNameWithNewIPKeepingID() {
        let original = SavedHost(name: "Roshar", host: "10.0.0.5", port: 7443, pinHex: pin)
        let moved = SavedHost(name: "Roshar", host: "10.0.0.9", port: 7443, pinHex: pin)
        let result = SavedHostsStore.upserting([original], with: moved)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.host, "10.0.0.9")
        XCTAssertEqual(result.first?.id, original.id) // same logical entry, refreshed
    }

    func testUpsertAddsNewName() {
        // Distinct Macs have distinct pins (the pinned cert SHA) — so this adds rather than folds.
        let roshar = SavedHost(name: "Roshar", host: "10.0.0.5", port: 7443, pinHex: pin)
        let shadesmar = SavedHost(name: "Shadesmar", host: "10.0.0.6", port: 7443, pinHex: String(repeating: "c", count: 64))
        let result = SavedHostsStore.upserting([roshar], with: shadesmar)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.name, "Shadesmar") // most-recent first
    }

    func testUpsertFallsBackToHostPortMatchWhenNamesDiffer() {
        let manual = SavedHost(name: "10.0.0.5", host: "10.0.0.5", port: 7443, pinHex: pin)
        let rePin = SavedHost(name: "10.0.0.5", host: "10.0.0.5", port: 7443, pinHex: String(repeating: "b", count: 64))
        let result = SavedHostsStore.upserting([manual], with: rePin)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.pinHex, String(repeating: "b", count: 64))
    }

    /// A Mac saved manually (name == its IP) folds into one entry when later seen via Bonjour under
    /// its real name + a new IP — matched by the stable pinned cert.
    func testUpsertFoldsManualAndBonjourEntriesByPin() {
        let manual = SavedHost(name: "10.0.0.5", host: "10.0.0.5", port: 7443, pinHex: pin)
        let bonjour = SavedHost(name: "Roshar", host: "10.0.0.9", port: 7443, pinHex: pin)
        let result = SavedHostsStore.upserting([manual], with: bonjour)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Roshar")
        XCTAssertEqual(result.first?.host, "10.0.0.9")
    }

    // MARK: - Inbound Mac→iPhone file transfer assembly

    func testIncomingFileTransferStreamsAssembledFileToDisk() throws {
        let transfers = IncomingFileTransfers()
        XCTAssertEqual(transfers.offer(FileOffer(transferID: 7, name: "notes.txt", size: 5)), "notes.txt")
        XCTAssertNil(transfers.chunk(FileChunk(transferID: 7, isLast: false, data: Array("hel".utf8))))
        let done = transfers.chunk(FileChunk(transferID: 7, isLast: true, data: Array("lo".utf8)))
        XCTAssertEqual(done?.name, "notes.txt")
        let data = try XCTUnwrap(done.flatMap { try? Data(contentsOf: $0.url) })
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello")
    }

    func testIncomingFileTransferIgnoresUnknownTransfer() {
        let transfers = IncomingFileTransfers()
        XCTAssertNil(transfers.chunk(FileChunk(transferID: 99, isLast: true, data: [1, 2, 3])))
    }

    func testIncomingFileTransferRejectsUnsafeOfferName() {
        let transfers = IncomingFileTransfers()
        XCTAssertNil(transfers.offer(FileOffer(transferID: 1, name: "..", size: 0)))
        XCTAssertEqual(transfers.offer(FileOffer(transferID: 2, name: "../../x.txt", size: 0)), "x.txt")
    }

    func testSafeFilenameStripsPathTraversal() {
        XCTAssertEqual(IncomingFileTransfers.safeFilename("notes.txt"), "notes.txt")
        XCTAssertEqual(IncomingFileTransfers.safeFilename("../../etc/passwd"), "passwd")
        XCTAssertEqual(IncomingFileTransfers.safeFilename("a/b/c.png"), "c.png")
    }

    func testSafeFilenameRejectsTraversalTokens() {
        XCTAssertNil(IncomingFileTransfers.safeFilename(".."))
        XCTAssertNil(IncomingFileTransfers.safeFilename("."))
        XCTAssertNil(IncomingFileTransfers.safeFilename(""))
    }

    private let pin = String(repeating: "a", count: 64)
}
