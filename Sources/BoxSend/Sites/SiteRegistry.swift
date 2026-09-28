import Foundation

/// 站点注册表：按 framework 选择适配器；NexusPHP 家族内置优先站点表。
enum SiteRegistry {

    static func adapter(for site: SiteConfig, client: HTTPClient, debugDir: String? = nil) -> SiteAdapter {
        switch site.framework {
        case .nexusPHP:
            return NexusPHPAdapter(site: site, client: client, debugDir: debugDir)
        default:
            // M1 只实现 NexusPHP；其余框架 M2 补齐
            fatalError("框架 \(site.framework.rawValue) 尚未实现适配器 (M2)")
        }
    }

    /// auto_feed 优先站点（全部 NexusPHP）
    static let prioritySites: [SiteConfig] = [
        SiteConfig(id: "luckpt", name: "LuckPT", url: "https://pt.luckpt.de/", framework: .nexusPHP, enabled: true),
        SiteConfig(id: "hdsky", name: "HDSky", url: "https://hdsky.me/", framework: .nexusPHP, enabled: true),
        SiteConfig(id: "chdbits", name: "CHDBits", url: "https://ptchdbits.co/", framework: .nexusPHP, enabled: true),
        SiteConfig(id: "hdhome", name: "HDHome", url: "https://hdhome.org/", framework: .nexusPHP, enabled: true),
        SiteConfig(id: "cmct", name: "CMCT", url: "https://springsunday.net/", framework: .nexusPHP, enabled: true),
        SiteConfig(id: "audiences", name: "Audiences", url: "https://audiences.me/", framework: .nexusPHP, enabled: true),
        SiteConfig(id: "ttg", name: "TTG", url: "https://totheglory.im/", framework: .nexusPHP, enabled: true),
        SiteConfig(id: "pter", name: "PTer", url: "https://pterclub.net/", framework: .nexusPHP, enabled: true),
        SiteConfig(id: "hhanclub", name: "HHanClub", url: "https://hhanclub.net/", framework: .nexusPHP, enabled: true),
    ]
}
