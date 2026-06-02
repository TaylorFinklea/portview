/// Portview wire protocol — shared contract between the Mac host and iPhone client.
/// (Named `Portview`, not `PortviewProtocol`, to avoid a type sharing its module's name.)
public enum Portview {
    /// Bonjour service type the host advertises and the client browses for.
    public static let bonjourServiceType = "_portview._udp"
}
