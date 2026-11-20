import SwiftUI
import UniformTypeIdentifiers

/// SMB 独立功能页：iPhone 直连用户指定的 SMB 服务器（不经 NAS 服务端，互不依赖）。
/// 连接、认证、浏览、下载、上传（读回校验）、删除、备份记录全部在本机完成。
struct SMBView: View {
    @ObservedObject private var config = SMBConfig.shared
    @ObservedObject private var registry = SMBBackupRegistry.shared
    @State private var path = ""
    @State private var entries: [SMBEntry] = []
    @State private var busy = false
    @State private var status: String?
    @State private var error: String?
    @State private var testing = false
    @State private var showImporter = false
    @State private var showRecords = false
    @State private var creatingDir = false
    @State private var newDirName = ""
    @State private var detailFile: SMBEntry?

    var body: some View {
        NavigationStack {
            Group {
                if !config.configured {
                    unconfigured
                } else {
                    browser
                }
            }
            .navigationTitle("SMB")
        }
    }

    private var unconfigured: some View {
        ContentUnavailableView {
            Label("SMB 未配置", systemImage: "externaldrive.badge.wifi")
        } description: {
            Text("在「设置」页填写 SMB 服务器地址、端口、共享名与凭据。\nSMB 与 NAS 互不依赖：无需 NAS 在线，凭据只保存在本机。")
        }
    }

