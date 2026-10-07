import Foundation

/// 从发布名称解析质量标记。
/// 用途：1) 质量型分类（HDHome/TTG 按分辨率分区）；2) 各站 medium/codec/audiocodec/standard 下拉自动填充。
enum QualityTokens {
    /// 媒介/源介质 token
    static func medium(from name: String, kind: ReleaseKind?) -> String? {
        let n = name.lowercased()
        if n.contains("remux") { return "remux" }
        if kind == .music || n.contains("flac") || n.contains("ape") || n.contains("m4a") { return "track" }
        if n.contains("hdtv") { return "hdtv" }
        let isDisc = n.contains("bluray") || n.contains("blu-ray") || n.contains("bdrip") || n.contains("brrip") || n.contains("bdiso")
        let isWeb = n.contains("web-dl") || n.contains("webdl") || n.contains("web rip") || n.contains("webrip")
        let is8K = n.contains("8k") || n.contains("4320")
        let is4K = n.contains("2160p") || n.contains("4k") || n.contains("uhd")
        if is8K { return isDisc ? "uhdbd8k" : "uhd8k" }
        if is4K {
            if isDisc { return "uhdbd" }
            if isWeb { return "webdl" }
            return "uhd"
        }
        if n.contains("1080p") || n.contains("1080i") || n.contains("720p") || n.contains("1440p") || n.contains("2k") {
            if isDisc { return "bluray" }
            if isWeb { return "webdl" }
            return "encode"
        }
        if n.contains("dvd") { return "dvd" }
        return nil
    }

    /// 分辨率型分类 token（HDHome/TTG 的分类按分辨率划分）
    static func catProfile(from name: String, kind: ReleaseKind?) -> String? {
        let n = name.lowercased()
        if kind == .music { return nil }
        if n.contains("remux") { return "remux" }
        let isDisc = n.contains("bluray") || n.contains("blu-ray") || n.contains("bdrip") || n.contains("brrip") || n.contains("bdiso")
        let is8K = n.contains("8k") || n.contains("4320")
        let is4K = n.contains("2160p") || n.contains("4k") || n.contains("uhd")
        if is8K { return isDisc ? "8k-bd" : "8k" }
        if is4K { return isDisc ? "uhd-bd" : "2160p" }
        if n.contains("1440p") || n.contains("2k") { return "1440p" }
        if n.contains("1080p") { return "1080p" }
        if n.contains("1080i") { return "1080i" }
        if n.contains("720p") { return "720p" }
        if n.contains("dvd") { return "dvd" }
        if n.contains("480") || n.contains("sd") { return "sd" }
        return nil
    }

    static func codec(from name: String) -> String? {
        let n = name.lowercased()
        if n.contains("x265") || n.contains("hevc") || n.contains("h265") || n.contains("h.265") { return "hevc" }
        if n.contains("x264") || n.contains("avc") || n.contains("h264") || n.contains("h.264") { return "avc" }
        if n.contains("xvid") { return "xvid" }
        if n.contains("vc-1") || n.contains("vc1") { return "vc1" }
        if n.contains("av1") { return "av1" }
        if n.contains("mpeg-2") || n.contains("mpeg2") { return "mpeg2" }
        return nil
    }

    static func audio(from name: String) -> String? {
        let n = name.lowercased()
        if n.contains("dts:x") || n.contains("dts x") { return "dtsc" }
        if n.contains("dts-hd") || n.contains("dts hd") || n.contains("dts.hd") || n.contains("dts-hdma") {
            if n.contains(".ma") || n.contains("-ma") || n.contains(" ma") || n.contains("dma") { return "dtsma" }
            return "dtsbr"
        }
        if n.contains("truehd") { return n.contains("atmos") ? "truehd atmos" : "truehd" }
        if n.contains("e-ac3") || n.contains("eac3") || n.contains("ddp") { return n.contains("atmos") ? "eac3 atmos" : "eac3" }
        if n.contains("dd5") || n.contains("ac3") { return "ac3" }
        if n.contains("dts") { return "dts" }
        if n.contains("flac") { return "flac" }
        if n.contains("ape") { return "ape" }
        if n.contains("opus") { return "opus" }
        if n.contains("m4a") || n.contains("alac") { return "m4a" }
        if n.contains("aac") { return "aac" }
        if n.contains("mp3") { return "mp3" }
        if n.contains("ogg") { return "ogg" }
        if n.contains("wav") { return "wav" }
        if n.contains("lpcm") || n.contains("pcm") { return "pcm" }
        return nil
    }

