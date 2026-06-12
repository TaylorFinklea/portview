import Testing
@testable import PortviewHostCore

@Suite struct HostRunnerTests {
    @Test func readyMessageIncludesPairingDetails() {
        let details = HostReadyDetails(
            serviceName: "Demo Mac",
            address: "10.0.0.5",
            port: 49152,
            pinHex: "abcdef",
            pairingURL: "portview://pair?host=10.0.0.5")

        let message = HostRunner.readyMessage(details)

        #expect(message.contains("Demo Mac"))
        #expect(message.contains("10.0.0.5:49152"))
        #expect(message.contains("abcdef"))
        #expect(message.contains("portview://pair?host=10.0.0.5"))
    }

    @Test func screenRecordingHelpUsesAppIdentity() {
        let help = HostRunner.screenRecordingHelp(for: .app(displayName: "Portview Host"))

        #expect(help.contains("Portview Host.app"))
        #expect(help.contains("Screen Recording"))
        #expect(!help.contains("TERMINAL app"))
    }

    @Test func screenRecordingHelpUsesTerminalIdentityForCLI() {
        let help = HostRunner.screenRecordingHelp(for: .terminal)

        #expect(help.contains("TERMINAL app"))
        #expect(help.contains("swift run portview-host"))
    }

    @Test func accessibilityHelpUsesTerminalIdentityForCLI() {
        let help = HostRunner.accessibilityHelp(for: .terminal)

        #expect(help.contains("enable your terminal"))
        #expect(!help.contains("Portview Host.app"))
    }

    @Test func accessibilityWarningEventUsesRequestedIdentity() {
        let event = HostRunner.accessibilityWarningEvent(for: .terminal)

        #expect(event == .accessibilityWarning(HostRunner.accessibilityHelp(for: .terminal)))
    }
}
