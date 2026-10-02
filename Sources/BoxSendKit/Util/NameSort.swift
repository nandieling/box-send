import Foundation
import CoreFoundation

/// 站点名称默认排序：数字开头的名称在前（按名称不区分大小写比较），
/// 其余按拼音字母顺序（中文取拼音首字母、纯拉丁名取首字母，同一首字母内按 zh-Hans-CN 拼音序）
public enum NameSort {
    private static let zhLocale: CFLocale = Locale(identifier: "zh-Hans-CN") as CFLocale

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
    static func zhLess(_ a: String, _ b: String) -> Bool {
        CFStringCompareWithOptionsAndLocale(
            a as CFString, b as CFString,
            CFRange(location: 0, length: a.utf16.count), [], zhLocale
        ).rawValue < 0
    }
}
