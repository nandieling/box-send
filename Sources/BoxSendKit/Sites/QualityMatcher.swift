import Foundation

/// 质量下拉动态匹配：按 token 关键词匹配站点选项文本（新 NexusPHP 站免逐站配置）。
/// 各站选项文案差异大（"H.265/HEVC" vs "H265" vs "x265"），统一 normalize 后做子串匹配，
/// 命中失败时按回退链尝试次优 token，最终回退到第一个有效选项。
enum QualityMatcher {

    /// 小写并去掉常见分隔符/标点，便于子串匹配
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        for ch in [" ", "\t", "-", "_", "/", "\\", ".", "(", ")", "[", "]", "|", "+", ":", "：", ",", "，", "\"", "'", "&"] {
            t = t.replacingOccurrences(of: ch, with: "")
        }
        return t
    }

    /// token -> (需包含的任一子串, 需全部不包含的子串)
    private struct Rule { let match: [String]; let exclude: [String] }

    private static let rules: [String: [String: Rule]] = [
        "medium": [
            "remux": Rule(match: ["remux"], exclude: []),
            "uhdbd": Rule(match: ["uhd", "4kultrahd"], exclude: ["uhdtv", "iptv"]),
            // 站点写法差异大："Blu-ray" / "BD 原盘"（库非）/ "Blu-Ray(原盘)"（铂金家）；
            // MiniBD 是小体积压制、BDRip 是重编码，都不算碟
            "bluray": Rule(match: ["bluray", "bd"], exclude: ["uhd", "mini", "rip"]),
            "webdl": Rule(match: ["webdl"], exclude: []),
            "webrip": Rule(match: ["webrip"], exclude: []),
            "hdtv": Rule(match: ["hdtv", "iptv", "tv"], exclude: ["uhdtv"]),
            "dvd": Rule(match: ["dvd"], exclude: []),
            "cd": Rule(match: ["cd", "sacd"], exclude: []),
            "track": Rule(match: ["track", "lossless", "无损"], exclude: []),
            "encode": Rule(match: ["encode", "rip", "压制"], exclude: []),
            "other": Rule(match: ["other", "其它", "其他"], exclude: []),
        ],
        // 站点常写裸数字（"1080"）或合并写法（"1080p/1080i/FHD"），裸数字兜底不可缺。
        // 3D 选项一律排除：52PT 的 "1080P-3D" 前缀更长会盖过 "2K/1080p"
        "standard": [
            "8k": Rule(match: ["8k", "4320"], exclude: ["3d"]),
            "2160p": Rule(match: ["2160", "4k"], exclude: ["3d"]),
            "1440p": Rule(match: ["1440", "2k"], exclude: ["3d"]),
            "1080p": Rule(match: ["1080p", "1080"], exclude: ["3d"]),
            "1080i": Rule(match: ["1080i", "1080"], exclude: ["3d"]),
            "720p": Rule(match: ["720"], exclude: ["3d"]),
            "sd": Rule(match: ["sd", "480", "576"], exclude: ["3d"]),
            "other": Rule(match: ["other", "其它", "其他"], exclude: []),
        ],
        "codec": [
            "hevc": Rule(match: ["h265", "hevc", "x265"], exclude: []),
            "avc": Rule(match: ["h264", "avc", "x264"], exclude: []),
            "vc1": Rule(match: ["vc1"], exclude: []),
            "mpeg2": Rule(match: ["mpeg2"], exclude: []),
            "av1": Rule(match: ["av1"], exclude: []),
            "xvid": Rule(match: ["xvid"], exclude: []),
            "vp9": Rule(match: ["vp9", "vp8"], exclude: []),
            "vvc": Rule(match: ["h266", "vvc"], exclude: []),
            "prores": Rule(match: ["prores"], exclude: []),
        ],
        "audiocodec": [
            // 站点常只写 "DTS-HD"（劳改所），不能因为缺 "MA" 就退到 TrueHD
            "dtsma": Rule(match: ["dtshdma", "dtshd"], exclude: []),
            "truehd": Rule(match: ["truehd"], exclude: []),
            "dtsx": Rule(match: ["dtsx"], exclude: []),
            "dtsc": Rule(match: ["dtsc"], exclude: []),
            "eac3": Rule(match: ["eac3", "ddp", "dolbydigitalplus"], exclude: []),
            "ac3": Rule(match: ["ac3", "dd"], exclude: []),
            "dts": Rule(match: ["dts"], exclude: ["dtshd", "dtsx", "dtsc"]),
            "flac": Rule(match: ["flac"], exclude: []),
            "ape": Rule(match: ["ape"], exclude: []),
            "aac": Rule(match: ["aac"], exclude: []),
            "mp3": Rule(match: ["mp3"], exclude: []),
            "pcm": Rule(match: ["pcm"], exclude: []),
            "ogg": Rule(match: ["ogg"], exclude: []),
            "m4a": Rule(match: ["m4a"], exclude: []),
            "opus": Rule(match: ["opus"], exclude: []),
            "alac": Rule(match: ["alac"], exclude: []),
            "wav": Rule(match: ["wav"], exclude: []),
            "other": Rule(match: ["other", "其它", "其他"], exclude: []),
            "dsd": Rule(match: ["dsd"], exclude: []),
            "av3a": Rule(match: ["av3a"], exclude: []),
        ],
        // 来源（source_sel）：转种既不是本站官种、也不是本站原创，优先「转载/转种」，
        // 其次纯兜底「其他」；官方/原创/自拍这类归属声明不参与兜底
        "source": [
            "reseed": Rule(match: ["转载", "转种"], exclude: ["官方", "原创"]),
            "other": Rule(match: ["other", "其它", "其他"], exclude: []),
        ],
        // 处理（processing_sel）：各站语义不同（烧包=处理方式、麒麟=年份、蟹黄堡=地区），
        // 匹配不到就留空，不用 first 兜底
        "processing": [
            "remux": Rule(match: ["remux"], exclude: []),
            // 不收裸 "blu"：城市站的"3D Red-blue/红蓝"会被它误命中
            "disc": Rule(match: ["原盘", "bluray", "蓝光", "bdrip"], exclude: []),
            "encode": Rule(match: ["重编码", "压制", "encode", "rip"], exclude: []),
            "web": Rule(match: ["源码", "webdl", "流媒体", "web"], exclude: []),
            "other": Rule(match: ["other", "其它", "其他"], exclude: []),
        ],
    ]

    /// 回退链：命中失败时依次尝试次优 token；"first" = 第一个有效选项（非"请选择"）
    private static let chains: [String: [String: [String]]] = [
        "medium": [
            "remux": ["remux", "bluray", "uhdbd", "encode", "webdl", "dvd", "other", "first"],
            "uhdbd": ["uhdbd", "bluray", "remux", "webdl", "other", "first"],
            "bluray": ["bluray", "uhdbd", "remux", "encode", "other", "first"],
            "webdl": ["webdl", "webrip", "hdtv", "other", "first"],
            "webrip": ["webrip", "webdl", "hdtv", "other", "first"],
            "hdtv": ["hdtv", "webrip", "dvd", "other", "first"],
            "dvd": ["dvd", "encode", "other", "first"],
            "encode": ["encode", "webrip", "hdtv", "other", "first"],
            "track": ["track", "cd", "other", "first"],
            "cd": ["cd", "track", "other", "first"],
            "other": ["other", "first"],
        ],
        "standard": [
            "8k": ["8k", "2160p", "first"],
            "2160p": ["2160p", "8k", "1440p", "1080p", "first"],
            "1440p": ["1440p", "1080p", "720p", "first"],
            "1080p": ["1080p", "1080i", "720p", "other", "first"],
            "1080i": ["1080i", "1080p", "first"],
            "720p": ["720p", "sd", "first"],
            "sd": ["sd", "720p", "first"],
        ],
        "source": [
            "reseed": ["reseed", "other"],
            "other": ["other"],
        ],
        "processing": [
            "remux": ["remux", "disc", "other"],
            "uhdbd": ["disc", "remux", "other"],
            "bluray": ["disc", "remux", "other"],
            "webdl": ["web", "encode", "other"],
            "webrip": ["web", "encode", "other"],
            "encode": ["encode", "other"],
            "other": ["other"],
        ],
        "codec": [
            "hevc": ["hevc", "av1", "vvc", "avc", "first"],
            "avc": ["avc", "hevc", "mpeg2", "vc1", "first"],
            "vc1": ["vc1", "avc", "mpeg2", "first"],
            "mpeg2": ["mpeg2", "avc", "vc1", "first"],
            "av1": ["av1", "hevc", "vp9", "first"],
            "xvid": ["xvid", "avc", "mpeg2", "first"],
            "vp9": ["vp9", "av1", "hevc", "first"],
            "vvc": ["vvc", "hevc", "av1", "first"],
            "prores": ["prores", "first"],
        ],
        "audiocodec": [
            // 音频不做「第一个选项」兜底：站点没列出这个编码时宁可不选
            // （慕雪阁的动漫音频表里没有 FLAC，按老链会勾成 APE）
            "dtsma": ["dtsma", "truehd", "dtsx", "dtsc", "dts", "eac3", "ac3", "aac"],
            "truehd": ["truehd", "dtsma", "eac3", "ac3"],
            "dtsx": ["dtsx", "dtsma", "dts", "eac3"],
            "dtsc": ["dtsc", "dts", "dtsx"],
            "eac3": ["eac3", "ac3", "aac"],
            "ac3": ["ac3", "eac3", "aac"],
            "dts": ["dts", "dtsx", "dtsc", "ac3", "aac"],
            "flac": ["flac"],
            "ape": ["ape"],
            "aac": ["aac", "m4a", "mp3"],
            "mp3": ["mp3", "aac"],
            "pcm": ["pcm", "other"],
            "ogg": ["ogg"],
            "m4a": ["m4a", "aac"],
            "opus": ["opus", "ogg"],
            "alac": ["alac", "flac"],
            "wav": ["wav", "pcm", "other"],
            "dsd": ["dsd", "flac"],
            "av3a": ["av3a", "dts", "ac3"],
        ],
    ]

    /// 年份型下拉（个别站 codec 下拉实为年份）：精确年份 -> 最近更低年 -> "N年前/更早" 兜底
    static func matchYear(_ year: Int, options: [(value: String, label: String)]) -> String? {
        let items = options.map { (value: $0.value, norm: normalize($0.label)) }.filter { $0.value != "0" }
        let years = items.compactMap { i -> (Int, String)? in
            guard let v = Int(i.norm), i.norm.count == 4, (1900...2100).contains(v) else { return nil }
            return (v, i.value)
        }
        guard !years.isEmpty else { return nil }
        if let hit = years.first(where: { $0.0 == year }) { return hit.1 }
        if let earlier = years.filter({ $0.0 < year }).max(by: { $0.0 < $1.0 }) { return earlier.1 }
        if let pre = items.first(where: { $0.norm.contains("年前") || $0.norm.contains("更早") || $0.norm.contains("earlier") }) {
            return pre.value
        }
        // 兜底：发行年份早于全部选项时选最早年份
        if let oldest = years.min(by: { $0.0 < $1.0 }) { return oldest.1 }
        return nil
    }

    /// 选项打分上下文：让"UHD Remux vs Remux"、"电影-Remux vs 动漫-完结"这类
    /// 多命中选项按发布实际特征选，而不是按选项先后顺序碰运气
    struct Context {
        var isUHD = false                 // 2160p/8K 发布：UHD/4K 选项优先，否则回避
        var isDIY = false                 // DIY 发布：有 "Blu-ray/DIY" 这类选项就选它，别选纯原盘
        var isDisc = false                // 碟片发布：不许退到「压制/Encode」（聆音只有 Encode 与 Other，该选 Other）
        var kindKeywords: [String] = []   // 分类关键词（动漫/电影…）：组合式选项（"动漫-完结"）优先
        var completed = false             // 整季/完结："完结"加分、"连载"减分
        init(isUHD: Bool = false, isDIY: Bool = false, isDisc: Bool = false,
             kindKeywords: [String] = [], completed: Bool = false) {
            self.isUHD = isUHD
            self.isDIY = isDIY
            self.isDisc = isDisc
            self.kindKeywords = kindKeywords.map { QualityMatcher.normalize($0) }
            self.completed = completed
        }
    }

    /// 「压制/重编码/流媒体」类选项：碟片发布不该落到这些上（1PT 的 DTS-HD MA 也不能算重编码）
    static func isEncodeLike(_ norm: String) -> Bool {
        ["encode", "压制", "重编码", "rip", "webdl", "webrip", "hdtv"].contains { norm.contains($0) }
    }

    /// DTS 家族发布：站点同时给了 DTS 类选项时不许回退到杜比 TrueHD/Atmos
    /// （1PT 音频只有 TrueHD 与 DTS，按顺序会选成 TrueHD）；只有 TrueHD 时才用它兜底
    static func isDolbyLabelForDTS(_ token: String, _ norm: String, dtsAvailable: Bool) -> Bool {
        dtsAvailable && ["dtsma", "dtsx", "dtsc", "dts"].contains(token)
            && ["truehd", "atmos", "dolby"].contains(where: { norm.contains($0) })
    }

    /// 选项表是否含介质项（Remux / Blu-ray / WEB-DL…）：来源下拉在有的站是介质表
    /// （蟹黄堡、青蛙、烧包），有的站是发布归属表（官方/转载/原创），两种选法完全不同。
    /// 判成介质表就交给 medium token 匹配，不走「转载」那套
    static func hasMediumOption(_ options: [(value: String, label: String)]) -> Bool {
        let keys = ["medium", "processing"].flatMap { attr in
            (rules[attr] ?? [:]).filter { $0.key != "other" }.values.flatMap { $0.match }
        }
        return options.contains { o in
            let n = normalize(o.label)
            return keys.contains { n.contains($0) }
        }
    }

    /// "其它/其他/Other" 只认纯兜底选项：城市站的"3D Alt/其他3D"这类带限定的选项不算
    static func isOtherLabel(_ norm: String) -> Bool {
        var t = norm
        for w in ["others", "other", "其它", "其他"] {
            t = t.replacingOccurrences(of: w, with: "")
        }
        return t.isEmpty
    }

    /// 在选项列表中为 token 选值；无匹配返回 nil
    static func match(token: String, attr: String, options: [(value: String, label: String)],
                      ctx: Context = Context()) -> String? {
        struct Opt { let value: String; let norm: String; let order: Int }
        let opts = options.enumerated().map { Opt(value: $1.value, norm: normalize($1.label), order: $0) }
        guard !opts.isEmpty, var chain = chains[attr]?[token] ?? chains[attr]?["other"] else { return nil }
        // 碟片发布的回退链里不许出现「压制/HDTV/流媒体」，宁可不填（聆音：只该选 Other）
        if ctx.isDisc { chain = chain.filter { !["encode", "webrip", "webdl", "hdtv"].contains($0) } }
        let dtsAvailable = opts.contains { $0.norm.contains("dts") }
        for t in chain {
            if t == "first" {
                let usable = opts.filter { $0.value != "0" && !$0.norm.contains("请选") }
                if ctx.isDisc, let ok = usable.first(where: { !isEncodeLike($0.norm) }) { return ok.value }
                return usable.first?.value
            }
            guard let rule = rules[attr]?[t] else { continue }
            let otherOnly = (t == "other")
            var best: (score: Int, order: Int, value: String)?
            for o in opts where rule.match.contains(where: { o.norm.contains($0) })
                && !rule.exclude.contains(where: { o.norm.contains($0) })
                && (!otherOnly || isOtherLabel(o.norm))
                && !(ctx.isDisc && isEncodeLike(o.norm))
                && !isDolbyLabelForDTS(token, o.norm, dtsAvailable: dtsAvailable) {
                var score = 10 - min(o.order, 9)            // 同分时保持原有顺序偏好
                for (i, pat) in rule.match.enumerated() {
                    var hit = 0
                    if o.norm == pat { hit = 8 }
                    else if o.norm.hasPrefix(pat) { hit = 5 }
                    else if o.norm.contains(pat) { hit = 2 }
                    // 主关键词（列表第一项）优先：DTS-HD MA 先选 "DTS-HD MA"，没有才选 "DTS-HD"
                    if hit > 0 { score += i == 0 ? hit : hit - 1 }
                }
                if ["uhd", "4k", "2160"].contains(where: { o.norm.contains($0) }) {
                    score += ctx.isUHD ? 7 : -7      // 4K 发布要盖过"Remux"这类更短的精确项
                }
                // DIY 发布优先 "Blu-ray/DIY"（铂金家/1PT/咖啡/库非都有这项）；不是 DIY 就别选它
                if ["medium", "processing"].contains(attr), o.norm.contains("diy") {
                    score += ctx.isDIY ? 7 : -6
                }
                if ctx.kindKeywords.contains(where: { o.norm.contains($0) }) { score += 6 }
                if o.norm.contains("完结") || o.norm.contains("完結") { score += ctx.completed ? 3 : -2 }
                if o.norm.contains("连载") && ctx.completed { score -= 3 }
                if best == nil || score > best!.score { best = (score, o.order, o.value) }
            }
            if let best { return best.value }
        }
        return nil
    }
}
