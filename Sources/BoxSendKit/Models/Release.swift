import Foundation

/// 从源站解析出的种子信息（对应 auto_feed 的 raw_info）。
public struct ReleaseInfo: Codable, CustomStringConvertible {
    public var siteID: String          // 源站 id
    public var detailURL: String
    public var name: String            // 发布名称
    public var descr: String           // 简介 HTML（清洗前）
    public var imdb: String?           // tt123456
    public var douban: String?
    public var size: Int64?            // bytes
    public var kind: ReleaseKind?
    public var torrentName: String     // .torrent 文件名
    public var torrentURL: String      // 带 passkey 的 .torrent 直链
    public var isForbidReseed: Bool    // 命中源站禁转标记

    init(siteID: String, detailURL: String, name: String, descr: String = "",
         imdb: String? = nil, douban: String? = nil, size: Int64? = nil,
         kind: ReleaseKind? = nil, torrentName: String = "", torrentURL: String = "",
         isForbidReseed: Bool = false) {
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
    }

    /// 稳定去重键：同一源站同一详情页视为同一种子
    public var dedupKey: String { "\(siteID)#\(detailURL)" }
    public var summary: String { "\(siteID): \(name) (imdb: \(imdb ?? "-"))" }
    public var description: String { summary }
}

public enum ReleaseKind: String, Codable {
    case movie, series, anime, documentary, music, other

    private static let seriesRe = try! NSRegularExpression(pattern: "S\\d{1,2}[. ]E\\d{1,3}")
    private static let series2Re = try! NSRegularExpression(pattern: "S\\d{2}E\\d{2}")

    /// 基于命名惯例的启发式判断
    public static func infer(from name: String) -> ReleaseKind {
        let range = NSRange(name.startIndex..., in: name)
        if seriesRe.firstMatch(in: name, range: range) != nil || series2Re.firstMatch(in: name, range: range) != nil {
            return .series
        }
        if name.contains("OST") || name.contains("FLAC") || name.contains("APE") || name.contains("AMV") { return .music }
        if name.contains("Anime") || name.contains("动漫") { return .anime }
        return .other
    }
}
