import Foundation
import Network

/// 视频扩展名 → MIME（投屏中继 Content-Type；也用于判定「可投屏」入口）
enum SMBVideoMime {
    static let map: [String: String] = [
        "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime",
        "mkv": "video/x-matroska", "webm": "video/webm", "ts": "video/mp2t",
        "avi": "video/x-msvideo", "wmv": "video/x-ms-wmv", "flv": "video/x-flv",
        "mpg": "video/mpeg", "mpeg": "video/mpeg", "3gp": "video/3gpp",
    ]

    static func forPath(_ name: String) -> String {
        map[ext(name)] ?? "application/octet-stream"
    }

    static func isVideo(_ name: String) -> Bool {
        map[ext(name)] != nil
    }

    private static func ext(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }
}

/// 本机 HTTP 中继：把 SMB 远端文件流式提供给电视（DLNA 渲染器只会拉 HTTP URL）。
///
/// 设计：支持「选择实际视频文件投放到电视」：
/// - NWListener 随机端口；URL 形如 http://<手机IP>:<port>/media/<token>，
///   token 一次一换（UUID），App 退出/被杀即失效（投屏是前台场景）。
/// - 支持 Range（渲染器普遍分段拉流）：206 + Content-Range；无 Range → 200 全量。
/// - 每连接打开一个 SMB 远端读句柄，按偏移 1MB 块流式写出，不在内存囤积整文件；
///   连接结束（区间发完/对端断开）即关闭句柄。
final class CastRelayServer: @unchecked Sendable {
    static let shared = CastRelayServer()

    struct Session {
        let path: String        // SMB 远端路径（base 相对）
        let size: UInt64
        let mime: String
    }

    private let queue = DispatchQueue(label: "sf.cast.relay")
    private var listener: NWListener?
    private var sessions: [String: Session] = [:]
    private var port: UInt16 = 0
    private let lock = NSLock()

    enum CastRelayError: LocalizedError {
        case startFailed
        case unknownToken
        var errorDescription: String? {
            switch self {
            case .startFailed: return "投屏中继启动失败"
            case .unknownToken: return "投屏会话已失效（请重新发起投屏）"
            }
        }
    }

    /// 启动监听（幂等）；只绑 Wi-Fi 接口（不暴露蜂窝/其他通道），返回实际端口
    func start() async throws -> UInt16 {
        lock.lock()
        if port != 0 {
            let p = port
            lock.unlock()
            return p
        }
        lock.unlock()

        let params = NWParameters.tcp
        params.requiredInterfaceType = .wifi   // 只服务局域网渲染器，不经蜂窝暴露
        let listener = try NWListener(using: params, on: .any)
        let done = DispatchSemaphore(value: 0)
        var started = false
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let p = listener.port?.rawValue {
                    self?.lock.lock()
                    self?.port = p
                    self?.lock.unlock()
                    started = true
                }
                done.signal()
            case .failed:
                done.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        _ = done.wait(timeout: .now() + 5)
        guard started else { throw CastRelayError.startFailed }
        lock.lock()
        let p = port
        lock.unlock()
        return p
    }

    /// 登记要投的 SMB 文件；返回相对 URL 路径 /media/<token>。
    /// 单文件策略：新登记即作废既有会话（同时只服务一个文件）；token 为
    /// UUIDv4（122 位随机，Apple 平台 CSPRNG），不可枚举。
    func register(path: String, size: UInt64, mime: String) -> String {
        let token = UUID().uuidString
        lock.lock()
        sessions.removeAll()
        sessions[token] = Session(path: path, size: size, mime: mime)
        lock.unlock()
        return "/media/\(token)"
    }

    /// 停止中继：清空全部会话并关闭监听（投屏结束/页面关闭时调用；
    /// App 退出由进程销毁兜底）。
    func stop() {
        lock.lock()
        sessions.removeAll()
        let l = listener
        listener = nil
        port = 0
        lock.unlock()
        l?.cancel()
    }

