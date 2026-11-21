import SwiftUI

/// DLNA 独立功能页：局域网设备发现（零配置可用，不依赖 NAS/SMB）+ 投屏会话控制。
/// 投放 NAS 媒体需要 NAS 在线（签名播放 URL 由 NAS 签发）；NAS 未配置/离线时
/// 仅「选择媒体」不可用，设备发现与会话控制不受影响。
struct DLNAView: View {
    @StateObject private var discovery = DLNADiscoveryModel()
    @State private var controller = CastController()
    @State private var selectedDevice: DLNADevice?
    @State private var castState: CastController.CastState = .idle
    @State private var position: AVTransport.Position?
    @State private var poller: Task<Void, Never>?
    @State private var error: String?
    @State private var showMediaPicker = false
    @State private var mediaItems: [MediaItem] = []
    @State private var mediaLoading = false
    @State private var mediaError: String?
    @State private var showManualIP = false
    @State private var manualIP = ""

    var body: some View {
        NavigationStack {
            List {
                deviceSection
                sessionSection
            }
            .navigationTitle("DLNA")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { discovery.start() } label: {
                            Label("组播搜索", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        Button { discovery.scanSubnet() } label: {
                            Label("扫描网段（真机推荐）", systemImage: "dot.radiowaves.left.and.right")
                        }
                        Button { showManualIP = true } label: {
                            Label("手动输入电视 IP", systemImage: "number")
                        }
                    } label: {
                        Label("搜索", systemImage: "magnifyingglass")
                    }
                }
            }
            .onAppear { if discovery.devices.isEmpty && !discovery.searching { discovery.start() } }
            .onDisappear { discovery.stop(); poller?.cancel() }
            .sheet(isPresented: $showMediaPicker) { mediaPicker }
            .alert("手动输入电视 IP", isPresented: $showManualIP) {
                TextField("如 192.168.x.x", text: $manualIP)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("探测") { discovery.probe(host: manualIP) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("向该地址发单播 M-SEARCH（无需多播权限）")
            }
        }
    }

    // MARK: - 设备发现（不依赖任何配置）

    private var deviceSection: some View {
        Section("局域网设备") {
            if discovery.devices.isEmpty {
                if discovery.searching {
                    Text(discovery.scanStatus ?? "正在搜索…").foregroundColor(.secondary)
                    ProgressView()
                } else {
                    Text("未发现设备。真机上组播需要 Apple 多播权限，请改用\n「搜索 → 扫描网段」或「手动输入电视 IP」。")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            if let s = discovery.scanStatus, !discovery.devices.isEmpty {
                Text(s).font(.caption).foregroundColor(.secondary)
            }
            ForEach(discovery.devices) { d in
                Button {
                    selectedDevice = d
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.friendlyName).foregroundColor(.primary)
                            Text(d.manufacturer.isEmpty ? d.modelName
                                 : "\(d.manufacturer) · \(d.modelName)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if selectedDevice == d {
                            Image(systemName: "checkmark").foregroundColor(.blue)
                        }
                    }
                }
            }
            if discovery.searching { ProgressView() }
        }
    }

    // MARK: - 投屏会话（数据源需 NAS；控制只走局域网 SOAP）

    private var sessionSection: some View {
        Section("投屏") {
            if let d = selectedDevice {
                Text("目标：\(d.friendlyName)").font(.caption).foregroundColor(.secondary)
                Text(stateText(castState)).font(.headline)
                if let p = position {
                    Text("进度 \(p.trackSeconds)s / \(p.durationSeconds)s")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let e = error { Text(e).foregroundColor(.red).font(.caption) }
                Button {
                    showMediaPicker = true
                    Task { await loadMedia() }
                } label: { Label("选择 NAS 媒体投屏", systemImage: "play.tv") }
                if isControllable {
                    Button("暂停") { Task {
                        if let st = await run({ try await controller.pause() }) {
                            castState = st
                        }
                    } }
                    Button("继续播放") { Task {
                        if let st = await run({ try await controller.resume() }) {
                            castState = st
                            if st == .confirmedPlaying { startPolling() }
                        }
                    } }
                    Button("停止", role: .destructive) { Task {
                        if let st = await run({ try await controller.stop() }) {
                            castState = st
                            if st == .stopped { poller?.cancel(); position = nil }
                        }
                    } }
                }
            } else {
                Text("先在上方选择设备；投屏 NAS 媒体需要 NAS 在线。")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var isControllable: Bool {
        switch castState {
        case .confirmedPlaying, .paused, .uriSent: return true
        default: return false
        }
    }

    // MARK: - NAS 媒体选择（NAS 离线 → 可显示错误，不崩溃）

    private var mediaPicker: some View {
        NavigationStack {
            List {
                if mediaLoading { ProgressView() }
                if let e = mediaError {
                    Text(e).foregroundColor(.red).font(.caption)
                    Text("NAS 未配置或离线时无法列出媒体；可到「设置」页配置 NAS。")
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach(mediaItems) { m in
                    Button {
                        showMediaPicker = false
                        Task { await cast(m) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(m.name).foregroundColor(.primary).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: m.sizeBytes, countStyle: .binary))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "play.circle").foregroundColor(.blue)
                        }
                    }
                }
            }
            .navigationTitle("选择媒体")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showMediaPicker = false }
                }
            }
        }
    }

    private func loadMedia() async {
        mediaLoading = true
        mediaError = nil
        mediaItems = []
        do {
            mediaItems = try await APIClient().listMedia()
        } catch {
            mediaError = "获取媒体列表失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
        mediaLoading = false
    }

    // MARK: - 投放与控制（与媒体页 CastSheet 同一状态机口径）

    private func cast(_ media: MediaItem) async {
        guard let device = selectedDevice else { return }
        error = nil
        position = nil
        castState = .connecting
        do {
            let url = try await APIClient().playURL(for: media)
            let item = CastController.CastMedia(url: url, title: media.name, mimeType: media.mime)
            castState = try await controller.cast(item: item, device: device, httpClient: client())
            if castState == .confirmedPlaying { startPolling() }
        } catch {
            castState = .idle
            self.error = error.localizedDescription
        }
    }

    private func client() -> (String, String, String) async throws -> String {
        let http = DLNADeviceHTTPClient()
        return { url, action, body in try await http.post(url: url, soapAction: action, body: body) }
    }

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
