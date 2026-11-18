import Foundation

/// DLNA 投屏会话控制器
/// 状态机明确区分"指令已发送"与"设备确认播放"，不显示虚假的投屏成功。
/// R-13：改为 actor——原 @unchecked Sendable 下 state/device/item/memoryStore 均无同步保护，
/// 并发调用会数据竞争；actor 隔离后所有状态访问天然串行。
public actor CastController {
    public enum CastState: Equatable, Sendable {
        case idle
        case connecting
        case uriSent                    // 指令发送成功，但设备未确认
        case confirmedPlaying           // GetTransportInfo = PLAYING
        case paused
        case stopped
        case error(String)
    }

    public struct CastError: Error, Sendable {
        public let kind: Kind
        public enum Kind: String, Sendable {
            case incompatible          // 兼容性预检不通过
            case deviceUnresponsive    // 设备无响应/超时
            case requestFailed         // SOAP 请求失败
            case notPlaying            // 指令成功但设备未确认播放
        }
        public let detail: String
    }

    public private(set) var state: CastState = .idle
    public private(set) var device: DLNADevice?
    public private(set) var item: CastMedia?

    /// 常用设备记忆（P6 接入 SwiftData；当前内存版）
    var memoryStore: [DLNADevice] = []

    public init() {}

    // MARK: 投屏目标（V2：NAS 签发 URL 零请求头，恒可直连，r5 §3.2）
    public struct CastMedia: Equatable, Sendable {
        public let url: String        // NAS 签名播放 URL（绝对地址）
        public let title: String
        public let mimeType: String   // video/mp4 或 application/vnd.apple.mpegurl
        public init(url: String, title: String, mimeType: String) {
            self.url = url; self.title = title; self.mimeType = mimeType
        }
    }

    public struct Precheck: Equatable, Sendable {
        public let ok: Bool
        public let needsConfirm: Bool
        public let reason: String?
    }

    public static func precheck(_ item: CastMedia) -> Precheck {
        // V2 播放地址由 NAS 签发：无需 Referer/Cookie，电视零请求头直连（r5 §3.2/§3.9）
        Precheck(ok: true, needsConfirm: false, reason: nil)
    }

    // MARK: 投屏流程（网络层，真机验证）
    public func cast(item: CastMedia, device: DLNADevice,
                     httpClient: @escaping (String, String, String) async throws -> String)
        async throws -> CastState {
        let pre = Self.precheck(item)
        guard pre.ok else {
            state = .error("incompatible")
            throw CastError(kind: .incompatible, detail: pre.reason ?? "不兼容")
        }
        state = .connecting
        self.device = device
        self.item = item

        // 1. SetAVTransportURI
        let mime = mimeType(for: item)
        let setBody = AVTransport.setURIEnvelope(url: item.url, mimeType: mime, title: item.title)
        do {
            _ = try await httpClient(device.controlURL,
                                     AVTransport.soapActionHeader(action: .setAVTransportURI),
                                     setBody)
        } catch {
            state = .error("requestFailed")
            throw CastError(kind: .requestFailed, detail: "发送媒体地址失败：\(error)")
        }

        // 2. Play
        do {
            _ = try await httpClient(device.controlURL,
                                     AVTransport.soapActionHeader(action: .play),
                                     AVTransport.playEnvelope())
        } catch {
            state = .error("requestFailed")
            throw CastError(kind: .requestFailed, detail: "发送播放指令失败：\(error)")
        }
        state = .uriSent

        // 3. 确认：轮询 GetTransportInfo（3 次 × 2s）
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                let xml = try await httpClient(device.controlURL,
                                               AVTransport.soapActionHeader(action: .getTransportInfo),
                                               AVTransport.soapEnvelope(action: .getTransportInfo))
                if AVTransport.parseTransportInfo(xml) == .playing {
                    state = .confirmedPlaying
                    memoryStore.append(device)
                    return state
                }
            } catch {
                // 轮询失败继续重试
            }
        }
        // 指令成功但设备没确认 —— 如实报告，不显示虚假成功
        state = .error("notPlaying")
        throw CastError(kind: .notPlaying,
                        detail: "指令已发送，但电视未确认开始播放。请在电视端查看，或更换其他地址重试。")
    }

    public func pause() async throws -> CastState {
        guard let device else { return state }
        _ = try await soapPost(device, action: .pause, body: AVTransport.soapEnvelope(action: .pause))
        state = .paused
        return state
    }

    /// 继续播放：重发 Play 并做确认（状态机口径与 cast 一致：确认后才回 confirmedPlaying）
    @discardableResult
    public func resume() async throws -> CastState {
        guard let device else { return state }
        _ = try await soapPost(device, action: .play, body: AVTransport.playEnvelope())
        state = .uriSent
        for _ in 0..<2 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let xml = try? await soapPost(device, action: .getTransportInfo,
                                          body: AVTransport.soapEnvelope(action: .getTransportInfo))
            if let xml, AVTransport.parseTransportInfo(xml) == .playing {
                state = .confirmedPlaying
                return state
            }
        }
        return state
    }

    public func stop() async throws -> CastState {
        guard let device else { return state }
        _ = try await soapPost(device, action: .stop, body: AVTransport.soapEnvelope(action: .stop))
        state = .stopped
        return state
    }

    /// 轮询进度（仅 App 在前台时；退出 App 后自然停止，电视继续播放）
    public func pollPosition(httpClient: @escaping (String, String, String) async throws -> String)
        async -> AVTransport.Position? {
        guard let device else { return nil }
        do {
            let xml = try await httpClient(device.controlURL,
                                           AVTransport.soapActionHeader(action: .getPositionInfo),
                                           AVTransport.soapEnvelope(action: .getPositionInfo))
            return AVTransport.parsePositionInfo(xml)
        } catch { return nil }
    }

    /// A4 合并：原 fakelessPost→httpClientSyncWrap→httpPost 三层包装收敛为一次 AVTransport.post。
    /// 错误映射保持原语义：URL 无效 → "URL 无效"；非 2xx → "HTTP <code>"；传输错误原样抛出。
    private func soapPost(_ device: DLNADevice, action: AVTransport.Action,
                          body: String) async throws -> String {
        do {
            return try await AVTransport.post(device.controlURL,
                                              action: AVTransport.soapActionHeader(action: action),
                                              body: body)
        } catch let e as AVTransport.SOAPPostError {
            switch e {
            case .invalidURL: throw CastError(kind: .requestFailed, detail: "URL 无效")
            case .httpStatus(let code): throw CastError(kind: .requestFailed, detail: "HTTP \(code)")
            }
        }
    }

    func mimeType(for item: CastMedia) -> String { item.mimeType }
}