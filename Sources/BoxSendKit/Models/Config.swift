import Foundation

/// 站点框架家族，对应 PT-depiler definitions 中的 schema 分类。
public enum SiteFramework: String, Codable {
    case nexusPHP = "NexusPHP"
    case unit3D = "Unit3D"
    case gazelle = "Gazelle"
    case gazelleJSONAPI = "GazelleJSONAPI"
    case luminance = "Luminance"
    case avistaz = "AvistazNetwork"
    case blu = "Blu"
    case tnode = "TNode"
    case haidan = "Haidan"
    case yemapt = "YemaPT"
    case xbtit = "XBTIT"
    case custom = "custom"
}

public struct SiteConfig: Codable {
    public var id: String
    public var name: String
    public var url: String            // 结尾带 /
    public var framework: SiteFramework
    public var enabled: Bool
    /// 详情/列表/搜索入口覆盖（M1 主要靠 NexusPHP 默认值 + 这里微调）
    public var overrides: SiteOverride?
}

/// 每站覆盖配置：把框架通用行为收敛到站点差异。
public struct SiteOverride: Codable {
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
    /// 字符串值分类映射（个别站分类值是字母 token，如 影 站 tr_category: "mo"/"tv"）；支持 "<kind>/<profile>" 键
    var categoryStringMap: [String: String]?
    /// 动态分类 ajax 端点（个别站分类下拉由 JS 异步生成，如 xingtan "ajax.php"）
    var ajaxCategoryPath: String?
    /// 动态分类：kind -> 顶层 mode（ajax 拉取子分类用）
    var ajaxCategoryModes: [String: Int]?
    /// 动态分类：kind -> 直接使用的子分类 ID（免 ajax）
    var ajaxCategorySubMap: [String: Int]?
    /// 动态分类：kind -> 在 ajax 返回的子分类名中检索的关键词
    var ajaxCategoryKeywords: [String: String]?
    /// 源介质下拉（质量+分辨率组合选值）：字段名，如 "tr_source"
    var sourceSelectField: String?
    /// 组合键选值表："medium" 或 "medium/standard" -> 站点值（字符串），如 "remux/2160p" -> "s52"
    var sourceMap: [String: String]?
    var extraUploadFields: [String: String]?  // 上传时额外提交的固定字段
    /// 命中即视为禁转（只推下载器、不转种），大小写不敏感
    var forbidReseedMarkers: [String]?
    public var userAgent: String?
    /// 质量下拉自动填充：字段名 -> medium|codec|audiocodec|standard
    var qualitySelects: [String: String]?
    /// 质量值表：medium|codec|audiocodec|standard -> token -> 站点 ID
    var qualityValueMaps: [String: [String: Int]]?
    /// 字符串值质量表（个别站选项值是字母 token，如 影 站 tr_resolution: "r3"）
    var qualityStringMaps: [String: [String: String]]?
    /// 副标题字段（中文 NexusPHP 家族 "small_descr"）；值取源简介"译名"
    var subtitleField: String?
    /// 简介格式：bbcode（中文站默认）| html
    var descrFormat: String?
    /// 标签复选框字段名（如 "option_sel[]"）；值 = 规范标签 -> 站点 ID（各站值类型不同：数字或字母 token）
    var tagField: String?
    var tagMap: [String: String]?
    /// 独立复选框标签（个别站的标签是若干独立 checkbox，命中时提交 字段名=yes）：规范标签 -> 字段名
    var tagCheckboxes: [String: String]?
    /// 规范标签: chinese_sub / hdr10 / hdr10plus / dovi / dtsx / atmos / forbid / limited
    /// 制作组下拉字段（如 "team_sel"）；未知组 -> teamOtherValue
    var teamField: String?
    var teamOtherValue: Int?
    /// 制作组名（出现在种子名 - 后）-> 站点 team ID
    var teamPatterns: [String: Int]?
    /// 地区字段（个别站的"制作组"下拉实为产地地区，如 Pterclub）；按源简介"产地"匹配
    var regionField: String?
    /// 产地文本（如 "美国"/"日本"）-> 站点地区 ID；无匹配 -> regionOtherValue
    var regionPatterns: [String: Int]?
    var regionOtherValue: Int?
    /// RSS 地址模板（NexusPHP 默认 "passkey.php?rss={passkey}"）
    var rssPath: String?
}

