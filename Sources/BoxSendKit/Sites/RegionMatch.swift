import Foundation

/// 产地（源站简介"产地"/"制片国家/地区"行）-> 上传页地区下拉选项。
/// 各站把这个下拉叫"来源/地区/产地"，字段名也不统一（熊猫/优堡/麒麟/咖啡是 source_sel，
/// 蟹黄堡是 processing_sel，HDVideo 是 region_sel），所以只按选项文案认出真正的地区表，再按产地取值。
enum RegionMatch {
    /// codes: 缩写（只按独立词元匹配，避免 "Australia" 里的 "us" 误命中）
    private struct Row { let region: String; let keys: [String]; let codes: [String]; let avoid: [String] }

    /// 规范产地 -> 选项文案关键词（中英与缩写都可能出现："JPN(日本)"/"日本(Japanese)"/"JPN/日本"）
    private static let table: [Row] = [
        Row(region: "日本", keys: ["日本", "jpn", "japan"], codes: ["jp"], avoid: []),
        Row(region: "韩国", keys: ["韩国", "korea", "kor"], codes: ["kr"], avoid: []),
        Row(region: "中国大陆", keys: ["中国大陆", "大陆", "中国", "china mainland", "chn"], codes: ["cn"], avoid: ["台湾", "香港", "台", "港", "tw", "hk"]),
        Row(region: "中国香港", keys: ["香港", "hong kong"], codes: ["hk"], avoid: []),
        Row(region: "中国台湾", keys: ["台湾", "taiwan"], codes: ["tw"], avoid: []),
        Row(region: "港台", keys: ["港台", "港澳台"], codes: ["hk/tw", "hktw"], avoid: []),
        Row(region: "美国", keys: ["美国", "usa", "united states", "欧美", "eur", "西方"], codes: ["us"], avoid: []),
        Row(region: "英国", keys: ["英国", "united kingdom", "england"], codes: ["uk", "gb"], avoid: []),
        Row(region: "法国", keys: ["法国", "france", "french", "欧洲", "eu"], codes: ["fr"], avoid: []),
        Row(region: "德国", keys: ["德国", "germany", "欧洲", "eu"], codes: ["de"], avoid: []),
        Row(region: "意大利", keys: ["意大利", "italy", "欧洲", "eu"], codes: ["it"], avoid: []),
        Row(region: "西班牙", keys: ["西班牙", "spain", "欧洲", "eu"], codes: ["es"], avoid: []),
        Row(region: "瑞典", keys: ["瑞典", "sweden", "欧洲", "eu"], codes: ["se"], avoid: []),
        Row(region: "加拿大", keys: ["加拿大", "canada"], codes: ["ca"], avoid: []),
        Row(region: "印度", keys: ["印度", "india"], codes: ["in"], avoid: []),
        Row(region: "泰国", keys: ["泰国", "thailand"], codes: ["th"], avoid: []),
        Row(region: "俄罗斯", keys: ["俄罗斯", "russia"], codes: ["ru"], avoid: []),
        Row(region: "澳大利亚", keys: ["澳大利亚", "澳洲", "australia"], codes: ["au"], avoid: []),
        Row(region: "新西兰", keys: ["新西兰", "new zealand"], codes: ["nz"], avoid: []),
        Row(region: "丹麦", keys: ["丹麦", "denmark"], codes: ["dk"], avoid: []),
        Row(region: "北欧", keys: ["北欧", "nordic", "scandinavian"], codes: [], avoid: []),
    ]

    /// 发布名里的国家词元（scene 发布常见的三字母国家码）-> 产地：简介没写产地时用
    private static let nameCodes: [(region: String, codes: [String])] = [
        ("日本", ["jpn", "jap", "japan", "japanese", "jp"]),
        ("韩国", ["kor", "korea", "korean", "kr"]),
        ("中国香港", ["hk", "hongkong", "hong kong"]),
        ("中国台湾", ["tw", "twn", "taiwan"]),
        ("中国大陆", ["chn", "china", "mainland", "cn"]),
        ("美国", ["usa", "unitedstates", "american", "us"]),
        ("英国", ["uk", "gbr", "england", "british"]),
        ("法国", ["fra", "france", "french"]),
        ("德国", ["ger", "deu", "germany", "german"]),
    ]

