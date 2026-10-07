import Foundation

/// Bangumi（番组计划）条目：馒头（Unit3D）动画分类「动画 / 动画-BluRay」发种必填。
///
/// 站点发种页只认 bangumi.tv / bgm.tv 的 subject 链接，且限制长度（去掉跟踪参数）。
/// 这里负责三件事：从源站信息里找出已有条目、生成检索关键词、给搜索结果打分。
enum Bangumi {
    /// 搜索结果里的一个候选条目（字段名沿用站方 media/bangumi/search 响应）
    struct Candidate {
        var id: String
        var names: [String]      // 原名 / 中文名 / 别名
        var date: String         // 放送开始 YYYY-MM-DD
        var type: Int            // 2 = 动画
        var nsfw: Bool
        var platform: String     // TV / OVA / WEB / MOVIE …
        var episodes: Int        // 话数（未知 0）

        init(id: String, names: [String], date: String, type: Int, nsfw: Bool,
             platform: String = "", episodes: Int = 0) {
            self.id = id
            self.names = names
            self.date = date
            self.type = type
            self.nsfw = nsfw
            self.platform = platform
            self.episodes = episodes
        }

        init?(row: [String: Any]) {
            guard let raw = row["id"] else { return nil }
            let sid: String
            if let s = raw as? String { sid = s }
            else if let i = raw as? Int { sid = String(i) }
            else if let d = raw as? Double { sid = String(Int(d)) }
            else { return nil }
            var list: [String] = []
            for key in ["name_cn", "name"] {
                if let v = row[key] as? String, !v.isEmpty { list.append(v) }
            }
            self.id = sid
            self.names = list
            self.date = (row["date"] as? String) ?? ""
            let t = row["type"]
            self.type = (t as? Int) ?? Int((t as? String) ?? "") ?? 0
            self.nsfw = (row["nsfw"] as? Bool) ?? ((row["nsfw"] as? String).map { $0 == "true" } ?? false)
            self.platform = ((row["platform"] as? String) ?? "").uppercased()
            let eps = row["eps"] ?? row["total_episodes"]
            self.episodes = (eps as? Int) ?? Int((eps as? String) ?? "") ?? 0
        }

        /// 条目年份（date 前四位）
        var year: Int? {
            guard date.count >= 4, let y = Int(date.prefix(4)) else { return nil }
            return (1900...2100).contains(y) ? y : nil
        }
    }

    // MARK: - 链接

