import Foundation

/// SSDP 发现 → 设备描述解析 → 可投屏设备列表
@MainActor
final class DLNADiscoveryModel: ObservableObject {
    @Published var devices: [DLNADevice] = []
    @Published var searching = false
    @Published var errorMessage: String?

    private let engine = SSDPDiscovery()

    func start() {
        searching = true
        errorMessage = nil
        devices = []
        Task { await run() }
    }

    func stop() {
        searching = false
    }

    private func run() async {
        // R-12 重写版 discover 会抛错（socket/bind/发送失败），如实暴露而不是静默吞掉
        let responses: [SSDPDiscovery.Response]
        do {
            responses = try await engine.discover(timeout: 5)
        } catch {
            searching = false
            errorMessage = "设备发现失败：\(error)"
            return
        }
        var found: [DLNADevice] = []
        for r in responses {
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
        devices = found
        searching = false
    }
}
