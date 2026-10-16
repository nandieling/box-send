import Foundation

/// 自动批量辅种：扫描下载器 → 逐条种子 × 参与站点 → 站内检索 → 下载站点那份 .torrent
/// → 判定同一种子 → 加进下载器（先暂停）→ 校验复核 → 满 100% 才启动，否则按策略回滚。
///
/// 与转种的分工：转种要发新种，辅种只是把站内已有的那条挂到本账号下做种。
/// 站点侧负载由 `SiteThrottle` 统一收口 —— 所有对站点的请求（检索、详情、下载种子文件）
/// 都要先领号，一次领号算一次，不按「是不是搜索页」区别对待。
public final class AssistPipeline {
    let config: AppConfig
    let cookies: CookieStore
    let client: HTTPClient
    let state: StateStore
    let downloader: Downloader
    let throttle: SiteThrottle

    public init(config: AppConfig, cookies: CookieStore, state: StateStore,
                downloader: Downloader, throttle: SiteThrottle? = nil) {
        self.config = config
        self.cookies = cookies
        self.client = HTTPClient(cookies: cookies, userAgent: config.userAgent)
        self.state = state
        self.downloader = downloader
        self.throttle = throttle ?? SiteThrottle(limits: config.assist?.throttleLimits ?? .init())
    }

    /// 逐条进展（界面卡片用）。与转种分开一套：辅种多了「校验中」这一态，
    /// 因为「已添加」不等于「已辅种」——要等下载器校验到 100% 才算成。
    public struct Status: Equatable {
        public enum Phase: Equatable { case working, verifying, done, failed, skipped }
        public var siteID: String
        /// 哪条种子（下载器里的 v1 hash，小写）；站点级提示时为空
        public var hash: String
        public var torrentName: String
        public var text: String
        public var phase: Phase
        public var detail: String
        /// 界面定位行用
        public var rowKey: String { "\(siteID)|\(hash)" }
    }

    public struct Options {
        /// 本轮参与的站点（nil = 用配置里的白名单）
        public var siteIDs: [String]?
        /// 只报告不动下载器
        public var dryRun = false
        /// 本轮最多处理几条（0 = 不限）
        public var limit = 0
        public var onEvent: ((Status) -> Void)?
        /// 等校验时的等待（注入点：单测不真睡觉）
        public var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        public init() {}
    }

    public struct Report {
        public var outcomes: [AssistOutcome] = []
        /// 本轮对站点发了多少次请求
        public var requests: Int { throttleUsed }
        public var throttleUsed = 0
        public var assistedCount: Int { outcomes.filter { $0.done }.count }
        public var pendingCount: Int {
            outcomes.filter { if case .nameOnly = $0.level { return true }; return false }.count
        }
        public var skippedCount: Int {
            outcomes.filter { if case .skip = $0.level { return true }; return false }.count
        }
    }

    /// 站点适配器工厂（默认走内置注册表；单测注入假适配器，不发真请求）
    var adapterFactory: (SiteConfig, HTTPClient) -> any SiteAdapter = { site, client in
        SiteRegistry.adapter(for: site, client: client)
    }

    // MARK: - 扫描

    /// 下载器里可以拿去辅种的种子（已完成 + 过大小/分类筛选）
    public func scanCandidates() throws -> [LocalTorrent] {
        guard let cfg = config.assist else { return [] }
        let all = try downloader.listTorrents()
        return all.filter { t in
            guard t.progress >= 0.999 else { return false }
            let gb = Double(t.totalSize) / 1_073_741_824
            if cfg.minSizeGB > 0, gb < cfg.minSizeGB { return false }
            if cfg.maxSizeGB > 0, gb > cfg.maxSizeGB { return false }
            if !cfg.categories.isEmpty {
                let mine = Set((t.category.map { [$0] } ?? []) + t.tags)
                if cfg.categories.first(where: { mine.contains($0) }) == nil { return false }
            }
            return true
        }
    }

    // MARK: - 执行

    @discardableResult
    public func run(torrents: [LocalTorrent], opts: Options = Options()) -> Report {
        var report = Report()
        guard let cfg = config.assist else { return report }
        let ids = opts.siteIDs ?? cfg.siteIDs
        // 站点在外层：一个站连着处理多条种子，间隔才有意义（种子在外层会变成
        // 一条种子挨个站敲一遍，每站各敲一次，节奏全废）
        for id in ids {
            guard let site = config.site(id) else { continue }
            let adapter = adapterFactory(SiteRegistry.effectiveSite(site), client)
            if !adapter.canPrecheckDuplicate {
                emit(opts, Status(siteID: id, hash: "", torrentName: "",
                                  text: "跳过：该站暂不支持站内检索", phase: .skipped,
                                  detail: "\(site.name) 没有可用的检索入口，辅种要靠检索找到站内那条"))
                continue
            }
            for t in torrents {
                if opts.limit > 0, report.outcomes.count >= opts.limit { return report }
                let out = attempt(t, site: site, adapter: adapter, cfg: cfg, opts: opts)
                report.outcomes.append(out)
                emit(opts, Status(siteID: id, hash: t.hash, torrentName: t.name,
                                  text: textOf(out), phase: phaseOf(out),
                                  detail: out.detailURL.map { "\(out.message)\n\($0)" } ?? out.message))
            }
        }
        report.throttleUsed = throttle.used
        return report
    }

