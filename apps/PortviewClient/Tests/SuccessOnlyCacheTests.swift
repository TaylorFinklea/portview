// SPDX-License-Identifier: Apache-2.0
import XCTest

@testable import PortviewClient

/// `SuccessOnlyCache` backs `SessionViewModel`'s device-identity memo (review Finding F): a
/// transient failure (e.g. a keychain read attempted before first-unlock) must NOT be remembered
/// past the attempt that hit it, or the surfaced "unlock and retry" message becomes a permanent
/// lie for the rest of the app process — while a SUCCESSFUL load stays memoized so the identity
/// isn't re-derived (or re-read from the keychain) on every subsequent connect.
final class SuccessOnlyCacheTests: XCTestCase {
    private struct Boom: Error {}

    func testCachesASuccessfulLoadAndNeverCallsLoadAgain() throws {
        var cache = SuccessOnlyCache<Int>()
        var calls = 0
        func load() throws -> Int { calls += 1; return 42 }

        XCTAssertEqual(try cache.resolve(load), 42)
        XCTAssertEqual(try cache.resolve(load), 42)
        XCTAssertEqual(calls, 1, "a cached success must not re-invoke load")
    }

    func testDoesNotCacheAFailureSoTheNextResolveRetries() {
        var cache = SuccessOnlyCache<Int>()
        var calls = 0
        func failingLoad() throws -> Int { calls += 1; throw Boom() }

        XCTAssertThrowsError(try cache.resolve(failingLoad))
        XCTAssertThrowsError(try cache.resolve(failingLoad))
        XCTAssertEqual(calls, 2, "a failed load must be re-attempted on the next resolve, not memoized")
    }

    func testARecoveredLoadAfterAFailureIsThenCached() throws {
        var cache = SuccessOnlyCache<Int>()
        var calls = 0
        func flakyThenGood() throws -> Int {
            calls += 1
            if calls == 1 { throw Boom() }
            return 7
        }

        XCTAssertThrowsError(try cache.resolve(flakyThenGood))
        XCTAssertEqual(try cache.resolve(flakyThenGood), 7)
        XCTAssertEqual(try cache.resolve(flakyThenGood), 7)
        XCTAssertEqual(calls, 2, "the recovered success must be cached; a third call reuses it without loading again")
    }
}