extension SiteOverride {
    /// 配置层覆盖内置层：标量字段配置非 nil 时生效；字典字段按 key 合并（内置的新 key 保留）
    func merged(over base: SiteOverride) -> SiteOverride {
        var out = base
        if let v = detailLinkPattern { out.detailLinkPattern = v }
        if let v = uploadPath { out.uploadPath = v }
        if let v = uploadActionPath { out.uploadActionPath = v }
        if let v = titleField { out.titleField = v }
        if let v = titleMode { out.titleMode = v }
        if let v = descrField { out.descrField = v }
        if let v = imdbField { out.imdbField = v }
        if let v = imdbValueTemplate { out.imdbValueTemplate = v }
        if let v = doubanField { out.doubanField = v }
        if let v = doubanValueTemplate { out.doubanValueTemplate = v }
        if let v = categoryField { out.categoryField = v }
        if let v = fileField { out.fileField = v }
        if let v = searchURL { out.searchURL = v }
        if let v = extraUploadFields { out.extraUploadFields = v }
        if let v = forbidReseedMarkers { out.forbidReseedMarkers = v }
        if let v = userAgent { out.userAgent = v }
        if let v = subtitleField { out.subtitleField = v }
        if let v = descrFormat { out.descrFormat = v }
        if let v = tagField { out.tagField = v }
        if let v = teamField { out.teamField = v }
        if let v = teamOtherValue { out.teamOtherValue = v }
        if let v = categoryMap { out.categoryMap = base.categoryMap?.merging(v) { _, new in new } }
        if let v = categoryStringMap { out.categoryStringMap = base.categoryStringMap?.merging(v) { _, new in new } }
        if let v = ajaxCategoryPath { out.ajaxCategoryPath = v }
        if let v = ajaxCategoryModes { out.ajaxCategoryModes = base.ajaxCategoryModes?.merging(v) { _, new in new } }
        if let v = ajaxCategorySubMap { out.ajaxCategorySubMap = base.ajaxCategorySubMap?.merging(v) { _, new in new } }
        if let v = ajaxCategoryKeywords { out.ajaxCategoryKeywords = base.ajaxCategoryKeywords?.merging(v) { _, new in new } }
        if let v = sourceSelectField { out.sourceSelectField = v }
        if let v = sourceMap { out.sourceMap = base.sourceMap?.merging(v) { _, new in new } }
        if let v = qualitySelects { out.qualitySelects = base.qualitySelects?.merging(v) { _, new in new } }
        if let v = qualityStringMaps {
            var m = base.qualityStringMaps ?? [:]
            for (k, nv) in v { m[k] = (m[k] ?? [:]).merging(nv) { _, n2 in n2 } }
            out.qualityStringMaps = m
        }
        if let v = qualityValueMaps {
            var m = base.qualityValueMaps ?? [:]
            for (k, nv) in v { m[k] = (m[k] ?? [:]).merging(nv) { _, n2 in n2 } }
            out.qualityValueMaps = m
        }
        if let v = tagMap { out.tagMap = base.tagMap?.merging(v) { _, new in new } }
        if let v = tagCheckboxes { out.tagCheckboxes = base.tagCheckboxes?.merging(v) { _, new in new } }
        if let v = teamPatterns { out.teamPatterns = base.teamPatterns?.merging(v) { _, new in new } }
        if let v = regionField { out.regionField = v }
        if let v = regionOtherValue { out.regionOtherValue = v }
        if let v = regionPatterns { out.regionPatterns = base.regionPatterns?.merging(v) { _, new in new } }
        if let v = rssPath { out.rssPath = v }
        return out
    }
}

