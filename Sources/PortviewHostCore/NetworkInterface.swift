import Foundation
import Darwin

enum NetworkInterface {
    /// Best-guess primary LAN IPv4 address (prefers `en0`). nil if none found.
    static func primaryIPv4() -> String? {
        var fallback: String?
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0 else { return nil }
        defer { freeifaddrs(ifaddrPointer) }

        var pointer = ifaddrPointer
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address, socklen_t(address.pointee.sa_len),
                                     &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let end = host.firstIndex(of: 0) ?? host.endIndex
            let ip = String(decoding: host[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = String(cString: current.pointee.ifa_name)
            if name == "en0" { return ip }                 // prefer the primary Wi-Fi/Ethernet
            if fallback == nil, name.hasPrefix("en") { fallback = ip }
        }
        return fallback
    }
}
