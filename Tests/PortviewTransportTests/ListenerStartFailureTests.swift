// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import Network
@testable import PortviewTransport

@Suite struct ListenerStartFailureTests {
    /// Guards a continuation against double-resume when the racing tasks below both settle
    /// (mirrors `HostRunner.SingleResumeGate`).
    private actor OneShot {
        private var fired = false
        func claim() -> Bool {
            guard !fired else { return false }
            fired = true
            return true
        }
    }

    /// Race `operation` against a deadline WITHOUT structurally awaiting the loser: a pre-fix
    /// wedged `start()` never resumes and is uncancellable, so a task-group race (`withTimeout`)
    /// would itself hang on teardown awaiting the wedged child. Returns nil on timeout, leaving
    /// the loser running unstructured — harmless in the test process (mirrors the
    /// `HostRunner.nextMessage` deadline idiom).
    private static func outcome<T: Sendable>(
        within timeout: Duration,
        of operation: @escaping @Sendable () async throws -> T
    ) async -> Result<T, any Error>? {
        let gate = OneShot()
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<T, any Error>?, Never>) in
            Task {
                let result: Result<T, any Error>
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                if await gate.claim() { cont.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if await gate.claim() { cont.resume(returning: nil) }
            }
        }
    }

    /// A listener that can't bind (its port is already taken) must surface a bounded error from
    /// `start()` instead of wedging the host run task. On current macOS the conflicting bind
    /// surfaces as `.failed(EADDRINUSE)` (already bounded); on paths/OSes where an unavailable
    /// binding reports `.waiting` instead, that state pre-fix hit `default: break` and never
    /// resumed. The unstructured race converts any hang into a test FAILURE instead of wedging
    /// the suite.
    @Test func startOnTakenPortFailsInsteadOfHanging() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()

        // Occupy an OS-assigned port (the same probe idiom as ListenerPortTests), then try to
        // bind a second listener to that exact port while the first still holds it.
        let holder = try PortviewListener(quicIdentity: identity)
        let takenPort = try await withTimeout(.seconds(15)) { try await holder.start() }
        defer { holder.cancel() }

        let contender = try PortviewListener(quicIdentity: identity, port: takenPort.rawValue)
        defer { contender.cancel() }
        switch await Self.outcome(within: .seconds(5), of: { try await contender.start() }) {
        case nil:
            Issue.record("start() on a taken port hung instead of failing in bounded time")
        case .success:
            Issue.record("start() on a taken port unexpectedly succeeded")
        case .failure:
            break // Expected: a bounded failure (EADDRINUSE via `.failed` or `.waiting`).
        }
    }

    /// `.cancelled` pre-fix hit `default: break` and never resumed `start()`'s continuation —
    /// a listener cancelled around start wedged the awaiting task forever (deterministic here:
    /// cancelling BEFORE `start()` delivers `.cancelled` to the state handler once started).
    /// Post-fix it must resume-throw. The unstructured race converts a pre-fix hang into a
    /// test FAILURE instead of wedging the suite.
    @Test func startOnACancelledListenerThrowsInsteadOfHanging() async throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned()
        let listener = try PortviewListener(quicIdentity: identity)
        listener.cancel()
        switch await Self.outcome(within: .seconds(5), of: { try await listener.start() }) {
        case nil:
            Issue.record("start() on a cancelled listener hung instead of throwing")
        case .success:
            Issue.record("start() on a cancelled listener unexpectedly succeeded")
        case .failure:
            break // Expected: a bounded failure (CancellationError via the `.cancelled` state).
        }
    }
}