public struct DownloaderConfig: Codable {
    public var type: DownloaderType       // qbittorrent | transmission
    public var url: String                // 如 http://127.0.0.1:8080 或 http://127.0.0.1:9091
    public var username: String
    public var password: String
    public var savePath: String?          // 存储路径（空 = 下载器默认）
    public var category: String?          // qBittorrent 分类
    public var skipChecking: Bool
    /// 需求 3：按【源站点 id】设置推送到下载器后的上传限速（bytes/s），0 = 不限速
    public var defaultUpLimit: Int64
    public var siteUpLimits: [String: Int64]
    /// reseed 失败时是否仍推下载器：always | on_success
    public var pushPolicy: PushPolicy

    /// VPS 剩余空间（GB，人工维护；VPS 只装下载器，WebAPI 无磁盘统计端点）。nil/0 = 不做大小检测
    public var vpsFreeGB: Int?
    /// 超过剩余空间（含安全边际）时的行为：warn = 弹窗提醒并继续 | skip = 跳过该种子
    public var sizeGuardMode: SizeGuardMode
    /// 安全边际（GB），剩余空间需大于 种子大小 + 边际 才放行
    public var sizeGuardMarginGB: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(DownloaderType.self, forKey: .type)
        url = try c.decode(String.self, forKey: .url)
        username = try c.decode(String.self, forKey: .username)
        password = try c.decode(String.self, forKey: .password)
        savePath = try c.decodeIfPresent(String.self, forKey: .savePath)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        skipChecking = try c.decodeIfPresent(Bool.self, forKey: .skipChecking) ?? true
        defaultUpLimit = try c.decodeIfPresent(Int64.self, forKey: .defaultUpLimit) ?? 0
        siteUpLimits = try c.decodeIfPresent([String: Int64].self, forKey: .siteUpLimits) ?? [:]
        pushPolicy = try c.decodeIfPresent(PushPolicy.self, forKey: .pushPolicy) ?? .always
        vpsFreeGB = try c.decodeIfPresent(Int.self, forKey: .vpsFreeGB)
        sizeGuardMode = try c.decodeIfPresent(SizeGuardMode.self, forKey: .sizeGuardMode) ?? .warn
        sizeGuardMarginGB = try c.decodeIfPresent(Int.self, forKey: .sizeGuardMarginGB) ?? 5
    }

    public init(type: DownloaderType, url: String, username: String, password: String,
                savePath: String?, category: String?, skipChecking: Bool,
                defaultUpLimit: Int64, siteUpLimits: [String: Int64], pushPolicy: PushPolicy,
                vpsFreeGB: Int? = nil, sizeGuardMode: SizeGuardMode = .warn, sizeGuardMarginGB: Int = 5) {
        self.type = type
        self.url = url
        self.username = username
        self.password = password
        self.savePath = savePath
        self.category = category
        self.skipChecking = skipChecking
        self.defaultUpLimit = defaultUpLimit
        self.siteUpLimits = siteUpLimits
        self.pushPolicy = pushPolicy
        self.vpsFreeGB = vpsFreeGB
        self.sizeGuardMode = sizeGuardMode
        self.sizeGuardMarginGB = sizeGuardMarginGB
    }

    public func upLimitFor(originSiteID: String) -> Int64 {
        siteUpLimits[originSiteID] ?? defaultUpLimit
    }
}

/// 大小检测：种子大小对比 VPS 剩余空间（WebAPI 无磁盘统计端点，剩余空间由用户按 VPS 实际维护）
public enum SizeGuardMode: String, Codable { case warn, skip }

public enum SizeGuard {
    public enum Verdict {
        case ok
        case over(String)
    }

    /// sizeBytes = 0 视为未知大小（放行）。freeGB = nil/<=0 视为未启用。
    public static func evaluate(sizeBytes: Int64, freeGB: Int?, marginGB: Int) -> Verdict {
        guard let free = freeGB, free > 0, sizeBytes > 0 else { return .ok }
        let margin = max(0, marginGB)
        let available = free - margin
        let sizeGB = (Double(sizeBytes) / 1_073_741_824.0).rounded(toPlaces: 2)
        guard available > 0 else {
            return .over("VPS 剩余空间（含 \(margin)GB 安全边际）不足，无法容纳新种子")
        }
        if sizeBytes > Int64(Double(available) * 1_073_741_824.0) {
            return .over("种子 \(String(format: "%.2f", sizeGB)) GiB 超过 VPS 剩余 \(free)GB（含 \(margin)GB 安全边际）")
        }
        return .ok
    }
}

