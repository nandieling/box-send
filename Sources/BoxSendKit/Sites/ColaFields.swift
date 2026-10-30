import Foundation

/// 可乐 PT（www.colapt.com）发种字段映射：把源站解析出的 ReleaseInfo 换算成
/// 它 PUT /torrents/{id}/metadata 要的那份 JSON。
///
/// 判据尽量复用全站共用的 QualityTokens（媒介 / 编码 / 音轨 / 中文字幕 / DIY / 完结），
/// 只把「可乐有哪些选项」这层写在这里：片源、分辨率、视频编码、HDR 四个下拉的合法值
/// 取自站点前端上传页的选项表（2026-10-30 从 https://www.colapt.com/assets/upload-layout-*.js
/// 里核过），选项表里没有的一律留空，不硬塞一个「看起来差不多」的值。
enum ColaFields {

    // MARK: - 下拉选项（站点选项表）

    static let sources = ["Blu-ray Disc", "DIY原盘", "Remux", "BDRip", "Blu-ray",
                          "WEB-DL", "WEBRip", "HDTV", "TVRip", "DVD", "DVDRip"]
    static let resolutions = ["2160p", "1080p", "1080i", "720p", "576p", "480p", "480i", "576i"]
    static let videoCodecs = ["HEVC / H.265", "AVC / H.264", "AV1", "VP9", "VC-1", "MPEG-2"]
    static let hdrs = ["HDR", "HDR Vivid", "HDR10", "HDR10+", "Dolby Vision",
                       "Dolby Vision + HDR10", "Dolby Vision + HDR10+", "HLG", "SDR"]

    // MARK: - 分类（可乐只有 5 类：电影 / 电视剧 / 动漫 / 综艺 / 其他）

    /// 站点作品分类：anime / movie / tv / variety / other
    static func mediaCategory(_ info: ReleaseInfo) -> String {
        // 纪录片在可乐归到「其他」：它没有纪录片分类，硬塞进电影会被审核打回
        if isDocumentary(info) { return "other" }
        switch info.kind ?? .other {
        case .movie: return "movie"
        case .series: return "tv"
        case .anime: return "anime"
        case .tvshow: return "variety"
        case .documentary, .music, .sports, .other: return "other"
        }
    }

    /// 给界面 / 日志看的中文分类名
    static func categoryLabel(_ info: ReleaseInfo) -> String {
        switch mediaCategory(info) {
        case "movie": return "电影"
        case "tv": return "电视剧"
        case "anime": return "动漫"
        case "variety": return "综艺"
        default: return "其他"
        }
    }

    /// 接口回来的作品分类 -> 体裁
    static func kind(fromCategory category: String) -> ReleaseKind {
        switch category.lowercased() {
        case "movie": return .movie
        case "tv": return .series
        case "anime": return .anime
        case "variety": return .tvshow
        default: return .other
        }
    }

