import Foundation

/// HTML -> NexusPHP BBCode 简介转换（中文站家族）。
/// 覆盖源站简介常见结构：引用框（fieldset/legend + color/size）、图片、链接、MediaInfo。
enum BBCode {

    /// 转换入口。base = 源站 URL（相对链接绝对化）。
    static func fromHTML(_ html: String, base: URL? = nil) -> String {
        var s = html
        // 源页 HTML 常含 CRLF/CR 换行；\r 会打断 \n 连续段使上限正则失效，先统一为 \n
        s = s.replacingOccurrences(of: "\r\n", with: "\n", options: [])
        s = s.replacingOccurrences(of: "\r", with: "\n", options: [])
        // 去脚本/样式块与注释
        s = HTMLUtil.replaceMatches(s, "<(script|style)[^>]*>.*?</\\1>",
                                    options: [.caseInsensitive, .dotMatchesLineSeparators]) { _ in "" }
        s = HTMLUtil.replaceMatches(s, "<!--.*?-->",
                                    options: [.dotMatchesLineSeparators]) { _ in "" }

        let tagRe = try! NSRegularExpression(pattern: "<[^>]+>", options: [.caseInsensitive])
        let nsRange = NSRange(s.startIndex..., in: s)
        let matches = tagRe.matches(in: s, options: [], range: nsRange)

        struct Frame { let kind: String; let value: String }
        var stack: [Frame] = []
        var quoteDepth = 0
        var skip: (tag: String, depth: Int)? = nil
        var out = ""

        func absURL(_ ref: String) -> String {
            let t = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") { return t }
            if t.hasPrefix("//") { return "https:" + t }
            if let base { return HTMLUtil.resolveURL(t, against: base) }
            return t
        }
        func attr(_ tag: String, _ name: String) -> String? {
            if let m = try? NSRegularExpression(pattern: "\(name)\\s*=\\s*[\"']([^\"']*)[\"']", options: .caseInsensitive) {
                let r = NSRange(tag.startIndex..., in: tag)
                if let hit = m.firstMatch(in: tag, options: [], range: r) {
                    return String(tag[Range(hit.range(at: 1), in: tag)!])
                }
            }
            return nil
        }
        func push(_ kind: String, _ value: String, _ code: String) {
            out += code
            stack.append(Frame(kind: kind, value: value))
        }
        func pop(_ kind: String, _ code: String) {
            // 找到最近的同类帧并关闭（容忍乱序嵌套）
            guard let idx = stack.lastIndex(where: { $0.kind == kind }) else { return }
            for _ in (idx + 1)..<stack.count {
                out += closeCode(stack[stack.count - 1].kind)
                stack.removeLast()
            }
            out += code
            stack.removeLast()
        }
        func closeCode(_ kind: String) -> String {
            switch kind {
            case "url": return "[/url]"
            case "color": return "[/color]"
            case "size": return "[/size]"
            default: return ""
            }
        }

        var cursor = s.startIndex
        for m in matches {
            guard let range = Range(m.range, in: s) else { continue }
            // 文本段（skip 模式下不输出）
            if cursor < range.lowerBound, skip == nil {
                out += HTMLUtil.decodeEntities(String(s[cursor..<range.lowerBound]))
            }
            cursor = range.upperBound
            let raw = String(s[range])
            var inner = String(raw.dropFirst().dropLast())
            let closing = inner.hasPrefix("/")
            if closing { inner = String(inner.dropFirst()) }
            inner = inner.trimmingCharacters(in: .whitespaces)
            // 标签名 = 首个 token
            let tagName = String(inner.prefix(while: { !$0.isWhitespace })).lowercased()
            // 去掉尾部斜杠（<br/>）
            var body = inner
            if body.hasSuffix("/") { body = String(body.dropLast()) }

            // skip 模式（script/style/legend）
            if let sk = skip {
                if tagName == sk.tag {
                    if !closing { skip = (sk.tag, sk.depth + 1) }
                    else {
                        skip = (sk.tag, sk.depth - 1)
                        if skip?.depth == 0 { skip = nil }
                    }
                }
                continue
            }

            if tagName == "script" || tagName == "style" {
                skip = (tagName, 1)
                continue
            }
            switch tagName {
            case "br":
                out += "\n"
            case "img":
                if let src = attr(body, "src") {
                    out += "[img]\(absURL(src))[/img]"
                }
            case "a":
                if !closing, let href = attr(body, "href") {
                    push("url", href, "[url=\(absURL(href))]")
                } else if closing {
                    pop("url", "[/url]")
                }
            case "fieldset":
                if !closing {
                    out += "[quote]\n"
                    quoteDepth += 1
                } else {
                    out += "\n[/quote]"
                    quoteDepth = max(0, quoteDepth - 1)
                }
            case "legend":
                if !closing { skip = ("legend", 1) }
            case "span":
                if !closing, let style = attr(body, "style"),
                   let cm = try? NSRegularExpression(pattern: "color\\s*:\\s*([A-Za-z]+)", options: .caseInsensitive) {
                    let r = NSRange(style.startIndex..., in: style)
                    if let hit = cm.firstMatch(in: style, options: [], range: r) {
                        let css = style[Range(hit.range(at: 1), in: style)!].lowercased()
                        let mapped: [String: String] = [
                            "darkred": "darkred", "red": "red", "blue": "blue", "darkblue": "darkblue",
                            "green": "green", "darkgreen": "darkgreen", "orange": "orange", "purple": "purple",
                            "pink": "pink", "gray": "gray", "grey": "gray", "brown": "brown", "cyan": "cyan",
                            "navy": "navy", "maroon": "maroon", "olive": "olive", "teal": "teal",
                        ]
                        if let c = mapped[css] { push("color", c, "[color=\(c)]") }
                    }
                } else if closing {
                    pop("color", "[/color]")
                }
            case "font":
                if !closing {
                    var emitted = false
                    if let sz = attr(body, "size"), let n = Int(sz), (1...7).contains(n) {
                        push("size", sz, "[size=\(n)]")
                        emitted = true
                    } else if let color = attr(body, "color"), !color.isEmpty {
                        let c = color.lowercased()
                        push("color", c, "[color=\(c)]")
                        emitted = true
                    }
                    if !emitted { /* 无 bcode 属性，忽略 */ }
                } else {
                    if stack.last?.kind == "size" { pop("size", "[/size]") }
                    else if stack.last?.kind == "color" { pop("color", "[/color]") }
                }
            case "div", "p", "table", "tbody", "tr", "ul", "ol", "li", "hr", "pre", "blockquote":
                if !closing { out += "\n" } else if tagName != "pre" { out += "\n" }
            default:
                break // b/i/em/u/sup/td/th/center/summary/details 等：仅去标签
            }
        }
        if cursor < s.endIndex, skip == nil {
            out += HTMLUtil.decodeEntities(String(s[cursor...]))
        }
        // 收尾未关闭的帧
        while let f = stack.popLast() { out += closeCode(f.kind) }

        // 规范化空白
        out = out.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        // 开标签连续：[quote]/[color]/[size] 后的空行去除（源页 <br> 产物）
        out = out.replacingOccurrences(of: "(\\[(?:quote|color=\\w+|size=\\d+)\\])\n\n",
                                       with: "$1", options: .regularExpression)
        // 闭标签序列合并：[/size]\n[/color]\n[/quote] -> 连续
        var prev = ""
        while prev != out {
            prev = out
            out = out.replacingOccurrences(of: "(\\[/[a-z]+\\])\n(\\[/[a-z]+\\])", with: "$1$2", options: .regularExpression)
        }
        // 闭标签序列前的空行 -> 单换行
        out = out.replacingOccurrences(of: "\n{2,}(\\[/[a-z]+\\])", with: "\n$1", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把 MediaInfo 插入到末尾截图 [img] 区块之前；无截图则追加到末尾。
    static func insertMediainfo(_ bbcode: String, mediainfo: String) -> String {
        let mi = mediainfo.trimmingCharacters(in: Self.trimSet)
        guard !mi.isEmpty else { return bbcode }
        let block = "[quote]\n\(mi)\n[/quote]"
        let lines = bbcode.components(separatedBy: "\n")
        var insertAt: Int? = nil
        for (i, line) in lines.enumerated().reversed() {
            let t = line.trimmingCharacters(in: Self.trimSet)
            if !t.isEmpty && !t.hasPrefix("[img]") {
                insertAt = i + 1
                break
            }
        }
        if let at = insertAt, at < lines.count {
            var newLines = lines
            // 插入点若本来就是空行，不再额外追加，避免产生连续 2 个空行
            let pad: [String] = lines[at].trimmingCharacters(in: Self.trimSet).isEmpty ? [] : [""]
            newLines.insert(contentsOf: ["", block] + pad, at: at)
            return newLines.joined(separator: "\n")
        }
        return bbcode + "\n\n" + block
    }

    /// 判空行用的空白集：常规空白之外，纳入全角空格 U+3000 与 NBSP（中文站简介常见）。
    private static let trimSet: CharacterSet = {
        var s = CharacterSet.whitespacesAndNewlines
        s.insert(charactersIn: "\u{3000}\u{00A0}")
        return s
    }()
}
