// SPDX-License-Identifier: Apache-2.0
/// Host → client, mutual-auth handshake (spec §3). A fresh 32-byte CSPRNG nonce the client must
/// sign to prove possession of its enrolled device key. Sent right after the host receives
/// `ClientHello`, before any session scaffolding. Fixed-width payload (no length prefix); decode
/// rejects a wrong length or any trailing bytes so the challenge framing is unambiguous.
public struct ServerChallenge: WireMessage, Equatable, Sendable {
    public static let messageType = MessageType.serverChallenge
    /// Nonce length in bytes (256-bit; single-use per connection).
    public static let nonceLength = 32

    public var nonce: [UInt8]

    public init(nonce: [UInt8]) { self.nonce = nonce }

    public func encode(into w: inout BinaryWriter) { w.putBytes(nonce) }

    public init(from r: inout BinaryReader) throws {
        nonce = try r.readBytes(Self.nonceLength)
        guard r.isAtEnd else { throw WireError.malformed("ServerChallenge: trailing bytes") }
    }
}
