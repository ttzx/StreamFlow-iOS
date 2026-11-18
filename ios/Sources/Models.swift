import Foundation

/// 下载任务（服务端 /api/v1/downloads 输出）
struct DownloadTask: Codable, Identifiable, Hashable {
    let id: String
    let type: String            // http | magnet | torrent
    let state: String           // queued | downloading | meta_info | paused | completed | failed | canceled
    let name: String?
    let url: String?
    let magnet: String?
    let sizeBytes: Int64?
    let downloadedBytes: Int64?
    let progress: Double?
    let speedBps: Int64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, type, state, name, url, magnet, progress, error
        case sizeBytes = "size_bytes"
        case downloadedBytes = "downloaded_bytes"
        case speedBps = "speed_bps"
    }
}

/// 媒体条目（/api/v1/media 输出）
struct MediaItem: Codable, Identifiable, Hashable {
    var id: String { mediaId }
    let mediaId: String
    let relPath: String
    let name: String
    let sizeBytes: Int64
    let mime: String
    let playUrl: String

    enum CodingKeys: String, CodingKey {
        case name, mime
        case mediaId = "media_id"
        case relPath = "rel_path"
        case sizeBytes = "size_bytes"
        case playUrl = "play_url"
    }
}

/// 创建任务响应
struct CreateTaskResponse: Codable {
    let id: String
    let state: String
}
