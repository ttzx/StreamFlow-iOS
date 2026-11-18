import Foundation

/// AVTransport SOAP 控制（HTTP POST + SOAPACTION 头）
public enum AVTransport {
    /// SOAP POST 的两类本地失败（URLSession 传输错误原样抛出）
    public enum SOAPPostError: Error, Sendable, Equatable {
        case invalidURL
        case httpStatus(Int)
    }

    /// 通用 SOAP POST（A4 合并点：原 CastController.httpPost 与 DLNAView.castHTTP）。
    /// 行为基线：POST + Content-Type text/xml + SOAPACTION 头 + 8s 超时 + URLSession.shared + 2xx 校验。
    /// （旧仓库的 URLValidator 会话不迁移；DLNA 直连局域网设备，无 SSRF 面。）
    public static func post(_ url: String, action: String, body: String,
                            timeout: TimeInterval = 8) async throws -> String {
        guard let u = URL(string: url) else { throw SOAPPostError.invalidURL }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue(action, forHTTPHeaderField: "SOAPACTION")
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SOAPPostError.httpStatus((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
    public static let serviceType = "urn:schemas-upnp-org:service:AVTransport:1"

    public enum Action: String, Sendable {
        case setAVTransportURI = "SetAVTransportURI"
        case play = "Play"
        case pause = "Pause"
        case stop = "Stop"
        case getPositionInfo = "GetPositionInfo"
        case getTransportInfo = "GetTransportInfo"
    }

    // MARK: 报文构造（公开以便测试）
    /// R-09：参数用有序数组，不遍历 Dictionary（原实现顺序不定，部分设备拒收）。
    /// SetAVTransportURI 固定为 InstanceID → CurrentURI → CurrentURIMetaData；Play 固定为 InstanceID → Speed。
    public static func soapEnvelope(action: Action, instanceID: Int = 0,
                                    arguments: [(String, String)] = []) -> String {
        var args = ""
        for (k, v) in arguments {
            args += "<\(k)>\(escapeXML(v))</\(k)>"
        }
        return [
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" ",
            "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">",
            "<s:Body>",
            "<u:\(action.rawValue) xmlns:u=\"\(serviceType)\">",
            "<InstanceID>\(instanceID)</InstanceID>",
            args,
            "</u:\(action.rawValue)>",
            "</s:Body>",
            "</s:Envelope>"
        ].joined()
    }

    public static func soapActionHeader(action: Action) -> String {
        "\"\(serviceType)#\(action.rawValue)\""
    }

    /// SetAVTransportURI：URL + 协议信息 + 元数据
    public static func setURIEnvelope(url: String, mimeType: String, title: String,
                                      instanceID: Int = 0) -> String {
        let protocolInfo = "http-get:*:\(mimeType):*"
        let metadata = [
            "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" ",
            "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" ",
            "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">",
            "<item id=\"streamflow-1\" restricted=\"1\">",
            "<dc:title>\(escapeXML(title))</dc:title>",
            "<upnp:class>object.item.videoItem</upnp:class>",
            "<res protocolInfo=\"\(protocolInfo)\">\(escapeXML(url))</res>",
            "</item></DIDL-Lite>"
        ].joined()
        return soapEnvelope(action: .setAVTransportURI, instanceID: instanceID,
                            arguments: [("CurrentURI", url),
                                        ("CurrentURIMetaData", metadata)])
    }

    public static func playEnvelope(instanceID: Int = 0) -> String {
        soapEnvelope(action: .play, instanceID: instanceID,
                     arguments: [("Speed", "1")])
    }

    // MARK: 响应解析（公开以便测试）
    public enum TransportState: String, Sendable {
        case stopped = "STOPPED"
        case playing = "PLAYING"
        case paused = "PAUSED_PLAYBACK"
        case transitioning = "TRANSITIONING"
        case unknown = "UNKNOWN"
    }

    public static func parseTransportInfo(_ xml: String) -> TransportState {
        let v = tagValue("CurrentTransportState", xml).uppercased()
        return TransportState(rawValue: v) ?? .unknown
    }

    public struct Position: Sendable, Equatable {
        public let trackSeconds: Int
        public let durationSeconds: Int
    }

    public static func parsePositionInfo(_ xml: String) -> Position? {
        let track = hmsToSeconds(tagValue("RelTime", xml))
        let dur = hmsToSeconds(tagValue("TrackDuration", xml))
        guard track != nil || dur != nil else { return nil }
        return Position(trackSeconds: track ?? 0, durationSeconds: dur ?? 0)
    }

    /// 未命中返回 ""（原语义）；核心实现见 XMLMini.tag
    static func tagValue(_ name: String, _ xml: String) -> String {
        XMLMini.tag(name, xml) ?? ""
    }

    public static func hmsToSeconds(_ hms: String) -> Int? {
        let parts = hms.split(separator: ":").map(String.init)
        guard parts.count == 3 else { return nil }
        let h = Double(parts[0]) ?? 0
        let m = Double(parts[1]) ?? 0
        let s = Double(parts[2]) ?? 0
        return Int(h * 3600 + m * 60 + s)
    }

    static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}