    /// 拼投屏 URL（手机当前局域网 IP）
    func url(for relativePath: String) -> String? {
        guard let ip = LANAddress.firstIPv4(), port != 0 else { return nil }
        return "http://\(ip):\(port)\(relativePath)"
    }

    // MARK: - 连接处理

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequestHead(connection, buffer: Data())
    }

    private func receiveRequestHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                self.dispatch(connection, head: head)
            } else if buf.count > 64 * 1024 || isComplete {
                connection.cancel()   // 异常请求头
            } else {
                self.receiveRequestHead(connection, buffer: buf)
            }
        }
    }

    /// 解析请求头 → 取会话 → 开读句柄 → 响应并流式发送
    private func dispatch(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, requestLine.hasPrefix("GET") else {
            respondHead(connection, status: "400 Bad Request", extra: [:], length: 0)
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        let token = parts.count > 1
            ? parts[1].replacingOccurrences(of: "/media/", with: "")
            : ""
        lock.lock()
        let session = sessions[token]
        lock.unlock()
        guard let s = session else {
            respondHead(connection, status: "404 Not Found", extra: [:], length: 0)
            connection.cancel()
            return
        }
        // Range: bytes=a-b（渲染器分段拉流的主形态）；无 Range = 200 全量
        var start: UInt64 = 0
        var end: UInt64 = s.size == 0 ? 0 : s.size - 1
        var partial = false
        for line in lines where line.lowercased().hasPrefix("range:") {
            let value = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("bytes=") {
                let spec = value.dropFirst(6)
                let segs = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                if let a = segs.first, let s0 = UInt64(a) {
                    start = min(s0, s.size == 0 ? 0 : s.size - 1)
                    partial = true
                }
                if segs.count == 2, let b = UInt64(segs[1]) {
                    end = min(b, s.size == 0 ? 0 : s.size - 1)
                }
            }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                // 读句柄每连接一个，整条连接复用（避免每块重开远端文件）
                let reader = try await SMBService.shared.openRelayReader(s.path)
                var extra: [String: String] = [
                    "Content-Type": s.mime,
                    "Accept-Ranges": "bytes",
                    "Connection": "close",
                ]
                if partial {
                    extra["Content-Range"] = "bytes \(start)-\(end)/\(s.size)"
                }
                let length = end >= start ? Int(clamping: end - start + 1) : 0
                self.respondHead(connection, status: partial ? "206 Partial Content" : "200 OK",
                                 extra: extra, length: length)
                await self.streamBody(connection, reader: reader,
                                      offset: start, end: end)
            } catch {
                connection.cancel()
            }
        }
    }

    private func respondHead(_ connection: NWConnection, status: String,
                             extra: [String: String], length: Int) {
        var head = "HTTP/1.1 \(status)\r\n"
        extra.forEach { head += "\($0): \($1)\r\n" }
        head += "Content-Length: \(length)\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    }

    /// 流式发送：SMB 远端 1MB 块 → 连接，直到区间末尾或对端断开
    private func streamBody(_ connection: NWConnection,
                            reader: SMBService.RelayReader,
                            offset: UInt64, end: UInt64) {
        guard offset <= end else {
            Task { await reader.close() }
            connection.cancel()   // 区间完成
            return
        }
        let chunk: UInt32 = offset + 1_000_000 > end
            ? UInt32(end - offset + 1) : 1_000_000
        Task { [weak self] in
            do {
                let data = try await reader.read(offset: offset, length: chunk)
                if data.isEmpty {
                    await reader.close()
                    connection.cancel()
                    return
                }
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self, error == nil else {
                        Task { await reader.close() }
                        connection.cancel()
                        return
                    }
                    self.streamBody(connection, reader: reader,
                                    offset: offset + UInt64(data.count), end: end)
                })
            } catch {
                await reader.close()
                connection.cancel()
            }
        }
    }
}
