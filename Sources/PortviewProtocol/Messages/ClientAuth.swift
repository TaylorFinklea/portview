// SPDX-License-Identifier: Apache-2.0
/// Client → host, mutual-auth handshake (spec §3). The client's device public key plus its
/// signature over `ClientAuthCrypto.signedPayload(nonce:hostCertSHA256:)` — proving possession of
/// the key enrolled in the host's `PairingStore`. The host derives the device id
/// (`SHA256(publicKey)`), looks up the enrolled record, requires an exact stored-key match, and
/// verifies the signature against the exact nonce it issued before building any scaffolding.
///
/// Fixed-width payload (32-byte key ‖ 64-byte Ed25519 signature; no length prefixes); decode
/// rejects a wrong length or any trailing bytes.
public struct ClientAuth: WireMessage, Equatable, Sendable {
    public static let messageType = MessageType.clientAuth
    /// Raw Curve25519 signing public-key length.
    public static let publicKeyLength = 32
    /// Ed25519 signature length.
    public static let signatureLength = 64

    public var publicKey: [UInt8]
    public var signature: [UInt8]

    public init(publicKey: [UInt8], signature: [UInt8]) {
        self.publicKey = publicKey
        self.signature = signature
    }

    public func encode(into w: inout BinaryWriter) {
        w.putBytes(publicKey)
        w.putBytes(signature)
    }

    public init(from r: inout BinaryReader) throws {
        publicKey = try r.readBytes(Self.publicKeyLength)
        signature = try r.readBytes(Self.signatureLength)
        guard r.isAtEnd else { throw WireError.malformed("ClientAuth: trailing bytes") }
    }
}
