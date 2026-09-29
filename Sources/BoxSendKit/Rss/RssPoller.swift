import Foundation

/// RSS 自动转种：轮询各源站 passkey RSS -> 去重新种 -> 逐条走 ReseedPipeline（转种 + 推下载器）。
/// 大小检测（SizeGuard）在 pipeline 内部生效，RSS 新种自动被覆盖。
public final class RssPoller {
    public struct ItemResult {
        public var siteID: String
        public var guid: String
        public var title: String
        public var ok: Bool
        public var message: String
        public init(siteID: String, guid: String, title: String, ok: Bool, message: String) {
            self.siteID = siteID
            self.guid = guid
            self.title = title
            self.ok = ok
            self.message = message
        }
    }

    let config: AppConfig
    let client: HTTPClient
    let state: StateStore
    private let pipeline: ReseedPipeline

    public init(config: AppConfig, cookies: CookieStore, state: StateStore, downloader: Downloader) {
        self.config = config
        self.client = HTTPClient(cookies: cookies, userAgent: config.userAgent)
        self.state = state
        self.pipeline = ReseedPipeline(config: config, cookies: cookies, state: state, downloader: downloader)
    }

    /// RSS 地址 = 站点根 URL + rssPath（{passkey} 占位），默认 NexusPHP passkey.php?rss={passkey}
    public static func feedURL(site: SiteConfig, passkey: String) -> String {
        let path = (site.overrides?.rssPath ?? "passkey.php?rss={passkey}")
            .replacingOccurrences(of: "{passkey}", with: passkey)
        let base = site.url.hasSuffix("/") ? String(site.url.dropLast()) : site.url
        return base + "/" + path
    }

    /// 轮询一次；返回每个处理过的新种结果（RSS 拉取失败只记日志不抛出）
    public func pollOnce() -> [ItemResult] {
        guard let rss = config.rss, rss.enabled else { return [] }
        var results: [ItemResult] = []
        for (siteID, passkey) in rss.passkeys.sorted(by: { $0.key < $1.key }) {
            let pk = passkey.trimmingCharacters(in: .whitespaces)
            guard !pk.isEmpty else { continue }
            guard let site = config.site(siteID) else {
                state.note("rss: 跳过未配置站点 \(siteID)")
                continue
            }
            let feedURL = Self.feedURL(site: site, passkey: pk)
            guard let resp = try? client.get(feedURL, referer: site.url) else {
                state.note("rss: 拉取失败 \(siteID)（网络错误）")
                continue
            }
            guard (200..<300).contains(resp.status) else {
                state.note("rss: 拉取失败 \(siteID) HTTP \(resp.status)")
                continue
            }
            let xml = String(data: resp.data, encoding: .utf8) ?? ""
            let items = RssFeed.parse(xml)
            guard !items.isEmpty else {
                state.note("rss: \(siteID) 无条目")
                continue
            }
            var fresh = 0
            for it in items {
                if state.isRssSeen(site: siteID, guid: it.guid) { continue }
                // 先标记再处理：中途崩溃也不至于重复转种（配合 pipeline 内查重兜底）
                state.markRssSeen(site: siteID, guid: it.guid)
                fresh += 1
                results.append(process(siteID: siteID, item: it))
            }
            state.note("rss: \(siteID) 共 \(items.count) 条，新种 \(fresh) 条")
        }
        return results
    }

    /// 单条新种走完整流水线；异常捕获后返回 FAIL 结果，不影响其它条目
    private func process(siteID: String, item: RssItem) -> ItemResult {
        var res = ItemResult(siteID: siteID, guid: item.guid, title: item.title, ok: false, message: "")
        let detailURL = Self.detailURL(from: item.link)
        do {
            let report = try pipeline.run(detailURL: detailURL, sourceSiteID: siteID, opts: .init())
            if report.sizeSkipped {
                res.ok = false
                res.message = "大小检测跳过: \(report.sizeGuardWarning ?? "")"
            } else {
                let r = report.outcomes.map { "\($0.site)=\($0.ok ? "OK" : "FAIL")" }.joined(separator: ",")
                let p = report.pushes.map { "\($0.site)=\($0.ok ? "OK" : "FAIL")" }.joined(separator: ",")
                res.ok = !report.outcomes.contains(where: { !$0.ok }) && !report.pushes.contains(where: { !$0.ok })
                res.message = "reseed[\(r.isEmpty ? "-" : r)] push[\(p.isEmpty ? "源站: " + (report.pushed ? "OK" : "skipped") : p)]"
            }
        } catch {
            res.message = error.localizedDescription
        }
        state.note("rss: [\(siteID)] \(res.ok ? "OK" : "FAIL") \(item.title.prefix(60)) \(res.message)")
        return res
    }

    /// RSS item link 归一化为详情页 URL（torrents.php?id= -> details.php?id=）
    static func detailURL(from link: String) -> String {
        link.replacingOccurrences(of: "torrents.php?id=", with: "details.php?id=")
    }
}
