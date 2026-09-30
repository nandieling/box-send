import Foundation

/// 转种 + 推下载器 流水线
/// 源站详情 -> 解析 -> (禁转检查) -> 逐目标站查重/上传 -> 推下载器(按源站限速)
public final class ReseedPipeline {
    let config: AppConfig
    let cookies: CookieStore
    let client: HTTPClient
    let state: StateStore
    let downloader: Downloader

    public init(config: AppConfig, cookies: CookieStore, state: StateStore, downloader: Downloader) {
        // 显式列入 targetSites 的站视为启用（内置表新站默认 enabled=false，
        // 避免"勾选了目标却因未启用被跳过"）
        var c = config
        c.sourceSites = c.sourceSites.map { site in
            var site = site
            if c.targetSites.contains(site.id) && !site.enabled { site.enabled = true }
            return site
        }
        self.config = c
        self.cookies = cookies
        self.client = HTTPClient(cookies: cookies, userAgent: config.userAgent)
        self.state = state
        self.downloader = downloader
    }

    public struct Options {
        public var skipReseed = false
        public var skipPush = false
        public var targets: [String]?    // nil = 用 config.targetSites
        /// 逐站实时事件（GUI 卡片状态用）：siteID / 状态文案 / ok（nil = 进行中）
        public var onSiteEvent: ((String, String, Bool?) -> Void)?
        /// 目标站自己的 .torrent 推送事件（转种成功后逐站推送）
        public var onSitePush: ((String, String, Bool?) -> Void)?
        /// 源站种子推送到下载器的事件
        public var onSourcePush: ((String, Bool?) -> Void)?

        public init(skipReseed: Bool = false, skipPush: Bool = false, targets: [String]? = nil,
                    onSiteEvent: ((String, String, Bool?) -> Void)? = nil,
                    onSitePush: ((String, String, Bool?) -> Void)? = nil,
                    onSourcePush: ((String, Bool?) -> Void)? = nil) {
            self.skipReseed = skipReseed
            self.skipPush = skipPush
            self.targets = targets
            self.onSiteEvent = onSiteEvent
            self.onSitePush = onSitePush
            self.onSourcePush = onSourcePush
        }
    }

    public struct Report: CustomStringConvertible {
        public var release: ReleaseInfo
        public var torrentBytes: Int
        public var torrentData: Data
        public var outcomes: [(site: String, ok: Bool, message: String)]
        public var pushed: Bool
        public var pushID: String?
        public var upLimit: Int64
        public var pushes: [(site: String, ok: Bool, message: String)]
        public var sizeSkipped: Bool
        public var sizeGuardWarning: String?

        public var description: String {
            var lines: [String] = ["[\(release.summary)] torrent \(torrentBytes) bytes"]
            if sizeSkipped {
                lines.append("  size: SKIP \(sizeGuardWarning ?? "")")
                return lines.joined(separator: "\n")
            }
            if let w = sizeGuardWarning {
                lines.append("  size: WARN \(w)")
            }
            for o in outcomes {
                lines.append("  reseed \(o.site): \(o.ok ? "OK" : "FAIL") \(o.message)")
            }
            lines.append("  push: \(pushed ? "OK (\(pushID ?? "")) upLimit=\(upLimit == 0 ? "unlimited" : "\(upLimit) B/s")" : "skipped")")
            for p in pushes {
                lines.append("  push[\(p.site)]: \(p.ok ? "OK" : "FAIL") \(p.message)")
            }
            if outcomes.contains(where: { !$0.ok }) {
                lines.append("  提示: 重跑同一条链接可重试失败站点（已成功的站点自动跳过）")
            }
            return lines.joined(separator: "\n")
        }
    }

