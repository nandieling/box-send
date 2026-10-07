import Foundation

/// 产地（源站简介"产地"行）-> 上传页地区下拉选项。
/// 各站把这个下拉叫"来源/地区/产地"，字段名也不统一（熊猫/优堡/麒麟/咖啡是 source_sel，
/// 蟹黄堡是 processing_sel），所以只按选项文案认出真正的地区表，再按产地取值。
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
    ]

    /// 标签里的独立词元（按非字母数字切分后的小写段）
    static func tokens(of label: String) -> Set<String> {
        Set(label.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }

    /// 产地文本（"日本"/"美国"/"中国"）-> 选项值；该下拉不含此产地时返回 nil（保持表单默认值）
    static func option(forRegion region: String, in options: [(value: String, label: String)]) -> String? {
        let want = region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty else { return nil }
        let row = table.first(where: { $0.region == want })
            ?? table.first(where: { want.hasSuffix($0.region) || $0.region.hasSuffix(want) })
        guard let row else { return nil }
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
}
