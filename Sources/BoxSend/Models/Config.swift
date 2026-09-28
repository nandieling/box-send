import Foundation

/// 站点框架家族，对应 PT-depiler definitions 中的 schema 分类。
enum SiteFramework: String, Codable {
    case nexusPHP = "NexusPHP"
    case unit3D = "Unit3D"
    case gazelle = "Gazelle"
    case gazelleJSONAPI = "GazelleJSONAPI"
    case luminance = "Luminance"
    case avistaz = "AvistazNetwork"
    case xbtit = "XBTIT"
    case custom = "custom"
}

struct SiteConfig: Codable {
    var id: String
    var name: String
    var url: String            // 结尾带 /
    var framework: SiteFramework
    var enabled: Bool
    /// 详情/列表/搜索入口覆盖（M1 主要靠 NexusPHP 默认值 + 这里微调）
    var overrides: SiteOverride?
}

/// 每站覆盖配置：把框架通用行为收敛到站点差异。
struct SiteOverride: Codable {
    var detailLinkPattern: String?      // 正则，匹配详情链接
    var uploadPath: String?             // 上传页地址，如 "upload.php"
    /// 真正的 POST 动作地址（中文 NexusPHP 家族是 "takeupload.php"）；缺省 = uploadPath
    var uploadActionPath: String?
    var titleField: String?             // 默认 "title"；中文站家族为 "name"
    /// 标题来源：reseed（默认，解析出的发布名）| torrentName（.torrent 文件名）| torrentNameDotted（文件名且空格换 .）
    var titleMode: String?
    var descrField: String?             // 默认 "descr"
    var imdbField: String?              // 默认 "imdbid"；中文站家族为 "url"，TTG 为 "imdb_c"
    /// imdb 字段值模板，{imdb} = tt 号；默认 "{imdb}"。url 型站点用 "http://www.imdb.com/title/{imdb}/"
    var imdbValueTemplate: String?
    var doubanField: String?            // 如 "url_douban" / "douban_id" / "douban"
    /// 豆瓣字段值模板，{douban} = 豆瓣号；默认 "{douban}"
    var doubanValueTemplate: String?
    var categoryField: String?          // 默认 "category"；中文站家族为 "type"
    var fileField: String?              // 默认 "file"；CHDBits 为 "torrentfile"
    var searchURL: String?              // 查重用，{imdb}/{name} 占位；nil = 关闭自动查重
    /// 分类映射：movie/series/anime/documentary/music/other，或 质量型站点用 "<kind>/<profile>"
    /// profile 取值：8k-bd/8k/uhd-bd/2160p/remux/bluray/1440p/1080p/1080i/720p/dvd/sd
    var categoryMap: [String: Int]?
    var extraUploadFields: [String: String]?  // 上传时额外提交的固定字段
    /// 命中即视为禁转（只推下载器、不转种），大小写不敏感
    var forbidReseedMarkers: [String]?
    var userAgent: String?
    /// 质量下拉自动填充：字段名 -> medium|codec|audiocodec|standard
    var qualitySelects: [String: String]?
    /// 质量值表：medium|codec|audiocodec|standard -> token -> 站点 ID
    var qualityValueMaps: [String: [String: Int]]?
}

struct DownloaderConfig: Codable {
    var type: DownloaderType       // qbittorrent | transmission
    var url: String                // 如 http://127.0.0.1:8080 或 http://127.0.0.1:9091
    var username: String
    var password: String
    var savePath: String?          // 存储路径（空 = 下载器默认）
    var category: String?          // qBittorrent 分类
    var skipChecking: Bool
    /// 需求 3：按【源站点 id】设置推送到下载器后的上传限速（bytes/s），0 = 不限速
    var defaultUpLimit: Int64
    var siteUpLimits: [String: Int64]
    /// reseed 失败时是否仍推下载器：always | on_success
    var pushPolicy: PushPolicy

    func upLimitFor(originSiteID: String) -> Int64 {
        siteUpLimits[originSiteID] ?? defaultUpLimit
    }
}

enum DownloaderType: String, Codable { case qbittorrent, transmission }
enum PushPolicy: String, Codable { case always, onSuccess }

struct GistSyncConfig: Codable {
    var gistID: String
    var token: String
    /// PT-depiler 备份密码；Gist 实际密钥 = password + "|" + gistID
    var encryptionKey: String
    var pollMinutes: Int
}

struct AppConfig: Codable {
    var dataDir: String
    var sourceSites: [SiteConfig]    // 可作为源站的站点（任一支持站均可）
    var targetSites: [String]        // 转种目标站 id 列表（按顺序执行）
    var downloader: DownloaderConfig
    var gistSync: GistSyncConfig?
    var userAgent: String
    var webToken: String?        // web 控制台访问令牌，nil/空 = 不启用

    static let `default` = AppConfig.load(path: "Config/boxsend.json") ?? AppConfig.template()

    func site(_ id: String) -> SiteConfig? {
        sourceSites.first { $0.id == id }
    }

    static func load(path: String) -> AppConfig? {
        let candidates = [path, ("~" as NSString).expandingTildeInPath + "/" + path]
        for p in candidates {
            guard FileManager.default.fileExists(atPath: p) else { continue }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else { continue }
            return try? JSONDecoder().decode(AppConfig.self, from: data)
        }
        return nil
    }

    static func template() -> AppConfig {
        // 模板由 Config/boxsend.json 承担，这里给最小可运行值
        AppConfig(
            dataDir: ".boxsend",
            sourceSites: [],
            targetSites: [],
            downloader: DownloaderConfig(
                type: .qbittorrent, url: "http://127.0.0.1:8080",
                username: "", password: "", savePath: nil, category: nil,
                skipChecking: true, defaultUpLimit: 0, siteUpLimits: [:], pushPolicy: .always
            ),
            gistSync: nil,
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            webToken: nil
        )
    }
}
