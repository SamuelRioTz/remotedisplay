import Foundation

/// IPs locales del Mac para mostrar cómo conectarse (LAN + Tailscale).
enum NetworkInfo {
    static func addresses() -> [(iface: String, ip: String)] {
        var result: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            if let addr = p.pointee.ifa_addr,
               (flags & IFF_UP) == IFF_UP,
               (flags & IFF_LOOPBACK) == 0,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    result.append((String(cString: p.pointee.ifa_name),
                                   String(cString: host)))
                }
            }
            ptr = p.pointee.ifa_next
        }
        return result
    }

    static func isTailscale(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p[0] == 100 && p[1] >= 64 && p[1] <= 127
    }

    /// IP de LAN (interfaz en*, excluyendo Tailscale).
    static func primaryLAN() -> String? {
        addresses().first { $0.iface.hasPrefix("en") && !isTailscale($0.ip) }?.ip
    }

    static func tailscale() -> String? {
        addresses().first { isTailscale($0.ip) }?.ip
    }
}