    public func run(detailURL: String, sourceSiteID: String?, opts: Options) throws -> Report {
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
        var release = try adapter.fetchDetail(detailURL: detailURL)
        var report = Report(release: release, torrentBytes: 0, torrentData: Data(), outcomes: [], pushed: false, pushID: nil, upLimit: 0, pushes: [], sizeSkipped: false, sizeGuardWarning: nil)

        // 3. 下载 .torrent，并用 bencode info.name 校正发布名（权威来源）
        let (torrentData, filename) = try adapter.downloadTorrentFile(release)
        report.torrentBytes = torrentData.count
        report.torrentData = torrentData
        if let tn = Bencode.infoName(torrentData), !tn.isEmpty, tn != release.name {
            state.note("name corrected by .torrent info.name: \(release.name) -> \(tn)")
            release.name = tn
        }
        release.size = Bencode.totalLength(torrentData) ?? release.size
        report.release = release
        state.note("release: \(release.summary) torrent \(filename)")

        // 3.5 大小检测：种子大小 vs VPS 剩余空间（含安全边际）
        if case .over(let msg) = SizeGuard.evaluate(sizeBytes: release.size ?? 0,
                                                    freeGB: config.downloader.vpsFreeGB,
                                                    marginGB: config.downloader.sizeGuardMarginGB) {
            if config.downloader.sizeGuardMode == .skip {
                report.sizeSkipped = true
                report.sizeGuardWarning = msg
                state.note("sizeGuard SKIP \(release.summary): \(msg)")
                return report
            }
            report.sizeGuardWarning = msg
            state.note("sizeGuard WARN \(release.summary): \(msg)")
        }

        // 4. 逐目标站转种
        let targets = opts.targets ?? config.targetSites
        // 转种成功的目标站 -> 其新种子详情页，稍后逐站推送该站自己的 .torrent
        var targetPushes: [(siteID: String, detailURL: String)] = []
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
                    opts.onSiteEvent?(tid, "转种中…", nil)
                    if state.isUploaded(site: tid, key: release.dedupKey) {
                        report.outcomes.append((tid, true, "已转种过，跳过"))
                        opts.onSiteEvent?(tid, "已转种过（跳过）", true)
                        if let tu = state.targetURL(site: tid, key: release.dedupKey) {
                            targetPushes.append((tid, tu))
                        }
                        continue
                    }
                    do {
                        let tAdapter = SiteRegistry.adapter(for: ts, client: client, debugDir: debugDir)
                        if let exists = try tAdapter.searchExists(release), !(ts.overrides?.searchURL ?? "").isEmpty {
                            report.outcomes.append((tid, true, "已存在: \(exists)"))
                            opts.onSiteEvent?(tid, "已存在（跳过）", true)
                            state.markUploaded(site: tid, key: release.dedupKey)
                            continue
                        }
                        let outcome = try tAdapter.upload(release, torrentData: torrentData, filename: filename)
                        if outcome.success {
                            state.markUploaded(site: tid, key: release.dedupKey)
                            state.note("reseed OK \(tid) <- \(release.summary)")
                            opts.onSiteEvent?(tid, "转种成功", true)
                            if let u = outcome.detailURL {
                                state.markTargetURL(site: tid, key: release.dedupKey, url: u)
                                targetPushes.append((tid, u))
                            } else {
                                state.note("reseed \(tid): 发布成功但未拿到新种子链接，跳过目标站推送")
                            }
                        } else {
                            state.note("reseed FAIL \(tid) <- \(release.summary): \(outcome.message)")
                            opts.onSiteEvent?(tid, "转种失败: \(outcome.message)", false)
                        }
                        report.outcomes.append((tid, outcome.success, outcome.message))
                    } catch {
                        report.outcomes.append((tid, false, "\(error.localizedDescription)"))
                        opts.onSiteEvent?(tid, "转种失败: \(error.localizedDescription)", false)
                    }
                }
            }
        } else {
            // skipReseed：从已有记录补齐目标站新种子链接，保证目标站 torrent 也能推送
            for tid in targets {
                if let tu = state.targetURL(site: tid, key: release.dedupKey) {
                    targetPushes.append((tid, tu))
                }
            }
        }

        // 5. 推下载器（站点限速，以「站点分组」页为准）
        let upLimit = config.effectiveUpLimit(siteID: release.siteID)
        report.upLimit = upLimit
        let reseedOk = report.outcomes.allSatisfy { $0.ok } || report.outcomes.isEmpty
        let shouldPush = !opts.skipPush && (config.downloader.pushPolicy == .always || reseedOk)
        if shouldPush {
            if state.isPushed(key: release.dedupKey) {
                report.pushed = true
                report.pushID = "already pushed"
                state.note("push: 已推送过，跳过: \(release.summary)")
                opts.onSourcePush?("已推送过（跳过）", true)
            } else {
                do {
                    opts.onSourcePush?("推送到下载器中…", nil)
                    let result = try downloader.addTorrent(
                        data: torrentData, filename: filename,
                        savePath: config.downloader.savePath,
                        category: config.downloader.category,
                        skipChecking: config.downloader.skipChecking,
                        upLimit: upLimit
                    )
                    report.pushed = true
                    report.pushID = result.id
                    state.markPushed(key: release.dedupKey, id: result.id)
                    var note = "push OK \(release.summary) upLimit=\(upLimit)"
                    if !result.note.isEmpty { note += " [\(result.note)]" }
                    state.note(note)
                    opts.onSourcePush?("已推送到下载器", true)
                } catch {
                    state.note("push FAIL \(release.summary): \(error.localizedDescription)")
                    opts.onSourcePush?("推送失败: \(error.localizedDescription)", false)
                    throw error
                }
            }
        }

        // 6. 逐目标站推送该站自己的 .torrent
        //    各站 .torrent 的 tracker 不同、info hash 通常也不同，在 qB 中是独立种子；
        //    按目标站限速（分组/站点 upLimit），避免某一站上传过快被封。
        if !opts.skipPush {
            for item in targetPushes {
                let pushKey = "\(item.siteID)#\(item.detailURL)"
                opts.onSitePush?(item.siteID, "推送该站种子中…", nil)
                if state.isPushed(key: pushKey) {
                    report.pushes.append((item.siteID, true, "已推送过，跳过"))
                    opts.onSitePush?(item.siteID, "已推送过（跳过）", true)
                    continue
                }
                do {
                    guard let ts = config.site(item.siteID) else {
                        report.pushes.append((item.siteID, false, "未配置的站点 id"))
                        continue
                    }
                    let tAdapter = SiteRegistry.adapter(for: ts, client: client, debugDir: debugDir)
                    let tInfo = try tAdapter.fetchDetail(detailURL: item.detailURL)
                    let (tData, tName) = try tAdapter.downloadTorrentFile(tInfo)
                    let limit = config.effectiveUpLimit(siteID: item.siteID)
                    let result = try downloader.addTorrent(
                        data: tData, filename: tName,
                        savePath: config.downloader.savePath,
                        category: config.downloader.category,
                        skipChecking: config.downloader.skipChecking,
                        upLimit: limit
                    )
                    state.markPushed(key: pushKey, id: result.id)
                    var msg = "upLimit=\(limit == 0 ? "unlimited" : "\(limit) B/s")"
                    if !result.note.isEmpty { msg += " [\(result.note)]" }
                    report.pushes.append((item.siteID, true, msg))
                    state.note("push[\(item.siteID)] OK \(tInfo.name) upLimit=\(limit)\(result.note.isEmpty ? "" : " [\(result.note)]")")
                    opts.onSitePush?(item.siteID, "已推送", true)
                } catch {
                    report.pushes.append((item.siteID, false, error.localizedDescription))
                    state.note("push[\(item.siteID)] FAIL \(item.detailURL): \(error.localizedDescription)")
                    opts.onSitePush?(item.siteID, "推送失败: \(error.localizedDescription)", false)
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
