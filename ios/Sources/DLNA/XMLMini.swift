import Foundation

/// 轻量 XML 标签取值（A5 合并点：原 AVTransport.tagValue 与 DeviceDescription.tag）。
/// 语义基线：正则 "<name>(.*?)</name>" 取首个匹配，整体去除首尾标签字面量；
/// 未命中返回 nil。是否 trim 由调用方选择（两处原实现行为分别保留）。
public enum XMLMini {
    public static func tag(_ name: String, _ xml: String, trim: Bool = false) -> String? {
        guard let r = xml.range(of: "<\(name)>(.*?)</\(name)>",
                                options: .regularExpression) else { return nil }
        let s = String(xml[r])
            .replacingOccurrences(of: "<\(name)>", with: "")
            .replacingOccurrences(of: "</\(name)>", with: "")
        return trim ? s.trimmingCharacters(in: .whitespaces) : s
    }
}