    /// 纪录片判据：体裁判成纪录片，或源站类别 / 豆瓣「◎类　　别」行里写着纪录
    static func isDocumentary(_ info: ReleaseInfo) -> Bool {
        if info.kind == .documentary { return true }
        let text = info.genre + " " + info.siteCategory + " " + HTMLUtil.stripTags(info.descr)
        return text.range(of: #"(?:纪录|紀錄|Documentary)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - 片源 / 分辨率 / 视频编码 / HDR

    /// 片源。判序是固定的，错一步就全错：
    /// 1. Remux 最先。Remux 是「无损抽出再封装」，跟「加装中文字幕的原盘」是两回事，
    ///    所以 Remux 既不进 DIY原盘，也不打 DIY 标签（全站同一把尺）。
    /// 2. 流媒体与电视源其次（媒介 token 把 web 一律收成 webdl，分不出 WEBRip，这里自己认）。
    /// 3. 盘类：带中文字幕证据的蓝光盘是蓝光 DIY -> 「DIY原盘」；出现 x264/x265 或写着
    ///    BDRip 的是压制盘 -> 「BDRip」；其余才是真正的原盘镜像 -> 「Blu-ray Disc」。
    /// 4. 一点依据都没有就返回 nil（留「未知」让用户自己点，别猜成原盘）。
    static func source(_ info: ReleaseInfo) -> String? {
        let n = info.name.lowercased()
        let m = QualityTokens.medium(from: info.name, kind: info.kind, mediainfo: info.mediainfo)
        if m == "remux" || n.contains("remux") { return "Remux" }
        if n.contains("webrip") || n.contains("web-rip") || n.contains("web rip") { return "WEBRip" }
        if m == "webdl" || n.contains("web-dl") || n.contains("webdl") { return "WEB-DL" }
        if m == "hdtv" || n.contains("hdtv") { return "HDTV" }
        if n.contains("tvrrip") || n.contains("tv-rip") { return "TVRip" }
        // 是不是「盘」：媒介 token 已经算过，另外补一次标题明写（token 认不出的写法）
        let discNamed = n.contains("bluray") || n.contains("blu-ray") || n.contains("bdrip")
            || n.contains("brrip") || n.contains("bdiso") || n.contains("bdmv")
        let isDisc = ["bluray", "uhdbd", "uhdbd8k"].contains(m ?? "")
            || ((m == "encode" || m == "uhd") && discNamed)
        if isDisc {
            // 加装中文字幕的蓝光盘 = 蓝光 DIY，走站点专门的「DIY原盘」选项
            if QualityTokens.isDIYRelease(info) { return "DIY原盘" }
            let pressed = QualityTokens.hasSoftwareEncoder(info.name)
                || QualityTokens.hasSoftwareEncoder(info.mediainfo)
            if pressed || n.contains("bdrip") || n.contains("bd-rip") || n.contains("brrip")
                || n.contains("encode") {
                return "BDRip"
            }
            return "Blu-ray Disc"
        }
        if m == "dvd" || n.contains("dvd") { return n.contains("dvdrip") ? "DVDRip" : "DVD" }
        return nil
    }

    /// 分辨率。可乐选项表里没有 8K，8K 归到 2160p；SD 按 MediaInfo 分 480/576 与逐行/隔行
    static func resolution(_ info: ReleaseInfo) -> String? {
        let std = QualityTokens.standard(from: info.name)
        let mi = info.mediainfo
        switch std {
        case "8k", "2160p": return "2160p"
        case "1080p": return "1080p"
        case "1080i": return "1080i"
        case "720p": return "720p"
        case "sd":
            if mi.range(of: "576", options: .caseInsensitive) != nil {
                return isInterlaced(mi) ? "576i" : "576p"
            }
            return isInterlaced(mi) ? "480i" : "480p"
        default:
            // 标题没写分辨率时，从 MediaInfo 的高度行认一次（常写成 "1 080 pixels"，带千分位空格）
            if let raw = HTMLUtil.group(mi, #"height[^0-9\n]{0,8}[0-9][0-9\s]{1,7}[0-9]"#, group: 0,
                                        options: [.caseInsensitive]) {
                switch raw.filter { $0.isNumber }.map(String.init).joined() {
                case "2160", "3840", "4096": return "2160p"
                case "1080": return isInterlaced(mi) ? "1080i" : "1080p"
                case "720": return "720p"
                case "576": return isInterlaced(mi) ? "576i" : "576p"
                case "480": return isInterlaced(mi) ? "480i" : "480p"
                default: break
                }
            }
            return nil
        }
    }

    /// 隔行迹象：MediaInfo 的 Scan type / Scan order，或标题里明写的 1080i、576i、480i
    private static func isInterlaced(_ mediainfo: String) -> Bool {
        mediainfo.range(of: #"scan\s*(?:type|order)\s*[:：][^\r\n]*(?:interlac|mbaff|paff)|(?:1080|576|480)i\b"#,
                        options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 视频编码。可乐表里没有 Xvid / ProRes，认成这些时留空（选项表里没有就不选）
    static func videoCodec(_ info: ReleaseInfo) -> String? {
        switch QualityTokens.codec(from: info.name, mediainfo: info.mediainfo) {
        case "hevc": return "HEVC / H.265"
        case "avc": return "AVC / H.264"
        case "av1": return "AV1"
        case "vp9": return "VP9"
        case "vc1": return "VC-1"
        case "mpeg2": return "MPEG-2"
        default: return nil
        }
    }

    /// HDR。先认标签 / 标题 / MediaInfo 里的 Dolby Vision、HDR10+、HDR10、Vivid、HLG，
    /// 都没有但 BT.709 明确是 SDR 时填 SDR；一点痕迹都没有就留空。
    static func hdr(_ info: ReleaseInfo) -> String? {
        let tags = QualityTokens.canonicalTags(info)
        // Encoding settings 那一长串里常有 hdr 字样，会误判，先剔掉
        let cleanMI = info.mediainfo.replacingOccurrences(
            of: #"Encoding settings\s*[:：][^\r\n]+"#, with: "",
            options: [.regularExpression, .caseInsensitive])
        let titleAndSub = info.name + " " + info.subtitle
        let combined = titleAndSub + " " + cleanMI
        if cleanMI.range(of: #"Color primaries\s*[:：]\s*BT\.?709"#, options: [.regularExpression, .caseInsensitive]) != nil,
           cleanMI.range(of: #"HDR format|Dolby Vision"#, options: [.regularExpression, .caseInsensitive]) == nil,
           matchHDRToken(titleAndSub) == nil {
            return "SDR"
        }
        let dv = tags.contains("dovi") || hasToken(#"Dolby Vision|\bDoVi\b|杜比视界"#, combined)
        let hdr10plus = tags.contains("hdr10plus") || hasToken(#"(?<!no-)\bHDR10\+"#, combined)
        let hdr10 = tags.contains("hdr10") || hasToken(#"(?<!no-)\bHDR10(?!\+)"#, combined)
        let vivid = hasToken(#"HDR Vivid"#, combined)
        let hlg = hasToken(#"\bHLG\b"#, combined)
        let generic = hasToken(#"(?<!no-)\bHDR\b"#, combined)
        if dv, hdr10plus { return "Dolby Vision + HDR10+" }
        if dv, hdr10 || generic { return "Dolby Vision + HDR10" }
        if dv { return "Dolby Vision" }
        if hdr10plus { return "HDR10+" }
        if hdr10 { return "HDR10" }
        if vivid { return "HDR Vivid" }
        if hlg { return "HLG" }
        if generic { return "HDR" }
        return nil
    }

    /// 只认「HDR / HDR10」这类整词，避免 1080HDR 之类粘连串误判
    private static func matchHDRToken(_ text: String) -> String? {
        hasToken(#"(?<!no-)\b(?:HDR|HDR10|HDR10\+|DoVi|DV|HLG)\b|杜比视界"#, text) ? "hdr" : nil
    }

    private static func hasToken(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - 音轨 / 字幕 / 制作组 / 标题

    /// 音轨：认得出才填，认不出留空（暮雪阁那次没 E-AC-3 却选了 APE，就是硬填的代价）
    static func audioTracks(_ info: ReleaseInfo) -> [String] {
        let name = info.name
        guard let token = QualityTokens.audio(from: name) else { return [] }
        let channels = channelsOf(name)
        let base: String
        switch token {
        case "dtsma": base = "DTS-HD MA"
        case "dtsbr": base = "DTS-HD HR"
        case "dtsc": base = "DTS:X"
        case "truehd": base = "TrueHD"
        case "truehd atmos": base = "TrueHD"
        case "eac3": base = "DDP"
        case "eac3 atmos": base = "DDP"
        case "ac3": base = "AC3"
        case "dts": base = "DTS"
        case "flac": base = "FLAC"
        case "ape": base = "APE"
        case "opus": base = "Opus"
        case "m4a": base = "AAC"
        case "aac": base = "AAC"
        case "mp3": base = "MP3"
        case "ogg": base = "OGG"
        case "wav": base = "WAV"
        case "pcm": base = "LPCM"
        default: base = token.uppercased()
        }
        var out = base
        if !channels.isEmpty { out += " " + channels }
        if token.contains("atmos") { out += " Atmos" }
        return [out]
    }

    /// 标题里的声道数（5.1 / 7.1 / 2.0 / 1.0）
    static func channelsOf(_ name: String) -> String {
        HTMLUtil.group(name, #"\b(7\.1|5\.1|2\.0|1\.0)\b"#, group: 1) ?? ""
    }

    /// 字幕语言（站点只有 zh / en / ja / other，最多 4 个）
    static func subtitleLanguages(_ info: ReleaseInfo) -> [String] {
        var out: [String] = []
        let tagLine = info.sourceTags.joined(separator: " ")
        if QualityTokens.hasChineseSubtitleEvidence(info)
            || tagLine.contains("中字") || tagLine.contains("国字") { out.append("zh") }
        if QualityTokens.hasEnglishSubtitles(info: info) || tagLine.contains("英字") { out.append("en") }
        if hasJapaneseSubtitle(info) || tagLine.contains("日字") { out.append("ja") }
        return Array(out.prefix(4))
    }

    /// 日文字幕证据（保守：只要明写的「日字 / 日文字幕 / 日语字幕」，别拿配音当字幕）
    static func hasJapaneseSubtitle(_ info: ReleaseInfo) -> Bool {
        let text = HTMLUtil.stripTags(info.descr) + "\n" + info.subtitle + "\n" + info.name
            + "\n" + info.sourceTags.joined(separator: " ")
        return text.range(of: #"日字|日文字幕|日语字幕|日文特效字"#, options: .regularExpression) != nil
    }

    /// 制作组：取发布名最后一段（…-Group.mkv 里的 Group）；纯质量词不算制作组
    static func releaseGroup(_ info: ReleaseInfo) -> String? {
        var name = info.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = name.range(of: #"\.(?:mkv|mp4|iso|ts|m2ts)$"#,
                               options: [.regularExpression, .caseInsensitive]) {
            name = String(name[..<cut.lowerBound])
        }
        guard let last = name.split(whereSeparator: { "-_ ".contains($0) }).last else { return nil }
        let candidate = String(last).trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count >= 2 else { return nil }
        if candidate.range(of: #"^(?:1080[pi]|720p|2160p|4K|8K|x264|x265|H\.?264|H\.?265|HEVC|AVC|AAC|AC3|DDP|DTS|TRUEHD|LPCM|FLAC|2\.0|5\.1|7\.1)$"#,
                           options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        return candidate
    }

    /// 主标题：走全站统一的改写规则（Remux 时把 Blu-ray 改成 BluRay 等）
    static func title(from info: ReleaseInfo) -> String {
        ReleaseTitle.rewrite(info.name)
    }

    /// 站点搜索用的关键词：去掉扩展名与制作组段
    static func searchKey(from name: String) -> String? {
        var s = name
        if let r = s.range(of: #"\.(mkv|mp4|iso|ts|m2ts|torrent)$"#, options: [.regularExpression, .caseInsensitive]) {
            s = String(s[..<r.lowerBound])
        }
        if let dash = s.range(of: "-", options: .backwards) {
            let tail = String(s[dash.upperBound...])
            if tail.range(of: #"^(?:1080[pi]|720p|2160p|4K)$"#, options: [.regularExpression, .caseInsensitive]) == nil {
                s = String(s[..<dash.lowerBound])
            }
        }
        let key = s.replacingOccurrences(of: ".", with: " ", options: .literal)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.count >= 4 ? key : nil
    }

    // MARK: - 引用块与截图

    /// 发种简介：来源引用在最上，随后源简介自带的制作引用（原盘来自…／字幕来自…），再正文。
    /// 织梦那条「转载资源请在简介中声明来源」的审核意见就是这么过的：来源与制作引用
    /// 并成同一个引用块，来源写在第一行，别并列成两段。
    static func description(_ info: ReleaseInfo, site: SiteConfig) -> String {
        var body = BBCode.fromHTML(info.descr, base: URL(string: site.url))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source = sourceQuoteLine(info, site: site) else { return body }
        // 源简介最上面已有 [quote]（BBCode 直接带出来的站）：并进去
        if let merged = NexusPHPAdapter.mergeIntoLeadingQuote(source: source, text: body) {
            return merged
        }
        // BBCode 转换会把 <blockquote>/<fieldset> 的引用壳丢掉（只剩纯文本），那样并不出来的话，
        // 就按 HTML 把制作引用单独取回来，与来源并成一个引用块，并从正文里去掉，免得重复出现
        let production = NexusPHPAdapter.sourceQuoteBlocks(info.descr)
            .filter { !$0.isEmpty && !NexusPHPAdapter.isMediaInfoText($0) }
        for block in production {
            body = body.replacingOccurrences(of: block, with: "", options: .literal)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let headLines = ([source] + production).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let head = quoteBlock(headLines.joined(separator: "\n"))
        return body.isEmpty ? head : head + "\n\n" + body
    }

    /// 转种来源那一行：用户在「批量转种」页填的源站引用优先；没填时只在站点配了
    /// 「简介开头注明转种来源」（可乐要注明转载来源）时补一句，避免和源简介自带的引用叠成两段
    static func sourceQuoteLine(_ info: ReleaseInfo, site: SiteConfig) -> String? {
        if !info.extraQuoteText.isEmpty { return info.extraQuoteText }
        let ov = SiteRegistry.effectiveSite(site).overrides
        guard ov?.descrSourcePrefix ?? true else { return nil }
        let label = (ov?.sourceLabel?.isEmpty == false ? ov?.sourceLabel : nil)
            ?? (info.sourceName.isEmpty ? info.siteID : info.sourceName)
        return "转载自\(label)，感谢发布者。"
    }

    /// BBCode 引用块（可乐简介按 BBCode 渲染）
    static func quoteBlock(_ text: String) -> String {
        "[quote]\n" + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n[/quote]"
    }

    /// 截图：源简介里的图片，海报已经由 poster 单独走，这里只留真截图（最多 20 张）
    static func screenshots(from info: ReleaseInfo, base: String) -> [String] {
        let urls = NexusPHPAdapter.screenshotURLs(from: info.descr, base: base)
        return Array(Set(urls.filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }).prefix(20))
    }

    /// 海报（新建作品时才用得上，必须是 https）
    static func poster(from info: ReleaseInfo, base: String) -> String? {
        guard let p = NexusPHPAdapter.posterURL(from: info.descr, base: base),
              p.hasPrefix("https://") else { return nil }
        return p
    }

    /// 简介正文里的「◎简　　介」段（新建作品时当 synopsis）
    static func synopsis(from info: ReleaseInfo) -> String {
        let plain = HTMLUtil.stripTags(info.descr)
        guard let r = plain.range(of: #"◎简\s*介\s*[\s\S]+"#, options: [.regularExpression]) else { return "" }
        var text = String(plain[r])
        text = text.replacingOccurrences(of: #"^◎简\s*介\s*"#, with: "", options: [.regularExpression])
        text = text.replacingOccurrences(of: #"\n◎[\s\S]*$"#, with: "", options: [.regularExpression])
        let out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.count >= 4 ? String(out.prefix(16000)) : ""
    }

    /// 简介里的 ◎导　　演 行（新建作品要至少一个导演）
    static func directors(from info: ReleaseInfo) -> [String] {
        let plain = HTMLUtil.stripTags(info.descr)
        guard let line = HTMLUtil.group(plain, #"◎导\s*演\s*([^\r\n]+)"#, group: 1) else { return [] }
        return line.split(whereSeparator: { "/／,，、".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 新建作品（源站没关联作品时）；必填不齐就返回 nil，交给上层报错
    static func newMedia(info: ReleaseInfo, descr synopsisText: String) -> [String: Any]? {
        var out: [String: Any] = ["category": mediaCategory(info)]
        let t = title(from: info)
        if !t.isEmpty {
            out["title"] = String(t.prefix(255))
            out["original_title"] = String((info.subtitle.isEmpty ? t : info.subtitle).prefix(255))
        }
        if let d = doubanID(info.douban) { out["douban_id"] = d }
        else if let i = ensureableIMDB(info.imdb) { out["imdb_id"] = i }
        else if let u = tmdbURL(info.tmdb) { out["tmdb_url"] = u }
        else { return nil }                      // 三个号都没有，站点不会收
        let synopsis = synopsisText.isEmpty ? synopsis(from: info) : synopsisText
        if !synopsis.isEmpty { out["synopsis"] = String(synopsis.prefix(16000)) }
        if let p = poster(from: info, base: info.detailURL) { out["poster_url"] = p }
        let dirs = directors(from: info)
        if !dirs.isEmpty { out["directors"] = dirs.prefix(100).map { String($0.prefix(255)) } }
        if let y = QualityTokens.year(from: info.name), (1800...2200).contains(y) { out["year"] = y }
        return out
    }

    // MARK: - 发布范围（剧集 / 动漫 / 综艺必填那几项）

    /// 可乐的 release_scope 是按分类的三选一对象；电影 / 其他返回 nil（站点也不问）
    static func releaseScope(_ info: ReleaseInfo) -> [String: Any]? {
        switch mediaCategory(info) {
        case "anime":
            let isMovie = info.name.range(of: #"剧场版|电影版|Anime\s*Movie|\bMOVIE\b"#,
                                           options: [.regularExpression, .caseInsensitive]) != nil
            var scope: [String: Any] = ["category": "anime",
                                        "anime_type": isMovie ? "movie" : animeType(info),
                                        "season": isMovie ? NSNull() : (seasonOf(info) ?? NSNull()),
                                        "scope": episodeScope(info),
                                        "episodes": isMovie ? NSNull() : (episodesOf(info) ?? NSNull())]
            if let t = scope["anime_type"] as? String, ["ova", "special"].contains(t) {
                scope["season"] = NSNull()
            }
            return scope
        case "tv":
            return ["category": "tv",
                    "season": seasonOf(info) ?? NSNull(),
                    "scope": episodeScope(info),
                    "episodes": episodesOf(info) ?? NSNull()]
        case "variety":
            let year = QualityTokens.year(from: info.name).map(String.init)
            return ["category": "variety",
                    "show_year": year ?? NSNull(),
                    "issue": episodesOf(info) ?? NSNull(),
                    "air_date": NSNull(),
                    "show_part": "main"]
        default:
            return nil
        }
    }

    private static func animeType(_ info: ReleaseInfo) -> String {
        let n = info.name.lowercased()
        if n.contains("ova") { return "ova" }
        if n.contains("ona") { return "ona" }
        if n.contains("sp") || n.contains("special") { return "special" }
        return "tv"
    }

    /// 季：S01E02 连写、S01.2009、第1季
    private static func seasonOf(_ info: ReleaseInfo) -> String? {
        if let s = HTMLUtil.group(info.name, #"\bS(\d{1,2})(?:[.\s_-]?E\d|\b)"#, group: 1, options: .caseInsensitive) { return s }
        if let s = HTMLUtil.group(info.name, #"第\s*(\d{1,3})\s*[季部]"#, group: 1) { return s }
        return nil
    }

    /// 集数：E02 / 第12集 / 全24话 / [01-12]
    private static func episodesOf(_ info: ReleaseInfo) -> String? {
        // S01E02 连写：前面是数字时 \b 不成立，单列一条
        if let e = HTMLUtil.group(info.name, #"S\d{1,2}[.\s_-]?E(?:P)?(\d{1,3})"#, group: 1, options: .caseInsensitive) { return e }
        if let e = HTMLUtil.group(info.name, #"\bE(?:P)?(\d{1,3})\b"#, group: 1, options: .caseInsensitive) { return e }
        if let e = HTMLUtil.group(info.name, #"第\s*(\d{1,4})\s*[集话話]"#, group: 1) { return e }
        if let e = HTMLUtil.group(info.name, #"全\s*(\d{1,4})\s*[集话話]"#, group: 1) { return e }
        if let e = HTMLUtil.group(info.name, #"\[(\d{1,4})(?:[-–]\d{1,4})?\]\s*$"#, group: 1) { return e }
        return nil
    }

    /// 发布范围：完结 / 全X话 → complete；单集 → single；写了区间 → multiple
    private static func episodeScope(_ info: ReleaseInfo) -> String {
        if QualityTokens.isCompletedRelease(info) { return "complete" }
        if let e = episodesOf(info) { return e.contains("-") ? "multiple" : "single" }
        // 连载体裁但一点集数痕迹都没有：按整季处理（站点这条允许留空，填了更省事）
        return "complete"
    }

    // MARK: - metadata 载荷

    /// PUT /torrents/{id}/metadata 的请求体
    static func metadata(info: ReleaseInfo, site: SiteConfig, mediaID: String,
                         expectedRevision: Int, screenshots shots: [String]) -> [String: Any] {
        var payload: [String: Any] = ["expected_revision": max(1, expectedRevision)]
        if isMediaReference(mediaID) { payload["media_id"] = mediaID }
        if let s = source(info), sources.contains(s) { payload["source"] = s }
        if let r = resolution(info), resolutions.contains(r) { payload["resolution"] = r }
        if let c = videoCodec(info), videoCodecs.contains(c) { payload["video_codec"] = c }
        if let h = hdr(info), hdrs.contains(h) { payload["hdr"] = h }
        let audio = audioTracks(info)
        if !audio.isEmpty { payload["audio"] = audio }
        let subs = subtitleLanguages(info)
        if !subs.isEmpty { payload["subtitles"] = subs }
        let desc = description(info, site: site)
        if !desc.isEmpty { payload["description"] = String(desc.prefix(65000)) }
        if !info.mediainfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["media_info"] = String(info.mediainfo.prefix(60000))
        }
        if let scope = releaseScope(info) { payload["release_scope"] = scope }
        let t = title(from: info)
        if !t.isEmpty { payload["release_name"] = String(t.prefix(1024)) }
        if !info.subtitle.isEmpty { payload["subtitle"] = String(info.subtitle.prefix(255)) }
        if let g = releaseGroup(info) { payload["release_group"] = String(g.prefix(64)) }
        if !shots.isEmpty { payload["screenshots"] = shots.map { String($0.prefix(2048)) } }
        // 官方标签只有源站是官种才跟随（同全站规则）；完结 / 中字 / 分辨率那几枚站点自己算
        payload["official"] = info.isOfficialSource
        return payload
    }

    // MARK: - 小工具

    /// 豆瓣：链接（https://movie.douban.com/subject/26647807/）或裸号都能取到号
    static func doubanID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let fromURL = HTMLUtil.group(raw, #"movie\.douban\.com/subject/([1-9][0-9]{0,19})"#, group: 1) {
            return fromURL
        }
        let numbers = raw.split(whereSeparator: { !$0.isNumber }).map(String.init)
            .filter { $0.count >= 4 && $0.first != "0" }
        return numbers.max(by: { $0.count < $1.count })
    }

    /// IMDb：取 tt 号
    static func imdbID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return HTMLUtil.firstMatch(raw, #"tt[0-9]{7,10}"#)
    }

    /// ensure 接口的 imdb_id 只收 7~8 位（spec 里 pattern 是 ^tt[0-9]{7,8}$）
    static func ensureableIMDB(_ raw: String?) -> String? {
        guard let id = imdbID(raw) else { return nil }
        return id.range(of: #"^tt[0-9]{7,8}$"#, options: .regularExpression) != nil ? id : nil
    }

    static func doubanURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return raw.range(of: #"^https?://movie\.douban\.com/subject/[1-9][0-9]{0,19}/?$"#,
                         options: [.regularExpression, .caseInsensitive]) != nil ? raw : nil
    }

    /// TMDB 规范链接 -> ensure 的 tmdb_ref；认不出返回 nil
    static func tmdbRef(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return tmdbURL(raw) ?? (raw.range(of: #"^(?:movie|tv)/[1-9][0-9]{0,19}$"#, options: .regularExpression) != nil ? raw : nil)
    }

    /// 站点认的 TMDB 链接写法
    static func tmdbURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return raw.range(of: #"^https://www\.themoviedb\.org/(?:movie|tv)/[1-9][0-9]{0,19}(?:-[A-Za-z0-9_~-]+)?/?$"#,
                         options: [.regularExpression, .caseInsensitive]) != nil ? raw : nil
    }

    /// 提交时 media_id 只认这三种写法（spec 的 MediaReference）
    static func isMediaReference(_ s: String) -> Bool {
        s.range(of: #"^(?:rc[1-9][0-9]{0,15}|tt[0-9]{7,10}|https://movie\.douban\.com/subject/[1-9][0-9]{0,19}/?)$"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 站点的 size_bytes 是十进制字符串，也可能直接给数字
    static func intOf(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s.filter { $0.isNumber }) }
        return nil
    }

    /// 标题比对用：小写、去掉点/下划线/连字符/空格这类分隔符
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"[.\-_【】\[\]()（）\s]"#, with: "", options: .regularExpression)
    }

    /// 大小一致（或源站没给大小）才算同一种子
    static func sameSize(_ siteSize: Int?, _ ourSize: Int64?) -> Bool {
        guard let siteSize, let ourSize, ourSize > 0 else { return true }
        let delta = abs(Int64(siteSize) - ourSize)
        return delta <= max(1024 * 1024, Int64(Double(ourSize) * 0.005))
    }

    /// 预览用：把任意 JSON 值压成一行文本
    static func text(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String { return s }
        if let b = value as? Bool { return b ? "yes" : "no" }
        if let arr = value as? [String] { return arr.joined(separator: "、") }
        if let n = value as? NSNumber { return n.stringValue }
        if let dict = value as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dict),
           let s = String(data: data, encoding: .utf8) { return s }
        return String(describing: value)
    }
}
