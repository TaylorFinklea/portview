/// Transport-layer constants shared by host and client.
public enum PortholeTransport {
    /// ALPN identifier negotiated on the QUIC/TLS handshake.
    public static let alpn = "porthole/1"
    /// Bonjour service type the host advertises and the client browses for (TLS-over-TCP POC).
    public static let bonjourServiceType = "_porthole._tcp"
}
