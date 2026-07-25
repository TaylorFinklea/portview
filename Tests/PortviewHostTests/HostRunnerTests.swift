// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import PortviewProtocol
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

    // MARK: - Sol review I3: Invalidate-First on the cancellation-driven shutdown path

    /// The serve task's cancellation handler (Stop Hosting / listener cancel) used to call
    /// `connection.close()` while the session capability was still VALID — the capability was only
    /// invalidated later, in `serveSession`'s defer. An already-dequeued `.typeText` could therefore
    /// keep posting its remaining CGEvents past the shutdown boundary (the synchronous injection loop
    /// never observes task cancellation). Design §7 invariant 1 says Invalidate-First holds on EVERY
    /// terminal path, so the mark must land strictly BEFORE the transport close.
    @Test func cancelServe_marksTheCapabilityInvalidBeforeClosingTheTransport() {
        let capability = SessionCapability()
        let box = SessionCapabilityBox()
        box.publish(capability)
        var validAtClose: Bool?

        HostRunner.cancelServe(box) { validAtClose = capability.isValid }

        #expect(validAtClose == false)     // withdrawn BEFORE the close ran
        #expect(capability.isValid == false)
        var injected = false
        #expect(capability.perform { injected = true } == false)
        #expect(injected == false)
    }

    /// Cancellation can land BEFORE `serveSession` has even created its capability (e.g. during the
    /// auth gate). The box must remember the withdrawal and apply it to whatever is published later —
    /// a session must never come up live on an already-cancelled serve task.
    @Test func cancelServe_withdrawalAppliesToACapabilityPublishedAfterwards() {
        let box = SessionCapabilityBox()
        HostRunner.cancelServe(box) { }

        let late = SessionCapability()
        box.publish(late)

        #expect(late.isValid == false)
    }

    /// The cancellation handler runs synchronously on the cancelling thread, so it must MARK (never
    /// drain): a session stalled inside an irreducible effect must not be able to wedge host
    /// shutdown. The in-flight effect completes — that is the accepted ≤ one-effect residual — but
    /// the close is not held up waiting for it.
    @Test func cancelServe_doesNotBlockOnAnInFlightEffect() {
        let capability = SessionCapability()
        let box = SessionCapabilityBox()
        box.publish(capability)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let performDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            capability.perform { entered.signal(); release.wait() }
            performDone.signal()
        }
        #expect(entered.wait(timeout: .now() + 10) == .success)

        var closed = false
        HostRunner.cancelServe(box) { closed = true }   // must return while the effect is parked

        #expect(closed)
        #expect(capability.isValid == false)
        release.signal()
        #expect(performDone.wait(timeout: .now() + 10) == .success)
    }

    // MARK: - Sol review I4(a): R9 backstop on host-local session-control effects

    /// The serve loop's session-control branches (`.startSession`/`.switchDisplay` → capture start,
    /// `.viewport` → live re-crop, `.clientFeedback` → encoder feedback, `.requestKeyframe`) mutate
    /// HOST-side state and had no capability guard, so a residual message delivered to a parked
    /// waiter after invalidation (design §10 R9) could still reconfigure — or START — screen capture
    /// for a revoked peer. Outbound was already gated; this is the host-side half.
    @Test func applySessionControl_runsWhileValidAndSkipsTheEffectAfterWithdrawal() async {
        let capability = SessionCapability()
        let capture = CaptureEngine(width: 640, height: 480)

        #expect(await HostRunner.applySessionControl(capability) { await capture.requestKeyframe() })
        #expect(await capture.consumeKeyframeRequest() == true)

        capability.markInvalid()
        #expect(await HostRunner.applySessionControl(capability) { await capture.requestKeyframe() } == false)
        #expect(await capture.consumeKeyframeRequest() == false)   // the gated effect never ran
    }

    /// Same gate over the feedback holder the adaptive rate controller reads: a revoked peer must not
    /// keep steering the encoder.
    @Test func applySessionControl_gatesClientFeedbackUpdates() async {
        let capability = SessionCapability()
        let holder = HostRunner.ClientFeedbackHolder()

        capability.markInvalid()
        #expect(await HostRunner.applySessionControl(capability) {
            holder.update(ClientFeedback(receivedFPSX100: 3000, receivedMbpsX100: 500,
                                         averageDecodeMsX100: 400, decodeQueueDepth: 1,
                                         droppedFrames: 0, rttMicros: 1000))
        } == false)

        #expect(holder.latest() == nil)
    }
}

private func firstValue<Element>(from stream: AsyncStream<Element>) async -> Element? {
    for await value in stream { return value }
    return nil
}
