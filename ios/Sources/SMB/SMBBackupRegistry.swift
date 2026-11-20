import Foundation

/// SMB 备份记录（本机登记，独立于任何服务端）：远端路径/大小/SHA-256/时间。
/// 持久化在 UserDefaults（记录量小；后续量大再迁 SQLite）。
struct SMBBackupRecord: Codable, Identifiable {
    var id: UUID = UUID()
    let remotePath: String
    let sizeBytes: Int64
    let sha256: String
    let createdAt: Date
    let note: String

    init(remotePath: String, sizeBytes: Int64, sha256: String, note: String = "") {
        self.remotePath = remotePath
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.note = note
        self.createdAt = Date()
    }
}

@MainActor
final class SMBBackupRegistry: ObservableObject {
    static let shared = SMBBackupRegistry()
    @Published private(set) var records: [SMBBackupRecord] = []

    private static let key = "sf.smbBackupRecords"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([SMBBackupRecord].self, from: data) {
            records = list
        }
    }

    func add(_ record: SMBBackupRecord) {
        records.insert(record, at: 0)
        persist()
    }

    func remove(_ record: SMBBackupRecord) {
        records.removeAll { $0.id == record.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
