import Foundation

/// 从源站解析出的种子信息（对应 auto_feed 的 raw_info）。
public struct ReleaseInfo: Codable, CustomStringConvertible {
    public var siteID: String          // 源站 id
    public var detailURL: String
    public var name: String            // 发布名称（下载 .torrent 后以 info.name 校正）
    public var descr: String           // 简介 HTML（原始，上传时按目标站格式转换）
    public var imdb: String?           // tt123456
    public var douban: String?
    public var tmdb: String?           // TMDB 规范链接 https://www.themoviedb.org/(movie|tv)/id
    public var size: Int64?            // bytes
    public var kind: ReleaseKind?
    public var torrentName: String     // .torrent 文件名
    public var torrentURL: String      // 带 passkey 的 .torrent 直链
    public var isForbidReseed: Bool    // 命中源站禁转标记
    public var subtitle: String        // 副标题（源简介"译名"，如 毒食难肥）
    public var genre: String           // 源站类别（如 纪录片）
    public var mediainfo: String       // 源页 MediaInfo/BDInfo 原文
    public var region: String          // 源简介"产地"（个别目标站"制作组"下拉实为地区）
    public var sourceName: String      // 源站显示名（如 LuckPT；目标站"附加信息=转种来源"用）
    public var bangumi: String         // Bangumi 番组计划条目链接（馒头动画分类发种必填）
    public var sourceTags: [String]    // 源站详情页"标签"行原文（如 ["官方","中字","完结"]）
    /// 「批量转种」页勾选「源站引用」时用户填写的文本：加在发种简介最上面，按目标站格式用引用包裹。
    /// 源站简介自带引用的可以不填，所以做成可选项（空串 = 不加）。
    public var extraQuote: String

