import Foundation

struct TimeoutError: Error {}

/// Run `operation`, failing with `TimeoutError` if it outlasts `duration`.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(for: duration); throw TimeoutError() }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
