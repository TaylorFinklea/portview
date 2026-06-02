import Foundation
import Network
import Security

/// Builds `NWParameters` for a TLS-over-TCP Portview connection.
///
/// This is the POC transport: an unambiguously bidirectional connection that avoids
/// QUIC's connection-vs-stream multiplexing semantics. QUIC (`QUICParameters`) remains
/// the production target; `PortviewConnection` is transport-agnostic, so swapping back
/// is a one-line change once QUIC stream multiplexing is finished.
public enum TLSParameters {
    /// Listener parameters presenting the host's identity, TLS 1.3 minimum.
    public static func server(identity: TLSIdentity) throws -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, try identity.makeSecIdentityT())
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    /// Client parameters pinning the host's certificate by SHA-256, TLS 1.3 minimum.
    public static func client(pinnedCertificateSHA256: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        CertificatePinning.install(on: tls.securityProtocolOptions, pinnedCertificateSHA256: pinnedCertificateSHA256)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}
