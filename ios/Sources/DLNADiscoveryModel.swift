import Foundation

/// SSDP 发现（组播 / 单播探测 / 网段扫描）→ 设备描述解析 → 可投屏设备列表。
///
/// 真机说明：iOS 上**组播**收发需要 multicast entitlement（未授权时组播包被系统
/// 静默丢弃）；**单播**不需要——「网段扫描」与「手动输入 IP」是 entitlement 到位前
/// 真机可用的发现路径。
@MainActor
final class DLNADiscoveryModel: ObservableObject {
    @Published var devices: [DLNADevice] = []
    @Published var searching = false
    @Published var scanStatus: String?
    @Published var errorMessage: String?

    private let engine = SSDPDiscovery()

    /// 组播发现（模拟器/已获 entitlement 的真机）
    func start() {
        searching = true
        errorMessage = nil
        scanStatus = "组播搜索…"
        devices = []
        Task { await run { try await self.engine.discover(timeout: 5) } }
    }

    /// 手动 IP 探测（单播 M-SEARCH，无需 entitlement）
    func probe(host: String) {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        searching = true
        errorMessage = nil
        scanStatus = "探测 \(h)…"
        Task { await run { try await self.engine.discover(unicastTo: h, timeout: 4) } }
    }

    /// 网段扫描（单播批量 /24，无需 entitlement）
    func scanSubnet() {
        guard let prefix = LANAddress.subnetPrefix() else {
            errorMessage = "未获取到本机局域网 IPv4（请确认 Wi-Fi 已连接）"
            return
        }
        searching = true
        errorMessage = nil
        scanStatus = "扫描网段 \(prefix).0/24（约 6 秒）…"
        Task { await run { try await self.engine.discoverSubnet(prefix: prefix, timeout: 6) } }
    }

    func stop() {
        searching = false
    }

    /// 统一执行：发现 → 解析 → 并入设备列表
    private func run(_ discover: @escaping () async throws -> [SSDPDiscovery.Response]) async {
        let responses: [SSDPDiscovery.Response]
        do {
            responses = try await discover()
        } catch {
            searching = false
            scanStatus = nil
            errorMessage = "设备发现失败：\((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            return
        }
        await merge(responses)
        searching = false
        scanStatus = nil
    }

    /// 响应 → 设备（拉取描述 XML；按 USN 去重后并入现有列表——扫描/手动探测与
    /// 组播结果可叠加，不互相清空）
    private func merge(_ responses: [SSDPDiscovery.Response]) async {
        let known = Set(devices.map(\.id))
        var found: [DLNADevice] = []
        for r in responses {
            guard !known.contains(r.usn) else { continue }
            // LOCATION 基础校验：必须是 http(s) 绝对地址且带主机名（R-15 配套）
            guard let url = URL(string: r.location),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host, !host.isEmpty else { continue }
            if let (data, resp) = try? await URLSession.shared.data(from: url),
               let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let xml = String(data: data, encoding: .utf8),
               let device = DeviceDescriptionParser.parse(xml, location: r.location, usn: r.usn) {
                found.append(device)
            }
        }
        devices.append(contentsOf: found)
    }
}
