// SPDX-License-Identifier: Apache-2.0
/// Host → client (SAS pairing preamble). The host's nonce commitment (32 bytes, `SASCode.commit`),
/// sent in response to the client commit and before either side reveals its nonce.
public struct SASHostCommit: WireMessage {
    public static let messageType = MessageType.sasHostCommit
    public var commit: [UInt8]

    public init(commit: [UInt8]) { self.commit = commit }

    public func encode(into w: inout BinaryWriter) { w.putBytes(commit) }
    public init(from r: inout BinaryReader) throws { commit = try r.readBytes(32) }
}