extension Double {
    func rounded(toPlaces n: Int) -> Double {
        let f = pow(10.0, Double(n))
        return (self * f).rounded() / f
    }
}

/// RSS 自动转种（源站 passkey RSS -> 新种子自动走转种流水线）
public struct RssConfig: Codable {
    public var enabled: Bool
    public var pollMinutes: Int          // 轮询间隔（分钟）
    public var passkeys: [String: String] // 源站 id -> RSS passkey（空 = 该站不参与）
    public init(enabled: Bool = false, pollMinutes: Int = 10, passkeys: [String: String] = [:]) {
        self.enabled = enabled
        self.pollMinutes = pollMinutes
        self.passkeys = passkeys
    }
    public static let empty = RssConfig()
}

/// PT-depiler 本地备份目录监控（发现新 zip 自动导入 cookie）
public struct ZipWatchConfig: Codable {
    public var enabled: Bool
    public var dir: String               // 监控目录（如 ~/Downloads）
    public var pollMinutes: Int
    public var password: String          // PT-depiler 备份密码（未加密备份可空）
    public init(enabled: Bool = false, dir: String = "~/Downloads", pollMinutes: Int = 5, password: String = "") {
        self.enabled = enabled
        self.dir = dir
        self.pollMinutes = pollMinutes
        self.password = password
    }
    public static let empty = ZipWatchConfig()
}

public enum DownloaderType: String, Codable { case qbittorrent, transmission }
public enum PushPolicy: String, Codable { case always, onSuccess }

public struct GistSyncConfig: Codable {
    public var gistID: String
    public var token: String
    /// PT-depiler 备份密码；Gist 实际密钥 = password + "|" + gistID
    public var encryptionKey: String
    public var pollMinutes: Int

    public init(gistID: String, token: String, encryptionKey: String, pollMinutes: Int) {
        self.gistID = gistID
        self.token = token
        self.encryptionKey = encryptionKey
        self.pollMinutes = pollMinutes
    }

    public static let empty = GistSyncConfig(gistID: "", token: "", encryptionKey: "", pollMinutes: 30)
}

/// 目标站分组：共用带宽上限（避免 VPS 上传带宽超限）
public struct GroupConfig: Codable, Equatable {
    public var name: String
    public var sites: [String]     // 成员站点 id
    public var upLimitMB: Int      // 分组带宽上限 MB/s，0 = 不限

    public init(name: String, sites: [String] = [], upLimitMB: Int = 0) {
        self.name = name
        self.sites = sites
        self.upLimitMB = upLimitMB
    }
}

public struct AppConfig: Codable {
    public var dataDir: String
    public var sourceSites: [SiteConfig]    // 可作为源站的站点（任一支持站均可）
    public var targetSites: [String]        // 转种目标站 id 列表（按顺序执行）
    public var downloader: DownloaderConfig
    public var gistSync: GistSyncConfig?
    public var userAgent: String
    public var webToken: String?        // web 控制台访问令牌，nil/空 = 不启用
    public var groups: [GroupConfig]    // 目标站分组（限速/单日量上限）
    public var rss: RssConfig?          // RSS 自动转种
    public var zipWatch: ZipWatchConfig? // PT-depiler 备份目录监控

    private enum CodingKeys: String, CodingKey {
        case dataDir, sourceSites, targetSites, downloader, gistSync, userAgent, webToken, groups, rss, zipWatch
    }