    /// 发布名中的年份（第一个 19xx/20xx 四位数字）
    /// 规范标签判定（源名 + 简介 + mediainfo 文本证据）——各适配器共享
    /// 标签文案 -> 规范标签（源站"标签"行文案、目标站复选框文案共用一张表）
    /// 顺序 = 匹配优先级：atmos 先于 dovi（"杜比全景声"）、hdr10plus 先于 hdr10（"HDR10"是"HDR10+"子串）
    static let tagTextMap: [(tag: String, keywords: [String])] = [
        ("atmos", ["atmos", "全景声"]),
        ("dovi", ["dovi", "杜比视界", "杜比视频", "dolby vision"]),
        ("hdr10plus", ["hdr10+", "hdrm"]),
        ("hdr10", ["hdr10", "hdr"]),
        ("dtsx", ["dtsx", "dts:x"]),
        ("chinese_sub", ["中字", "中文字幕", "中文", "简中", "繁中", "zz"]),
        ("english_sub", ["英字", "英文字幕", "english sub"]),
        ("demand", ["应求", "应求种"]),
        ("mandarin", ["国语"]),
        ("cantonese", ["粤语", "粤配"]),
        ("forbid", ["禁转", "禁止转载", "jz"]),
        ("limited", ["限转", "xz"]),
        ("diy", ["diy", "自压"]),
        ("first", ["首发"]),
        ("disc", ["原盘"]),
        ("completed", ["完结", "完結", "全集", "complete", "finished"]),
        ("anime", ["动画", "动漫", "anime"]),
        ("remux", ["remux"]),
        // 题材标签：取源站「类别」行（财神等站按题材标签审核，缺题材标签会被打回）
        ("comedy", ["喜剧", "comedy"]),
        ("action", ["动作", "action"]),
        ("romance", ["爱情", "情色", "romance"]),
        ("drama", ["剧情", "drama"]),
        ("scifi", ["科幻", "sci-fi", "scifi"]),
        ("horror", ["恐怖", "horror"]),
        ("thriller", ["惊悚", "悬疑", "thriller", "mystery"]),
        ("documentary", ["纪录", "纪录片", "documentary"]),
        ("war", ["战争", "war"]),
        ("family", ["家庭", "family"]),
        ("crime", ["犯罪", "crime"]),
        ("history", ["历史", "古装", "history"]),
        ("sport", ["运动", "体育", "sport"]),
        ("fantasy", ["奇幻", "魔幻", "玄幻", "fantasy"]),
        ("adventure", ["冒险", "adventure"]),
        ("music_film", ["歌舞", "音乐", "music"]),
        ("children", ["儿童", "child"]),
        ("animation", ["动画", "动漫", "animation"]),
    ]

    /// 规范标签 -> 站点标签值/字段名 的映射见各站 overrides（tagMap / tagCheckboxes）
    static func canonicalTags(_ info: ReleaseInfo) -> [String] {
        var tags: [String] = []
        let n = info.name.uppercased()
        let evidence = HTMLUtil.stripTags(info.descr) + "\n" + info.mediainfo + "\n" + info.subtitle
        if n.contains("DTS:X") || n.contains("DTS X") { tags.append("dtsx") }
        if n.contains("ATMOS") { tags.append("atmos") }
        if n.contains("HDR10+") { tags.append("hdr10plus") }
        else if n.contains("HDR10") { tags.append("hdr10") }
        if n.contains("DOVI") || n.contains("DOLBY VISION") { tags.append("dovi") }
        if evidence.contains("中文字幕") || evidence.contains("简体") || evidence.contains("繁体") || evidence.contains("中文") || evidence.contains("中字") || info.name.contains("中字") {
            tags.append("chinese_sub")
        }
        if n.contains("DIY") && (n.hasPrefix("DIY") || n.contains(" DIY") || n.contains("DIY ") || n.contains("DIY-")) {
            tags.append("diy")
        }
        if ["bluray", "uhdbd", "uhdbd8k"].contains(medium(from: info.name, kind: info.kind)) {
            tags.append("disc")
        }
        if info.isForbidReseed { tags.append("forbid") }
        if evidence.contains("限转") { tags.append("limited") }
        if medium(from: info.name, kind: info.kind) == "remux" { tags.append("remux") }
        if info.kind == .anime { tags.append("anime") }
        if isCompletedRelease(info) { tags.append("completed") }
        // 源站"标签"行是打标最权威的依据（官方/英字/应求等无法从发布名推断）
        for raw in info.sourceTags {
            let s = raw.lowercased()
            for (tag, keywords) in tagTextMap where !tags.contains(tag) {
                if keywords.contains(where: { s.contains($0) }) { tags.append(tag) }
            }
        }
        for tag in genreTags(info.genre) where !tags.contains(tag) { tags.append(tag) }
        return tags
    }

