import Foundation

/// 从源站解析出的种子信息（对应 auto_feed 的 raw_info）。
public struct ReleaseInfo: Codable, CustomStringConvertible {
    public var siteID: String          // 源站 id
    public var detailURL: String
    public var name: String            // 发布名称（下载 .torrent 后以 info.name 校正）
    public var descr: String           // 简介 HTML（原始，上传时按目标站格式转换）
    public var imdb: String?           // tt123456
    public var douban: String?
    public var size: Int64?            // bytes
    public var kind: ReleaseKind?
    public var torrentName: String     // .torrent 文件名
    public var torrentURL: String      // 带 passkey 的 .torrent 直链
    public var isForbidReseed: Bool    // 命中源站禁转标记
    public var subtitle: String        // 副标题（源简介"译名"，如 毒食难肥）
    public var genre: String           // 源站类别（如 纪录片）
    public var mediainfo: String       // 源页 MediaInfo/BDInfo 原文

    init(siteID: String, detailURL: String, name: String, descr: String = "",
         imdb: String? = nil, douban: String? = nil, size: Int64? = nil,
         kind: ReleaseKind? = nil, torrentName: String = "", torrentURL: String = "",
         isForbidReseed: Bool = false, subtitle: String = "", genre: String = "",
         mediainfo: String = "") {
        self.siteID = siteID
        self.detailURL = detailURL
        self.name = name
        self.descr = descr
        self.imdb = imdb
        self.douban = douban
        self.size = size
        self.kind = kind
        self.torrentName = torrentName
        self.torrentURL = torrentURL
        self.isForbidReseed = isForbidReseed
        self.subtitle = subtitle
        self.genre = genre
        self.mediainfo = mediainfo
    }

    private enum CodingKeys: String, CodingKey {
        case siteID, detailURL, name, descr, imdb, douban, size, kind
        case torrentName, torrentURL, isForbidReseed, subtitle, genre, mediainfo
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
    }

    /// 稳定去重键：同一源站同一详情页视为同一种子
    public var dedupKey: String { "\(siteID)#\(detailURL)" }
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
            if genre.contains("纪录片") { return .documentary }
            if genre.contains("综艺") { return .tvshow }
            if genre.contains("体育") { return .sports }
            if genre.contains("动漫") || genre.contains("动画") { return .anime }
            if genre.contains("音乐") || genre.contains("无损") { return .music }
            if genre.contains("剧集") { return .series }
        }
        if name.contains("OST") || name.contains("FLAC") || name.contains("APE") || name.contains("AMV") { return .music }
        if name.contains("Anime") || name.contains("动漫") { return .anime }
        return .other
    }
}
