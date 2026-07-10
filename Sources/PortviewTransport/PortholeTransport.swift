// SPDX-License-Identifier: Apache-2.0
/// Transport-layer constants shared by host and client.
public enum PortviewTransport {
    /// ALPN identifier negotiated on the QUIC/TLS handshake.
    public static let alpn = "portview/1"
    /// Bonjour service type the host advertises and the client browses for. `_udp` because the
    /// default transport is QUIC (UDP). Must stay in sync with the client's NSBonjourServices.
    public static let bonjourServiceType = "_portview._udp"
}
