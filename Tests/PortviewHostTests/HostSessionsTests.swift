import Testing
@testable import PortviewHostCore

/// The pure reducer + formatting behind the macOS host's "device connected" state. Driven entirely
/// by real `HostRunnerEvent`s emitted from the serve loop — no fabricated telemetry.
@Suite struct HostSessionsTests {
    private func stats() -> HostSessionStats {
        HostSessionStats(throughputMbps: 8.4, fps: 60, encodeMs: 3.1, displayWidth: 1512, displayHeight: 982)
    }

    @Test func connectingDeviceAppearsWithNameAndCount() {
        var sessions = HostSessions()
        sessions.apply(.deviceConnected(id: "a", name: "iPhone 15 Pro"))
        #expect(sessions.count == 1)
        #expect(sessions.primaryName == "iPhone 15 Pro")
    }

    @Test func secondDeviceIncrementsCountAndKeepsFirstPrimary() {
        var sessions = HostSessions()
        sessions.apply(.deviceConnected(id: "a", name: "iPhone"))
        sessions.apply(.deviceConnected(id: "b", name: "iPad"))
        #expect(sessions.count == 2)
        #expect(sessions.primaryName == "iPhone")
    }

    @Test func duplicateConnectIdDoesNotDouble() {
        var sessions = HostSessions()
        sessions.apply(.deviceConnected(id: "a", name: "iPhone"))
        sessions.apply(.deviceConnected(id: "a", name: "iPhone"))
        #expect(sessions.count == 1)
    }

    @Test func disconnectRemovesDevice() {
        var sessions = HostSessions()
        sessions.apply(.deviceConnected(id: "a", name: "iPhone"))
        sessions.apply(.deviceConnected(id: "b", name: "iPad"))
        sessions.apply(.deviceDisconnected(id: "a"))
        #expect(sessions.count == 1)
        #expect(sessions.primaryName == "iPad")
    }

    @Test func statsStoredWhileConnected() {
        var sessions = HostSessions()
        sessions.apply(.deviceConnected(id: "a", name: "iPhone"))
        sessions.apply(.sessionStats(stats()))
        #expect(sessions.latestStats == stats())
    }

    @Test func lastDisconnectClearsStats() {
        var sessions = HostSessions()
        sessions.apply(.deviceConnected(id: "a", name: "iPhone"))
        sessions.apply(.sessionStats(stats()))
        sessions.apply(.deviceDisconnected(id: "a"))
        #expect(sessions.count == 0)
        #expect(sessions.latestStats == nil)
    }

    @Test func unrelatedEventsAreIgnored() {
        var sessions = HostSessions()
        sessions.apply(.message("host ready"))
        sessions.apply(.accessibilityWarning("grant it"))
        #expect(sessions.count == 0)
        #expect(sessions.latestStats == nil)
    }

    // MARK: - Formatting

    @Test func pinGroupsFirstTwoQuadsThenEllipsisThenLastQuad() {
        let pin = "3f9a1c0e" + String(repeating: "0", count: 52) + "b27c" // 64 hex chars
        #expect(HostFormat.groupedPin(pin) == "3f9a 1c0e … b27c")
    }

    @Test func shortPinReturnedUnchanged() {
        #expect(HostFormat.groupedPin("abcd") == "abcd")
    }

    @Test func sessionDurationFormatsMinutesSeconds() {
        #expect(HostFormat.sessionDuration(252) == "04:12")
        #expect(HostFormat.sessionDuration(5) == "00:05")
        #expect(HostFormat.sessionDuration(3661) == "61:01")
    }
}
