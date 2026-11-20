import Foundation

/// SSDP 局域网设备发现（UDP 多播 239.255.255.250:1900）
///
/// R-12 重写版（对照旧实现的缺陷逐项消除）：
/// - 无连接 BSD socket：bind 0.0.0.0:1900（SO_REUSEADDR/REUSEPORT）→ sendto 多播地址 →
///   poll + recvfrom 收设备的单播回复。旧版用 connected UDP（NWConnection 连到多播地址），
///   会把源地址不是多播组的单播回复过滤掉，实际收不到设备响应。
/// - 超时用 poll 截止时间驱动，不依赖 Timer/RunLoop（旧版 Timer 在无 RunLoop 的
///   队列上可能永不触发）。
/// - 没有 DispatchGroup enter/leave 失衡问题；socket 在 defer 中必然关闭（旧版连接从不 cancel）。
/// - 无可变共享状态，类型 Sendable（并发隔离 R-13 口径一致）。
/// - 组播与单播 M-SEARCH 双路径（UPnP 1.1 均合法）：组播为标准发现；单播用于
///   「手动输入电视 IP」回退路径（r5 预留方案），且不触发 iOS 多播 entitlement。
/// - ⚠️ 真机限制（Apple 官方文档 com.apple.developer.networking.multicast）：
///   iOS 上 app **发送或接收**任何 IP 多播/广播都必须持有 multicast entitlement，
///   且需向 Apple 申请审批。模拟器不受此限制（走 macOS 网络栈）；
///   真机多播发现为待决事项，单播路径不受影响。
public final class SSDPDiscovery: Sendable {
    public struct Response: Codable, Sendable, Hashable {
        public let location: String     // 设备描述 XML 地址
        public let st: String           // 服务类型
        public let usn: String
    }

    public enum DiscoveryError: Error, Sendable, Equatable {
        case socketCreationFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case sendFailed(errno: Int32)
        case badTarget(String)
    }

    public static let avtransportST = "urn:schemas-upnp-org:service:AVTransport:1"

    public init() {}

    /// 构造 M-SEARCH 报文（公开以便测试）
    public static func mSearchPacket(st: String = SSDPDiscovery.avtransportST) -> String {
        [
            "M-SEARCH * HTTP/1.1",
            "HOST: 239.255.255.250:1900",
            "MAN: \"ssdp:discover\"",
            "MX: 3",
            "ST: \(st)",
            "", ""
        ].joined(separator: "\r\n")
    }

    /// 解析 SSDP 响应（公开以便测试）；LOCATION 必须是 http(s) 绝对地址（R-12 校验项）
    public static func parseResponse(_ raw: String) -> Response? {
        guard raw.uppercased().contains("HTTP/1.1 200") else { return nil }
        var location: String?, st: String?, usn: String?
        for line in raw.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "LOCATION": location = value
            case "ST", "NT": if st == nil { st = value }
            case "USN": usn = value
            default: break
            }
        }
        guard let loc = location,
              let u = URL(string: loc),
              let scheme = u.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = u.host, !host.isEmpty else { return nil }
        return Response(location: loc, st: st ?? "", usn: usn ?? loc)
    }

    /// 组播发现（标准路径；真机需 multicast entitlement）
    public func discover(timeout: TimeInterval = 5,
                         st: String = SSDPDiscovery.avtransportST) async throws -> [Response] {
        var target = try Self.makeTarget(host: "239.255.255.250", port: 1900)
        return try await Self.run(target: &target, timeout: timeout, st: st)
    }

    /// 单播 M-SEARCH（UPnP 1.1 合法；「手动输入电视 IP」回退路径，无需 entitlement）
    public func discover(unicastTo host: String, port: UInt16 = 1900,
                         timeout: TimeInterval = 5,
                         st: String = SSDPDiscovery.avtransportST) async throws -> [Response] {
        var target = try Self.makeTarget(host: host, port: port)
        return try await Self.run(target: &target, timeout: timeout, st: st)
    }

    // MARK: - 内部实现

    private static func makeTarget(host: String, port: UInt16) throws -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        var sin = in_addr()
        guard inet_pton(AF_INET, host, &sin) == 1 else {
            throw DiscoveryError.badTarget(host)
        }
        addr.sin_addr = sin
        return addr
    }

    private static func run(target: inout sockaddr_in, timeout: TimeInterval,
                            st: String) async throws -> [Response] {
        let deadline = Date().addingTimeInterval(timeout)

        // 1. 建无连接 UDP socket
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw DiscoveryError.socketCreationFailed(errno: errno) }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // 2. bind 0.0.0.0:0（临时端口）：M-SEARCH 的单播回复发回请求源端口；
        //    不要绑 1900——与本机其他 SSDP 监听（如模拟电视 mock）SO_REUSEPORT 冲突时
        //    内核会在两个 socket 间分流，回复会丢（实测 CI）。
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindOK = withUnsafePointer(to: &local) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { throw DiscoveryError.bindFailed(errno: errno) }

        // 3. sendto 目标（两次，间隔 200ms，提升命中率）
        let payload = Array(Self.mSearchPacket(st: st).utf8)
        for _ in 0..<2 {
            let sent = withUnsafePointer(to: &target) { dptr -> Int in
                dptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    payload.withUnsafeBytes { raw in
                        sendto(fd, raw.baseAddress, raw.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent >= 0 else { throw DiscoveryError.sendFailed(errno: errno) }
            if Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(min(0.2, deadline.timeIntervalSinceNow) * 1_000_000_000))
            }
        }

        // 4. 接收循环：poll 剩余时间，收满截止时间为止
        var results: [Response] = []
        var seen = Set<String>()
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remainingMs = Int32(max(1, min(1000, Int(deadline.timeIntervalSinceNow * 1000))))
            let nready = withUnsafeMutablePointer(to: &pfd) { pfptr in
                poll(pfptr, 1, remainingMs)
            }
            guard nready > 0 else { continue }              // 本轮 poll 超时，继续到截止时间
            guard (pfd.revents & Int16(POLLIN)) != 0 else { continue }
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { continue }
            let raw = String(decoding: buf[..<n], as: UTF8.self)
            if let r = Self.parseResponse(raw), seen.insert(r.usn).inserted {
                results.append(r)
            }
        }
        return results
    }
}