    /// 标签里的独立词元（按非字母数字切分后的小写段）
    static func tokens(of label: String) -> Set<String> {
        Set(label.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }

    /// 任意产地写法（"日本"/"Japan"/"JPN"/"制片国家/地区: 日本"）-> 表内规范产地；认不出返回 nil
    static func canonical(_ text: String) -> String? {
        let norm = QualityMatcher.normalize(text)
        guard !norm.isEmpty else { return nil }
        let toks = tokens(of: text)
        var best: (len: Int, region: String)?
        for row in table {
            guard !row.avoid.contains(where: { norm.contains($0) }) else { continue }
            var longest = 0
            for key in row.keys where norm.contains(key) { longest = max(longest, key.count) }
            for code in row.codes where toks.contains(code) { longest = max(longest, 2) }
            guard longest > 0 else { continue }
            if best == nil || longest > best!.len { best = (longest, row.region) }
        }
        return best?.region
    }

    /// 产地文本（"日本"/"美国"/"中国"）-> 选项值；该下拉不含此产地时返回 nil（保持表单默认值）
    static func option(forRegion region: String, in options: [(value: String, label: String)]) -> String? {
        let want = region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty else { return nil }
        let name = canonical(want)
            ?? table.first(where: { want.hasSuffix($0.region) || $0.region.hasSuffix(want) })?.region
        guard let name, let row = table.first(where: { $0.region == name }) else { return nil }
        var best: (score: Int, order: Int, value: String)?
        for (i, o) in options.enumerated() where o.value != "0" {
            let norm = QualityMatcher.normalize(o.label)
            guard !row.avoid.contains(where: { norm.contains($0) }) else { continue }
            var score = 10 - min(i, 9)
            var longest = 0
            for key in row.keys where norm.contains(key) { longest = max(longest, key.count) }
            // 缩写只按独立词元匹配：站点常写成 "JP(日)" / "US/EU(欧美)"
            for code in row.codes where Self.tokens(of: o.label).contains(code) {
                longest = max(longest, 2)
            }
            guard longest > 0 else { continue }
            score += longest
            if norm.contains("其它") || norm.contains("其他") || norm.contains("other") { score -= 6 }
            if best == nil || score > best!.score { best = (score, i, o.value) }
        }
        return best?.value
    }

    /// 选项文案是不是地区表（至少 3 项能对上已知产地）：没写产地时，只有地区表才允许填
    /// 推断值或「其他」兜底，免得把国家名填进媒介/来源那类下拉
    static func looksLikeRegionTable(_ options: [(value: String, label: String)]) -> Bool {
        options.filter { $0.value != "0" && canonical($0.label) != nil }.count >= 3
    }

    /// 地区表里的兜底项：「其他/其它/Other/其他地区/其他国家」（HDVideo 的 28=其他地区）
    static func otherOption(_ options: [(value: String, label: String)]) -> String? {
        options.first { o in
            guard o.value != "0" else { return false }
            var n = QualityMatcher.normalize(o.label)
            for w in ["其他地区", "其它地区", "其他地区", "其他国家", "其它国家", "其它国家",
                      "others", "other", "其他", "其它", "请选择", "地区", "国家", "产地"] {
                n = n.replacingOccurrences(of: w, with: "")
            }
            return n.isEmpty
        }?.value
    }

    /// 简介没写产地时给地区下拉推断产地：先认发布名里的国家词元（JPN/USA/HK…），
    /// 再退到「动画=日本」（国漫/国创一般带中文标记，不猜）。认不出返回 nil。
    static func guess(info: ReleaseInfo) -> String? {
        let toks = tokens(of: info.name)
        for row in nameCodes where row.codes.contains(where: { toks.contains($0) }) { return row.region }
        guard info.kind == .anime else { return nil }
        let text = QualityMatcher.normalize([info.name, info.subtitle, info.genre].joined(separator: " "))
        if ["国漫", "国创", "国产", "大陆", "华语", "国语", "中国"].contains(where: { text.contains($0) }) { return nil }
        return "日本"
    }
}
