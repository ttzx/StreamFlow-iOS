import Foundation

/// 分享文本识别（移植自 LiuZhuan 3.0 的 parseShare / cleanUrl / extractUrls 基线）：
/// 整段分享文字、b23.tv 短链（含 o23.tv/823.tv 等首字母误识别纠正）、裸链接（无 scheme）、
/// BV 号兜底、【】标题提取。URL 边界只用 ASCII 字符——B站分享文本里链接后常紧跟中文。
enum ShareParser {
    struct Result: Equatable {
        let urls: [String]
        let title: String
    }

    static func parse(_ raw: String) -> Result {
        let s = sanitize(raw)
        var urls = extractUrls(s)

        var title = ""
        // 【】标题（分享文本标准形态；多重【嵌套时取到第一个】为止，与基线一致）
        if let bracket = firstMatch(in: s, pattern: "[【\\[]([^】\\]]+)[】\\]]") {
            title = bracket.trimmingCharacters(in: .whitespaces)
        }
        if title.isEmpty, let first = urls.first {
            let before = (s.components(separatedBy: first).first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if before.count > 1 && before.count < 100 { title = before }
        }

        // 没有任何 URL 时 BV 号兜底（如只复制了 BV1xx4x1x7xx）
        if urls.isEmpty, let bv = firstMatch(in: s, pattern: "BV[a-zA-Z0-9]{10}") {
            urls.append("https://www.bilibili.com/video/" + bv)
        }

        return Result(urls: dedupe(urls), title: title.isEmpty ? "StreamFlow" : title)
    }

    // MARK: - 清洗与提取（与 LiuZhuan 逐条对齐）

    private static func sanitize(_ text: String) -> String {
        String(text)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\u0026", with: "&", options: [.caseInsensitive])
            .replacingOccurrences(of: "\\/", with: "/")
    }

    private static func extractUrls(_ raw: String) -> [String] {
        // 1) 带协议的 ASCII URL（中文不是 URL 字符，不会被吞进链接）
        var matches = allMatches(in: raw,
            pattern: "https?:\\/\\/[A-Za-z0-9\\-._~:\\/?#\\[\\]@!$&'()*+,;=%]+")

        // 2) 裸链接（无 https://）：b23.tv、bilibili 系短域、bilibili.com
        let rest = raw.replacingOccurrences(of: " ", with: "  ") // 占位，防止相邻匹配粘连
        let barePattern =
            "(?:^|[^A-Za-z0-9./@_-])((?:(?:www\\.|m\\.)?(?:b23\\.tv|bili(?:2233|22|33|23)\\.cn)" +
            "|(?:live\\.|www\\.|m\\.)?bilibili\\.com)\\/[A-Za-z0-9_\\/\\-]+" +
            "(?:\\?[A-Za-z0-9_=&%.\\-]*)?)"
        for m in allMatches(in: rest, pattern: barePattern) {
            matches.append("https://" + m)
        }

        return matches.compactMap { cleanUrl($0) }.map(fixShortHost)
    }

    /// 清洗：去零宽字符/转义/引号/尾部中文标点，收紧查询串；校验 ASCII URL 形态
    static func cleanUrl(_ value: String) -> String? {
        var u = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return nil }
        u = u.replacingOccurrences(of: "&amp;", with: "&")
        u = u.replacingOccurrences(of: "\\u0026", with: "&", options: [.caseInsensitive])
        u = u.replacingOccurrences(of: "\\/", with: "/")
        u = u.replacingOccurrences(of: "\u{200B}", with: "").replacingOccurrences(of: "\u{FEFF}", with: "")
        u = u.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        // 尾部中文标点 / 半角括号引号（分享文本链接后常带标点）
        while let last = u.unicodeScalars.last,
              ["，", "。", "；", "、", "）", "》", "】", "」", "』", ")", "]", "}"].contains(String(last)) {
            u = String(u.dropLast())
        }
        guard u.range(of: "^https?://[^\\s<>\"'{}]+$", options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        // 查询串收紧：?& → &、多个 & 合并
        if let q = u.firstIndex(of: "?") {
            let base = String(u[..<q])
            var query = String(u[u.index(after: q)...])
                .replacingOccurrences(of: "^\\?+", with: "", options: .regularExpression)
            query = query.replacingOccurrences(of: "\\?&", with: "&", options: .regularExpression)
            query = query.replacingOccurrences(of: "&{2,}", with: "&", options: .regularExpression)
            u = query.isEmpty ? base : base + "?" + query
        }
        return u
    }

    /// 短链首字母误识别纠正：o23.tv / 823.tv / 623.tv → b23.tv（路径不动）
    static func fixShortHost(_ url: String) -> String {
        guard let r = try? NSRegularExpression(pattern: "^(https?://)(?!b23\\.tv)[A-Za-z0-9]23\\.tv(?=[/?#]|$)",
                                               options: [.caseInsensitive]) else { return url }
        let range = NSRange(url.startIndex..<url.endIndex, in: url)
        return r.stringByReplacingMatches(in: url, range: range, withTemplate: "$1b23.tv")
    }

    // MARK: - 工具

    private static func firstMatch(in text: String, pattern: String) -> String? {
        allMatches(in: text, pattern: pattern).first
    }

    private static func allMatches(in text: String, pattern: String) -> [String] {
        guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return r.matches(in: text, range: range).compactMap {
            $0.range.location == NSNotFound ? nil : Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func dedupe(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for u in urls where seen.insert(u).inserted { out.append(u) }
        return out
    }
}
