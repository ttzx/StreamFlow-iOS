import AVKit
import SwiftUI

/// 媒体库页：浏览 NAS 媒体 + 内置播放 + 投屏入口
struct MediaView: View {
    @StateObject private var api = APIClient()
    @State private var items: [MediaItem] = []
    @State private var playing: MediaItem?
    @State private var casting: MediaItem?
    @State private var errorMessage: String?
    @State private var renaming: MediaItem?
    @State private var renameText = ""
    @State private var moving: MediaItem?
    @State private var confirmDelete: MediaItem?
    @State private var smbMessage = ""
    @State private var smbAlertShown = false
    @State private var smbBrowsing: MediaItem?

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }
    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
    }
    private var smbAlertBinding: Binding<Bool> {
        Binding(get: { smbAlertShown }, set: { smbAlertShown = $0 })
    }
    private var smbTitle: String {
        if smbMessage.hasPrefix("备份成功") { return "备份完成" }
        if smbMessage.hasPrefix("请先") { return "SMB 未配置" }
        return "备份失败"
    }

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
                        .contextMenu {
                            Button { renaming = item; renameText = item.name } label: {
                                Label("重命名", systemImage: "pencil") }
                            Button { moving = item } label: {
                                Label("移动/分类", systemImage: "folder") }
                            Button { Task { await startSMBBackup(item) } } label: {
                                Label("备份到 SMB", systemImage: "cloud.upload") }
                            Divider()
                            Button(role: .destructive) { confirmDelete = item } label: {
                                Label("删除", systemImage: "trash") }
                        }
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
            .sheet(item: $moving) { media in
                MoveSheet(api: api, media: media) { Task { await load() } }
            }
            .alert("重命名", isPresented: renameBinding, presenting: renaming) { item in
                TextField("新名称", text: $renameText)
                Button("确定") { Task { await doRename(item) } }
                Button("取消", role: .cancel) {}
            } message: { _ in Text("输入新的文件名（可省略扩展名）") }
            .confirmationDialog("删除媒体", isPresented: deleteDialogBinding,
                                titleVisibility: .visible, presenting: confirmDelete) { item in
                Button("仅解除登记（保留文件）", role: .destructive) {
                    Task { await doDelete(item, deleteFile: false) }
                }
                Button("删除文件（不可恢复）", role: .destructive) {
                    Task { await doDelete(item, deleteFile: true) }
                }
                Button("取消", role: .cancel) {}
            } message: { item in Text(item.name) }
            .alert(smbTitle, isPresented: smbAlertBinding) {
                Button("好", role: .cancel) {}
            } message: { Text(smbMessage) }
            .sheet(item: $smbBrowsing) { media in
                // 备份目标经 SMB 直连浏览选择（不经 NAS；SMB 凭据只在本机使用）
                SMBDirPickerSheet { target in
                    Task { await backupNASMediaToSMB(media, dir: target) }
                }
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

    // ---- 媒体管理（重命名/移动/删除/SMB 备份） ----

    /// SMB 备份入口（NAS 媒体 → SMB）：SMB 目标直连浏览；凭据只在本机使用
    private func startSMBBackup(_ item: MediaItem) async {
        guard SMBConfig.shared.configured else {
            smbMessage = "请先在「设置」页配置 SMB 服务器（独立于 NAS）"
            smbAlertShown = true
            return
        }
        smbBrowsing = item
    }

    /// NAS 媒体 → SMB 管道：需要 NAS 在线（数据来源）+ SMB 可达；
    /// SMB 凭据不发给 NAS，NAS 故障不影响 SMB 独立功能
    private func backupNASMediaToSMB(_ media: MediaItem, dir: String) async {
        do {
            let record = try await SMBMediaBackup.run(api: api, media: media, remoteDir: dir)
            SMBBackupRegistry.shared.add(record)
            smbMessage = "备份成功：\(record.remotePath)（\(ByteCountFormatter.string(fromByteCount: record.sizeBytes, countStyle: .binary))，SHA-256 校验一致）"
            smbAlertShown = true
            await load()
        } catch {
            smbMessage = "备份失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            smbAlertShown = true
        }
    }

    private func doRename(_ item: MediaItem) async {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            _ = try await api.renameMedia(item, name: name)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func doDelete(_ item: MediaItem, deleteFile: Bool) async {
        do {
            try await api.deleteMedia(item, deleteFile: deleteFile)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    // NAS 媒体 → SMB 备份已改为手机端管道（SMBMediaBackup），SMB 凭据不出本机
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
    @State private var showManualIP = false
    @State private var manualIP = ""

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
                        if discovery.searching {
                            Text(discovery.scanStatus ?? "正在搜索…").foregroundColor(.secondary)
                            ProgressView()
                        } else {
                            Text("未发现设备。用「扫描网段」或「手动输入 IP」查找电视（真机组播需 Apple 权限）。")
                                .font(.caption).foregroundColor(.secondary)
                        }
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
                    HStack {
                        Button("组播搜索") { discovery.start() }
                        Spacer()
                        Button("扫描网段") { discovery.scanSubnet() }
                        Spacer()
                        Button("手动输入 IP") { showManualIP = true }
                    }
                }
            }
            .navigationTitle("投屏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { discovery.stop(); poller?.cancel(); dismiss() }
                }
            }
            .onAppear { if discovery.devices.isEmpty && !discovery.searching { discovery.start() } }
            .onDisappear { discovery.stop(); poller?.cancel() }
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

/// 移动/分类 sheet：选择现有目录或新建目录（目录即分类）
struct MoveSheet: View {
    let api: APIClient
    let media: MediaItem
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var dirs: [String] = []
    @State private var selected: String?
    @State private var newDir = ""
    @State private var error: String?
    @State private var moving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("目标目录") {
                    Button { selected = "" } label: {
                        HStack {
                            Text("根目录（不分类）").foregroundColor(.primary)
                            if selected == "" { Spacer(); Image(systemName: "checkmark").foregroundColor(.blue) }
                        }
                    }
                    ForEach(dirs, id: \.self) { d in
                        Button { selected = d } label: {
                            HStack {
                                Text(d).foregroundColor(.primary)
                                if selected == d { Spacer(); Image(systemName: "checkmark").foregroundColor(.blue) }
                            }
                        }
                    }
                    if let s = selected {
                        Text("将移动到：\(s.isEmpty ? "根目录" : s)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Section("新建目录（可含子路径，如 电影/2026）") {
                    TextField("目录名", text: $newDir)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("创建目录") { Task { await createDir() } }
                }
                Section {
                    Button("移动") { Task { await move() } }.disabled(moving)
                    if moving { ProgressView() }
                    if let e = error { Text(e).foregroundColor(.red).font(.caption) }
                }
            }
            .navigationTitle("移动/分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { await loadDirs() }
        }
    }

    private func loadDirs() async {
        dirs = (try? await api.listDirs()) ?? []
    }

    private func createDir() async {
        let p = newDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        do { try await api.createDir(p); dirs.append(p); newDir = "" } catch {
            self.error = error.localizedDescription
        }
    }

    private func move() async {
        moving = true; error = nil
        do {
            _ = try await api.moveMedia(media, dir: selected ?? "")
            onDone()
            dismiss()
        } catch { self.error = error.localizedDescription }
        moving = false
    }
}

