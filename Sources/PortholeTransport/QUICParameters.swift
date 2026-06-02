import Foundation
import Network
import Security

/// Builds `NWParameters` for Porthole QUIC endpoints.
public enum QUICParameters {
    private static func baseOptions() -> NWProtocolQUIC.Options {
        let q = NWProtocolQUIC.Options(alpn: [PortholeTransport.alpn])
        q.idleTimeout = 30_000
        q.initialMaxStreamsBidirectional = 100
        q.initialMaxStreamsUnidirectional = 1000
        return q
    }

    /// Listener parameters presenting the host's identity.
    public static func server(identity: TLSIdentity) throws -> NWParameters {
        let q = baseOptions()
        sec_protocol_options_set_local_identity(q.securityProtocolOptions, try identity.makeSecIdentityT())
        return NWParameters(quic: q)
    }

    /// Client parameters. M0 spike trusts the host's self-signed cert unconditionally;
    /// M1 replaces the verify block with QR-pinned-fingerprint validation.
    public static func client() -> NWParameters {
        let q = baseOptions()
        sec_protocol_options_set_verify_block(
            q.securityProtocolOptions,
            { _, _, complete in complete(true) },
            DispatchQueue(label: "porthole.tls.verify")
        )
        return NWParameters(quic: q)
    }
}
