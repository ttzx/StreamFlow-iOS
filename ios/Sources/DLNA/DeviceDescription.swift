import Foundation

/// UPnP 设备描述解析（LOCATION 的 XML）
public struct DLNADevice: Codable, Sendable, Identifiable, Hashable {
    public var id: String { usn }
    public let usn: String
    public let friendlyName: String
    public let manufacturer: String
    public let modelName: String
    public let controlURL: String      // AVTransport controlURL（绝对地址）
}

public enum DeviceDescriptionParser {
    /// 从 device XML + LOCATION 基地址解析设备（公开以便测试）
    /// R-15（第 4 条，安全相关）：controlURL 必须与 LOCATION 同主机，否则拒绝该设备，
    /// 防止被投屏 URL 发往攻击者主机（外泄 NAS 签名地址）。
    public static func parse(_ xml: String, location: String, usn: String) -> DLNADevice? {
        let name = tag("friendlyName", xml)
        let maker = tag("manufacturer", xml)
        let model = tag("modelName", xml)
        // 在 serviceList 中找 AVTransport:1 的 controlURL
        // （原移植稿 `xml.range(of:)...` 与 `services.lowerBound...` 是从未编译过的笔误；
        //   语义：找到 <serviceList> 起点后取到串尾）
        guard let svcRange = xml.range(of: "<serviceList>") else { return nil }
        let sub = String(xml[svcRange.lowerBound...])
        var controlRelative: String?
        // 逐块扫描 service
        for chunk in sub.components(separatedBy: "<service>") {
            guard chunk.contains("urn:schemas-upnp-org:service:AVTransport:1") else { continue }
            controlRelative = tag("controlURL", chunk)
            break
        }
        guard let rel = controlRelative else { return nil }
        let controlURL = absoluteURL(rel, base: location)
        // R-15 第 4 条：controlURL 必须与 LOCATION 同主机（绝对地址 + host 一致），否则拒绝
        guard let baseHost = URLComponents(string: location)?.host,
              let ctrlHost = URLComponents(string: controlURL)?.host,
              !baseHost.isEmpty, baseHost == ctrlHost else {
            return nil
        }
        return DLNADevice(usn: usn,
                          friendlyName: name ?? "未知设备",
                          manufacturer: maker ?? "",
                          modelName: model ?? "",
                          controlURL: controlURL)
    }

    /// 命中后 trim、未命中 nil（原语义）；核心实现见 XMLMini.tag
    static func tag(_ name: String, _ xml: String) -> String? {
        XMLMini.tag(name, xml, trim: true)
    }

    static func absoluteURL(_ rel: String, base: String) -> String {
        if rel.hasPrefix("http://") || rel.hasPrefix("https://") { return rel }
        // LOCATION 形如 http://192.0.2.10:49152/desc.xml（RFC 5737 文档示例地址）→ 截取 scheme://host:port
        guard let m = base.range(of: #"^https?://[^/]+"#, options: .regularExpression) else {
            return rel
        }
        let origin = String(base[m])
        return rel.hasPrefix("/") ? origin + rel : origin + "/" + rel
    }
}