import AVKit
import SwiftUI

/// 媒体库页：浏览 NAS 媒体 + 内置播放 + 投屏入口
struct MediaView: View {
    @StateObject private var api = APIClient()
    @State private var items: [MediaItem] = []
    @State private var playing: MediaItem?
    @State private var casting: MediaItem?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let e = errorMessage {
                    Text(e).foregroundColor(.red).font(.caption)
                }
                if items.isEmpty {
                    Text("暂无媒体（下载完成或手动登记后出现）").foregroundColor(.secondary)
                }
                ForEach(items) { item in
                    MediaRow(item: item,
                             onPlay: { Task { await play(item) } },
                             onCast: { casting = item })
                }
            }
            .navigationTitle("媒体库")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("刷新") { Task { await load() } }
                }
            }
            .task { await load() }
            .sheet(item: $playing) { media in
                PlayerView(api: api, media: media)
            }
            .sheet(item: $casting) { media in
                CastSheet(api: api, media: media)
            }
        }
    }

    private func load() async {
        do {
            items = try await api.listMedia()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func play(_ item: MediaItem) async {
        do {
            let url = try await api.playURL(for: item)
            var fresh = item
            // 播放地址可能变更（每次请求新签名），用最新 URL 播放
            fresh = MediaItem(
                mediaId: item.mediaId, relPath: item.relPath, name: item.name,
                sizeBytes: item.sizeBytes, mime: item.mime, playUrl: url)
            playing = fresh
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MediaRow: View {
    let item: MediaItem
    let onPlay: () -> Void
    let onCast: () -> Void

    var body: some View {
        HStack {
            Image(systemName: item.mime.contains("mpegurl") ? "tv" : "video")
                .foregroundColor(.blue)
            VStack(alignment: .leading) {
                Text(item.name).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .binary))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("播放", action: onPlay).buttonStyle(.bordered).font(.caption)
            Button("投屏", action: onCast).buttonStyle(.bordered).font(.caption)
        }
    }
}

/// 内置播放器（AVPlayer；签名 URL 由服务端签发，零请求头）
struct PlayerView: View {
    let api: APIClient
    let media: MediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Button("关闭") { dismiss() }
                    .padding(12)
            }
            .onAppear {
                if let url = URL(string: media.playUrl) {
                    player = AVPlayer(url: url)
                    player?.play()
                }
            }
            .onDisappear { player?.pause(); player = nil }
    }
}

/// 投屏 sheet：DLNA 发现 + 选择设备 + 投放/控制 + 状态/进度（轮询 GetPositionInfo）
struct CastSheet: View {
    let api: APIClient
    let media: MediaItem
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = DLNADiscoveryModel()
    @State private var controller = CastController()
    @State private var castState: String = "未投屏"
    @State private var position: AVTransport.Position?
    @State private var poller: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section("状态") {
                    Text(castState).font(.headline)
                    if let p = position {
                        Text("进度 \(p.trackSeconds)s / \(p.durationSeconds)s")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if let e = error { Text(e).foregroundColor(.red).font(.caption) }
                }
                if castState == "电视已确认播放" || castState == "已暂停" || castState == "指令已发送" {
                    Section("控制") {
                        Button("暂停") { Task {
                            if let st = await run({ try await controller.pause() }) { castState = stateText(st) }
                        } }
                        Button("继续播放") { Task {
                            if let st = await run({ try await controller.resume() }) {
                                castState = stateText(st)
                                if st == .confirmedPlaying { startPolling() }
                            }
                        } }
                        Button("停止", role: .destructive) { Task {
                            if let st = await run({ try await controller.stop() }) {
                                castState = stateText(st)
                                if st == .stopped { poller?.cancel(); position = nil }
                            }
                        } }
                    }
                }
                Section("局域网设备") {
                    if discovery.devices.isEmpty {
                        Text(discovery.searching ? "正在搜索…" : "未发现设备。点击下方按钮重新搜索。")
                            .foregroundColor(.secondary)
                    }
                    ForEach(discovery.devices) { device in
                        Button {
                            Task { await cast(to: device) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(device.friendlyName)
                                Text(device.manufacturer.isEmpty ? device.modelName
                                     : "\(device.manufacturer) · \(device.modelName)")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    Button("重新搜索") { discovery.start() }
                }
            }
            .navigationTitle("投屏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { discovery.stop(); poller?.cancel(); dismiss() }
                }
            }
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop(); poller?.cancel() }
        }
    }

    /// DLNA SOAP 直连闭包（局域网设备，非 NAS API）
    private func client() -> (String, String, String) async throws -> String {
        let http = DLNADeviceHTTPClient()
        return { url, action, body in try await http.post(url: url, soapAction: action, body: body) }
    }

    /// 统一执行：成功返回状态机结果，失败置 error 并返回 nil
    private func run(_ op: @escaping () async throws -> CastController.CastState)
        async -> CastController.CastState? {
        error = nil
        do { return try await op() } catch { self.error = error.localizedDescription; return nil }
    }

    private func stateText(_ s: CastController.CastState) -> String {
        switch s {
        case .confirmedPlaying: return "电视已确认播放"
        case .paused: return "已暂停"
        case .stopped: return "已停止"
        case .uriSent: return "指令已发送"
        case .connecting: return "连接中…"
        case .idle: return "未投屏"
        case .error(let e): return "错误：\(e)"
        }
    }

    private func cast(to device: DLNADevice) async {
        error = nil
        position = nil
        castState = "获取播放地址…"
        do {
            let url = try await api.playURL(for: media)
            let target = CastController.CastMedia(url: url, title: media.name, mimeType: media.mime)
            castState = "发送投屏指令…"
            let c = client()
            let state = try await controller.cast(item: target, device: device) { url, action, body in
                try await c(url, action, body)
            }
            switch state {
            case .confirmedPlaying:
                castState = stateText(state)
                startPolling()
            case .uriSent:
                castState = stateText(state)
            default:
                castState = stateText(state)
            }
        } catch {
            castState = "投屏失败"
            self.error = error.localizedDescription
        }
    }

    /// 状态/进度轮询：每 2s GetPositionInfo（仅 sheet 存活期间）
    private func startPolling() {
        poller?.cancel()
        let c = client()
        poller = Task {
            while !Task.isCancelled {
                position = await controller.pollPosition(httpClient: c)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

/// DLNA 设备直连 HTTP（局域网，与 NAS API 分离）
struct DLNADeviceHTTPClient {
    func post(url: String, soapAction: String, body: String) async throws -> String {
        guard let u = URL(string: url) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue(soapAction, forHTTPHeaderField: "SOAPACTION")
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
