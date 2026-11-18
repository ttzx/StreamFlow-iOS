import Foundation

/// NAS 连接配置（UserDefaults 持久化；Key 不进 iCloud，仅本机）
@MainActor
final class ServerConfig: ObservableObject {
    static let shared = ServerConfig()

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "sf.baseURL") }
    }
    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "sf.apiKey") }
    }
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
