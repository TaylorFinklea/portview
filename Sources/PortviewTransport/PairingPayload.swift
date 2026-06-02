import Foundation

/// Everything a client needs to connect to a host, encodable as a QR / deep-link URL:
/// `portview://pair?host=<addr>&port=<n>&pin=<hex>&name=<label>`.
///
/// The pin travels only via the QR shown on the Mac's own screen — never broadcast over
/// Bonjour — so it stays the out-of-band secret that anchors certificate pinning.
public struct PairingPayload: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var pinHex: String
    public var name: String?

    public init(host: String, port: UInt16, pinHex: String, name: String? = nil) {
        self.host = host
        self.port = port
        self.pinHex = pinHex
        self.name = name
    }

    /// The `portview://pair?…` URL string to encode in a QR code.
    public var urlString: String {
        var components = URLComponents()
        components.scheme = "portview"
        components.host = "pair"
        var items = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "pin", value: pinHex),
        ]
        if let name { items.append(URLQueryItem(name: "name", value: name)) }
        components.queryItems = items
        return components.string ?? ""
    }

    /// Parse a scanned `portview://pair?…` URL; nil if malformed.
    public init?(urlString: String) {
        guard let components = URLComponents(string: urlString),
              components.scheme == "portview",
              components.host == "pair" else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { query[item.name] = value }
        }
        guard let host = query["host"],
              let portString = query["port"],
              let port = UInt16(portString),
              let pin = query["pin"] else { return nil }
        self.init(host: host, port: port, pinHex: pin, name: query["name"])
    }
}
