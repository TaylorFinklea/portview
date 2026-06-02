/// Transport-layer constants shared by host and client.
public enum PortviewTransport {
    /// ALPN identifier negotiated on the QUIC/TLS handshake.
    public static let alpn = "portview/1"
    /// Bonjour service type the host advertises and the client browses for (TLS-over-TCP POC).
    public static let bonjourServiceType = "_portview._tcp"
}