    private var browser: some View {
        List {
            Section {
                Text(config.summary).font(.caption).foregroundColor(.secondary)
                if let s = status { Text(s).font(.caption).foregroundColor(.green) }
                if let e = error { Text(e).foregroundColor(.red).font(.caption) }
            }
            Section("当前位置：\(path.isEmpty ? "共享根目录" : path)") {
                if busy && entries.isEmpty { ProgressView() }
                if !path.isEmpty {
                    Button {
                        Task { path = parentOf(path); await refresh() }
                    } label: { Label("⬆️ 上一级", systemImage: "arrow.turn.up.left") }
                }
                ForEach(entries) { e in
                    row(e)
                }
                if entries.isEmpty && !busy {
                    Text("（空目录）").foregroundColor(.secondary).font(.caption)
                }
            }
        }
        .refreshable { await refresh() }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { showRecords = true } label: { Label("备份记录", systemImage: "list.bullet.rectangle") }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { creatingDir = true } label: { Label("新建目录", systemImage: "folder.badge.plus") }
                Button { showImporter = true } label: { Label("上传", systemImage: "square.and.arrow.up") }
                Button { Task { await refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
        }
        .task(id: path) { await refresh() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await handleImport(urls) }
            }
        }
        .alert("新建目录（当前目录下）", isPresented: $creatingDir) {
            TextField("目录名", text: $newDirName)
            Button("创建") { Task { await createDir() } }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showRecords) { SMBRecordsSheet() }
        .sheet(item: $detailFile) { e in
            SMBFileDetailSheet(path: child(path, e.name), entry: e) { await refresh() }
        }
    }

    private func row(_ e: SMBEntry) -> some View {
        Button {
            if e.isDirectory {
                path = child(path, e.name)
            } else {
                detailFile = e
            }
        } label: {
            HStack {
                Image(systemName: e.isDirectory ? "folder.fill" : "doc")
                    .foregroundColor(e.isDirectory ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.name).foregroundColor(.primary).lineLimit(1)
                    if !e.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .binary))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await delete(e) }
            } label: { Label("删除", systemImage: "trash") }
        }
    }

    // MARK: - 动作

    private func refresh() async {
        guard config.configured else { return }
        busy = true
        error = nil
        do {
            entries = try await SMBService.shared.list(path)
            status = "已连接：\(config.summary)"
        } catch {
            entries = []
            status = nil
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        busy = false
    }

    private func handleImport(_ urls: [URL]) async {
        busy = true
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let record = try await SMBService.shared.uploadVerified(
                    localURL: url, remoteRel: child(path, url.lastPathComponent), note: "本机上传")
                SMBBackupRegistry.shared.add(record)
                status = "已上传并校验：\(url.lastPathComponent)（SHA-256 一致）"
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        busy = false
        await refresh()
    }

    private func delete(_ e: SMBEntry) async {
        do {
            try await SMBService.shared.delete(child(path, e.name), isDirectory: e.isDirectory)
            await refresh()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func createDir() async {
        let name = newDirName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try await SMBService.shared.createDirectory(child(path, name))
            newDirName = ""
            await refresh()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func child(_ base: String, _ name: String) -> String {
        base.isEmpty ? name : base + "/" + name
    }

    private func parentOf(_ p: String) -> String {
        guard let idx = p.lastIndex(of: "/") else { return "" }
        return String(p[..<idx])
    }
}

/// SMB 文件详情：下载到本机（文件 App 可见）
private struct SMBFileDetailSheet: View {
    let path: String
    let entry: SMBEntry
    var onDone: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section("文件") {
                    Text(entry.name)
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .binary)) · \(path)")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section {
                    Button {
                        Task { await download() }
                    } label: { Label("下载到本机（文件 App 可见）", systemImage: "square.and.arrow.down") }
                        .disabled(busy)
                    if busy { ProgressView() }
                    if let m = message { Text(m).font(.caption).foregroundColor(.green) }
                    if let e = error { Text(e).foregroundColor(.red).font(.caption) }
                }
            }
            .navigationTitle("SMB 文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }

    private func download() async {
        busy = true
        error = nil
        message = nil
        do {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(entry.name)
            try await SMBService.shared.download(path, to: dest)
            message = "已保存到：文件 App → StreamFlow → Downloads/\(entry.name)"
            await onDone()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        busy = false
    }
}

/// 备份记录（本机登记）：远端路径/大小/SHA-256/时间
struct SMBRecordsSheet: View {
    @ObservedObject private var registry = SMBBackupRegistry.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if registry.records.isEmpty {
                    Text("暂无备份记录").foregroundColor(.secondary)
                }
                ForEach(registry.records) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.remotePath).font(.subheadline).lineLimit(2)
                        Text("\(ByteCountFormatter.string(fromByteCount: r.sizeBytes, countStyle: .binary)) · SHA-256 \(r.sha256.prefix(12))… · \(r.createdAt.formatted())\(r.note.isEmpty ? "" : " · \(r.note)")")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            registry.remove(r)
                        } label: { Label("移除记录", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle("SMB 备份记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

/// 目录选择（SMB 备份目标）：直连浏览，供媒体页「备份到 SMB」选目标目录
struct SMBDirPickerSheet: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var dirs: [SMBEntry] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section("当前位置") {
                    Text(path.isEmpty ? "共享根目录" : path).font(.headline)
                }
                Section("目录") {
                    if !path.isEmpty {
                        Button {
                            Task { await browse(parentOf(path)) }
                        } label: { Label("⬆️ 上一级", systemImage: "arrow.turn.up.left") }
                    }
                    ForEach(dirs) { d in
                        Button {
                            Task { await browse(child(path, d.name)) }
                        } label: { Label(d.name, systemImage: "folder").foregroundColor(.primary) }
                    }
                    if dirs.isEmpty && !busy {
                        Text("（无子目录）").foregroundColor(.secondary).font(.caption)
                    }
                }
                Section {
                    Button("备份到此处") { onPick(path); dismiss() }.disabled(busy)
                    if busy { ProgressView() }
                    if let e = error { Text(e).foregroundColor(.red).font(.caption) }
                }
            }
            .navigationTitle("选择 SMB 目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { await browse(path) }
        }
    }

    private func browse(_ dir: String) async {
        error = nil
        do {
            dirs = try await SMBService.shared.list(dir).filter { $0.isDirectory }
            path = dir
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func child(_ base: String, _ name: String) -> String {
        base.isEmpty ? name : base + "/" + name
    }

    private func parentOf(_ p: String) -> String {
        guard let idx = p.lastIndex(of: "/") else { return "" }
        return String(p[..<idx])
    }
}

/// NAS 媒体 → SMB 备份管道：NAS 下载（签名 URL）→ 本机临时文件 → SMB 直连上传（读回校验）。
/// SMB 凭据只在本机使用，不发送给 NAS；该动作需要 NAS 在线（数据来源），
/// 但 SMB 独立功能（浏览/读写/备份本机文件）不依赖 NAS。
enum SMBMediaBackup {
    static func run(api: APIClient, media: MediaItem, remoteDir: String) async throws
        -> SMBBackupRecord {
        // 1) NAS 签名播放 URL（零请求头）
        let url: URL
        do {
            let play = try await api.playURL(for: media)
            guard let parsed = URL(string: play) else {
                throw SMBServiceError.other("NAS 返回的播放地址无效：\(play)")
            }
            url = parsed
        } catch let e as SMBServiceError {
            throw e
        } catch {
            throw SMBServiceError.other(
                "NAS 获取媒体失败（备份 NAS 媒体需要 NAS 在线）：\((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
        }
        // 2) 下载到本机临时文件（流式落盘）
        let safeName = media.name.replacingOccurrences(of: "/", with: "_")
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("smb-backup-\(UUID().uuidString)-\(safeName)")
        do {
            let (file, resp) = try await URLSession.shared.download(from: url)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                throw SMBServiceError.other("NAS 媒体下载失败（HTTP \(code)）")
            }
            if FileManager.default.fileExists(atPath: local.path) {
                try FileManager.default.removeItem(at: local)
            }
            try FileManager.default.moveItem(at: file, to: local)
        } catch let e as SMBServiceError {
            throw e
        } catch {
            throw SMBServiceError.other(
                "NAS 媒体下载失败：\((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
        }
        defer { try? FileManager.default.removeItem(at: local) }
        // 3) SMB 直连上传 + 读回校验 + 登记
        let rel = remoteDir.isEmpty ? safeName : remoteDir + "/" + safeName
        return try await SMBService.shared.uploadVerified(
            localURL: local, remoteRel: rel, note: "NAS 媒体备份")
    }
}