    private func emit(_ opts: Options, _ s: Status) { opts.onEvent?(s) }

    private func textOf(_ o: AssistOutcome) -> String {
        switch o.level {
        case .sameHash, .sameFiles: return o.done ? "辅种成功" : "待复核"
        case .nameOnly: return "待人工确认"
        case .skip(let why): return "跳过：\(why)"
        }
    }

    private func phaseOf(_ o: AssistOutcome) -> Status.Phase {
        switch o.level {
        case .sameHash, .sameFiles: return o.done ? .done : .verifying
        case .nameOnly: return .skipped
        case .skip: return .skipped
        }
    }

    /// 发请求前的预筛：命中就一次请求都不花（已在该站做种 / 已辅过 / 负缓存期内）
    private struct PreSkip {
        let why: String
        let detail: String
    }

    private func preSkip(_ t: LocalTorrent, site: SiteConfig, cfg: AssistConfig) -> PreSkip? {
        if let host = AssistConfig.announceHost(of: site), t.trackerHosts.contains(host) {
            return PreSkip(why: "已在该站做种", detail: "这份文件的 tracker 里已经有 \(host)")
        }
        if state.isAssisted(site: site.id, hash: t.hash) {
            return PreSkip(why: "此前已辅过", detail: "本轮跳过，重跑不重复检索")
        }
        if state.assistMissedAt(site: site.id, hash: t.hash,
                               ttlSeconds: Double(cfg.missTTLDays) * 86_400) != nil {
            return PreSkip(why: "站内没有（\(cfg.missTTLDays) 天内查过）", detail: "负缓存生效，不重复检索")
        }
        return nil
    }

    /// 本轮计划：一条种子 × 一个站，预先标出哪些会跳过（不发任何站点请求）。
    /// 界面先给人看「这次要敲哪些站的门、大概敲几次」，再决定跑不跑。
    public struct PlanRow {
        public var siteID: String
        public var hash: String
        public var torrentName: String
        /// nil = 本轮会去站内检索；有值 = 直接跳过及原因
        public var skipReason: String?
    }

    public func plan(torrents: [LocalTorrent], siteIDs: [String]? = nil) -> [PlanRow] {
        guard let cfg = config.assist else { return [] }
        var rows: [PlanRow] = []
        for id in (siteIDs ?? cfg.siteIDs) {
            guard let site = config.site(id) else { continue }
            // 建适配器不发请求，可以拿它先问一句「这站有没有检索入口」
            let adapter = adapterFactory(SiteRegistry.effectiveSite(site), client)
            for t in torrents {
                var reason: String?
                if !adapter.canPrecheckDuplicate {
                    reason = "该站暂不支持站内检索"
                } else {
                    reason = preSkip(t, site: site, cfg: cfg)?.why
                }
                rows.append(PlanRow(siteID: site.id, hash: t.hash, torrentName: t.name,
                                    skipReason: reason))
            }
        }
        return rows
    }

