import Foundation

/// 站点对「文件名」的校验规则。两处各不相同，别混用：
/// - `uploadName`：上传时 multipart 里那个 .torrent 文件名。NexusPHP 家族只认 ASCII，
///   最窄的一种形如 `^[\\w.-]+\\.torrent$`，中文片名一进去整站就被拒。
/// - `legalComponent`：种子**内部**的文件名。馒头这类站按 Windows 那套禁令查，
///   中文合法、`<>:"/\\|?*` 不合法——带「Minami-ke: Okawari」这种冒号的片名会被整单打回。
public enum SiteFileName {
    /// 上传文件名用的字符白名单：字母数字下划线连字符留下，其余（中文、空格、方括号、
    /// 冒号…）一律收成一个点，首尾分隔去掉，超长在分隔处截断
    public static func asciiName(_ text: String) -> String {
        var out = ""
        var lastSep = false
        for scalar in text.unicodeScalars {
            let ok = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9") || scalar == "_" || scalar == "-"
            if ok {
                out.unicodeScalars.append(scalar)
                lastSep = false
            } else if !lastSep {
                out.append(".")
                lastSep = true
            }
        }
        let sep = CharacterSet(charactersIn: " .-_")
        var name = out.trimmingCharacters(in: sep)
        if name.count > 120 {
            // 截断也落在分隔上，别留半个词和一个孤零零的点
            name = String(name.prefix(120)).trimmingCharacters(in: sep)
        }
        return name
    }

    /// 上传给目标站的 .torrent 文件名：洗成 ASCII，洗到没法看就改用主标题，再不行兜底一个
    public static func uploadName(_ source: String, title: String) -> String {
        let cleaned = asciiName((source as NSString).deletingPathExtension)
        let base = cleaned.count >= 8 ? cleaned : asciiName(title)
        return (base.count >= 4 ? base : "release") + ".torrent"
    }

    /// 种子内部一个文件/目录名（原始字节）。有非法字符时返回洗过的字节，没有返回 nil
    /// ——返回 nil 让调用方保住原字节，别白改一次 hash。
    /// 逐字节扫：文件名未必是 UTF-8，而多字节序列的字节都 ≥0x80，不会与 ASCII 撞车
    public static func legalComponent(_ text: Data) -> Data? {
        var hit = false
        for x in text where isIllegal(x) { hit = true; break }
        guard hit else { return nil }
        var out: [UInt8] = []
        for x in text { out.append(isIllegal(x) ? 0x2E /* . */ : x) }
        // 真改过名才顺手收拾：连着的点收一个，首尾的点与空格去掉（这些 Windows 同样不认）
        var collapsed: [UInt8] = []
        for x in out {
            if x == 0x2E, collapsed.last == 0x2E { continue }
            collapsed.append(x)
        }
        while collapsed.first == 0x2E { collapsed.removeFirst() }
        while let l = collapsed.last, l == 0x2E || l == 0x20 { collapsed.removeLast() }
        if collapsed.isEmpty { collapsed = Array("file".utf8) }
        return Data(collapsed)
    }

    /// Windows 那套文件名禁令（站方那条校验的来头）：保留字符 + 控制字符
    private static func isIllegal(_ b: UInt8) -> Bool {
        b < 0x20 || b == 0x7F || b == UInt8(ascii: ":") || b == UInt8(ascii: "<")
            || b == UInt8(ascii: ">") || b == UInt8(ascii: "\"") || b == UInt8(ascii: "/")
            || b == UInt8(ascii: "\\") || b == UInt8(ascii: "|") || b == UInt8(ascii: "?")
            || b == UInt8(ascii: "*")
    }
}
