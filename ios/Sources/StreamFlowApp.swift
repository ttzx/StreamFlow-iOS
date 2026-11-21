import SwiftUI

/// StreamFlow iOS 客户端入口：任务 / 媒体库 / SMB / DLNA / 设置。
/// 三功能独立：NAS（服务端+API Key）、SMB（iOS 直连，独立凭据）、
/// DLNA（局域网发现/浏览/播放，不依赖 NAS/SMB）。
@main
struct StreamFlowApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                TasksView()
                    .tabItem { Label("任务", systemImage: "arrow.down.circle") }
                MediaView()
                    .tabItem { Label("媒体库", systemImage: "film") }
                SMBView()
                    .tabItem { Label("SMB", systemImage: "externaldrive") }
                DLNAView()
                    .tabItem { Label("DLNA", systemImage: "tv") }
                SettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape") }
            }
        }
    }
}

/// NAS 连接设置（ServerConfig）；SMB 直连配置独立在下方（SMBConfig）。
/// 三功能互不依赖：NAS 失效不影响 SMB；SMB 失效不影响 NAS/DLNA。
struct SettingsView: View {
    @ObservedObject private var config = ServerConfig.shared
    @ObservedObject private var smbCfg = SMBConfig.shared
    @State private var testResult: String?
    @State private var testing = false
    @State private var smbSaveResult: String?
    @State private var smbTestResult: String?
    @State private var smbTesting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("NAS 连接（下载/媒体服务）") {
                    TextField("NAS 地址（http://IP:8080）", text: $config.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $config.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存并测试连接") {
                        Task { await test() }
                    }
                    if testing {
                        ProgressView()
                    }
                    if let r = testResult {
                        Text(r).font(.caption).foregroundColor(
                            r.hasPrefix("连接成功") ? .green : .red)
                    }
                    if !config.isValid {
                        Text("尚未配置有效的 NAS 地址与 API Key，任务/媒体页将无法连接（不影响 SMB/DLNA）。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Section("SMB 直连（iOS ↔ SMB 服务器，独立于 NAS）") {
                    TextField("SMB 服务器地址（IP 或主机名）", text: $smbCfg.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("端口（默认 445）", text: $smbCfg.portText)
                        .keyboardType(.numberPad)
                    TextField("共享名（可选；留空进 SMB 页自动枚举）", text: $smbCfg.share)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("用户名（可留空）", text: $smbCfg.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码（可留空，存本机 Keychain）", text: $smbCfg.password)
                    TextField("远端基目录（可留空）", text: $smbCfg.baseDir)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Button("保存 SMB 配置") { smbSaveResult = smbCfg.save() }
                        Spacer()
                        Button("测试 SMB 连接") { Task { await testSMB() } }
                    }
                    if let r = smbSaveResult {
                        Text(r).font(.caption).foregroundColor(
                            r.hasPrefix("已") ? .green : .red)
                    }
                    if let r = smbTestResult {
                        Text(r).font(.caption).foregroundColor(
                            r.hasPrefix("SMB 连接成功") ? .green : .red)
                    }
                    Text("SMB 凭据只保存在本机（密码存 Keychain），不发送给 NAS 或其他服务；NAS 离线时 SMB 功能不受影响。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("DLNA（局域网设备）") {
                    Text("DLNA 发现与浏览不依赖任何配置；投屏 NAS 媒体需 NAS 在线。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .scrollDismissesKeyboardImmediately()
            .keyboardDoneBar()
            .navigationTitle("设置")
        }
    }

    private func test() async {
        testing = true
        testResult = nil
        let api = APIClient()
        do {
            try await api.health()
            testResult = "连接成功"
        } catch {
            testResult = "连接失败：\(error.localizedDescription)"
        }
        testing = false
    }

    /// SMB 登录测试（账户认证与共享选择分离：此处只测登录；
    /// 共享名留空 = 进 SMB 页自动枚举，选定时再做共享级测试）
    private func testSMB() async {
        guard !smbCfg.host.isEmpty else {
            smbTestResult = "请先填写 SMB 服务器地址"
            return
        }
        smbTesting = true
        smbTestResult = nil
        do {
            try await SMBService.shared.testLogin()
            if smbCfg.share.isEmpty {
                smbTestResult = "SMB 登录成功（\(smbCfg.host):\(smbCfg.portNumber)，未选共享）"
            } else {
                try await SMBService.shared.testConnection()
                smbTestResult = "SMB 连接成功（\(smbCfg.summary)）"
            }
        } catch {
            smbTestResult = "SMB 连接失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
        smbTesting = false
    }
}
