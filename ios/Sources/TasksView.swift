import SwiftUI

/// 下载任务页：列表 + 进度 + 暂停/继续/取消/删除 + 创建（链接/磁力）
struct TasksView: View {
    @StateObject private var api = APIClient()
    @State private var tasks: [DownloadTask] = []
    @State private var showingCreate = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let e = errorMessage {
                    Text(e).foregroundColor(.red).font(.caption)
                }
                if tasks.isEmpty {
                    Text("暂无任务").foregroundColor(.secondary)
                }
                ForEach(tasks) { task in
                    TaskRow(task: task,
                            onPause: { run { try await api.pauseTask(task.id) } },
                            onResume: { run { try await api.resumeTask(task.id) } },
                            onCancel: { run { try await api.cancelTask(task.id) } },
                            onDelete: { run { try await api.deleteTask(task.id, deleteFiles: false) } })
                }
            }
            .navigationTitle("下载任务")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("新建") { showingCreate = true }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("刷新") { Task { await load() } }
                }
            }
            .task { await load() }
            .sheet(isPresented: $showingCreate) {
                CreateTaskSheet(api: api) { Task { await load() } }
            }
        }
    }

    private func load() async {
        do {
            tasks = try await api.listTasks()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct TaskRow: View {
    let task: DownloadTask
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.name ?? task.id).lineLimit(1).font(.headline)
                Spacer()
                stateBadge
            }
            if let p = task.progress {
                ProgressView(value: p)
            }
            HStack {
                Text("\(formatBytes(task.downloadedBytes ?? 0)) / \(formatBytes(task.sizeBytes ?? 0))")
                if let s = task.speedBps, s > 0 {
                    Text("· \(formatBytes(s))/s")
                }
                Spacer()
                if let e = task.error, !e.isEmpty {
                    Text(e).foregroundColor(.red).font(.caption).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            if isActive(task.state) {
                HStack {
                    if task.state == "paused" {
                        Button("继续", action: onResume)
                    } else {
                        Button("暂停", action: onPause)
                    }
                    Button("取消", role: .destructive, action: onCancel)
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
        .swipeActions {
            Button("删除", role: .destructive, action: onDelete)
        }
    }

    private func isActive(_ state: String) -> Bool {
        ["queued", "downloading", "meta_info", "paused"].contains(state)
    }

    @ViewBuilder
    private var stateBadge: some View {
        let (text, color): (String, Color) = {
            switch task.state {
            case "downloading": ("下载中", .blue)
            case "queued": ("排队", .gray)
            case "meta_info": ("解析", .orange)
            case "paused": ("已暂停", .orange)
            case "completed": ("完成", .green)
            case "failed": ("失败", .red)
            case "canceled": ("已取消", .gray)
            default: (task.state, .gray)
            }
        }()
        Text(text).font(.caption).foregroundColor(color)
    }

    private func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)
    }
}

private struct CreateTaskSheet: View {
    let api: APIClient
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var savePath = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("链接 / 磁力") {
                    TextField("https://… 或 magnet:?xt=…", text: $input, axis: .vertical)
                        .lineLimit(3)
                }
                Section("保存到（相对媒体根目录，可空）") {
                    TextField("movie/", text: $savePath)
                }
                if let e = error {
                    Text(e).foregroundColor(.red)
                }
            }
            .navigationTitle("新建下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { Task { await create() } }
                        .disabled(busy || input.isEmpty)
                }
            }
        }
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("magnet:?") {
                _ = try await api.createMagnet(magnet: trimmed, savePath: savePath)
            } else {
                _ = try await api.createHTTP(url: trimmed, savePath: savePath)
            }
            onCreated()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