    /// 源站「类别」行（如 "喜剧 / 动画"）解析成题材标签。
    /// 只看类别行，不从简介正文取，避免简介里的演职员/简介文案误命中标签。
    static func genreTags(_ genre: String) -> [String] {
        let lower = genre.lowercased()
        guard !lower.isEmpty else { return [] }
        let parts = lower.components(separatedBy: CharacterSet(charactersIn: "/、,;|,，； "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var out: [String] = []
        for part in parts {
            // 每个题材词只取第一个命中的规范标签（"动画" 归 anime，不再重复产出 animation）
            if let hit = tagTextMap.first(where: { e in e.keywords.contains { part == $0 || part.contains($0) } }) {
                if !out.contains(hit.tag) { out.append(hit.tag) }
            }
        }
        return out
    }

    /// 连载类（动漫/剧集/综艺）之外一律不打"完结"：电影、纪录片的简介里出现
    /// "完结"/"Complete name"（MediaInfo 字段）曾被误判成整季完结（多站误勾完结标签）。
    /// 判定顺序：连载类闸门 -> 源站"连载中/完结"标记 -> 文案完结标记 -> 整季包启发式。
    static func isCompletedRelease(_ info: ReleaseInfo) -> Bool {
        guard [.anime, .series, .tvshow].contains(info.kind ?? .other) else { return false }
        // 源站明确标注连载中时，一票否决（整季包启发式也不能翻案）
        if info.sourceTags.contains(where: {
            ["未完结", "未完結", "连载", "連載", "更新中", "正在更新", "分集"].contains($0)
        }) { return false }
        if info.sourceTags.contains(where: {
            ($0.contains("完结") || $0.contains("完結")) && !$0.contains("未")
        }) { return true }
        let raw = (HTMLUtil.stripTags(info.descr) + "\n" + info.subtitle + "\n" + info.name)
            .replacingOccurrences(of: "未完结", with: "")
            .replacingOccurrences(of: "未完結", with: "")
        if raw.range(of: "完结|完結|全集", options: .regularExpression) != nil { return true }
        if raw.range(of: "全\\s*\\d+\\s*[集话話]", options: .regularExpression) != nil { return true }
        // 英文 complete/finished：排除 MediaInfo 的 "Complete name" 字段行
        if raw.range(of: #"(?i)\b(complete|finished)\b(?!\s*name)"#, options: .regularExpression) != nil {
            return true
        }
        let n = info.name.uppercased()
        let season = n.range(of: #"S\d{1,2}(?![\dE])"#, options: .regularExpression) != nil
        let singleEpisode = n.range(of: #"(E\d{1,3}|第\s*\d+\s*[集话])"#, options: .regularExpression) != nil
        return season && !singleEpisode
    }

    /// 分类/标签文案的繁体字形归一：站点分类表多用繁体或中英混排（"紀錄教育""卡通動漫"），
    /// 只按简体关键词匹配会整批漏掉（1PTBA、麒麟、咖啡的纪录片分类曾因此上传失败）
    static func toSimplified(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s { out.append(tradToSimp[c] ?? c) }
        return out
    }

    /// 关键词匹配用的归一形式：小写 + 去空白 + 繁体转简体
    static func normLabel(_ s: String) -> String {
        toSimplified(s).lowercased()
            .replacingOccurrences(of: "[\\s\u{3000}\u{00A0}]+", with: "", options: .regularExpression)
    }

    private static let tradToSimp: [Character: Character] = {
        let t = Array("紀錄電視劇綜藝動樂會體賽軟遊戲書結質圖頭羅時兒愛驚曆戰險畫壓過網從為與廣慶態發種專業個們說話漢簡聯訊腦絡資優麗應臺張")
        let s = Array("纪录电视剧综艺动乐会体赛软游戏书结质图头罗时儿爱惊历战险画压过网从为与广庆态发种专业个们说话汉简联讯脑络资优丽应台张")
        precondition(t.count == s.count, "繁简映射表两侧字数必须一致")
        var m: [Character: Character] = [:]
        for (i, c) in t.enumerated() { m[c] = s[i] }
        return m
    }()

    static func year(from name: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: "(?<![0-9])(?:19|20)[0-9]{2}(?![0-9])") else { return nil }
        let ns = NSRange(name.startIndex..., in: name)
        for m in re.matches(in: name, options: [], range: ns) {
            guard let r = Range(m.range, in: name), let v = Int(String(name[r])), (1900...2100).contains(v) else { continue }
            return v
        }
        return nil
    }

    static func standard(from name: String) -> String? {
        let n = name.lowercased()
        if n.contains("8k") || n.contains("4320") { return "8k" }
        if n.contains("2160p") || n.contains("4k") || n.contains("uhd") { return "2160p" }
        if n.contains("1080p") { return "1080p" }
        if n.contains("1080i") { return "1080i" }
        if n.contains("720p") { return "720p" }
        if n.contains("480") || n.contains("sd") || n.contains("dvd") { return "sd" }
        return nil
    }
}
