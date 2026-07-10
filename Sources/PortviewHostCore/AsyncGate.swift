// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Minimal FIFO async mutex: `enter()` suspends until the gate is free, `leave()` admits the next
/// waiter in arrival order. Exists because an `NSLock` cannot be held across an `await` — use it to
/// serialize a critical section that contains suspension points (e.g. `CaptureEngine`'s
/// mutate → `stream.updateConfiguration(_:)` → rollback sequences). Not cancellation-aware: a
/// waiter admitted after its task was cancelled still runs its section, so keep sections short.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        // All locking lives inside the synchronous continuation closure (NSLock is `noasync`),
        // which also makes the busy-check and the waiter-append one atomic step.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy {
                waiters.append(continuation)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func leave() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
        } else {
            // Ownership transfers to the resumed waiter (`busy` stays true).
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}
