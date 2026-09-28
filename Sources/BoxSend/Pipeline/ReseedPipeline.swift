import Foundation

/// 转种 + 推下载器 流水线
/// 源站详情 -> 解析 -> (禁转检查) -> 逐目标站查重/上传 -> 推下载器(按源站限速)
final class ReseedPipeline {
    let config: AppConfig
    let cookies: CookieStore
    let client: HTTPClient
    let state: StateStore
    let downloader: Downloader

    init(config: AppConfig, cookies: CookieStore, state: StateStore, downloader: Downloader) {
        self.config = config
        self.cookies = cookies
        self.client = HTTPClient(cookies: cookies, userAgent: config.userAgent)
        self.state = state
        self.downloader = downloader
    }

    struct Options {
        var skipReseed = false
        var skipPush = false
        var targets: [String]?    // nil = 用 config.targetSites
    }

    struct Report: CustomStringConvertible {
        var release: ReleaseInfo
        var torrentBytes: Int
        var outcomes: [(site: String, ok: Bool, message: String)]
        var pushed: Bool
        var pushID: String?
        var upLimit: Int64

        var description: String {
            var lines: [String] = ["[\(release.summary)] torrent \(torrentBytes) bytes"]
            for o in outcomes {
                lines.append("  reseed \(o.site): \(o.ok ? "OK" : "FAIL") \(o.message)")
            }
            lines.append("  push: \(pushed ? "OK (\(pushID ?? "")) upLimit=\(upLimit == 0 ? "unlimited" : "\(upLimit) B/s")" : "skipped")")
            return lines.joined(separator: "\n")
        }
    }

    func run(detailURL: String, sourceSiteID: String?, opts: Options) throws -> Report {
        // 1. 定位源站
        let site: SiteConfig
        if let id = sourceSiteID, let s = config.site(id) {
            site = s
        } else {
            let host = (try? URL(string: detailURL)?.host()) ?? ""
            guard let s = config.sourceSites.first(where: { host.hasSuffix($0.url.host() ?? $0.url) || $0.url.contains(host) }) else {
                throw BoxSendError.badInput("未找到源站配置: \(detailURL)（--site 指定或在 sourceSites 中配置）")
            }
            site = s
        }
        let debugDir = (config.dataDir as NSString).expandingTildeInPath
        let adapter = SiteRegistry.adapter(for: site, client: client, debugDir: debugDir)

        // 2. 解析详情
        let release = try adapter.fetchDetail(detailURL: detailURL)
        var report = Report(release: release, torrentBytes: 0, outcomes: [], pushed: false, pushID: nil, upLimit: 0)

        // 3. 下载 .torrent
        let (torrentData, filename) = try adapter.downloadTorrentFile(release)
        report.torrentBytes = torrentData.count
        state.note("release: \(release.summary) torrent \(filename)")

        // 4. 逐目标站转种
        let targets = opts.targets ?? config.targetSites
        if !opts.skipReseed {
            if release.isForbidReseed {
                state.note("forbid-reseed marker hit, skip reseed: \(release.summary)")
            } else {
                for tid in targets {
                    guard let ts = config.site(tid) else {
                        report.outcomes.append((tid, false, "未配置的站点 id"))
                        continue
                    }
                    guard ts.enabled else {
                        report.outcomes.append((tid, false, "已禁用"))
                        continue
                    }
                    if state.isUploaded(site: tid, key: release.dedupKey) {
                        report.outcomes.append((tid, true, "已转种过，跳过"))
                        continue
                    }
                    do {
                        let tAdapter = SiteRegistry.adapter(for: ts, client: client, debugDir: debugDir)
                        if let exists = try tAdapter.searchExists(release), !(ts.overrides?.searchURL ?? "").isEmpty {
                            report.outcomes.append((tid, true, "已存在: \(exists)"))
                            state.markUploaded(site: tid, key: release.dedupKey)
                            continue
                        }
                        let outcome = try tAdapter.upload(release, torrentData: torrentData, filename: filename)
                        if outcome.success {
                            state.markUploaded(site: tid, key: release.dedupKey)
                            state.note("reseed OK \(tid) <- \(release.summary)")
                        } else {
                            state.note("reseed FAIL \(tid) <- \(release.summary): \(outcome.message)")
                        }
                        report.outcomes.append((tid, outcome.success, outcome.message))
                    } catch {
                        report.outcomes.append((tid, false, "\(error.localizedDescription)"))
                    }
                }
            }
        }

        // 5. 推下载器（需求 3：按源站点限速）
        let upLimit = config.downloader.upLimitFor(originSiteID: release.siteID)
        report.upLimit = upLimit
        let reseedOk = report.outcomes.allSatisfy { $0.ok } || report.outcomes.isEmpty
        let shouldPush = !opts.skipPush && (config.downloader.pushPolicy == .always || reseedOk)
        if shouldPush {
            if state.isPushed(key: release.dedupKey) {
                report.pushed = true
                report.pushID = "already pushed"
            } else {
                do {
                    let id = try downloader.addTorrent(
                        data: torrentData, filename: filename,
                        savePath: config.downloader.savePath,
                        category: config.downloader.category,
                        skipChecking: config.downloader.skipChecking,
                        upLimit: upLimit
                    )
                    report.pushed = true
                    report.pushID = id
                    state.markPushed(key: release.dedupKey, id: id)
                    state.note("push OK \(release.summary) upLimit=\(upLimit)")
                } catch {
                    state.note("push FAIL \(release.summary): \(error.localizedDescription)")
                    throw error
                }
            }
        }
        return report
    }
}

extension String {
    func host() -> String? {
        guard let u = URL(string: self) else { return nil }
        return u.host
    }
}
