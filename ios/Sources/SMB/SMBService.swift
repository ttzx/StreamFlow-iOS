import Foundation
import CryptoKit
import SMBClient

/// iOS 直连 SMB2/3 客户端服务（基于 SMBClient 库，Network.framework 原生传输）。
///
/// 独立性硬约束：本服务不读 ServerConfig（NAS 配置）、不向 NAS 服务端发起任何
/// 请求、不携带任何 NAS 凭据。SMB 功能在 NAS 服务端离线/API Key 无效时完全可用。
enum SMBServiceError: LocalizedError {
    case notConfigured
    case authFailed
    case shareNotFound
    case accessDenied
    case pathNotFound
    case unreachable(String)
    case timeout
    case integrityMismatch(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "SMB 未配置（请在设置页填写 SMB 服务器地址与共享名）"
        case .authFailed:
            return "SMB 认证失败（检查用户名/密码）"
        case .shareNotFound:
            return "共享不存在（检查共享名）"
        case .accessDenied:
            return "权限不足（远端拒绝访问）"
        case .pathNotFound:
            return "远端路径不存在"
        case .unreachable(let d):
            return "无法连接 SMB 服务器：\(d)"
        case .timeout:
            return "连接超时（SMB 服务器无响应）"
        case .integrityMismatch(let d):
            return "完整性校验失败：\(d)"
        case .other(let d):
            return "SMB 错误：\(d)"
        }
    }
}

/// SMB 目录条目（base 相对）
struct SMBEntry: Identifiable, Hashable {
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let lastWriteTime: Date?
    var id: String { name }
}