    /// 归一化条目号：接受完整链接（含任意跟踪参数）、/subject/123、纯数字
    static func subjectID(from text: String?) -> String? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.allSatisfy({ $0.isNumber }) { return raw }
        // 必须是番组计划的条目页：豆瓣/IMDb 也有 /subject/、/title/ 结构，不能误认
        guard isBangumiURL(raw) else { return nil }
        for pat in ["/subject/(\\d+)", "[?&](?:subject_id|subject)=(\\d+)"] {
            if let id = HTMLUtil.group(raw, pat, options: [.caseInsensitive]) { return id }
        }
        return nil
    }

    /// 是否番组计划系域名（含 chibimaru 等镜像）
    static func isBangumiURL(_ s: String) -> Bool {
        guard let host = URL(string: s)?.host?.lowercased() else {
            return containsHostPattern(s)
        }
        return ["bangumi.tv", "bgm.tv", "chibimaru.tv", "bangumi.moe"].contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }

    /// 没有 scheme 的裸链接（"bangumi.tv/subject/123"）按文本判断
    private static func containsHostPattern(_ s: String) -> Bool {
        HTMLUtil.group(s, "^(?:www\\.)?(?:bangumi\\.tv|bgm\\.tv|chibimaru\\.tv|bangumi\\.moe)/", options: [.caseInsensitive]) != nil
    }

    /// 站点发种页接受的规范链接（bangumi.tv 主域，不带参数）
    static func link(subjectID: String) -> String { "https://bangumi.tv/subject/\(subjectID)" }

    /// 从源站简介 HTML 里找 Bangumi 条目（不少源站简介直接贴了条目链接）
    static func subjectID(inHTML html: String) -> String? {
        let hosts = ["bangumi\\.tv", "bgm\\.tv", "chibimaru\\.tv", "bangumi\\.moe"]
        for host in hosts {
            if let id = HTMLUtil.group(html, "(?:https?://)?(?:www\\.)?\(host)/subject/(\\d+)") { return id }
        }
        return nil
    }

    // MARK: - 检索关键词

    /// 从种子名/副标题提取检索词：中日文标题优先，其次英文标题（去掉站名前缀、季号、清晰度等噪声）
    static func searchKeywords(from info: ReleaseInfo) -> [String] {
        var out: [String] = []
        func add(_ s: String?) {
            guard var t = s?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            t = stripNoise(t)
            guard t.count >= 2 else { return }
            if !out.contains(where: { $0.compare(t, options: .caseInsensitive) == .orderedSame }) { out.append(t) }
        }
        add(longestCJK(in: info.name))
        add(firstCJK(in: info.name))
        add(latinTitle(in: info.name))
        add(info.subtitle)
        return Array(out.prefix(4))
    }

    /// 标题噪声：站名标签、季号、"全N话"、清晰度等（Bangumi 检索对噪声很敏感）
    static func stripNoise(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: [.regularExpression, .caseInsensitive])
        for pat in [#"第\s*[0-9一二三四五六七八九十百零]+\s*[季部话篇]"#,
                    #"S\d{1,2}(?:E\d{1,3})?"#,
                    #"全\s*\d+\s*[话集卷]"#,
                    #"(?:19|20)\d{2}"#,
                    #"\d{3,4}[pi]"#] {
            t = t.replacingOccurrences(of: pat, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        t = t.replacingOccurrences(of: #"[._\-/]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cjkRuns(in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}]{2,}"#) else { return [] }
        let ns = NSRange(s.startIndex..., in: s)
        return re.matches(in: s, options: [], range: ns).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    private static func longestCJK(in s: String) -> String? {
        let runs = cjkRuns(in: s).filter { !isSeasonNoise($0) }
        return runs.max { $0.count < $1.count }
    }

    private static func firstCJK(in s: String) -> String? {
        cjkRuns(in: s).first { !isSeasonNoise($0) }
    }

    private static func isSeasonNoise(_ s: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "^(?:第[0-9一二三四五六七八九十百零]+[季部话篇]|全集?|剧场版|OVA|OAD|SP|番外)$",
                                                options: .caseInsensitive) else { return false }
        return re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// 英文标题：跳过中日文 token，截到第一个年份/清晰度等噪声 token 为止
    ///（"[站名].摇曳百合.Yuru.Yuri.S03.2015.1080p.BluRay…" -> "Yuru Yuri"）
    static func latinTitle(in name: String) -> String? {
        let cleaned = stripNoise(name)
        var words: [String] = []
        for token in cleaned.split(separator: " ") {
            let low = token.lowercased()
            if low.isEmpty { continue }
            if containsCJK(String(token)) { continue }
            if low.allSatisfy({ $0.isNumber }) { break }
            if noiseTokens.contains(low) { break }
            words.append(String(token))
            if words.count >= 6 { break }
        }
        let t = words.joined(separator: " ")
        return t.count >= 3 ? t : nil
    }

    /// 清晰度/编码/站点标注：出现在标题中间即视为标题结束
    static let noiseTokens: Set<String> = [
        "remux", "bluray", "blu-ray", "bdrip", "brrip", "bdmv", "bd", "dvd", "hdtv", "webdl", "web",
        "x264", "x265", "hevc", "avc", "h264", "h265", "av1", "aac", "flac", "lpcm", "dts", "atmos",
        "hdr", "hdr10", "hdr10+", "dovi", "2160p", "1080p", "1080i", "720p", "480p", "4k", "uhd",
        "2audios", "dual", "audio", "audios", "chs", "cht", "chi", "jap", "ja", "zh", "10bit", "8bit",
        "complete", "ova", "oad", "vol", "fin"]

    /// 特别篇（剧场版/OVA/OAD/SP）：这类发布要挑对应的短篇条目，而不是正季
    static func isSpecialRelease(_ name: String) -> Bool {
        let n = name.uppercased()
        return ["剧场版", "劇場版", "电影版", "OAD", "OVA"].contains(where: { name.contains($0) })
            || ["THE MOVIE", "MOVIE", " MOV "].contains(where: { n.contains($0) })
            || HTMLUtil.group(n, #"(^|[^A-Z])SP[0-9]?($|[^A-Z])"#) != nil
    }

    static func containsCJK(_ s: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}]"#) else { return false }
        return re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: - 打分选择

    /// 为候选打分：标题命中为主，年份/动画类型加成，R18 扣分
    static func score(_ candidate: Candidate, keywords: [String], year: Int?, special: Bool = false) -> Int {
        var best = 0
        for keyword in keywords {
            let k = normalize(keyword)
            guard k.count >= 2 else { continue }
            for name in candidate.names {
                let n = normalize(name)
                guard n.count >= 2 else { continue }
                if n == k { best = max(best, 8) }
                else if n.contains(k) || k.contains(n) { best = max(best, 6) }
                else {
                    let kt = Set(tokenize(keyword)), nt = Set(tokenize(name))
                    let inter = kt.intersection(nt).count
                    if inter >= 2 { best = max(best, 3 * inter / max(kt.count, 1) + 1) }
                }
            }
        }
        if best == 0 { return 0 }
        if candidate.type == 2 { best += 2 }
        if let ey = candidate.year, let year {
            if ey == year { best += 3 } else if abs(ey - year) == 1 { best += 1 }
        }
        // 同名多条目（TV 各季 / OVA / 剧场版）：按发布形态加成，避免把 OVA 当成本季
        if special {
            if ["OVA", "MOVIE", "剧场版"].contains(candidate.platform) { best += 2 }
            if candidate.episodes > 0 && candidate.episodes <= 2 { best += 1 }
        } else {
            if candidate.platform == "TV" { best += 2 }
            if candidate.episodes >= 6 { best += 1 }
        }
        if candidate.nsfw { best -= 4 }
        return best
    }

    /// 选出可信的条目：返回（规范链接，命中分数）；都不够可信时返回 nil
    static func pick(_ candidates: [Candidate], keywords: [String], year: Int?,
                     special: Bool = false, minScore: Int = 6) -> (link: String, score: Int)? {
        var best: (id: String, score: Int)?
        for c in candidates {
            let s = score(c, keywords: keywords, year: year, special: special)
            guard s >= minScore else { continue }
            if best == nil || s > best!.score { best = (c.id, s) }
        }
        if let b = best { return (link(subjectID: b.id), b.score) }
        // 标题只有罗马字/英文时，本地无法与中文条目比对；此时采信站方检索结果：
        // 优先"有整季话数"的条目（OVA/SP 不算一季），再取放送日期离发布年份最近的
        guard !keywords.contains(where: { containsCJK($0) }) else { return nil }
        var usable = candidates.filter { $0.type == 2 && !$0.nsfw }
        guard !usable.isEmpty else { return nil }
        if !special {
            let seasons = usable.filter { $0.episodes >= 6 }
            if !seasons.isEmpty { usable = seasons }
        }
        guard let year else { return (link(subjectID: usable[0].id), 0) }
        let nearest = usable.min { dateDistance($0.date, year) < dateDistance($1.date, year) }!
        return (link(subjectID: nearest.id), 0)
    }

    /// 逐个关键词检索，取首个可信结果（search 由调用方注入，便于单测）
    static func resolve(_ info: ReleaseInfo, minScore: Int = 6,
                        search: (String) -> [Candidate]) -> (link: String, keyword: String)? {
        if let id = subjectID(from: info.bangumi) { return (link(subjectID: id), "源站条目") }
        let year = QualityTokens.year(from: info.name)
        let special = isSpecialRelease(info.name)
        for kw in searchKeywords(from: info) {
            let rows = search(kw)
            if let hit = pick(rows, keywords: [kw] + searchKeywords(from: info), year: year,
                              special: special, minScore: minScore) {
                return (hit.link, kw)
            }
        }
        return nil
    }

    /// 条目日期与"发布年份年中"的天数差（只有年份可比时的粗略距离）
    static func dateDistance(_ date: String, _ year: Int) -> Int {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 1, let y = parts.first else { return 9999 }
        let days = (y * 372 + (parts.count > 1 ? parts[1] : 7) * 31 + (parts.count > 2 ? parts[2] : 15))
            - (year * 372 + 7 * 31 + 15)
        return abs(days)
    }

    private static func normalize(_ s: String) -> String {
        let t = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        return t.replacingOccurrences(of: #"[^0-9a-z\p{Han}\p{Hiragana}\p{Katakana}]"#,
                                      with: "", options: .regularExpression)
    }

    private static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 2 }
            .map(String.init)
    }
}
