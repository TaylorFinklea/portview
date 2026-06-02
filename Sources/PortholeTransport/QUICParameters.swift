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

    /// Client parameters that pin the host's certificate by SHA-256 of its DER encoding.
    /// The handshake succeeds only if the presented leaf certificate matches `pinnedCertificateSHA256`.
    /// (M0/POC: the pin is computed from the host's generated identity; M1 carries it in the pairing QR.)
    public static func client(pinnedCertificateSHA256: Data) -> NWParameters {
        let q = baseOptions()
        CertificatePinning.install(on: q.securityProtocolOptions, pinnedCertificateSHA256: pinnedCertificateSHA256)
        return NWParameters(quic: q)
    }
}
