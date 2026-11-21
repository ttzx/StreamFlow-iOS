import Foundation

/// 本机局域网 IPv4 工具：投屏中继 URL 拼装 + 网段扫描前缀推导。
enum LANAddress {
    /// 首个非 link-local 的 en* IPv4（排除 utun/lo0/awdl/llw/p2p）
    static func firstIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let iface = current.pointee
            ptr = iface.ifa_next
            guard let sa = iface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var addr = sockaddr_in()
            memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
            var bytes = addr.sin_addr.s_addr.bigEndian
            let octets = withUnsafeBytes(of: &bytes) { Array($0) }
            // 排除 169.254 link-local（APIPA，无法跨设备）
            if octets[0] == 169, octets[1] == 254 { continue }
            return "\(octets[0]).\(octets[1]).\(octets[2]).\(octets[3])"
        }
        return nil
    }

    /// 本机所在 IPv4 网段前缀（如 "192.168.0"）；取不到返回 nil
    static func subnetPrefix() -> String? {
        guard let ip = firstIPv4() else { return nil }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.dropLast().joined(separator: ".")
    }
}