    /// 一条种子 × 一个站
    private func attempt(_ t: LocalTorrent, site: SiteConfig, adapter: any SiteAdapter,
                         cfg: AssistConfig, opts: Options) -> AssistOutcome {
        func out(_ level: AssistLevel, _ msg: String, url: String? = nil, done: Bool = false)
            -> AssistOutcome {
            AssistOutcome(siteID: site.id, torrentName: t.name, level: level,
                          detailURL: url, done: done, message: msg)
        }
        // 先筛掉不该花请求的组合：白扔请求既慢又给站点添负载
        if let pre = preSkip(t, site: site, cfg: cfg) {
            return out(.skip(pre.why), pre.detail)
        }
        if !throttle.acquire(site.id) {
            return out(.skip("本轮检索预算用完"), "站点请求预算已用满，下次接着跑")
        }
        let query = ReleaseInfo(siteID: site.id, detailURL: site.url, name: t.name)
        guard let detail = try? adapter.searchExists(query) else {
            state.markAssistMiss(site: site.id, hash: t.hash)
            return out(.skip("站内无此种子"), "站内检索没找到同名种子")
        }
        guard throttle.acquire(site.id),
              let info = try? adapter.fetchDetail(detailURL: detail),
              throttle.acquire(site.id),
              let (data, _) = try? adapter.downloadTorrentFile(info) else {
            return out(.skip("站点那条读不下来"), "详情或 .torrent 下载失败（cookie 可能失效）")
        }
        guard let localFiles = try? downloader.torrentFiles(hash: t.hash), !localFiles.isEmpty else {
            return out(.nameOnly(info.name), "读不到本地种子的文件清单，没法逐文件比对")
        }
        let local = TorrentFingerprint(root: TorrentFingerprint.commonRoot(localFiles),
                                       files: localFiles)
        let (level, why) = AssistMatcher.judge(localHashes: t.allHashes, local: local,
                                              siteTorrentData: data, siteName: info.name)
        switch level {
        case .nameOnly:
            return out(level, "名字对得上但文件清单对不上：\(why)")
        case .skip(let why):
            return out(.skip(why), why)
        case .sameHash, .sameFiles:
            if case .sameFiles = level, !cfg.autoAcceptSameFiles {
                return out(.nameOnly(info.name), "站点重新打包过（hash 不同），按设置不自动采纳")
            }
            let sitePaths = Set(Bencode.fileList(data)?.map { $0.path } ?? [])
            switch AssistMatcher.layout(localPaths: Set(localFiles.map { $0.path }),
                                       sitePaths: sitePaths) {
            case .rootDiffers:
                return out(level, "文件一致，但站点种子的内层目录名与本地不同，"
                                + "直接加会重下一整份，先不动下载器", url: detail)
            case .differs:
                return out(level, "文件一致，但目录结构不同，直接加会重下一整份，先不动下载器",
                           url: detail)
            case .same:
                break
            }
            if opts.dryRun {
                return out(level, "可辅（dry-run 未推送）：\(why)", url: detail)
            }
            return push(t, site: site, cfg: cfg, data: data, level: level, why: why, detail: detail, opts: opts)
        }
    }

    /// 加进下载器 → 等校验 → 满 100% 才启动
    private func push(_ t: LocalTorrent, site: SiteConfig, cfg: AssistConfig, data: Data,
                      level: AssistLevel, why: String, detail: String, opts: Options) -> AssistOutcome {
        func out(_ msg: String, url: String? = detail, done: Bool = false,
                 phaseLevel: AssistLevel? = nil) -> AssistOutcome {
            AssistOutcome(siteID: site.id, torrentName: t.name, level: phaseLevel ?? level,
                          detailURL: url, done: done, message: msg)
        }
        let limit = config.effectiveUpLimit(siteID: site.id)
        do {
            _ = try downloader.addTorrent(data: data, filename: (Bencode.infoName(data) ?? t.name) + ".torrent",
                                          savePath: t.savePath, category: t.category,
                                          skipChecking: false, upLimit: limit, paused: true)
        } catch {
            return AssistOutcome(siteID: site.id, torrentName: t.name, level: level,
                                 detailURL: detail, message: "加进下载器失败：\(error.localizedDescription)")
        }
        let siteHash = Bencode.infoHash(data)?.lowercased() ?? t.hash
        var waited: TimeInterval = 0
        let poll = TimeInterval(max(1, cfg.verifyPollSec))
        while waited < TimeInterval(cfg.verifyWaitSec) {
            if let p = try? downloader.torrentProgress(hash: siteHash) {
                if p.progress >= 0.999 {
                    try? downloader.setPaused(hashes: [siteHash], paused: false)
                    state.markAssisted(site: site.id, hash: t.hash, url: detail,
                                       level: level == .sameHash ? "sameHash" : "sameFiles")
                    state.note("assist[\(site.id)] OK \(t.name) \(level == .sameHash ? "同 hash" : "同文件")")
                    return AssistOutcome(siteID: site.id, torrentName: t.name, level: level,
                                         detailURL: detail, done: true,
                                         message: "校验到 100%，已启动（\(why)）")
                }
                // 校验跑完仍不满：文件对不上，留着它会自己重下一整份
                if waited > 0, !isChecking(p.state) {
                    if cfg.removeOnVerifyFail {
                        try? downloader.removeTorrent(hash: siteHash, keepFiles: true)
                        return AssistOutcome(siteID: site.id, torrentName: t.name, level: level,
                                             detailURL: detail,
                                             message: "校验后只到 \(Int(p.progress * 100))%，已删掉刚加的种子"
                                                    + "（文件保留）：内层路径与本地对不上")
                    }
                    return AssistOutcome(siteID: site.id, torrentName: t.name, level: level,
                                         detailURL: detail,
                                         message: "校验后只到 \(Int(p.progress * 100))%，种子保持暂停："
                                                + "文件对不上，别让它开始重下")
                }
            }
            opts.sleep(poll)
            waited += poll
        }
        return AssistOutcome(siteID: site.id, torrentName: t.name, level: level, detailURL: detail,
                             message: "校验还没跑完（等了 \(cfg.verifyWaitSec) 秒），"
                                    + "种子先留在下载器里暂停着，稍后回来看结果")
    }

    private func isChecking(_ state: String) -> Bool {
        ["checking", "checkingFiles", "checkingResumeData", "allocating", "metadownload"].contains(state)
    }
}