    /// 去掉首尾空白后的源站引用文本
    public var extraQuoteText: String { extraQuote.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// BBCode 引用块（NexusPHP / Gazelle / Blu / PeerGo / Discuz 家族），含尾部换行
    public var extraQuoteBBCode: String {
        extraQuoteText.isEmpty ? "" : "[quote]\n" + extraQuoteText + "\n[/quote]\n"
    }

    /// HTML 引用块（Unit3D 等 HTML 简介站点）
    public var extraQuoteHTML: String {
        guard !extraQuoteText.isEmpty else { return "" }
        let t = extraQuoteText
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br />")
        return "<blockquote>" + t + "</blockquote><br />\n"
    }

    /// Markdown 引用块（YemaPT 简介用）
    public var extraQuoteMarkdown: String {
        guard !extraQuoteText.isEmpty else { return "" }
        let lines = extraQuoteText.components(separatedBy: "\n").map { "> \($0)" }
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// 源站把该种子标成官种/官方发布。目标站的种子不是官种（不该打官方标签），
    /// 「首发」标签也只有源站是官种时才跟随，见 QualityTokens.canonicalTags。
    public var isOfficialSource: Bool {
        sourceTags.contains { t in
            let n = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return n.contains("官种") || n == "官方" || n.contains("官方发布") || n == "official"
        }
    }

    init(siteID: String, detailURL: String, name: String, descr: String = "",
         imdb: String? = nil, douban: String? = nil, tmdb: String? = nil, size: Int64? = nil,
         kind: ReleaseKind? = nil, torrentName: String = "", torrentURL: String = "",
         isForbidReseed: Bool = false, subtitle: String = "", genre: String = "",
         mediainfo: String = "", region: String = "", sourceName: String = "",
         bangumi: String = "", sourceTags: [String] = [], extraQuote: String = "") {
        self.siteID = siteID
        self.detailURL = detailURL
        self.name = name
        self.descr = descr
        self.imdb = imdb
        self.douban = douban
        self.tmdb = tmdb
        self.size = size
        self.kind = kind
        self.torrentName = torrentName
        self.torrentURL = torrentURL
        self.isForbidReseed = isForbidReseed
        self.subtitle = subtitle
        self.genre = genre
        self.mediainfo = mediainfo
        self.region = region
        self.sourceName = sourceName
        self.bangumi = bangumi
        self.sourceTags = sourceTags
        self.extraQuote = extraQuote
    }

    private enum CodingKeys: String, CodingKey {
        case siteID, detailURL, name, descr, imdb, douban, size, kind, extraQuote
        case torrentName, torrentURL, isForbidReseed, subtitle, genre, mediainfo, region
        case sourceName, bangumi, sourceTags
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        siteID = try c.decode(String.self, forKey: .siteID)
        detailURL = try c.decode(String.self, forKey: .detailURL)
        name = try c.decode(String.self, forKey: .name)
        descr = try c.decodeIfPresent(String.self, forKey: .descr) ?? ""
        imdb = try c.decodeIfPresent(String.self, forKey: .imdb)
        douban = try c.decodeIfPresent(String.self, forKey: .douban)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        kind = try c.decodeIfPresent(ReleaseKind.self, forKey: .kind)
        torrentName = try c.decodeIfPresent(String.self, forKey: .torrentName) ?? ""
        torrentURL = try c.decodeIfPresent(String.self, forKey: .torrentURL) ?? ""
        isForbidReseed = try c.decodeIfPresent(Bool.self, forKey: .isForbidReseed) ?? false
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        genre = try c.decodeIfPresent(String.self, forKey: .genre) ?? ""
        mediainfo = try c.decodeIfPresent(String.self, forKey: .mediainfo) ?? ""
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? ""
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        bangumi = try c.decodeIfPresent(String.self, forKey: .bangumi) ?? ""
        sourceTags = try c.decodeIfPresent([String].self, forKey: .sourceTags) ?? []
        extraQuote = try c.decodeIfPresent(String.self, forKey: .extraQuote) ?? ""
    }

    /// 稳定去重键：同一源站同一详情页视为同一种子
    public var dedupKey: String { "\(siteID)#\(Self.normalizeKeyURL(detailURL))" }

    /// 详情页 URL 归一化：去掉 `hit=1` 一类访问统计参数，
    /// 避免同一页面因 URL 带/不带参数产生两个不同的去重键
    static func normalizeKeyURL(_ s: String) -> String {
        guard var c = URLComponents(string: s), var items = c.queryItems else { return s }
        let filtered = items.filter { $0.name != "hit" }
        guard filtered.count != items.count else { return s }
        c.queryItems = filtered.isEmpty ? nil : filtered
        return c.string ?? s
    }
    public var summary: String { "\(siteID): \(name) (imdb: \(imdb ?? "-"))" }
    public var description: String { summary }
}

public enum ReleaseKind: String, Codable {
    case movie, series, tvshow, anime, documentary, music, sports, other

    private static let seriesRe = try! NSRegularExpression(pattern: "S\\d{1,2}[. ]E\\d{1,3}")
    private static let series2Re = try! NSRegularExpression(pattern: "S\\d{2}E\\d{2}")

    /// 优先用源站"类别"行（如 纪录片），其次命名惯例启发式
    public static func infer(from name: String, genre: String = "") -> ReleaseKind {
        let range = NSRange(name.startIndex..., in: name)
        if seriesRe.firstMatch(in: name, range: range) != nil || series2Re.firstMatch(in: name, range: range) != nil {
            return .series
        }
        if !genre.isEmpty {
            let g = genre.lowercased()
            if genre.contains("纪录片") || g.contains("documentary") { return .documentary }
            if genre.contains("综艺") || g.contains("tv show") || g.contains("varied") { return .tvshow }
            if genre.contains("体育") || g.contains("sports") { return .sports }
            if genre.contains("动漫") || genre.contains("动画") || g.contains("anime") || g.contains("animation") { return .anime }
            if genre.contains("音乐") || genre.contains("无损") || g.contains("music") { return .music }
            if genre.contains("剧集") || g.contains("series") || g.contains("tv") { return .series }
            if g.contains("movie") || genre.contains("电影") { return .movie }
        }
        if name.contains("OST") || name.contains("FLAC") || name.contains("APE") || name.contains("AMV") { return .music }
        if name.contains("Anime") || name.contains("动漫") { return .anime }
        return .other
    }
}
