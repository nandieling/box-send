import Foundation

/// 站点名称默认排序：数字开头的名称在前（按名称不区分大小写比较），
/// 其余按拼音字母顺序（中文取拼音首字母、纯拉丁名取首字母，同一首字母内按 zh-Hans-CN 拼音序）
public enum NameSort {
    private static let zhLocale = Locale(identifier: "zh-Hans-CN")

    /// 各拼音首字母对应的最小拼音单字（用于二分确定中文名的拼音首字母）
    private static let probes: [Character: String] = [
        "a": "阿", "b": "八", "c": "擦", "d": "搭", "e": "鹅", "f": "发",
        "g": "嘎", "h": "哈", "j": "鸡", "k": "卡", "l": "拉", "m": "妈",
        "n": "拿", "o": "哦", "p": "趴", "q": "七", "r": "然", "s": "撒",
        "t": "他", "w": "挖", "x": "西", "y": "牙", "z": "扎",
    ]

    /// a 是否应排在 b 前面
    public static func isBefore(_ a: String, _ b: String) -> Bool {
        let ad = isDigitStart(a)
        let bd = isDigitStart(b)
        if ad != bd { return ad }
        if ad { return a.localizedCaseInsensitiveCompare(b) == .orderedAscending }
        let ia = initialLetter(a)
        let ib = initialLetter(b)
        if ia != ib { return ia < ib }
        return zhLess(a, b)
    }

    /// 按默认排序规则排序名称列表
    public static func sorted(_ names: [String]) -> [String] {
        names.sorted { isBefore($0, $1) }
    }

    /// 把移回「批量添加站点」列表的站点插入既有手动排序：
    /// 已有元素的相对顺序（用户手动排序）保持不变；已在 order 中的站点保留原位
    /// （卡片上原有的手动位置），其余返回站点先按名称默认序排序、再逐个插到其名称序位置
    /// （order 为空时结果即纯名称默认序，不追加到末尾）
    public static func reinsert(_ returnedIDs: [String], into order: [String], name: (String) -> String) -> [String] {
        let orderSet = Set(order)
        var out = order    // 已在排序中的站点保持原有位置（卡片上的手动位置）
        var seen = Set<String>()
        let toInsert = returnedIDs
            .filter { seen.insert($0).inserted && !orderSet.contains($0) }
            .sorted { isBefore(name($0), name($1)) }
        for id in toInsert {
            let n = name(id)
            // 插到第一个「名称序排在其后」的元素之前；都不排在其后则追加到末尾
            if let pos = out.firstIndex(where: { isBefore(n, name($0)) }) {
                out.insert(id, at: pos)
            } else {
                out.append(id)
            }
        }
        return out
    }

    /// 名称首字母：拉丁取首字母（小写）；中文用各首字母最小拼音字二分出拼音首字母
    static func initialLetter(_ s: String) -> Character {
        if let f = s.first, f.isASCII, f.isLetter { return Character(f.lowercased()) }
        var result: Character = "a"
        for c in "abcdefghijklmnopqrstuvwxyz" {
            guard let probe = probes[c] else { continue }
            if zhLess(probe, s) || s == probe { result = c }
        }
        return result
    }

    /// 以 ASCII 数字开头（中文数字汉字如「三」「百」的 Unicode Nt 属性也是数字，需排除）
    private static func isDigitStart(_ s: String) -> Bool {
        guard let f = s.first else { return false }
        return f.isASCII && f.isNumber
    }

    /// 拼音序（CLDR 中文语区排序 = 拼音，同音字按编码顺序）
    /// 用 Foundation 的本地化比较而不是直接调 CoreFoundation：mac 上它本来就是
    /// CFStringCompareWithOptionsAndLocale 的一层壳，结果一样；Windows 那套 Foundation 没有
    /// CoreFoundation 这个模块，但同样落到 ICU 的 CLDR 排序，三个平台一套代码。
    static func zhLess(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [], locale: zhLocale) == .orderedAscending
    }
}

extension Array {
    /// 按站点分组的排列先后排序：组号小的先，组内按卡片顺序；未分组的排最后并保持原顺序。
    /// 批量 cookie/API Key 检测用它保证「先检上面的分组」，与界面看到的顺序一致。
    public func sortedBySiteGroup(groups: [GroupConfig], id: (Element) -> String) -> [Element] {
        let ranked = enumerated().map { (offset, element) -> (rank: (Int, Int), offset: Int, element: Element) in
            let sid = id(element)
            var r: (Int, Int) = (groups.count, 0)
            for (gi, g) in groups.enumerated() {
                if let k = g.sites.firstIndex(of: sid) {
                    r = (gi, k)
                    break
                }
            }
            return (r, offset, element)
        }
        return ranked.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.offset < b.offset
        }.map(\.element)
    }
}
