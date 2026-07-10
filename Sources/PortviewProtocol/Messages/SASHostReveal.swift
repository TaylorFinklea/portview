// SPDX-License-Identifier: Apache-2.0
/// Host → client (SAS pairing preamble). The host's 16-byte nonce, revealed only after the client
/// reveal verifies. The client verifies it against the earlier `SASHostCommit`, then both derive the
/// 6-digit code.
public struct SASHostReveal: WireMessage {
    public static let messageType = MessageType.sasHostReveal
    public var nonce: [UInt8]

    public init(nonce: [UInt8]) { self.nonce = nonce }

    public func encode(into w: inout BinaryWriter) { w.putBytes(nonce) }
    public init(from r: inout BinaryReader) throws { nonce = try r.readBytes(16) }
}
