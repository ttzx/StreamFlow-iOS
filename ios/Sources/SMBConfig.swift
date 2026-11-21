import Foundation

/// SMB 直连配置：与 NAS 配置完全独立（独立持久化；密码 Keychain，其余 UserDefaults）。
/// 键名沿用历史 sf.smb*（与旧版设置无缝衔接，已保存的配置升级后仍在）。
/// 注意：不加 @MainActor（SMBService actor 需直接读取快照）；UI 绑定/写入都在主线程。
final class SMBConfig: ObservableObject {
    static let shared = SMBConfig()

    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "sf.smbHost") }
    }
    @Published var portText: String {
        didSet { UserDefaults.standard.set(portText, forKey: "sf.smbPort") }
    }
    @Published var share: String {
        didSet { UserDefaults.standard.set(share, forKey: "sf.smbShare") }
    }
    @Published var username: String {
        didSet { UserDefaults.standard.set(username, forKey: "sf.smbUsername") }
    }
    @Published var baseDir: String {
        didSet { UserDefaults.standard.set(baseDir, forKey: "sf.smbBaseDir") }
    }
    @Published var password: String {
        didSet {
            if password.isEmpty {
                KeychainStore.delete("sf.smbPassword")
                keychainWriteFailed = false
            } else {
                // Keychain 写失败必须可感知：静默丢密码 = 重启后配置残缺
                keychainWriteFailed = !KeychainStore.set(password, forKey: "sf.smbPassword")
            }
        }
    }
    /// 最近一次 Keychain 写入是否失败（UI 据此在保存结果中如实报错）
    @Published var keychainWriteFailed = false

    /// 只要求主机地址；共享名可选：账户认证与共享选择分离，
    /// 登录后可自动枚举共享）。未选共享时进入 SMB 页会先出现共享选择列表。
    var configured: Bool { !host.isEmpty }
    var shareSelected: Bool { !share.isEmpty }
    var portNumber: Int { Int(portText.trimmingCharacters(in: .whitespaces)) ?? 445 }

    var summary: String {
        "\(host):\(portNumber)/\(share.isEmpty ? "未选共享" : share)\(username.isEmpty ? "（匿名）" : " · \(username)")"
    }

    private init() {
        let d = UserDefaults.standard
        host = d.string(forKey: "sf.smbHost") ?? ""
        portText = d.string(forKey: "sf.smbPort") ?? "445"
        share = d.string(forKey: "sf.smbShare") ?? ""
        username = d.string(forKey: "sf.smbUsername") ?? ""
        baseDir = d.string(forKey: "sf.smbBaseDir") ?? ""
        password = KeychainStore.get("sf.smbPassword") ?? ""
    }

    /// 保存当前表单（显式入口；返回给 UI 的确认文案，失败时如实报错）
    func save() -> String {
        guard !host.isEmpty else {
            return "保存失败：请填写 SMB 服务器地址"
        }
        if keychainWriteFailed {
            return "保存失败：Keychain 写入失败（OSStatus 见日志），密码未持久化"
        }
        return share.isEmpty
            ? "已保存（未选共享：进入 SMB 页自动枚举选择）"
            : "已保存（密码已存本机 Keychain）"
    }
}
