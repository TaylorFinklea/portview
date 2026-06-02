/// Porthole wire protocol — shared contract between the Mac host and iPhone client.
/// (Named `Porthole`, not `PortholeProtocol`, to avoid a type sharing its module's name.)
public enum Porthole {
    /// Bonjour service type the host advertises and the client browses for.
    public static let bonjourServiceType = "_porthole._udp"
}
