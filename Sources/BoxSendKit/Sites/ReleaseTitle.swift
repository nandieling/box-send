import Foundation

/// 目标站主标题的统一改写规则（所有框架、所有目标站共用）。
///
/// 蓝光 Remux 的片源写法在多个站点是硬性校验：写成 "Blu-ray" 会被直接拒收
/// （春天、青蛙都报「标题片源拼写错误：Remux 资源，片源必须拼写为 BluRay」），
/// 所以这条规则默认对所有转种目标站生效。站点自身还有别的写法要求时，
/// 在 overrides.remuxTitleTokens 里追加，规则与默认表一起按整词应用。
enum ReleaseTitle {

    /// 全站点默认改写：只在发布名含独立 Remux 段时生效
    static let defaultRemuxTokens: [String: String] = ["Blu-ray": "BluRay"]

    /// 发布名里是否有独立的 Remux 段（按 . _ - 空格 分词，避免 REMUXED 之类误判）
    static func hasRemuxToken(_ title: String) -> Bool {
        title.range(of: #"(?i)(^|[._\s-])remux($|[._\s-])"#, options: .regularExpression) != nil
    }

    /// 默认表 + 本站追加规则一起改写（长 token 先替换，避免 "UHD Blu-ray" 被短 token 抢走）
    static func rewrite(_ title: String, extraTokens: [String: String]? = nil) -> String {
        var table = defaultRemuxTokens
        for (k, v) in extraTokens ?? [:] { table[k] = v }
        return rewrite(title, tokens: table)
    }

    /// 按给定表整词改写（保留原来的分隔符与点号风格）
    /// "…1080p.Blu-ray.Remux.AVC…" -> "…1080p.BluRay.Remux.AVC…"
    static func rewrite(_ title: String, tokens table: [String: String]) -> String {
        guard hasRemuxToken(title) else { return title }
        var out = title
        for (token, replacement) in table.sorted(by: { $0.key.count > $1.key.count })
        where !token.isEmpty && !replacement.isEmpty {
            let pattern = "(?i)(^|[._\\s-])" + NSRegularExpression.escapedPattern(for: token) + "(?=$|[._\\s-])"
            let safe = replacement.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "$", with: "\\$")
            out = out.replacingOccurrences(of: pattern, with: "$1" + safe, options: [.regularExpression])
        }
        return out
    }
}
