import Foundation

/// StreamFlow NAS API 客户端（docs/22 口径：Bearer Key、统一错误信封）
@MainActor
final class APIClient: ObservableObject {
    @Published var lastError: String?

    /// 测试注入（Simulator 集成测试用独立测试环境，不读 UserDefaults）
    private let overrideBase: URL?
    private let overrideKey: String?

    init(base: URL? = nil, apiKey: String? = nil) {
        self.overrideBase = base
        self.overrideKey = apiKey
    }

    private var base: URL? { overrideBase ?? ServerConfig.shared.base }
    private var key: String { overrideKey ?? ServerConfig.shared.apiKey }

    private func request(_ path: String, method: String = "GET",
                         body: Data? = nil, contentType: String = "application/json") -> URLRequest? {
        // path 可含 query（如 "api/v1/media?limit=100"）。appendingPathComponent 会把
        // ?/= 当路径字符百分号编码（实测 GET /api/v1/media%3Flimit%3D100 → 404），
        // 必须用 URLComponents 分离 path 与 query；base 自带路径前缀时保持追加语义。
        guard let base else { return nil }  // 未配置 NAS 地址：由 send 抛出可显示错误，不崩溃
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var p = String(parts[0])
        if !p.hasPrefix("/") { p = "/" + p }
        let basePath = comps.path
        comps.path = (basePath.isEmpty || basePath == "/") ? p : basePath + p
        if parts.count > 1 { comps.query = String(parts[1]) }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body }
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        return req
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }

    private func send<T: Decodable>(_ req: URLRequest?) async throws -> T {
        guard let req else {
            throw APIError.network("未配置 NAS 地址（请在设置页填写后重试）")
        }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch let e as URLError {
            // 网络层错误给出可判读的中文提示（错误地址/不可达/超时/无网络）
            throw APIError.network(Self.describe(e))
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.network("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let env: ErrorEnvelope? = try? decode(data)
            if let env {
                throw APIError.server(env.error.code, env.error.message)
            }
            throw APIError.server("http_\(http.statusCode)", "HTTP \(http.statusCode)")
        }
        return try decode(data)
    }

    // ---- 健康 ----

    func health() async throws {
        struct Health: Codable { let status: String }
        let _: Health = try await send(request("api/v1/health"))
    }

    // ---- 下载任务 ----

    func createHTTP(url: String, savePath: String) async throws -> DownloadTask {
        struct Body: Codable { let url: String; let save_path: String }
        let body = try JSONEncoder().encode(Body(url: url, save_path: savePath))
        return try await send(request("api/v1/downloads", method: "POST", body: body))
    }

    func createMagnet(magnet: String, savePath: String) async throws -> DownloadTask {
        struct Body: Codable { let magnet: String; let save_path: String }
        let body = try JSONEncoder().encode(Body(magnet: magnet, save_path: savePath))
        return try await send(request("api/v1/downloads", method: "POST", body: body))
    }

    func listTasks(state: String? = nil) async throws -> [DownloadTask] {
        struct Page: Codable { let items: [DownloadTask] }
        var path = "api/v1/downloads?limit=50"
        if let state { path += "&state=\(state)" }
        let page: Page = try await send(request(path))
        return page.items
    }

    func pauseTask(_ id: String) async throws {
        struct VoidBody: Codable {}
        let _: DownloadTask = try await send(request("api/v1/downloads/\(id)/pause", method: "POST"))
    }

    func resumeTask(_ id: String) async throws {
        let _: DownloadTask = try await send(request("api/v1/downloads/\(id)/resume", method: "POST"))
    }

    func cancelTask(_ id: String) async throws {
        let _: DownloadTask = try await send(request("api/v1/downloads/\(id)/cancel", method: "POST"))
    }

    func deleteTask(_ id: String, deleteFiles: Bool) async throws {
        var path = "api/v1/downloads/\(id)"
        if deleteFiles { path += "?delete_files=true" }
        let _: EmptyResponse = try await send(request(path, method: "DELETE"))
    }

    // ---- 媒体 ----

    func listMedia() async throws -> [MediaItem] {
        struct Page: Codable { let items: [MediaItem] }
        let page: Page = try await send(request("api/v1/media?limit=100"))
        return page.items
    }

    func registerMedia(path: String) async throws -> MediaItem {
        struct Resp: Codable {
            let media_id: String; let rel_path: String; let name: String
            let size_bytes: Int64; let mime: String; let play_url: String
        }
        struct Body: Codable { let path: String }
        let body = try JSONEncoder().encode(Body(path: path))
        let r: Resp = try await send(request("api/v1/media", method: "POST", body: body))
        return MediaItem(mediaId: r.media_id, relPath: r.rel_path, name: r.name,
                         sizeBytes: r.size_bytes, mime: r.mime, playUrl: r.play_url)
    }

    /// 媒体管理：重命名 / 移动（分类目录）/ 删除 / 目录清单 / SMB 备份
    func renameMedia(_ media: MediaItem, name: String) async throws -> MediaItem {
        struct Body: Codable { let name: String }
        let body = try JSONEncoder().encode(Body(name: name))
        return try await send(request("api/v1/media/\(media.mediaId)/rename",
                                      method: "POST", body: body))
    }

    func moveMedia(_ media: MediaItem, dir: String) async throws -> MediaItem {
        struct Body: Codable { let dir: String }
        let body = try JSONEncoder().encode(Body(dir: dir))
        return try await send(request("api/v1/media/\(media.mediaId)/move",
                                      method: "POST", body: body))
    }

    func deleteMedia(_ media: MediaItem, deleteFile: Bool) async throws {
        struct Resp: Codable { let status: String; let file_deleted: Bool }
        let _: Resp = try await send(request("api/v1/media/\(media.mediaId)?delete_file=\(deleteFile)",
                                             method: "DELETE"))
    }

    func createDir(_ path: String) async throws {
        struct Body: Codable { let path: String }
        struct Resp: Codable { let path: String; let created: Bool }
        let _: Resp = try await send(request("api/v1/media/dirs", method: "POST",
                                             body: try JSONEncoder().encode(Body(path: path))))
    }

    func listDirs() async throws -> [String] {
        struct Resp: Codable { let dirs: [String] }
        let r: Resp = try await send(request("api/v1/media/dirs"))
        return r.dirs
    }

    // SMB 直连已迁移至 SMBService（三功能独立：iOS 不再经 NAS 代连 SMB，
    // SMB 凭据不发送给 NAS 服务端。服务端 /smb/* 保留为其自身 env 配置能力）。

    /// NAS 不可达类 URLError → 可判读中文提示
    private static func describe(_ e: URLError) -> String {
        switch e.code {
        case .cannotFindHost: return "找不到主机（检查 NAS 地址是否正确）"
        case .cannotConnectToHost:
            return "无法连接 NAS（地址/端口错误或服务未启动）"
        case .notConnectedToInternet: return "无可用网络连接"
        case .timedOut: return "连接超时（NAS 无响应）"
        case .networkConnectionLost: return "连接中断"
        case .dnsLookupFailed: return "域名解析失败"
        default: return e.localizedDescription
        }
    }

    func playURL(for media: MediaItem, format: String? = nil) async throws -> String {
        struct Resp: Codable { let play_url: String }
        struct Body: Codable { let media_id: String; let format: String? }
        let body = try JSONEncoder().encode(Body(media_id: media.mediaId, format: format))
        let resp: Resp = try await send(request("api/v1/play-urls", method: "POST", body: body))
        return resp.play_url
    }
}

struct EmptyResponse: Codable {}

struct ErrorEnvelope: Codable {
    struct E: Codable { let code: String; let message: String }
    let error: E
}

enum APIError: LocalizedError {
    case network(String)
    case server(String, String)

    var errorDescription: String? {
        switch self {
        case .network(let detail): return "网络错误：\(detail)"
        case .server(_, let message): return message
        }
    }
}