    /// 向后兼容：旧配置无 groups 字段时解码为空
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dataDir = try c.decode(String.self, forKey: .dataDir)
        sourceSites = try c.decode([SiteConfig].self, forKey: .sourceSites)
        targetSites = try c.decode([String].self, forKey: .targetSites)
        downloader = try c.decode(DownloaderConfig.self, forKey: .downloader)
        gistSync = try c.decodeIfPresent(GistSyncConfig.self, forKey: .gistSync)
        userAgent = try c.decode(String.self, forKey: .userAgent)
        webToken = try c.decodeIfPresent(String.self, forKey: .webToken)
        groups = try c.decodeIfPresent([GroupConfig].self, forKey: .groups) ?? []
        rss = try c.decodeIfPresent(RssConfig.self, forKey: .rss)
        zipWatch = try c.decodeIfPresent(ZipWatchConfig.self, forKey: .zipWatch)
    }

    public init(dataDir: String, sourceSites: [SiteConfig], targetSites: [String],
                downloader: DownloaderConfig, gistSync: GistSyncConfig?, userAgent: String,
                webToken: String?, groups: [GroupConfig] = [], rss: RssConfig? = nil,
                zipWatch: ZipWatchConfig? = nil) {
        self.dataDir = dataDir
        self.sourceSites = sourceSites
        self.targetSites = targetSites
        self.downloader = downloader
        self.gistSync = gistSync
        self.userAgent = userAgent
        self.webToken = webToken
        self.groups = groups
        self.rss = rss
        self.zipWatch = zipWatch
    }

    public static let `default` = AppConfig.load(path: "Config/boxsend.json") ?? AppConfig.template()

    public func site(_ id: String) -> SiteConfig? {
        sourceSites.first { $0.id == id }
    }

    /// 站点所属分组（第一个包含该站的分组）
    public func groupOf(siteID: String) -> GroupConfig? {
        groups.first { $0.sites.contains(siteID) }
    }

    /// 实际生效的上传限速（bytes/s）：站点限速与所属分组带宽上限取小，0 = 不限
    public func effectiveUpLimit(siteID: String) -> Int64 {
        let siteLimit = downloader.upLimitFor(originSiteID: siteID)
        let groupLimit = Int64(groupOf(siteID: siteID)?.upLimitMB ?? 0) * 1_048_576
        switch (siteLimit, groupLimit) {
        case (0, 0): return 0
        case (0, _): return groupLimit
        case (_, 0): return siteLimit
        default: return min(siteLimit, groupLimit)
        }
    }

    public static func load(path: String) -> AppConfig? {
        let candidates = [path, ("~" as NSString).expandingTildeInPath + "/" + path]
        for p in candidates {
            guard FileManager.default.fileExists(atPath: p) else { continue }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else { continue }
            guard var cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else { continue }
            return cfg.mergedWithRoster()
        }
        return nil
    }

    /// 内置站点表新增的站点自动并入 sourceSites；已存在的内置站点以注册表站名为准
    /// （用户自定义站 id 不在注册表中的，原样保留）
    public func mergedWithRoster() -> AppConfig {
        let roster = Dictionary(uniqueKeysWithValues: SiteRegistry.prioritySites.map { ($0.id, $0) })
        var cfg = self
        var renamed = false
        cfg.sourceSites = sourceSites.map { site in
            var site = site
            if let r = roster[site.id], site.name != r.name {
                site.name = r.name
                renamed = true
            }
            return site
        }
        let existing = Set(sourceSites.map(\.id))
        let added = SiteRegistry.prioritySites.filter { !existing.contains($0.id) }
        guard renamed || !added.isEmpty else { return self }
        cfg.sourceSites += added
        return cfg
    }

    public static func template() -> AppConfig {
        // 模板由 Config/boxsend.json 承担，这里给最小可运行值
        AppConfig(
            dataDir: ".boxsend",
            sourceSites: SiteRegistry.prioritySites,
            targetSites: ["luckpt", "hdsky", "chdbits", "hdhome", "cmct", "audiences", "ttg", "pter"],
            downloader: DownloaderConfig(
                type: .qbittorrent, url: "http://127.0.0.1:8080",
                username: "", password: "", savePath: nil, category: nil,
                skipChecking: true, defaultUpLimit: 0, siteUpLimits: [:], pushPolicy: .always
            ),
            gistSync: nil,
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            webToken: nil,
            groups: [],
            rss: RssConfig(enabled: false, pollMinutes: 10, passkeys: [:]),
            zipWatch: ZipWatchConfig(enabled: false, dir: "~/Downloads", pollMinutes: 5, password: "")
        )
    }
}
