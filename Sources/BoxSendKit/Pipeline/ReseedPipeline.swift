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

    /// 目标站种子详情页链接补全：旧版 state 里存过相对链接（details.php?id=1），
    /// 直接当 URL 用会 unsupported URL，按站点主页补成绝对地址
    func absoluteTargetURL(_ siteID: String, _ url: String) -> String {
        guard !url.lowercased().hasPrefix("http"), let base = config.site(siteID)?.url,
              let u = URL(string: base) else { return url }
        return HTMLUtil.resolveURL(url, against: u)
    }

    /// 源站种子推下载器（按源站限速）。失败只记事件不抛出：转种与推下载器互不依赖，
    /// 下载器连不上时也应该把种先发到目标站。
    /// 这一行讲的是「源站种子」，文案统一用获取（源站种子获取中… / 源站种子已获取），
    /// 和目标站卡片上的推送区分开，免得看着像目标站已经推完。
    private func pushSourceTorrent(torrentData: Data, filename: String, upLimit: Int64,
                                   release: ReleaseInfo, opts: Options, report: inout Report) {
        if state.isPushed(key: release.dedupKey) {
            report.pushed = true
            report.pushID = "already pushed"
            state.note("push: 已推送过，跳过: \(release.summary)")
            opts.onSourcePush?(SiteStatus(siteID: release.siteID, text: "源站种子已获取", phase: .done,
                                          detail: "此前已获取过"))
            return
        }
        opts.onSourcePush?(SiteStatus(siteID: release.siteID, text: "源站种子获取中…", phase: .working))
        do {
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
            opts.onSourcePush?(SiteStatus(siteID: release.siteID, text: "源站种子已获取", phase: .done,
                                          detail: result.note))
        } catch {
            state.note("push FAIL \(release.summary): \(error.localizedDescription)")
            report.pushes.append((release.siteID, false, "源站种子获取失败：\(error.localizedDescription)"))
            opts.onSourcePush?(SiteStatus(siteID: release.siteID, text: "源站种子获取失败", phase: .failed,
                                          detail: error.localizedDescription))
        }
    }

    /// 逐目标站推送该站自己的 .torrent（转完一站就推一站，不等整组）
    /// 各站 .torrent 的 tracker 不同、info hash 通常也不同，在 qB 中是独立种子；
    /// 按目标站限速（分组/站点 upLimit），避免某一站上传过快被封。
    private func pushTargetSite(siteID: String, detailURL: String, seedPreexisting: Bool,
                                debugDir: String, opts: Options, report: inout Report) {
        let pushKey = "\(siteID)#\(detailURL)"
        opts.onSitePush?(SiteStatus(siteID: siteID, text: "推送中…", phase: .working))
        // 本次没新发种的站提示「推送已有种子」，让用户分清推的是刚发的还是站内现成的
        let pushedText = seedPreexisting ? "推送已有种子" : "已推送"
        if state.isPushed(key: pushKey) {
            report.pushes.append((siteID, true, "已推送过，跳过"))
            opts.onSitePush?(SiteStatus(siteID: siteID, text: pushedText, phase: .done,
                                        detail: "此前已推送过"))
            return
        }
        do {
            guard let ts = config.site(siteID) else {
                report.pushes.append((siteID, false, "未配置的站点 id"))
                return
            }
            let tAdapter = adapterFactory(ts, client, debugDir)
            let tInfo = try tAdapter.fetchDetail(detailURL: detailURL)
            let (tData, tName) = try tAdapter.downloadTorrentFile(tInfo)
            let limit = config.effectiveUpLimit(siteID: siteID)
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
            report.pushes.append((siteID, true, msg))
            state.note("push[\(siteID)] OK \(tInfo.name) upLimit=\(limit)\(result.note.isEmpty ? "" : " [\(result.note)]")")
            // 下载器给的附加说明必须显示出来：种子 hash 与源站相同时 qB 只回"已存在"，
            // 补没补上本站 tracker 全在这句话里，只写"已推送"会把没生效的推送看成成功
            opts.onSitePush?(SiteStatus(siteID: siteID, text: pushedText, phase: .done,
                                        detail: result.note.isEmpty ? tInfo.name
                                                                    : "\(tInfo.name)\n\(result.note)"))
        } catch {
            report.pushes.append((siteID, false, error.localizedDescription))
            state.note("push[\(siteID)] FAIL \(detailURL): \(error.localizedDescription)")
            opts.onSitePush?(SiteStatus(siteID: siteID, text: "推送失败", phase: .failed,
                                        detail: error.localizedDescription))
        }
    }

    /// 站点适配器工厂（默认走内置注册表；单测注入假适配器以核对逐站执行顺序）
    var adapterFactory: (SiteConfig, HTTPClient, String) -> any SiteAdapter = { site, client, debugDir in
        SiteRegistry.adapter(for: site, client: client, debugDir: debugDir)
    }

    /// 限时执行一段同步工作：站点或图床卡住时不能把整轮转种拖到天荒地老
    /// （实测肉丝下载源站截图能卡几分钟）。超时后放弃等待并按失败报，
    /// 后台那次请求自己跑完，站点那边可能仍然发种成功。
    private func bounded<T>(_ seconds: TimeInterval, _ what: String,
                            _ work: @escaping () throws -> T) throws -> T {
        if seconds <= 0 { return try work() }
        let box = BoundedResult<T>()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(Result { try work() })
            sem.signal()
        }
        guard sem.wait(timeout: .now() + seconds) == .success, let result = box.get() else {
            throw BoxSendError.badInput("\(what)超时（超过 \(Int(seconds)) 秒未返回）")
        }
        return try result.get()
    }

    /// 跨线程放结果的小盒子（超时后主流程可能先读，也可能后台先写）
    private final class BoundedResult<T> {
        private var stored: Result<T, Error>?
        private let lock = NSLock()
        func set(_ value: Result<T, Error>) {
            lock.lock(); defer { lock.unlock() }
            stored = value
        }
        func get() -> Result<T, Error>? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    /// 逐站实时状态（运行页卡片两行提示用）：短文案 + 阶段 + 详情。
    /// 文案固定为几种（转种中… / 转种成功 / 种子已存在，跳过 / 转种失败），
    /// 完整原因放 detail，交给悬浮提示与卡片下方说明行，卡片上不会被截断。
    public struct SiteStatus: Equatable {
        public enum Phase: Equatable {
            case working       // 进行中
            case done          // 本次真的发了新种 / 推送成功
            case exists        // 站内已有该种子（别人先发），跳过上传，只推送站内种子
            case failed        // 网络、站点校验等失败
        }
        public var siteID: String
        public var text: String
        public var phase: Phase
        public var detail: String

        public init(siteID: String, text: String, phase: Phase, detail: String = "") {
            self.siteID = siteID
            self.text = text
            self.phase = phase
            self.detail = detail
        }
    }
    public struct Options {
        public var skipReseed = false
        public var skipPush = false
        public var targets: [String]?    // nil = 用 config.targetSites
        /// 「批量转种」页的源站引用（可选）：非空时加在各目标站简介最上面并用引用包裹
        public var sourceQuote: String = ""
        /// 逐站转种结果事件（GUI 卡片状态用）
        public var onSiteEvent: ((SiteStatus) -> Void)?
        /// 目标站自己的 .torrent 推送事件（转种成功后逐站推送）
        public var onSitePush: ((SiteStatus) -> Void)?
        /// 源站种子推送到下载器的事件
        public var onSourcePush: ((SiteStatus) -> Void)?
        /// 单个目标站一次转种（查重 + 上传）的时长上限；站点或图床卡住时不拖垮整轮
        public var siteTimeout: TimeInterval = 300
        /// 转种成功但需要人工注意的提示（siteID / 提示文案），例如附加信息留空
        public var onSiteWarning: ((String, String) -> Void)?

        public init(skipReseed: Bool = false, skipPush: Bool = false, targets: [String]? = nil,
                    siteTimeout: TimeInterval = 300,
                    onSiteEvent: ((SiteStatus) -> Void)? = nil,
                    onSitePush: ((SiteStatus) -> Void)? = nil,
                    onSourcePush: ((SiteStatus) -> Void)? = nil,
                    onSiteWarning: ((String, String) -> Void)? = nil) {
            self.skipReseed = skipReseed
            self.skipPush = skipPush
            self.targets = targets
            self.siteTimeout = siteTimeout
            self.onSiteEvent = onSiteEvent
            self.onSitePush = onSitePush
            self.onSourcePush = onSourcePush
            self.onSiteWarning = onSiteWarning
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
        /// 转种成功但需要人工注意的提示（如附加信息留空）
        public var warnings: [(site: String, message: String)] = []

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
            for w in warnings {
                lines.append("  reseed \(w.site): 提示 \(w.message)")
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
        // 多进程（App/CLI）共用 state.json：运行前重新加载磁盘快照，避免旧内存状态覆盖另一进程的转种记录
        state.reload()
        // 1. 定位源站
        let site: SiteConfig
        if let id = sourceSiteID, let s = config.site(id) {
            site = s
        } else {
            guard let s = config.site(forURL: detailURL) else {
                throw BoxSendError.badInput("未找到源站配置: \(detailURL)（--site 指定，或先在「站点分组」添加该站）")
            }
            site = s
        }
        let debugDir = (config.dataDir as NSString).expandingTildeInPath
        let adapter = adapterFactory(site, client, debugDir)
        // TMDB 反查（设置里配置了才建）：目标站上传页有 TMDB 输入框、又没从源站带出链接时才发请求
        let tmdb = TMDBResolver.make(client: client, config: config.tmdb)

        // 2. 解析详情
        var release = try adapter.fetchDetail(detailURL: detailURL)
        // 源站详情没直接给出条目号时，从简介正文里找 Bangumi 链接（馒头动画发种要用）
        if release.bangumi.isEmpty, let id = Bangumi.subjectID(inHTML: release.descr) {
            release.bangumi = Bangumi.link(subjectID: id)
        }
        // 「批量转种」页勾选的源站引用：由各适配器按目标站简介格式包裹后置顶
        release.extraQuote = opts.sourceQuote.trimmingCharacters(in: .whitespacesAndNewlines)
        var report = Report(release: release, torrentBytes: 0, torrentData: Data(), outcomes: [], pushed: false, pushID: nil, upLimit: 0, pushes: [], sizeSkipped: false, sizeGuardWarning: nil, warnings: [])

        // 3. 下载 .torrent，用 bencode 校正大小；发布名保持源站详情页主标题
        //（.torrent 的 info.name 常带站方前缀/点分文件名，不宜作为目标站主标题）
        let (torrentData, filename) = try adapter.downloadTorrentFile(release)
        report.torrentBytes = torrentData.count
        report.torrentData = torrentData
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

        // 3.6 源站种子先推下载器：这样源站种子尽早开始做种，
        //     目标站则是转完一个立刻推那一站的种子（见第 4 步），不再等整组跑完
        let upLimit = config.effectiveUpLimit(siteID: release.siteID)
        report.upLimit = upLimit
        if !opts.skipPush {
            pushSourceTorrent(torrentData: torrentData, filename: filename, upLimit: upLimit,
                              release: release, opts: opts, report: &report)
        }

        // 4. 逐目标站转种：每站转完当场把该站自己的 .torrent 推给下载器，再进下一站
        let targets = opts.targets ?? config.targetSites
        if !opts.skipReseed {
            if release.isForbidReseed {
                state.note("forbid-reseed marker hit, skip reseed: \(release.summary)")
            } else {
                for tid in targets {
                    guard let ts = config.site(tid) else {
                        report.outcomes.append((tid, false, "未配置的站点 id"))
                        opts.onSiteEvent?(SiteStatus(siteID: tid, text: "转种失败", phase: .failed,
                                                     detail: "未配置的站点 id"))
                        continue
                    }
                    guard ts.enabled else {
                        report.outcomes.append((tid, false, "已禁用"))
                        continue
                    }
                    opts.onSiteEvent?(SiteStatus(siteID: tid, text: "转种中…", phase: .working))
                    if state.isUploaded(site: tid, key: release.dedupKey) {
                        report.outcomes.append((tid, true, "转种成功（此前已转种）"))
                        opts.onSiteEvent?(SiteStatus(siteID: tid, text: "转种成功", phase: .done,
                                                     detail: "此前已转种过，本次跳过上传"))
                        if let tu = state.targetURL(site: tid, key: release.dedupKey) {
                            pushTargetSite(siteID: tid, detailURL: absoluteTargetURL(tid, tu),
                                           seedPreexisting: false, debugDir: debugDir, opts: opts, report: &report)
                        }
                        continue
                    }
                    do {
                        let tAdapter = adapterFactory(ts, client, debugDir)
                        // 注入 TMDB 反查：适配器只在上传页真有 TMDB 输入框、且源站没带链接时才调用
                        tAdapter.setTMDBLookup { info in
                            guard let r = tmdb else { return nil }
                            let link = r.resolve(imdb: info.imdb, douban: info.douban,
                                                 name: info.name, altName: info.subtitle)
                            if link == nil, let why = r.lastError {
                                self.state.note("tmdb[\(tid)] 反查失败：\(why)")
                            } else if let link, let warn = r.lastWarning {
                                self.state.note("tmdb[\(tid)] 反查填写 \(link)：\(warn)")
                            }
                            return link
                        }
                        // 上传前先站内查重：显式配了 searchURL 的站，或 NexusPHP 这类有通用检索端点的站。
                        // 命中即跳过上传并把站内已有种子推给下载器；查重出错不阻断转种，查不到就照常上传
                        let canPrecheck = !(ts.overrides?.searchURL ?? "").isEmpty || tAdapter.canPrecheckDuplicate
                        let precheck = canPrecheck
                            ? (try? bounded(min(60, opts.siteTimeout / 3), "站内查重") {
                                try tAdapter.searchExists(release)
                            }) ?? nil
                            : nil
                        if let exists = precheck {
                            let uAbs = absoluteTargetURL(tid, exists)
                            report.outcomes.append((tid, true, "种子已存在，跳过：\(uAbs)"))
                            state.markUploaded(site: tid, key: release.dedupKey)
                            state.markTargetURL(site: tid, key: release.dedupKey, url: uAbs)
                            state.note("reseed EXIST \(tid): 站内已有该种子，跳过上传，已有种子 \(uAbs)")
                            opts.onSiteEvent?(SiteStatus(siteID: tid, text: "种子已存在，跳过", phase: .exists,
                                                         detail: "站内已有该种子（别人先发或此前已发）\n\(uAbs)"))
                            pushTargetSite(siteID: tid, detailURL: uAbs, seedPreexisting: true,
                                           debugDir: debugDir, opts: opts, report: &report)
                            continue
                        }
                        let outcome = try bounded(opts.siteTimeout, "单站转种") {
                            try tAdapter.upload(release, torrentData: torrentData, filename: filename)
                        }
                        if outcome.success {
                            state.markUploaded(site: tid, key: release.dedupKey)
                            if outcome.alreadyExists {
                                // 站点提示该种子已存在（同 hash / 同名种子已由别人发布）：不算本次转种成功
                                var existing = outcome.detailURL
                                if existing == nil {
                                    existing = try? tAdapter.searchExists(release, relaxed: true)
                                }
                                if let u = existing {
                                    let uAbs = absoluteTargetURL(tid, u)
                                    state.markTargetURL(site: tid, key: release.dedupKey, url: uAbs)
                                    state.note("reseed EXIST \(tid): 已存在（跳过上传），已有种子 \(u)")
                                    report.outcomes.append((tid, true, "种子已存在，跳过：\(uAbs)"))
                                    opts.onSiteEvent?(SiteStatus(siteID: tid, text: "种子已存在，跳过", phase: .exists,
                                                                 detail: "\(outcome.message)\n已有种子：\(uAbs)"))
                                    pushTargetSite(siteID: tid, detailURL: uAbs, seedPreexisting: true,
                                                   debugDir: debugDir, opts: opts, report: &report)
                                } else {
                                    state.note("reseed EXIST \(tid): 已存在（跳过上传），未找到已有种子链接，跳过目标站推送")
                                    report.outcomes.append((tid, true, "种子已存在，跳过（站内没检索到该种子链接）"))
                                    opts.onSiteEvent?(SiteStatus(siteID: tid, text: "种子已存在，跳过", phase: .exists,
                                                                 detail: "\(outcome.message)\n站内没检索到该种子链接，本次未推送"))
                                }
                            } else {
                                state.note("reseed OK \(tid) <- \(release.summary)")
                                report.outcomes.append((tid, true, "转种成功"))
                                opts.onSiteEvent?(SiteStatus(siteID: tid, text: "转种成功", phase: .done))
                                // cmct / 劳改所：附加信息 = 手填源站引用 + 源简介自带引用块，
                                // 两处都没有就提醒（不算失败）
                                if SiteRegistry.reseedSourceText(for: release).isEmpty,
                                   SiteRegistry.needsSourceQuoteField(ts) {
                                    let w = "未填「源站引用」且源简介无引用块：该站附加信息/其它信息（转种来源）留空"
                                    state.note("reseed WARN \(tid): \(w)")
                                    report.warnings.append((tid, w))
                                    opts.onSiteWarning?(tid, w)
                                }
                                if let u = outcome.detailURL {
                                    let uAbs = absoluteTargetURL(tid, u)
                                    state.markTargetURL(site: tid, key: release.dedupKey, url: uAbs)
                                    pushTargetSite(siteID: tid, detailURL: uAbs, seedPreexisting: false,
                                                   debugDir: debugDir, opts: opts, report: &report)
                                } else {
                                    // 站点回「发布成功」却没给新种子链接（实测海胆）：回站内检索一次把链接
                                    // 找回来照常推送；实在找不到要明确提醒，静默跳过会被看成已经在做种
                                    let recovered: String? = canPrecheck
                                        ? (try? bounded(min(60, opts.siteTimeout / 3), "站内回查") {
                                            try tAdapter.searchExists(release, relaxed: true)
                                        }) ?? nil
                                        : nil
                                    if let u = recovered {
                                        let uAbs = absoluteTargetURL(tid, u)
                                        state.markTargetURL(site: tid, key: release.dedupKey, url: uAbs)
                                        state.note("reseed \(tid): 站点未回新种子链接，站内回查命中 \(uAbs)")
                                        report.outcomes.append((tid, true, "转种成功（站内回查补到种子链接）"))
                                        opts.onSiteEvent?(SiteStatus(siteID: tid, text: "转种成功", phase: .done,
                                                                     detail: "站点没回新种子链接，站内回查补到：\(uAbs)"))
                                        pushTargetSite(siteID: tid, detailURL: uAbs, seedPreexisting: false,
                                                       debugDir: debugDir, opts: opts, report: &report)
                                    } else {
                                        let w = "发布成功，但站点没回新种子链接、站内回查也没找到：本次未推送下载器，请到站内手动推送"
                                        state.note("reseed \(tid): \(w)")
                                        report.warnings.append((tid, w))
                                        opts.onSiteWarning?(tid, w)
                                    }
                                }
                            }
                        } else {
                            state.note("reseed FAIL \(tid) <- \(release.summary): \(outcome.message)")
                            var msg = outcome.message
                            // 杜比的「你必须填写TMDB链接」：顺带指个路，免得用户不知道去哪配
                            if msg.localizedCaseInsensitiveContains("tmdb"), tmdb == nil {
                                msg += "（未配置 TMDB 反查：设置 → TMDB 链接 → API 网关/API Key）"
                            }
                            report.outcomes.append((tid, false, msg))
                            opts.onSiteEvent?(SiteStatus(siteID: tid, text: "转种失败", phase: .failed,
                                                         detail: msg))
                        }
                    } catch {
                        report.outcomes.append((tid, false, error.localizedDescription))
                        opts.onSiteEvent?(SiteStatus(siteID: tid, text: "转种失败", phase: .failed,
                                                     detail: error.localizedDescription))
                    }
                }
            }
        } else {
            // skipReseed：把此前记录过的目标站种子逐站推一遍
            for tid in targets {
                if let tu = state.targetURL(site: tid, key: release.dedupKey) {
                    pushTargetSite(siteID: tid, detailURL: absoluteTargetURL(tid, tu),
                                   seedPreexisting: true, debugDir: debugDir, opts: opts, report: &report)
                }
            }
        }

        let failedSites = report.outcomes.filter { !$0.ok }.map { $0.site }
        if !failedSites.isEmpty {
            state.note("push：\(failedSites.count) 个目标站转种失败（\(failedSites.joined(separator: "、"))），"
                + "不影响已成功的站点推送")
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
