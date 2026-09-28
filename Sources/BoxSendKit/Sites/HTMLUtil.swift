import Foundation

/// 无依赖的轻量 HTML 文本提取（正则驱动，NexusPHP 页面结构规整时够用）
enum HTMLUtil {

    static func firstMatch(_ text: String, _ pattern: String, options: NSRegularExpression.Options = []) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range) else { return nil }
        guard m.range.length > 0 else { return nil }
        return String(text[Range(m.range, in: text)!])
    }

    static func group(_ text: String, _ pattern: String, group: Int = 1,
                      options: NSRegularExpression.Options = [.caseInsensitive]) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range),
              m.numberOfRanges > group else { return nil }
        let r = m.range(at: group)
        guard r.location != NSNotFound else { return nil }
        return String(text[Range(r, in: text)!])
    }

    static func allMatches(_ text: String, _ pattern: String,
                           options: NSRegularExpression.Options = [.caseInsensitive]) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var out: [String] = []
        for m in re.matches(in: text, options: [], range: range) {
            out.append(String(text[Range(m.range, in: text)!]))
        }
        return out
    }

    /// 提取标签内文本（去子标签，保留属性）
    static func tagContent(_ html: String, tag: String, attrs: String? = nil) -> String? {
        let pat = "<\(tag)(?:\\s[^>]*?)?>(.*?)</\\(tag)>"
        let inner = group(html, pat, group: 1, options: .dotMatchesLineSeparators)
        return inner.map { decodeEntities(stripTags($0)) }
    }

    static func stripTags(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "</p>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(s)
    }


    /// 跨平台 replace-all：按原始串上的匹配位置倒序替换
    static func replaceMatches(_ html: String, _ pattern: String,
                               options: NSRegularExpression.Options = [.caseInsensitive],
                               with block: (NSTextCheckingResult) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return html }
        let range = NSRange(html.startIndex..., in: html)
        let matches = re.matches(in: html, options: [], range: range)
        guard !matches.isEmpty else { return html }
        var result = html
        for m in matches.reversed() {
            guard let r = Range(m.range, in: result) else { continue }
            result.replaceSubrange(r, with: block(m))
        }
        return result
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let map: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#039;": "'", "&#39;": "'", "&apos;": "'",
            "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&laquo;": "«", "&raquo;": "»",
            "&rarr;": "→", "&larr;": "←", "&plusmn;": "±", "&times;": "×",
        ]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        out = replaceMatches(out, "&#(\\d+);") { m in
            let orig = String(out[Range(m.range, in: out)!])
            if let r = Range(m.range(at: 1), in: out), let code = Int(out[r]),
               let scalar = Unicode.Scalar(code) {
                return String(Character(scalar))
            }
            return orig
        }
        return out
    }

    static func resolveURL(_ ref: String, against base: URL) -> String {
        if let u = URL(string: ref) {
            if u.scheme != nil { return u.absoluteString }
            return URL(string: ref, relativeTo: base)?.absoluteString ?? ref
        }
        return base.absoluteString + ref
    }

    /// 从 <a ...>text</a> 中提取 href 与文本
    static func anchorText(_ html: String, hrefPattern: String) -> [(href: String, text: String)] {
        var out: [(String, String)] = []
        // 逐段处理更稳：找出所有 <a ...>...</a>
        guard let re = try? NSRegularExpression(pattern: "<a\\s[^>]*?href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
                                                options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        for m in re.matches(in: html, options: [], range: range) {
            guard m.numberOfRanges >= 3 else { continue }
            let href = String(html[Range(m.range(at: 1), in: html)!])
            let rawText = String(html[Range(m.range(at: 2), in: html)!])
            let text = stripTags(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
            if href.contains(hrefPattern) {
                out.append((href, text))
            }
        }
        return out
    }
}