actor SMBService {
    static let shared = SMBService()

    private var client: SMBClient?
    private var activeHost: String?
    private var activePort: Int?
    private var activeShare: String?
    private var activeBaseDir: String?

    /// 丢弃当前连接（下次操作重新建连）
    func invalidate() {
        if let c = client {
            c.session.disconnect()
        }
        client = nil
        activeHost = nil
        activePort = nil
        activeShare = nil
        activeBaseDir = nil
    }

    // MARK: - 路径

    private func full(_ base: String, _ rel: String) -> String {
        let parts = [base, rel]
            .flatMap { $0.split(separator: "/").map(String.init) }
            .filter { !$0.isEmpty && $0 != "." }
        return parts.joined(separator: "/")
    }

    // MARK: - 连接

    private func ensureConnected(_ cfg: SMBConfig) async throws -> SMBClient {
        guard cfg.configured else { throw SMBServiceError.notConfigured }
        if let c = client, activeHost == cfg.host, activePort == cfg.portNumber,
           activeShare == cfg.share, activeBaseDir == cfg.baseDir {
            return c
        }
        drop()
        let c = SMBClient(host: cfg.host, port: cfg.portNumber)
        do {
            try await withTimeout(10) {
                try await c.login(username: cfg.username.isEmpty ? nil : cfg.username,
                                  password: cfg.password.isEmpty ? nil : cfg.password)
            }
            try await withTimeout(10) { try await c.connectShare(cfg.share) }
        } catch {
            drop()
            throw SMBService.mapError(error)
        }
        client = c
        activeHost = cfg.host
        activePort = cfg.portNumber
        activeShare = cfg.share
        activeBaseDir = cfg.baseDir
        return c
    }

    private func drop() {
        if let c = client {
            c.session.disconnect()
        }
        client = nil
    }

    private func withTimeout<T>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T)
        async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SMBServiceError.timeout
            }
            guard let first = try await group.next() else {
                throw SMBServiceError.timeout
            }
            group.cancelAll()
            return first
        }
    }

    static func mapError(_ e: Error) -> SMBServiceError {
        if let er = e as? ErrorResponse {
            switch er.header.status {
            case 0xC000_006D, 0xC000_0064: return .authFailed
            case 0xC000_0022: return .accessDenied
            case 0xC000_00CC: return .shareNotFound
            case 0xC000_0034, 0xC000_003A: return .pathNotFound
            default:
                return .other("NTStatus 0x\(String(er.header.status, radix: 16))")
            }
        }
        let text = String(describing: e)
        if text.contains("timed out") || text.contains("timeout") { return .timeout }
        if text.contains("Connection refused") || text.contains("reset by peer")
            || text.contains("host is unreachable") || text.contains("No route to host") {
            return .unreachable(text)
        }
        if e is CancellationError { return .timeout }
        return .other((e as? LocalizedError)?.errorDescription ?? text)
    }

    // MARK: - 操作

    /// 连接测试（登录 + 挂共享 + ECHO 保活）
    func testConnection() async throws {
        let c = try await ensureConnected(SMBConfig.shared)
        do {
            try await withTimeout(10) { try await c.keepAlive() }
        } catch {
            throw SMBService.mapError(error)
        }
    }

    /// 列目录（base 相对路径；过滤 . / ..）
    func list(_ rel: String) async throws -> [SMBEntry] {
        let cfg = SMBConfig.shared
        let c = try await ensureConnected(cfg)
        do {
            let files = try await withTimeout(20) { try await c.listDirectory(path: self.full(cfg.baseDir, rel)) }
            return files
                .filter { $0.name != "." && $0.name != ".." }
                .map { SMBEntry(name: $0.name, isDirectory: $0.isDirectory,
                                size: $0.size, lastWriteTime: $0.lastWriteTime) }
                .sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
        } catch {
            throw SMBService.mapError(error)
        }
    }

    func createDirectory(_ rel: String) async throws {
        let cfg = SMBConfig.shared
        let c = try await ensureConnected(cfg)
        do {
            try await withTimeout(20) { try await c.createDirectory(path: self.full(cfg.baseDir, rel)) }
        } catch {
            throw SMBService.mapError(error)
        }
    }

    func delete(_ rel: String, isDirectory: Bool) async throws {
        let cfg = SMBConfig.shared
        let c = try await ensureConnected(cfg)
        do {
            if isDirectory {
                try await withTimeout(20) { try await c.deleteDirectory(path: self.full(cfg.baseDir, rel)) }
            } else {
                try await withTimeout(20) { try await c.deleteFile(path: self.full(cfg.baseDir, rel)) }
            }
        } catch {
            throw SMBService.mapError(error)
        }
    }

    /// 下载到本机（流式写盘，不占内存）
    func download(_ rel: String, to destination: URL) async throws {
        let cfg = SMBConfig.shared
        let c = try await ensureConnected(cfg)
        let remote = full(cfg.baseDir, rel)
        do {
            try await withTimeout(600) {
                try await c.download(path: remote, localPath: destination, overwrite: true)
            }
        } catch {
            throw SMBService.mapError(error)
        }
    }

    /// 上传文件（流式）+ 读回完整性校验（SHA-256 逐字节比对），返回备份记录
    func uploadVerified(localURL: URL, remoteRel: String, note: String = "") async throws
        -> SMBBackupRecord {
        let cfg = SMBConfig.shared
        let c = try await ensureConnected(cfg)
        let remote = full(cfg.baseDir, remoteRel)
        // 1) 本地 SHA-256
        guard let inStream = try? FileHandle(forReadingFrom: localURL) else {
            throw SMBServiceError.other("本地文件不可读")
        }
        defer { try? inStream.close() }
        var localHasher = SHA256()
        var localSize: UInt64 = 0
        while let chunk = try inStream.read(upToCount: 1 << 20), !chunk.isEmpty {
            localHasher.update(data: chunk)
            localSize += UInt64(chunk.count)
        }
        let localSha = localHasher.finalize().finalizedHex
        // 2) 上传（流式）
        do {
            try await withTimeout(1800) {
                try await c.upload(localPath: localURL, remotePath: remote)
            }
        } catch {
            throw SMBService.mapError(error)
        }
        // 3) 读回校验：证明 SMB 服务端真正落盘的字节与本地一致
        var remoteHasher = SHA256()
        var remoteSize: UInt64 = 0
        var offset: UInt64 = 0
        let reader = c.fileReader(path: remote)
        do {
            while true {
                let data = try await withTimeout(60) {
                    try await reader.read(offset: offset, length: 1 << 20)
                }
                if data.isEmpty { break }
                remoteHasher.update(data: data)
                remoteSize += UInt64(data.count)
                offset += UInt64(data.count)
            }
            try await reader.close()
        } catch {
            throw SMBService.mapError(error)
        }
        let remoteSha = remoteHasher.finalize().finalizedHex
        guard remoteSize == localSize, remoteSha == localSha else {
            throw SMBServiceError.integrityMismatch(
                "本地 \(localSize)B/\(localSha.prefix(12)) vs 远端 \(remoteSize)B/\(remoteSha.prefix(12))")
        }
        return SMBBackupRecord(remotePath: remote, sizeBytes: Int64(remoteSize),
                               sha256: remoteSha, note: note)
    }

    func stat(_ rel: String) async throws -> SMBEntry? {
        let cfg = SMBConfig.shared
        let c = try await ensureConnected(cfg)
        do {
            let s = try await withTimeout(20) { try await c.fileStat(path: self.full(cfg.baseDir, rel)) }
            return SMBEntry(name: rel, isDirectory: s.isDirectory, size: s.size,
                            lastWriteTime: s.lastWriteTime)
        } catch let e as SMBServiceError {
            throw e
        } catch {
            throw SMBService.mapError(error)
        }
    }
}

extension SHA256.Digest {
    var finalizedHex: String { map { String(format: "%02x", $0) }.joined() }
}
