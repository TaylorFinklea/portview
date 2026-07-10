import Foundation
import Network
import Security

/// Builds `NWParameters` for Portview QUIC endpoints.
public enum QUICParameters {
    private static func baseOptions() -> NWProtocolQUIC.Options {
        let q = NWProtocolQUIC.Options(alpn: [PortviewTransport.alpn])
        q.idleTimeout = 30_000
        // Per-tunnel stream allowance, lowered from the old 100/1000 toward what lane-splitting
        // actually needs (spec "Per-tunnel stream cap"): primary + 3 secondary lanes, ×2 for the
        // spike-pinned double-delivery quirk (dead duplicate deliveries persist with group
        // clients), ×2 headroom. This is the transport-level backstop against a stream flood
        // into per-stream buffers; the tighter app-level bound is
        // `AcceptedTunnel.maxLanePathStreams`. Phase 1 opens no unidirectional streams
        // (client-opened lanes must be bidi to carry host→client frames).
        q.initialMaxStreamsBidirectional = 16
        q.initialMaxStreamsUnidirectional = 4
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

    /// SAS pairing preamble ONLY: accepts any cert and captures its leaf SHA-256 (TOFU). Never use
    /// this for a streaming session — the captured hash gates trust via the SAS code, after which the
    /// client re-dials with the pinned `client(pinnedCertificateSHA256:)`. See `SASPreamblePinning`.
    static func clientCapturingCert() -> (NWParameters, CertificateCapture) {
        let q = baseOptions()
        let capture = CertificateCapture()
        SASPreamblePinning.installCapturing(on: q.securityProtocolOptions, capture: capture)
        return (NWParameters(quic: q), capture)
    }
}
