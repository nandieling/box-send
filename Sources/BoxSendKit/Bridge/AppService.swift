import Foundation

/// 无头应用服务：把「配置 + cookie + 同步 + 转种流水线」这套应用级动作收在核心库里，
/// 用 JSON 契约对外暴露，供 Windows 界面（以及 web 控制台）调用。
///
/// 契约只有一个入口：`invoke(method, params)` 同步返回 `{ok, result}` 或 `{ok:false, error}`。
/// 耗时动作（同步、批量检测、转种）立刻返回并跑在后台队列，界面靠 `snapshot` + `events`
/// 轮询取进度——不跨边界回调，少一类线程编组 bug。
///
/// 线程模型：内部一把锁只保护状态读写，网络 I/O 期间不持锁。
public final class AppService {

    public struct Failure: Error, CustomStringConvertible, CustomNSError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
        public var errorDescription: String? { message }
    }

    /// 推给界面的一条事件（日志、逐站状态、阶段提示）
    public struct Event {
        public var seq: Int
        public var kind: String        // note | site | phase | run | error
        public var siteID: String?
        public var text: String
        public var detail: String
        public var phase: String?
        public var ok: Bool?
        public var time: Double
    }

    public let configPath: String
    public let dataDir: String

    /// 可重入：写日志时 state.note 会回调回来，同一条调用链上可能二次加锁
    private let lock = NSRecursiveLock()
    private var cfg: AppConfig
    private var configError: String?
    private var eventSeq = 0
    private var eventLog: [Event] = []
    private var checkResults: [String: StateStore.CookieCheckRec] = [:]
    private var busyCookieSync = false
    private var busyCookieCheck = false
    private var busyDownloader = false
    private var busyZip = false
    private var busyUpdate = false
    private var checkGeneration = 0
    private var running = false
    private var runningStep = ""
    private var lastReport = ""
    private var siteEvents: [String: Event] = [:]      // 逐站最新状态（转种页）
    private var pushEvents: [String: Event] = [:]
    private var sourcePushEvent: Event?
    private var siteWarnings: [String: String] = [:]
    private var cookieMessage: String?
    private var downloaderMessage: String?
    private var zipMessage: String?
    private var updateMessage: String?
    private var updateRelease: SoftwareUpdate.Release?
    private var logs: [String]

    public let state: StateStore
    public let cookies = CookieStore()
    private let queue = DispatchQueue(label: "boxsend.service", attributes: .concurrent)

    // MARK: 生命周期

    /// - Parameters:
    ///   - configPath: 配置文件路径；不存在时用内置站点模板新建
    ///   - dataDir: 运行时数据目录（cookies.json / state.json / debug/），默认取配置的 dataDir
    public init(configPath: String = AppPaths.configFile, dataDir: String? = nil) throws {
        self.configPath = configPath
        var loaded = AppConfig.load(path: configPath)
        if loaded == nil {
            loaded = AppConfig.template()
        }
        var c = loaded ?? AppConfig.template()
        let dir = Platform.expandPath(dataDir ?? c.dataDir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        c.dataDir = dir
        self.dataDir = dir
        self.cfg = c
        self.state = StateStore(dataDir: dir)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("cookies.json")) {
            _ = try? cookies.replace(from: data)
        }
        self.logs = state.recentNotes
        self.state.onNote = { [weak self] line in
            guard let self else { return }
            self.lock.lock()
            self.logs.append(line)
            if self.logs.count > 400 { self.logs.removeFirst(self.logs.count - 400) }
            self.lock.unlock()
        }
        lock.lock()
        for s in c.sourceSites {
            if let rec = state.cookieCheck(s.id) { checkResults[s.id] = rec }
        }
        lock.unlock()
        save()
    }

    // MARK: 入口

    /// 调用一个动作。params 为界面传来的 JSON 对象（缺失字段用默认值）。
    @discardableResult
    public func invoke(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        switch method {
        case "version":
            return ["version": BoxSendVersion.version, "platform": Platform.osName,
                    "configPath": configPath, "dataDir": dataDir,
                    "themes": ThemeCatalog.allJSON]
        case "snapshot":
            return snapshot()
        case "events":
            return ["events": events(since: int(params["since"]) ?? 0)]
        case "logs.clear":
            mutate { self.logs = [] }
            return [:]

        case "config.get":
            return ["config": try json(cfg)]
        case "config.set":
            guard let obj = params["config"] else { throw Failure("缺少 config") }
            let newCfg = try decodeConfig(obj)
            mutate { self.cfg = newCfg; self.cfg.dataDir = self.dataDir }
            save()
            return ["config": try json(cfg)]
        case "config.patch":
            // 只覆盖给出的顶层字段，其余保持原值（界面按区块保存，避免整份覆盖丢字段）
            guard let obj = params["patch"] as? [String: Any] else { throw Failure("缺少 patch") }
            let merged = try patchConfig(obj)
            mutate { self.cfg = merged }
            save()
            return ["config": try json(cfg)]

        case "appearance.set":
            mutate {
                if let t = params["themeID"] as? String { cfg.appearance.themeID = t }
                if let o = params["bgOpacity"] as? Double { cfg.appearance.bgOpacity = min(1, max(0, o)) }
                if params.keys.contains("bgImage") {
                    cfg.appearance.bgImage = params["bgImage"] as? String
                }
            }
            save()
            return [:]

        case "groups.add":
            let name = params["name"] as? String ?? ""
            let mb = int(params["upLimitMB"]) ?? 0
            mutate { cfg.addGroup(name: name, upLimitMB: mb) }
            save()
            return groupsAndSites()
        case "groups.rename":
            guard let i = int(params["index"]) else { throw Failure("缺少 index") }
            mutate { cfg.renameGroup(at: i, name: params["name"] as? String ?? "") }
            save()
            return groupsAndSites()
        case "groups.remove":
            guard let i = int(params["index"]) else { throw Failure("缺少 index") }
            mutate { self.cfg.removeGroup(at: i, unselect: { _ in }) }
            save()
            return groupsAndSites()
        case "groups.move":
            mutate { cfg.moveGroup(named: params["dragged"] as? String ?? "",
                                   before: params["before"] as? String ?? "") }
            save()
            return groupsAndSites()
        case "groups.setLimit":
            guard let i = int(params["index"]) else { throw Failure("缺少 index") }
            mutate { cfg.setGroupUpLimit(at: i, mb: int(params["upLimitMB"]) ?? 0) }
            save()
            return groupsAndSites()
        case "groups.sortSites":
            let gi = int(params["group"]) ?? -1
            let nums = (params["order"] as? [String: Any])?.compactMapValues { int($0) } ?? [:]
            mutate { cfg.sortGroupSites(gi, by: nums) }
            save()
            return groupsAndSites()

        case "sites.add":
            let ids = (params["ids"] as? [String]) ?? []
            let gi = int(params["group"]) ?? -1
            mutate { cfg.addManagedSites(ids, group: gi) }
            if let nums = params["order"] as? [String: Any], gi >= 0 {
                mutate { cfg.sortGroupSites(gi, by: nums.compactMapValues { int($0) }) }
            }
            save()
            return groupsAndSites()
        case "sites.remove":
            let ids = (params["ids"] as? [String]) ?? []
            mutate { for id in ids { self.cfg.removeManagedSite(id, unselect: { _ in }) } }
            save()
            return groupsAndSites()
        case "sites.setEnabled":
            let ids = (params["ids"] as? [String]) ?? []
            let on = params["enabled"] as? Bool ?? true
            mutate { for id in ids { cfg.setSiteEnabled(id, on) } }
            save()
            return groupsAndSites()
        case "sites.move":
            mutate { cfg.moveManagedSite(params["id"] as? String ?? "",
                                         delta: int(params["delta"]) ?? 0) }
            save()
            return groupsAndSites()
        case "sites.moveBefore":
            mutate { cfg.moveSite(params["id"] as? String ?? "",
                                  before: params["before"] as? String ?? "") }
            save()
            return groupsAndSites()
        case "sites.setGroup":
            guard let i = int(params["index"]) else { throw Failure("缺少 index") }
            mutate { cfg.setGroup(index: i, for: params["id"] as? String ?? "") }
            save()
            return groupsAndSites()
        case "sites.setApiKey":
            let id = params["id"] as? String ?? ""
            let raw = (params["apiKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            mutate {
                guard let i = cfg.sourceSites.firstIndex(where: { $0.id == id }) else { return }
                cfg.sourceSites[i].apiKey = raw.isEmpty ? nil : raw
                if !raw.isEmpty { cfg.sourceSites[i].enabled = true }
                self.note("api: 单站 \(id) key 已更新")
            }
            save()
            if !raw.isEmpty { checkCookiesAsync([id], force: true) }
            return groupsAndSites()
        case "sites.setUpLimit":
            let id = params["id"] as? String ?? ""
            mutate { cfg.setSiteUpLimitMB(int(params["upLimitMB"]), siteID: id) }
            save()
            return groupsAndSites()

        case "targets.set":
            let ids = (params["ids"] as? [String]) ?? []
            mutate { cfg.applyTargetSites(ids) }
            save()
            return groupsAndSites()
        case "sourceQuote.set":
            mutate {
                cfg.sourceQuoteEnabled = params["enabled"] as? Bool ?? false
                cfg.sourceQuoteText = params["text"] as? String ?? ""
            }
            save()
            return [:]

        case "cookies.getRaw":
            let id = params["id"] as? String ?? ""
            return ["raw": existingCookieHeader(forID: id)]
        case "cookies.setRaw":
            let id = params["id"] as? String ?? ""
            let raw = params["raw"] as? String ?? ""
            return try setSiteCookie(siteID: id, raw: raw)
        case "cookies.remove":
            let id = params["id"] as? String ?? ""
            var removed = false
            mutate {
                guard let site = cfg.site(id) else { return }
                removed = cookies.removeHost(Self.host(of: site))
                self.note("cookie: 移除 \(site.id) 本地 cookie")
            }
            persistCookies()
            return ["removed": removed]
        case "cookies.clear":
            mutate { cookies.clear(); self.note("cookie: 清空本地 cookie") }
            persistCookies()
            return [:]
        case "cookies.trim":
            var removed = 0
            mutate {
                let hosts = Set(cfg.sourceSites.filter(\.enabled).map { Self.host(of: $0) })
                for host in cookies.hosts() where !hosts.contains(host) {
                    _ = cookies.removeHost(host)
                    removed += 1
                }
            }
            persistCookies()
            return ["removed": removed]
        case "cookies.sync":
            return try syncCookies(source: params["source"] as? String ?? "both")
        case "cookies.check":
            let ids = (params["ids"] as? [String]) ?? []
            let force = params["force"] as? Bool ?? true
            return checkCookiesAsync(ids, force: force)
        case "cookies.stopCheck":
            mutate { checkGeneration += 1 }
            return [:]
        case "cookies.importZip":
            guard let p = params["path"] as? String, !p.isEmpty else { throw Failure("缺少 path") }
            return try importZip(path: p, password: params["password"] as? String ?? "")

        case "zip.scan":
            return try scanZip()

        case "downloader.test":
            return try testDownloader()

        case "zip.set":
            mutate {
                var z = cfg.zipWatch ?? ZipWatchConfig()
                if let d = params["dir"] as? String { z.dir = d }
                if let pw = params["password"] as? String { z.password = pw }
                if let m = int(params["pollMinutes"]) { z.pollMinutes = max(1, m) }
                if let e = params["enabled"] as? Bool { z.enabled = e }
                cfg.zipWatch = z
            }
            save()
            return ["zipWatch": try json(cfg.zipWatch as Any)]

        case "run.start":
            return try startRun(params)
        case "run.status":
            return runState()

        case "tmdb.test":
            return try testTMDB()
        case "update.check":
            return try checkUpdate()
        default:
            throw Failure("未知方法: \(method)")
        }
    }

    /// 给 C ABI / HTTP 边界用的字符串版入口：输入 `{method, params}`，返回 `{ok, result|error}`
    public func invokeJSON(_ requestJSON: String) -> String {
        var method = ""
        var params: [String: Any] = [:]
        if let data = requestJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            method = obj["method"] as? String ?? ""
            params = obj["params"] as? [String: Any] ?? [:]
        }
        do {
            let result = try invoke(method, params)
            return Self.encode(["ok": true, "result": result])
        } catch let f as Failure {
            return Self.encode(["ok": false, "error": f.message])
        } catch {
            return Self.encode(["ok": false, "error": error.localizedDescription])
        }
    }

    // MARK: 快照

    public func snapshot() -> [String: Any] {
        lock.lock()
        let c = cfg
        let snap = cookies.snapshot()
        let checks = checkResults
        let busy = [
            "cookieSync": busyCookieSync, "cookieCheck": busyCookieCheck,
            "downloaderTest": busyDownloader, "zipScan": busyZip, "update": busyUpdate,
        ]
        let run = runStateLocked()
        let messages: [String: Any] = [
            "cookie": cookieMessage ?? "",
            "downloader": downloaderMessage ?? "",
            "zip": zipMessage ?? "",
            "update": updateMessage ?? "",
            "config": configError ?? "",
            "lastGistSync": state.lastGistSync.map(Self.dateText) ?? "从未同步",
        ]
        let warnings = siteWarnings
        let logLines = logs
        let update = updateRelease
        lock.unlock()

        var updateDict: [String: Any] = [:]
        if let u = update {
            updateDict = ["version": u.version, "title": u.title, "url": u.url,
                          "downloadURL": u.downloadURL ?? "",
                          "hasUpdate": SoftwareUpdate.isNewer(u.version, than: BoxSendVersion.version)]
        }
        var cookieList: [[String: Any]] = []
        for host in snap.keys.sorted() {
            cookieList.append(["host": host, "count": snap[host]?.count ?? 0])
        }
        return [
            "platform": Platform.osName,
            "version": BoxSendVersion.version,
            "configPath": configPath,
            "dataDir": dataDir,
            "config": (try? json(c)) ?? [:],
            "cookies": ["hosts": cookieList, "total": snap.values.reduce(0) { $0 + $1.count }],
            "sites": siteStatesLocked(c, snap: snap, checks: checks),
            "groups": groupsLocked(c),
            "run": run,
            "busy": busy,
            "messages": messages,
            "warnings": warnings,
            "update": updateDict,
            "logs": logLines,
        ]
    }

    public func events(since: Int, limit: Int = 200) -> [[String: Any]] {
        lock.lock()
        let picked = eventLog.filter { $0.seq > since }.suffix(limit)
        lock.unlock()
        return picked.map(Self.eventJSON)
    }

    // MARK: 转种

    private func startRun(_ params: [String: Any]) throws -> [String: Any] {
        guard let detailURL = params["detailURL"] as? String, !detailURL.isEmpty else {
            throw Failure("请先填写源站种子链接")
        }
        var snapshotForRun: AppConfig!
        lock.lock()
        if running {
            lock.unlock()
            throw Failure("正在运行，请等当前任务结束")
        }
        running = true
        runningStep = "准备中"
        lastReport = ""
        siteEvents = [:]
        pushEvents = [:]
        sourcePushEvent = nil
        siteWarnings = [:]
        snapshotForRun = cfg
        lock.unlock()

        let cfg = snapshotForRun!
        let jar = CookieStore()
        if let data = cookies.exportBackupJSON() { _ = try? jar.replace(from: data) }
        let client = HTTPClient(cookies: jar, userAgent: cfg.userAgent)
        let downloader = DownloaderFactory.make(cfg, client: client)
        let pipeline = ReseedPipeline(config: cfg, cookies: jar, state: state, downloader: downloader)

        var opts = ReseedPipeline.Options()
        opts.skipReseed = params["skipReseed"] as? Bool ?? false
        opts.skipPush = params["skipPush"] as? Bool ?? false
        opts.targets = (params["targets"] as? [String])?.isEmpty == false ? (params["targets"] as? [String]) : nil
        opts.sourceQuote = params["sourceQuote"] as? String ?? ""
        opts.onSiteEvent = { [weak self] e in self?.recordSite(e, push: false) }
        opts.onSitePush = { [weak self] e in self?.recordSite(e, push: true) }
        opts.onSourcePush = { [weak self] e in
            guard let self else { return }
            let ev = self.makeEvent(e, kind: "push")
            self.mutate { self.sourcePushEvent = ev }
            self.emit("push", e.siteID, e.text, e.detail, phase: Self.phaseName(e.phase), ok: nil)
        }
        opts.onSiteWarning = { [weak self] siteID, text in
            self?.lock.lock()
            self?.siteWarnings[siteID] = text
            self?.lock.unlock()
            self?.emit("note", nil, "警告 \(siteID): \(text)", "", phase: nil, ok: nil)
        }

        let sourceSiteID = params["sourceSiteID"] as? String
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let report = try pipeline.run(detailURL: detailURL, sourceSiteID: sourceSiteID, opts: opts)
                self.mutate {
                    self.running = false
                    self.runningStep = "完成"
                    self.lastReport = report.description
                }
                self.persistCookies()
                self.emit("run", nil, "完成：\(report.description)", "", phase: nil, ok: true)
            } catch {
                self.mutate {
                    self.running = false
                    self.runningStep = "失败"
                    self.lastReport = error.localizedDescription
                }
                self.emit("error", nil, "转种失败: \(error.localizedDescription)", "", phase: nil, ok: false)
            }
        }
        return runState()
    }

    private func recordSite(_ e: ReseedPipeline.SiteStatus, push: Bool) {
        let kind = push ? "push" : "site"
        let ev = makeEvent(e, kind: kind)
        mutate {
            if push { self.pushEvents[e.siteID] = ev } else { self.siteEvents[e.siteID] = ev }
        }
        emit(kind, e.siteID, e.text, e.detail, phase: Self.phaseName(e.phase), ok: nil)
    }

    private func makeEvent(_ e: ReseedPipeline.SiteStatus, kind: String) -> Event {
        Event(seq: nextSeq(), kind: kind, siteID: e.siteID, text: e.text,
              detail: e.detail, phase: Self.phaseName(e.phase), ok: nil,
              time: Date().timeIntervalSince1970)
    }

    /// 逐站阶段名（界面据此配图标/颜色）
    static func phaseName(_ p: ReseedPipeline.SiteStatus.Phase) -> String {
        switch p {
        case .working: return "working"
        case .done: return "done"
        case .exists: return "exists"
        case .failed: return "failed"
        }
    }

    private func runState() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return runStateLocked()
    }

    private func runStateLocked() -> [String: Any] {
        var out: [String: Any] = [
            "running": running, "step": runningStep, "lastReport": lastReport,
            "sites": Array(siteEvents.values).sorted { $0.seq < $1.seq }.map(Self.eventJSON),
            "pushes": Array(pushEvents.values).sorted { $0.seq < $1.seq }.map(Self.eventJSON),
        ]
        if let s = sourcePushEvent { out["sourcePush"] = Self.eventJSON(s) }
        return out
    }

    // MARK: cookie 同步

    /// 拉取 Gist / CookieCloud 备份。本地已检测有效的 cookie 不被备份覆盖（同步不新增失效）。
    private func syncCookies(source: String) throws -> [String: Any] {
        var c: AppConfig!
        lock.lock()
        if busyCookieSync {
            lock.unlock()
            throw Failure("同步正在进行中")
        }
        busyCookieSync = true
        c = cfg
        lock.unlock()

        defer { mutate { self.busyCookieSync = false } }
        let client = HTTPClient(cookies: cookies, userAgent: c.userAgent)

        var rawsBySource: [(label: String, raws: [String: String])] = []
        var errors: [String] = []
        if source == "gist" || source == "both" {
            if let g = c.gistSync, !g.gistID.isEmpty, !g.token.isEmpty {
                do {
                    let fetched = try GistSync(config: g, client: client).fetch()
                    let map = (try? JSONSerialization.jsonObject(with: fetched.data)) as? [String: Any] ?? [:]
                    rawsBySource.append(("Gist", CookieRawMerge.rawStrings(map: map)))
                    state.setLastGistSync(Date().timeIntervalSince1970)
                } catch {
                    errors.append("Gist: \(error.localizedDescription)")
                }
            } else {
                errors.append("Gist: 未配置 gistID/token")
            }
        }
        if source == "cookieCloud" || source == "both" {
            if let cc = c.cookieCloud, !cc.host.isEmpty, !cc.key.isEmpty {
                do {
                    rawsBySource.append(("CookieCloud", try CookieCloudSync(config: cc, client: client).fetch()))
                } catch {
                    errors.append("CookieCloud: \(error.localizedDescription)")
                }
            } else {
                errors.append("CookieCloud: 未配置服务器/KEY")
            }
        }

        var imported = 0
        var kept = 0
        var skipped = 0
        lock.lock()
        let sites = cfg.managedSites.isEmpty ? cfg.sourceSites : cfg.managedSites
        for (label, raws) in rawsBySource {
            for (host, raw) in raws where !raw.isEmpty {
                guard let site = matchSite(host, in: sites) else { skipped += 1; continue }
                let h = Self.host(of: site)
                if checkResults[site.id]?.ok == true {
                    kept += 1
                    continue                      // 本地这份是有效的，不被备份覆盖
                }
                if cookies.mergeRawString(host: h, raw) {
                    imported += 1
                } else {
                    kept += 1
                }
            }
            note("cookie: \(label) 备份已拉取")
        }
        cookieMessage = "同步完成：导入 \(imported) 个站，保留 \(kept) 个"
            + (errors.isEmpty ? "" : "；\(errors.joined(separator: "；"))")
        lock.unlock()
        persistCookies()
        emit("note", nil, cookieMessage ?? "", "", phase: nil, ok: errors.isEmpty)
        // 同步完立刻逐站复检（mac 版同一步）：界面上要看到新导入的 cookie 到底能不能用
        var recheck: [String] = []
        lock.lock()
        recheck = (cfg.managedSites.isEmpty ? cfg.sourceSites : cfg.managedSites).map { $0.id }
        lock.unlock()
        _ = checkCookiesAsync(recheck, force: true)
        return ["imported": imported, "kept": kept, "skipped": skipped, "errors": errors]
    }

    /// 备份里的 host 与配置里的站点匹配（去 www、大小写不敏感）
    private func matchSite(_ host: String, in sites: [SiteConfig]) -> SiteConfig? {
        let want = CookieRawMerge.norm(host)
        return sites.first { CookieRawMerge.norm(Self.host(of: $0)) == want }
    }

    private func setSiteCookie(siteID: String, raw: String) throws -> [String: Any] {
        guard let site = cfg.site(siteID) else { throw Failure("未配置的站点 id: \(siteID)") }
        let h = Self.host(of: site)
        var message = ""
        mutate {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                _ = cookies.removeHost(h)
                message = "已清空 \(site.name) 的 cookie"
            } else {
                cookies.importRawString(host: h, raw)
                message = "已保存 \(site.name) 的 cookie"
            }
            self.cookieMessage = message
            self.note("cookie: 手动写入 \(site.id)")
        }
        persistCookies()
        checkCookiesAsync([siteID], force: true)
        return ["message": message]
    }

    private func importZip(path: String, password: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: Platform.expandPath(path))
        var imported = 0
        var message = ""
        do {
            imported = try PTDZipImport.importZip(url: url, password: password, into: cookies)
            message = "导入 \(imported) 条 cookie"
        } catch {
            message = error.localizedDescription
        }
        mutate {
            self.cookieMessage = message
            self.note("zip: \(url.lastPathComponent) -> \(message)")
        }
        persistCookies()
        return ["imported": imported, "message": message]
    }

    /// 扫描备份目录里新增的 PT-depiler 备份并导入。后台跑，结果走 messages.zip 与 events。
    /// force = true 时忽略「未启用监控」直接扫（界面上的手动扫描按钮）。
    private func scanZip(force: Bool = false) throws -> [String: Any] {
        var dir = ""
        var pw = ""
        lock.lock()
        if busyZip {
            lock.unlock()
            throw Failure("扫描正在进行中")
        }
        guard force || (cfg.zipWatch?.enabled ?? false) else {
            zipMessage = "先在 Cookie 页启用备份目录监控并填写目录"
            let m = zipMessage!
            lock.unlock()
            throw Failure(m)
        }
        dir = cfg.zipWatch?.dir ?? "~/Downloads"
        pw = cfg.zipWatch?.password ?? ""
        busyZip = true
        zipMessage = "扫描备份目录…"
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let names = ZipWatcher.scanOnce(dir: dir, password: pw, store: self.cookies, state: self.state)
            var message = ""
            self.mutate {
                let hosts = Set(self.cfg.sourceSites.filter(\.enabled).map { Self.host(of: $0) })
                var removed = 0
                for host in self.cookies.hosts() where !hosts.contains(host) {
                    _ = self.cookies.removeHost(host)
                    removed += 1
                }
                let base = names.isEmpty ? "扫描完成：无新备份" : "扫描完成：已导入 \(names.joined(separator: ", "))"
                message = base + (removed > 0 ? "；已清理 \(removed) 个未启用站点的 cookie" : "")
                self.zipMessage = message
                self.persistCookies()
                self.busyZip = false
            }
            self.emit("note", nil, message, "", phase: nil, ok: true)
        }
        return ["started": true]
    }

    // MARK: cookie 检测

    /// 逐站检测（后台跑，结果走 events/snapshot）。ids 为空 = 检测全部已启用站点。
    private func checkCookiesAsync(_ ids: [String], force: Bool) -> [String: Any] {
        var targets: [SiteConfig] = []
        var generation = 0
        lock.lock()
        if busyCookieCheck {
            lock.unlock()
            return ["started": false, "reason": "检测正在进行中"]
        }
        busyCookieCheck = true
        generation = checkGeneration
        let c = cfg
        let all = ids.isEmpty ? c.sourceSites.filter { $0.enabled } : ids.compactMap { c.site($0) }
        // 按分组顺序检测（界面上先看到的先检）
        targets = all.sortedBySiteGroup(groups: c.groups) { $0.id }.filter { site in
            force || checkResults[site.id] == nil
        }
        lock.unlock()

        if targets.isEmpty {
            mutate { self.busyCookieCheck = false }
            return ["started": true, "checked": 0]
        }
        queue.async { [weak self] in
            guard let self else { return }
            let c = self.cfg
            let client = HTTPClient(cookies: self.cookies, userAgent: c.userAgent)
            client.setRequestTimeout(20)
            var done = 0
            for site in targets {
                let stale = self.lock.withLock { self.checkGeneration != generation }
                if stale { break }
                if !self.hasCredential(site) {
                    self.recordCheck(site.id, ok: false, "本地无 cookie")
                    done += 1
                    self.emit("site", site.id, "\(site.name): 本地无 cookie", "", phase: "check", ok: false)
                    continue
                }
                let r = CookieCheck.check(site: site, client: client)
                self.recordCheck(r.siteID, ok: r.ok, r.message)
                done += 1
                self.emit("site", r.siteID, "\(site.name): \(r.message)", "", phase: "check", ok: r.ok)
            }
            self.mutate { self.busyCookieCheck = false }
            self.emit("note", nil, "cookie 检测完成：\(done) 个站", "", phase: nil, ok: true)
        }
        return ["started": true, "checked": targets.count]
    }

    private func recordCheck(_ siteID: String, ok: Bool, _ message: String) {
        state.setCookieCheck(siteID: siteID, ok: ok, message: message)
        lock.lock()
        checkResults[siteID] = StateStore.CookieCheckRec(ok: ok, message: message, time: Date().timeIntervalSince1970)
        lock.unlock()
    }

    private func hasCredential(_ site: SiteConfig) -> Bool {
        if Self.usesAPIKey(site) {
            return !(site.apiKey ?? "").isEmpty
        }
        return cookies.cookieHeader(forHost: Self.host(of: site)) != nil
    }

    private func existingCookieHeader(forID siteID: String) -> String {
        guard let site = cfg.site(siteID) else { return "" }
        return cookies.cookieHeader(forHost: Self.host(of: site)) ?? ""
    }

    // MARK: 下载器 / TMDB / 更新

    private func testDownloader() throws -> [String: Any] {
        let c = cfg
        lock.lock()
        if busyDownloader {
            lock.unlock()
            throw Failure("测试正在进行中")
        }
        busyDownloader = true
        lock.unlock()
        defer { mutate { self.busyDownloader = false } }

        let client = HTTPClient(cookies: cookies, userAgent: c.userAgent)
        do {
            let info = try DownloaderFactory.make(c, client: client).testConnection()
            mutate { self.downloaderMessage = "连接成功：\(info)" }
            emit("note", nil, "下载器连接成功", info, phase: nil, ok: true)
            return ["ok": true, "message": "连接成功：\(info)"]
        } catch {
            let why = "连接失败：\(error.localizedDescription)"
            mutate { self.downloaderMessage = why }
            emit("error", nil, "下载器\(why)", "", phase: nil, ok: false)
            return ["ok": false, "message": why]
        }
    }

    /// 拿一条站内已知条目试查（银魂剧场版 tt2374144 / 豆瓣 11615927），验证网关与 key 通不通
    private func testTMDB() throws -> [String: Any] {
        guard var t = cfg.tmdb else { throw Failure("未配置 TMDB") }
        t.enabled = true
        let client = HTTPClient(cookies: cookies, userAgent: cfg.userAgent)
        guard let r = TMDBResolver.make(client: client, config: t) else {
            throw Failure("未填写 TMDB key")
        }
        if let link = r.resolve(imdb: "tt2374144", douban: "11615927",
                                name: "Gekijouban Gintama Kanketsu-hen 2013 1080p Blu-ray") {
            return ["ok": true, "link": link]
        }
        return ["ok": false, "error": r.lastError ?? "TMDB 没有匹配条目"]
    }

    private func checkUpdate() throws -> [String: Any] {
        let c = cfg
        mutate { self.busyUpdate = true; self.updateMessage = "检查中…" }
        defer { mutate { self.busyUpdate = false } }
        let client = HTTPClient(cookies: cookies, userAgent: c.userAgent)
        switch SoftwareUpdate.latest(client: client) {
        case .found(let rel):
            mutate {
                self.updateRelease = rel
                self.updateMessage = SoftwareUpdate.isNewer(rel.version, than: BoxSendVersion.version)
                    ? "发现新版本 \(rel.version)" : "已是最新版本 \(BoxSendVersion.version)"
            }
            return ["found": true, "version": rel.version, "url": rel.url,
                    "downloadURL": rel.downloadURL ?? "",
                    "hasUpdate": SoftwareUpdate.isNewer(rel.version, than: BoxSendVersion.version)]
        case .failed(let why):
            mutate { self.updateMessage = why }
            return ["found": false, "error": why]
        }
    }

    // MARK: 内部

    /// 该站走 API Key 还是走 cookie（合并内置 override 后判断，与 mac 版同规则）
    static func usesAPIKey(_ site: SiteConfig) -> Bool {
        let es = SiteRegistry.effectiveSite(site)
        return (es.overrides?.apiBase ?? "") != "" || (es.overrides?.usesAPIKey == true)
    }

    private static func host(of site: SiteConfig) -> String {
        (URL(string: site.url)?.host ?? site.url).lowercased()
    }

    private func mutate(_ body: () -> Void) {
        lock.lock()
        body()
        lock.unlock()
    }

    private func note(_ s: String) {
        state.note(s)
    }

    private func emit(_ kind: String, _ siteID: String?, _ text: String, _ detail: String,
                      phase: String?, ok: Bool?) {
        lock.lock()
        eventSeq += 1
        eventLog.append(Event(seq: eventSeq, kind: kind, siteID: siteID, text: text,
                              detail: detail, phase: phase, ok: ok,
                              time: Date().timeIntervalSince1970))
        if eventLog.count > 500 { eventLog.removeFirst(eventLog.count - 500) }
        lock.unlock()
    }

    private func nextSeq() -> Int {
        lock.lock()
        defer { lock.unlock() }
        eventSeq += 1
        return eventSeq
    }

    private func persistCookies() {
        guard let data = cookies.exportBackupJSON() else { return }
        try? data.write(to: URL(fileURLWithPath: dataDir).appendingPathComponent("cookies.json"),
                        options: .atomic)
    }

    /// 界面保存配置成功后清掉上一次的读取错误
    private func save() {
        do {
            let data = try JSONEncoder().encode(cfg)
            try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
            mutate { self.configError = nil }
        } catch {
            mutate { self.configError = "配置保存失败: \(error.localizedDescription)" }
        }
    }

    private func json(_ value: Any) throws -> [String: Any] {
        let data: Data
        if let enc = value as? Encodable {
            data = try JSONEncoder().encode(AnyEncodable(enc))
        } else if let any = value as? Any {
            data = try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        } else {
            throw Failure("无法序列化的值")
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func decodeConfig(_ obj: Any) throws -> AppConfig {
        let data = try JSONSerialization.data(withJSONObject: obj)
        guard let c = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            throw Failure("配置 JSON 解析失败")
        }
        return c
    }

    /// 用给出的字段覆盖现有配置（其余字段保持原值）。小节只合并一层：
    /// `{"zipWatch":{"enabled":true}}` 不会把同节其他字段抹掉，界面区块就能只提交改过的那几项。
    private func patchConfig(_ patch: [String: Any]) throws -> AppConfig {
        var base = try json(cfg)
        for (k, v) in patch {
            if let section = v as? [String: Any], let existing = base[k] as? [String: Any] {
                var merged = existing
                for (fk, fv) in section { merged[fk] = fv }
                base[k] = merged
            } else {
                base[k] = v
            }
        }
        base["dataDir"] = dataDir
        return try decodeConfig(base)
    }

    private func groupsAndSites() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return ["groups": groupsLocked(cfg), "sites": siteStatesLocked(cfg,
                                                                       snap: cookies.snapshot(),
                                                                       checks: checkResults)]
    }

    private func groupsLocked(_ c: AppConfig) -> [[String: Any]] {
        c.groups.enumerated().map { (i, g) in
            ["index": i, "name": g.name, "sites": g.sites, "upLimitMB": g.upLimitMB]
        }
    }

    private func siteStatesLocked(_ c: AppConfig, snap: [String: [Cookie]],
                                  checks: [String: StateStore.CookieCheckRec]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for s in c.sourceSites {
            let h = Self.host(of: s)
            let rec = checks[s.id]
            let pos = c.managedSitePosition(s.id)
            out.append([
                "id": s.id, "name": s.name, "url": s.url,
                "framework": s.framework.rawValue,
                "enabled": s.enabled, "managed": s.managed,
                "group": c.groupIndex(of: s.id),
                "indexInBlock": pos.index, "blockSize": pos.count,
                "usesAPIKey": Self.usesAPIKey(s),
                "hasAPIKey": !(s.apiKey ?? "").isEmpty,
                "cookieCount": snap[h]?.count ?? 0,
                "hasCookie": snap[h] != nil && !(snap[h]?.isEmpty ?? true),
                "check": rec.map { ["ok": $0.ok, "message": $0.message, "time": $0.time] }
                    ?? ["ok": NSNull(), "message": "", "time": 0] as [String: Any],
                "upLimitMB": c.downloader.siteUpLimits[s.id].map { Int($0 / 1_048_576) } ?? 0,
                "warning": siteWarnings[s.id] ?? "",
                "needsSourceQuote": SiteRegistry.needsSourceQuoteField(s),
            ])
        }
        return out
    }

    /// JSON 对象 -> 送给边界的字符串（UTF-8，无转义中文）
    static func encode(_ obj: [String: Any]) -> String {
        let opts: JSONSerialization.WritingOptions = [.fragmentsAllowed]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: opts) else {
            return "{\"ok\":false,\"error\":\"结果序列化失败\"}"
        }
        return String(data: data, encoding: .utf8) ?? "{\"ok\":false,\"error\":\"结果编码失败\"}"
    }

    static func eventJSON(_ e: Event) -> [String: Any] {
        var d: [String: Any] = ["seq": e.seq, "kind": e.kind, "text": e.text,
                                "detail": e.detail, "time": e.time]
        d["site"] = e.siteID ?? ""
        d["phase"] = e.phase ?? ""
        d["ok"] = e.ok ?? NSNull()
        return d
    }

    static func dateText(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    private func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
}

/// JSONEncoder 对 `any Encodable` 的支持包装
private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

private extension NSRecursiveLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
