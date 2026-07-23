// SPDX-License-Identifier: Apache-2.0
import Foundation
import PortviewProtocol

/// Client-side pure signer for the mutual-auth challenge (spec §3): turns a host `ServerChallenge`
/// plus the client's pinned host-cert hash into a `ClientAuth` response, via `ClientIdentity.sign`.
public enum ChallengeResponse {
    /// `pinnedCertSHA256` must be exactly 32 bytes (the pin the client already holds from its
    /// pinned dial, never server-supplied) — `nil` on any other length, or if signing throws.
    public static func make(
        identity: ClientIdentity, challenge: ServerChallenge, pinnedCertSHA256: Data
    ) -> ClientAuth? {
        guard pinnedCertSHA256.count == 32 else { return nil }
        guard let signature = try? identity.sign(
            nonce: challenge.nonce, hostCertSHA256: Array(pinnedCertSHA256))
        else { return nil }
        return ClientAuth(publicKey: Array(identity.publicKey), signature: signature)
    }
}
