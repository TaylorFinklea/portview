import Testing
@testable import PortviewProtocol

@Suite struct HostLockStatusTests {
    @Test func hostLockStatusRoundTripsLocked() throws {
        let message = HostLockStatus(locked: true)
        var w = BinaryWriter()
        message.encode(into: &w)
        var r = BinaryReader(w.bytes)
        #expect(try HostLockStatus(from: &r) == message)
        #expect(HostLockStatus.messageType == .hostLockStatus)
    }

    @Test func hostLockStatusRoundTripsUnlocked() throws {
        let message = HostLockStatus(locked: false)
        var w = BinaryWriter()
        message.encode(into: &w)
        var r = BinaryReader(w.bytes)
        #expect(try HostLockStatus(from: &r) == message)
    }

    @Test func hostLockStatusThroughFrameBothStates() throws {
        for locked in [true, false] {
            let any: AnyMessage = .hostLockStatus(HostLockStatus(locked: locked))
            #expect(try Frame.decode(Frame.encodeAny(any)) == any)
        }
    }

    /// Pin the on-wire encoding so a refactor can't silently shift the tag or payload (a self-consistent
    /// round-trip alone wouldn't catch a tag change). Frame = [varint bodyLen][type byte][payload];
    /// HostLockStatus is tag 26 with a 1-byte bool payload, so bodyLen = 2.
    @Test func hostLockStatusWireBytesArePinned() {
        #expect(MessageType.hostLockStatus.rawValue == 26)
        #expect(Frame.encodeAny(.hostLockStatus(HostLockStatus(locked: true))) == [2, 26, 1])
        #expect(Frame.encodeAny(.hostLockStatus(HostLockStatus(locked: false))) == [2, 26, 0])
    }
}
