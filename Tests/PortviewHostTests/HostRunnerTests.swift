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

    @Test func identityServiceDiffersForAppAndCLI() {
        let app = HostRunner.identityKeychainService(for: .app(displayName: "Portview Host"))
        let cli = HostRunner.identityKeychainService(for: .terminal)

        #expect(app != cli)  // signed app and unsigned CLI must not share a keychain item
        // The displayName must not affect the app's service key (all app launches share one identity).
        #expect(HostRunner.identityKeychainService(for: .app(displayName: "Other")) == app)
    }

    @Test func serveConnectionsCancelsActiveSessionsWhenStreamEnds() async {
        let (connections, connectionContinuation) = AsyncStream<Int>.makeStream()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (cancelled, cancelledContinuation) = AsyncStream<Void>.makeStream()

        let serving = Task {
            await HostRunner.serveConnections(connections) { _ in
                startedContinuation.yield(())
                await withTaskCancellationHandler {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                } onCancel: {
                    cancelledContinuation.yield(())
                }
            }
        }

        connectionContinuation.yield(1)
        #expect(await firstValue(from: started) != nil)

        connectionContinuation.finish()
        #expect(await firstValue(from: cancelled) != nil)
        await serving.value
    }
}

private func firstValue<Element>(from stream: AsyncStream<Element>) async -> Element? {
    for await value in stream { return value }
    return nil
}
