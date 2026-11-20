import Foundation

/// NAS 连接配置（UserDefaults 持久化；Key 不进 iCloud，仅本机）。
/// SMB 直连配置已拆分至 SMBConfig（三功能独立：SMB 不依赖 NAS，反之亦然）。
@MainActor
final class ServerConfig: ObservableObject {
    static let shared = ServerConfig()

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "sf.baseURL") }
    }
    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "sf.apiKey") }
    }
    // SMB 直连配置见 SMBConfig（三功能独立架构：SMB 与 NAS 互不依赖）
    var isValid: Bool {
        guard let url = URL(string: baseURL), url.scheme == "http" || url.scheme == "https" else { return false }
        return !apiKey.isEmpty
    }

    private init() {
        baseURL = UserDefaults.standard.string(forKey: "sf.baseURL") ?? ""
        apiKey = UserDefaults.standard.string(forKey: "sf.apiKey") ?? ""
    }

    var base: URL? { URL(string: baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL) }
}
