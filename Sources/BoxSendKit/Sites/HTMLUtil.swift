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

    /// 按正则提取指定捕获组的每次出现（按文档顺序）
    static func allGroups(_ text: String, _ pattern: String, group: Int = 1,
                          options: NSRegularExpression.Options = [.caseInsensitive]) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, options: [], range: ns).compactMap { m in
            guard m.numberOfRanges > group, let r = Range(m.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }

    /// 提取标签内文本（去子标签，保留属性）
    static func tagContent(_ html: String, tag: String, attrs: String? = nil) -> String? {
        let pat = "<\(tag)(?:\\s[^>]*?)?>(.*?)</\\(tag)>"
        let inner = group(html, pat, group: 1, options: .dotMatchesLineSeparators)
        return inner.map { decodeEntities(stripTags($0)) }
    }

    /// 按 id 提取 div 内容（配对 <div>/</div>，支持嵌套）
    static func divContent(_ html: String, id: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<div[^>]*id=[\"']\(NSRegularExpression.escapedPattern(for: id))[\"'][^>]*>", options: .caseInsensitive),
              let m = re.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)) else { return nil }
        let contentStart = Range(m.range, in: html)!.upperBound
        let divRe = try! NSRegularExpression(pattern: "<div\\b|</div>", options: .caseInsensitive)
        var depth = 1
        var idx = contentStart
        while idx < html.endIndex {
            let r = NSRange(idx..., in: html)
            guard let dm = divRe.firstMatch(in: html, options: [], range: r),
                  dm.range.location >= r.location else { return nil }
            // NSRange 是 UTF-16 偏移：必须用 Range(_:in:) 换算，
            // 不能用 index(offsetBy:)（按 Character 计），否则遇到 CRLF/emoji 会越界崩溃
            guard let dr = Range(NSRange(location: dm.range.location, length: dm.range.length), in: html) else {
                return nil
            }
            let tag = html[dr]
            if tag.hasPrefix("</div") {
                depth -= 1
                if depth == 0 { return String(html[contentStart..<dr.lowerBound]) }
            } else {
                depth += 1
            }
            idx = dr.upperBound
        }
        return nil
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

    /// 从 openPattern 命中的 <div> 起，按 <div>/</div> 深度配对提取该 div 的完整内容（含嵌套）
    static func divByOpenTag(_ html: String, _ openPattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: openPattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)) else { return nil }
        let start = Range(m.range, in: html)!.upperBound
        let startOffset = m.range.location + m.range.length
        let divRe = try! NSRegularExpression(pattern: "<div\\b|</div>", options: [.caseInsensitive])
        // 全量匹配后过滤（NSRegularExpression 局部 range 搜索有跨行漏匹配 quirk）
        let matches = divRe.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
        var depth = 1
        for dm in matches where dm.range.location >= startOffset {
            if html[Range(dm.range, in: html)!].hasPrefix("</div") {
                depth -= 1
                if depth == 0 { return String(html[start..<Range(dm.range, in: html)!.lowerBound]) }
            } else {
                depth += 1
            }
        }
        return nil
    }

    /// 从 <a ...>text</a> 中提取 href 与文本
    /// 解析 <select name="X"> 的选项 [(value, label)]（动态分类解析用）
    static func selectOptions(_ html: String, name: String) -> [(value: String, label: String)] {
        let pat = "<select[^>]*name=['\"']" + NSRegularExpression.escapedPattern(for: name) + "[\"''][^>]*>([\\s\\S]*?)</select>"
        guard let m = firstMatch(html, pat) else { return [] }
        let optPat = "<option[^>]*value=['\"']([^\"']*)[\"''][^>]*>([\\s\\S]*?)</option>"
        var out: [(String, String)] = []
        for o in firstMatches(m, optPat) {
            let label = stripTags(o.1).trimmingCharacters(in: .whitespacesAndNewlines)
            out.append((o.0, label))
        }
        return out
    }

    /// 同名下拉的全部实例（新 NexusPHP 页面可含多个 type 下拉，各带 data-mode）。
    /// 返回每个下拉的 data-mode（可为 nil）与其选项列表
    static func selectGroups(_ html: String, name: String) -> [(mode: String?, options: [(value: String, label: String)])] {
        let pat = "<select[^>]*name=['\"']" + NSRegularExpression.escapedPattern(for: name) + "[\"''][^>]*>([\\s\\S]*?)</select>"
        guard let re = try? NSRegularExpression(pattern: pat, options: []) else { return [] }
        let ns = NSRange(html.startIndex..., in: html)
        var out: [(String?, [(String, String)])] = []
        for m in re.matches(in: html, options: [], range: ns) {
            guard m.numberOfRanges >= 2,
                  let whole = Range(m.range, in: html),
                  let bodyR = Range(m.range(at: 1), in: html) else { continue }
            let openTag = String(html[whole].prefix { $0 != ">" })
            let mode = group(openTag, "data-mode=['\"]([^\"']*)['\"]")
            var opts: [(String, String)] = []
            for o in firstMatches(String(html[bodyR]), "<option[^>]*value=['\"']([^\"']*)[\"'][^>]*>([\\s\\S]*?)</option>") {
                opts.append((o.0, stripTags(o.1).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            out.append((mode, opts))
        }
        return out
    }

    /// 复选框 (name, value, label)；label = 标签后紧随的文本（到下一个标签为止）
    static func checkboxes(_ html: String) -> [(name: String, value: String, label: String)] {
        guard let re = try? NSRegularExpression(pattern: "<input[^>]*type=['\"]checkbox['\"][^>]*>", options: [.caseInsensitive]) else { return [] }
        let ns = NSRange(html.startIndex..., in: html)
        var out: [(String, String, String)] = []
        for m in re.matches(in: html, options: [], range: ns) {
            guard let r = Range(m.range, in: html) else { continue }
            let tag = String(html[r])
            guard let name = group(tag, "name=['\"]([^\"']*)['\"]"),
                  let value = group(tag, "value=['\"]([^\"']*)['\"]") else { continue }
            let tail = String(html[r.upperBound...]).prefix(while: { $0 != "<" })
            var label = String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
            let after = String(html[r.upperBound...].prefix(400))
            if label.isEmpty {
                // 标签在紧随的 <label>…</label> 里（如 HAIDAN 的 tag_list[]）
                if let lm = after.range(of: "<label", options: .caseInsensitive),
                   after.distance(from: after.startIndex, to: lm.lowerBound) <= 3,
                   let openEnd = after[lm.lowerBound...].firstIndex(of: ">"),
                   let em = after.range(of: "</label>", options: .caseInsensitive,
                                        range: after.index(after: openEnd)..<after.endIndex) {
                    // 从 <label …> 的 > 之后开始（label 常带 for 属性，且文案可能再套 <a>）
                    label = stripTags(String(after[after.index(after: openEnd)..<em.lowerBound]))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if label.isEmpty,
               let em = after.range(of: "</label>", options: .caseInsensitive),
               hasOpenLabelBefore(html, r.lowerBound) {
                // <label><input …><img>文案</label>（麒麟等：文案前有图标，label 在 input 之前）
                label = stripTags(String(after[..<em.lowerBound]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            out.append((name, value, label))
        }
        return out
    }

    /// input 前是否有尚未闭合的 <label>（label 包裹 input 的写法）
    static func hasOpenLabelBefore(_ html: String, _ at: String.Index) -> Bool {
        let back = html[html.startIndex..<at]
        guard let lm = back.range(of: "<label", options: [.backwards, .caseInsensitive]) else { return false }
        return back[lm.upperBound...].range(of: "</label>", options: .caseInsensitive) == nil
    }

    /// 页面 textarea 字段名列表（判断是否有 technical_info/media_info 等专用字段）
    static func textareaNames(_ html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<textarea[^>]*name=['\"]([^\"']*)['\"][^>]*>") else { return [] }
        let ns = NSRange(html.startIndex..., in: html)
        return re.matches(in: html, options: [], range: ns).compactMap { m in
            guard let r = Range(m.range(at: 1), in: html) else { return nil }
            return String(html[r])
        }
    }

    static func firstMatches(_ text: String, _ pattern: String, options: NSRegularExpression.Options = []) -> [(String, String)] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, options: [], range: ns).compactMap { m in
            guard m.numberOfRanges >= 3,
                  let r1 = Range(m.range(at: 1), in: text),
                  let r2 = Range(m.range(at: 2), in: text) else { return nil }
            return (String(text[r1]), String(text[r2]))
        }
    }

    static func anchorText(_ html: String, hrefPattern: String) -> [(href: String, text: String)] {
        var out: [(String, String)] = []
        // 逐段处理更稳：找出所有 <a ...>...</a>
        // 属性值里可能含 ">"（如 xbtit 的 onmouseover="overlib('<img … border=0>')"），
        // 用「引号段或普通字符」消费开标签，避免在值中的 ">" 处提前截断
        let open = #"(?i)<a\s(?:[^>"']|"[^"]*"|'[^']*')*?href=["']([^"']+)["'](?:[^>"']|"[^"]*"|'[^']*')*>"#
        guard let re = try? NSRegularExpression(pattern: open + "(.*?)</a>",
                                                options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        // hrefPattern 按正则匹配（detailLinkPattern/search 端点均为正则）；无法编译时退回子串
        let hrefRe = try? NSRegularExpression(pattern: hrefPattern, options: [.caseInsensitive])
        let range = NSRange(html.startIndex..., in: html)
        for m in re.matches(in: html, options: [], range: range) {
            guard m.numberOfRanges >= 3 else { continue }
            let href = String(html[Range(m.range(at: 1), in: html)!])
            let rawText = String(html[Range(m.range(at: 2), in: html)!])
            let text = stripTags(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
            let hit: Bool
            if let hrefRe {
                let r = NSRange(href.startIndex..., in: href)
                hit = hrefRe.firstMatch(in: href, options: [], range: r) != nil
            } else {
                hit = href.contains(hrefPattern)
            }
            if hit {
                out.append((href, text))
            }
        }
        return out
    }
}
