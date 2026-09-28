import Foundation

/// 从源站解析出的种子信息（对应 auto_feed 的 raw_info）。
struct ReleaseInfo: Codable, CustomStringConvertible {
    var siteID: String          // 源站 id
    var detailURL: String
    var name: String            // 发布名称
    var descr: String           // 简介 HTML（清洗前）
    var imdb: String?           // tt123456
    var douban: String?
    var size: Int64?            // bytes
    var kind: ReleaseKind?
    var torrentName: String     // .torrent 文件名
    var torrentURL: String      // 带 passkey 的 .torrent 直链
    var isForbidReseed: Bool    // 命中源站禁转标记

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
    var dedupKey: String { "\(siteID)#\(detailURL)" }
    var summary: String { "\(siteID): \(name) (imdb: \(imdb ?? "-"))" }
    var description: String { summary }
}

enum ReleaseKind: String, Codable {
    case movie, series, anime, documentary, music, other

    private static let seriesRe = try! NSRegularExpression(pattern: "S\\d{1,2}[. ]E\\d{1,3}")
    private static let series2Re = try! NSRegularExpression(pattern: "S\\d{2}E\\d{2}")

    /// 基于命名惯例的启发式判断
    static func infer(from name: String) -> ReleaseKind {
        let range = NSRange(name.startIndex..., in: name)
        if seriesRe.firstMatch(in: name, range: range) != nil || series2Re.firstMatch(in: name, range: range) != nil {
            return .series
        }
        if name.contains("OST") || name.contains("FLAC") || name.contains("APE") || name.contains("AMV") { return .music }
        if name.contains("Anime") || name.contains("动漫") { return .anime }
        return .other
    }
}
