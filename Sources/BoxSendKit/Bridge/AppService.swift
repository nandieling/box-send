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
        /// 辅种行定位键（站点|种子 hash）；其他动作留空
        public var key: String = ""
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
    /// 此刻正在检测的站（界面据此在单张卡片上写「检测中」，不必等整批跑完）
    private var checkingSites: Set<String> = []
    private var busyCookieSync = false
    private var busyCookieCheck = false
    private var busyDownloader = false
    private var busyZip = false
    private var busyUpdate = false
    private var busySSH = false
    private var busyAssist = false
    private var checkGeneration = 0
    private var running = false
    private var runningStep = ""
    private var lastReport = ""
    private var siteEvents: [String: Event] = [:]      // 逐站最新状态（转种页）
    private var pushEvents: [String: Event] = [:]
    private var sourcePushEvent: Event?
    private var siteWarnings: [String: String] = [:]
    /// 辅种逐行状态（key = 站点|种子 hash）
    private var assistRows: [String: Event] = [:]
    private var assistStep = ""
    private var assistReport = ""
    /// 定时自动跑的钟（从进程起来算第一轮的起点）
    private var assistAutoRun = AssistAutoRun()
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
        Trace.mark("init: 读配置")
        var loaded = AppConfig.load(path: configPath)
        if loaded == nil {
            loaded = AppConfig.template()
        }
        Trace.mark("init: 配置解析\(loaded == nil ? "失败，用内置模板" : "完毕")")
        var c = loaded ?? AppConfig.template()
        Trace.mark("init: 展开数据目录")
        let dir = Platform.expandPath(dataDir ?? c.dataDir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        c.dataDir = dir
        self.dataDir = dir
        self.cfg = c
        Trace.mark("init: 状态库 \(dir)")
        self.state = StateStore(dataDir: dir)
        Trace.mark("init: 读 cookies")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("cookies.json")) {
            _ = try? cookies.replace(from: data)
        }
        Trace.mark("init: 取日志")
        self.logs = state.recentNotes
        self.state.onNote = { [weak self] line in
            guard let self else { return }
            self.lock.lock()
            self.logs.append(line)
            if self.logs.count > 400 { self.logs.removeFirst(self.logs.count - 400) }
            self.lock.unlock()
        }
        Trace.mark("init: 套间站点表")
        lock.lock()
        for s in c.sourceSites {
            if let rec = state.cookieCheck(s.id) { checkResults[s.id] = rec }
        }
        lock.unlock()
        Trace.mark("init: 落盘")
        save()
        Trace.mark("init: 收工")
    }

    // MARK: 入口

    /// 调用一个动作。params 为界面传来的 JSON 对象（缺失字段用默认值）。
    @discardableResult
    public func invoke(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        switch method {
        case "version":
            return ["version": BoxSendVersion.version, "platform": Platform.osName,
                    "configPath": configPath, "dataDir": dataDir,
                    "themes": ThemeCatalog.allJSON,
                    // 界面拿这些当占位值，免得两端各写一份默认值写歪
                    "sshDefaults": ["keyPath": "~/.ssh/id_ed25519",
                                    "testMB": SSHConfig().testMB,
                                    "probeURL": SSHConfig.defaultProbeURL,
                                    "throttlingMBps": SSHConfig.throttlingHintMBps]]
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
        case "sites.matchURL":
            // 源站自动识别：转种页那行「源站：自动（某站）」的标签用，匹配规则只在核心一处
            let matched = cfg.site(forURL: params["url"] as? String ?? "")
            return ["id": matched?.id ?? "", "name": matched?.name ?? ""]
        case "sites.candidates":
            // 批量添加站点弹窗：待添加的站点连同显示顺序一起由核心排好（含名称拼音默认序）
            let rows: [[String: Any]] = cfg.unmanagedDisplayOrder().compactMap { id in
                guard let s = cfg.site(id) else { return nil }
                return ["id": s.id, "name": s.name, "url": s.url]
            }
            return ["sites": rows]
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
            _ = try setSiteAPIKey(siteID: params["id"] as? String ?? "",
                                  raw: params["apiKey"] as? String ?? "")
            return groupsAndSites()
        case "sites.setUpLimit":
            let id = params["id"] as? String ?? ""
            mutate { cfg.setSiteUpLimitMB(int(params["upLimitMB"]), siteID: id) }
            save()
            return groupsAndSites()
        case "sites.setAutoFree":
            // 「发种后免费一天」：只有站内有免费链接特征的站点能开
            let id = params["id"] as? String ?? ""
            mutate { cfg.setSiteAutoFree(params["on"] as? Bool ?? false, siteID: id) }
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
            // 弹窗预填：API 站回填 apiKey，其余回填 cookie 罐，界面不用关心差别
            let id = params["id"] as? String ?? ""
            return ["raw": existingCredential(forID: id),
                    "usesAPIKey": cfg.site(id).map { Self.usesAPIKey($0) } ?? false]
        case "cookies.setRaw":
            let id = params["id"] as? String ?? ""
            let raw = params["raw"] as? String ?? ""
            return try setSiteCredential(siteID: id, raw: raw)
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
            return try testDownloader(id: params["id"] as? String)

        case "downloaders.add":
            return try addDownloader(params)
        case "downloaders.save":
            return try saveDownloader(params)
        case "downloaders.remove":
            return try removeDownloader(params)
        case "downloaders.assign":
            return try assignDownloaderRole(params)

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

        case "assist.scan":
            return try assistScan(params)
        case "assist.start":
            return try startAssist(params)
        case "assist.confirm":
            return try confirmAssist(params)
        case "assist.tick":
            return tickAssist()
        case "assist.status":
            return assistState()

        case "ssh.test":
            return try testSSHSpeed()
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
        Trace.mark("invokeJSON: 解析完，动作=\(method.isEmpty ? "(没认出来)" : method)")
        do {
            let result = try invoke(method, params)
            Trace.mark("invokeJSON: 动作跑完，开始编码")
            let text = Self.encode(["ok": true, "result": result])
            Trace.mark("invokeJSON: 编码完")
            return text
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
            "sshTest": busySSH, "assist": busyAssist,
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
            "downloaders": Self.downloadersJSON(c),
            "downloaderRoles": ["reseed": c.reseedDownloader.id, "assist": c.assistDownloader.id],
            "cookies": ["hosts": cookieList, "total": snap.values.reduce(0) { $0 + $1.count }],
            "sites": siteStatesLocked(c, snap: snap, checks: checks),
            "groups": groupsLocked(c),
            "run": run,
            "assist": assistStateLocked(),
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

    // MARK: 多下载器
    //
    // 发种推的那台和辅种扫的那台经常不是同一台机器，所以列表与用途指派都在核心里，
    // 界面两端只是列表与两个下拉。

    /// 快照/返回值里的下载器列表与用途指派
    static func downloadersJSON(_ c: AppConfig) -> [[String: Any]] {
        c.allDownloaders.map { d in
            [
                "id": d.id, "name": d.name, "label": d.label,
                "type": d.type.rawValue, "url": d.url, "username": d.username,
                "password": d.password,
                "savePath": d.savePath ?? "", "category": d.category ?? "",
                "skipChecking": d.skipChecking,
                "defaultUpLimit": d.defaultUpLimit,
                "pushPolicy": d.pushPolicy.rawValue,
                "vpsFreeGB": d.vpsFreeGB as Any,
                "sizeGuardMode": d.sizeGuardMode.rawValue,
                "sizeGuardMarginGB": d.sizeGuardMarginGB,
                "isMain": d.id == c.downloader.id,
            ]
        }
    }

    private func downloadersState() -> [String: Any] {
        lock.lock()
        let c = cfg
        lock.unlock()
        return ["downloaders": Self.downloadersJSON(c),
                "downloaderRoles": ["reseed": c.reseedDownloader.id,
                                    "assist": c.assistDownloader.id]]
    }

    private func addDownloader(_ params: [String: Any]) throws -> [String: Any] {
        mutate {
            let id = "dl-" + String(Int(Date().timeIntervalSince1970 * 1000) % 1_000_000_000)
            var d = cfg.downloader.copiedAs(id: id, name: cfg.nextDownloaderName())
            // 照主下载器抄骨架，但地址与账号留空：新建时人要自己填
            d.url = ""
            d.username = ""
            d.password = ""
            d.vpsFreeGB = nil
            if let name = params["name"] as? String, !name.isEmpty { d.name = name }
            cfg.updateDownloader(d)
            self.downloaderMessage = "已新增 \(d.name)，填好地址与账号后点测试连接"
        }
        save()
        return downloadersState()
    }

    /// 保存一台（按 id upsert）。逐站限速在站点分组页改，这里不动它。
    private func saveDownloader(_ params: [String: Any]) throws -> [String: Any] {
        guard let obj = params["downloader"] else { throw Failure("缺少 downloader") }
        guard let raw = try? JSONSerialization.data(withJSONObject: obj) else {
            throw Failure("downloader 格式不对")
        }
        var d: DownloaderConfig
        do {
            d = try JSONDecoder().decode(DownloaderConfig.self, from: raw)
        } catch {
            throw Failure("downloader 读不出来：\(error.localizedDescription)")
        }
        if let name = (params["downloader"] as? [String: Any])?["name"] as? String, !name.isEmpty {
            d.name = name
        }
        mutate {
            let existing = cfg.downloaderEntry(id: d.id)
            d.siteUpLimits = existing.siteUpLimits
            if d.savePath?.isEmpty == true { d.savePath = nil }
            if d.category?.isEmpty == true { d.category = nil }
            if d.name.isEmpty { d.name = existing.name }
            cfg.updateDownloader(d)
        }
        save()
        return downloadersState()
    }

    private func removeDownloader(_ params: [String: Any]) throws -> [String: Any] {
        let id = params["id"] as? String ?? ""
        lock.lock()
        let isMain = id == cfg.downloader.id
        lock.unlock()
        guard !isMain else { throw Failure("主下载器不能删：把用途改到别的机器上再删这台") }
        mutate { cfg.removeDownloader(id: id) }
        save()
        return downloadersState()
    }

    private func assignDownloaderRole(_ params: [String: Any]) throws -> [String: Any] {
        let role = params["role"] as? String ?? "reseed"
        let id = params["id"] as? String ?? ""
        mutate { cfg.assignDownloader(role: role, id: id) }
        save()
        return downloadersState()
    }

    // MARK: 辅种
    //
    // 与转种分开一套：辅种不发新种，只是把站内已有的那条挂到自己账号下做种。
    // 站点请求的节奏由 AssistPipeline 里的 SiteThrottle 收口，界面只管发起与显示。

    /// 扫描下载器 + 生成本轮计划。只读，不动下载器，也不发站点请求。
    private func assistScan(_ params: [String: Any]) throws -> [String: Any] {
        lock.lock()
        let cfg = self.cfg
        lock.unlock()
        let (pipe, _) = try makeAssistPipeline(cfg)
        let picked = (params["siteIDs"] as? [String])?.isEmpty == false ? (params["siteIDs"] as? [String]) : nil
        let scan = try pipe.scanAndRecord()
        let candidates = scan.torrents
        let rows = pipe.plan(torrents: candidates, siteIDs: picked)
        let nameOf: (String) -> String = { id in
            guard let s = cfg.site(id) else { return id }
            return SiteRegistry.effectiveSite(s).name
        }
        return [
            "summary": [
                "count": scan.count,
                "previousCount": scan.previousCount as Any,
                "changed": scan.changed,
                "deltaText": scan.deltaText,
                "lastScan": scan.lastScan.map { Self.dateText($0.timeIntervalSince1970) } ?? "从未",
                "assistedBySite": scan.assistedBySite,
            ],
            "downloader": pipe.downloaderLabel,
            "torrents": candidates.map { t in
                [
                    "hash": t.hash,
                    "name": t.name,
                    "size": t.totalSize,
                    "sizeText": String(format: "%.2f GiB", Double(t.totalSize) / 1_073_741_824),
                    "savePath": t.savePath,
                    "trackers": t.trackerHosts,
                ]
            },
            "rows": rows.map { r in
                [
                    "key": "\(r.siteID)|\(r.hash)",
                    "siteID": r.siteID,
                    "siteName": nameOf(r.siteID),
                    "hash": r.hash,
                    "torrentName": r.torrentName,
                    "skip": r.skipReason ?? "",
                ]
            },
            "sites": (picked ?? cfg.assist?.siteIDs ?? []).map { ["id": $0, "name": nameOf($0)] },
            "budget": pipe.throttle.remaining,
        ]
    }

    private func startAssist(_ params: [String: Any]) throws -> [String: Any] {
        var cfg: AppConfig!
        lock.lock()
        if busyAssist {
            lock.unlock()
            throw Failure("辅种正在运行，请等当前任务结束")
        }
        let force = (params["forceKeys"] as? [String]) ?? []
        busyAssist = true
        // 只采纳一条时别把别的行打回「待检索」，那会让整表看起来没跑过
        if force.isEmpty { assistRows = [:] }
        assistStep = force.isEmpty ? "扫描下载器…" : "已采纳，重新核对这一条…"
        assistReport = ""
        cfg = self.cfg
        lock.unlock()

        let (pipe, jar) = try makeAssistPipeline(cfg)
        var opts = AssistPipeline.Options()
        opts.siteIDs = (params["siteIDs"] as? [String])?.isEmpty == false ? (params["siteIDs"] as? [String]) : nil
        opts.dryRun = params["dryRun"] as? Bool ?? false
        opts.limit = int(params["limit"]) ?? 0
        opts.forceKeys = Set(force)
        opts.onEvent = { [weak self] st in
            guard let self else { return }
            let ev = Event(seq: self.nextSeq(), kind: "assist", siteID: st.siteID,
                           text: "\(st.torrentName)｜\(st.text)", detail: st.detail,
                           phase: Self.assistPhaseName(st.phase), ok: nil,
                           time: Date().timeIntervalSince1970, key: st.rowKey)
            self.mutate { self.assistRows[st.rowKey] = ev }
            self.emit("assist", st.siteID, ev.text, st.detail, phase: ev.phase, ok: nil)
        }
        let picked = opts.siteIDs ?? cfg.assist?.siteIDs ?? []
        queue.async { [weak self] in
            guard let self else { return }
            var reportText = ""
            var failure = ""
            do {
                let scan = try pipe.scanAndRecord()
                // 单条采纳：只跑被点名的那条，别顺带把整个下载器过一遍
                let forceHashes = Set(force.compactMap { $0.split(separator: "|").last }.map(String.init))
                let candidates = forceHashes.isEmpty ? scan.torrents
                    : scan.torrents.filter { forceHashes.contains($0.hash) }
                self.mutate { self.assistStep = "候选 \(candidates.count) 条 × 站点 \(picked.count) 个" }
                let report = pipe.run(torrents: candidates, opts: opts)
                reportText = "成功 \(report.assistedCount)，待人工确认 \(report.pendingCount)，"
                    + "跳过 \(report.skippedCount)，站点请求 \(report.requests) 次"
            } catch {
                failure = error.localizedDescription
            }
            self.mutate {
                self.busyAssist = false
                self.assistStep = failure.isEmpty ? "完成" : "失败"
                self.assistReport = failure.isEmpty ? reportText : failure
            }
            self.persistCookies()
            self.emit(failure.isEmpty ? "assist" : "error", nil,
                      failure.isEmpty ? "辅种结束：\(reportText)" : "辅种失败: \(failure)",
                      "", phase: nil, ok: failure.isEmpty)
        }
        return assistState()
    }

    /// 人工采纳一条「待人工确认」：只跑这一条，预筛（负缓存、已辅过）一律让路
    private func confirmAssist(_ params: [String: Any]) throws -> [String: Any] {
        guard let key = params["key"] as? String, key.contains("|") else {
            throw Failure("没说要采纳哪条")
        }
        let siteID = String(key.split(separator: "|").first ?? "")
        guard !siteID.isEmpty else { throw Failure("没说要采纳哪条") }
        return try startAssist(["siteIDs": [siteID], "forceKeys": [key]])
    }

    /// 定时自动跑：界面只管每分钟敲这一下，该不该跑由核心库判断（两端共用一套算法）
    private func tickAssist() -> [String: Any] {
        lock.lock()
        let minutes = cfg.assist?.autoRunMinutes ?? 0
        let busy = busyAssist
        let sites = cfg.assist?.siteIDs ?? []
        lock.unlock()
        guard minutes > 0, !busy, !sites.isEmpty, assistAutoRun.due(minutes: minutes) else {
            return ["started": false, "minutes": minutes,
                    "nextInMinutes": assistAutoRun.minutesLeft(minutes: minutes) as Any]
        }
        assistAutoRun.noteRun()
        do {
            _ = try startAssist([:])
            return ["started": true, "minutes": minutes, "nextInMinutes": minutes]
        } catch {
            return ["started": false, "minutes": minutes, "error": error.localizedDescription]
        }
    }

    /// 辅种用的流水线：每次新建 cookie 罐与下载器，跑完把 Set-Cookie 并回主罐
    private func makeAssistPipeline(_ c: AppConfig) throws -> (AssistPipeline, CookieStore) {
        guard c.assist != nil else { throw Failure("请先在设置里配置辅种（assist）") }
        let jar = CookieStore()
        lock.lock()
        if let data = cookies.exportBackupJSON() { _ = try? jar.replace(from: data) }
        lock.unlock()
        let client = HTTPClient(cookies: jar, userAgent: c.userAgent)
        let downloader = DownloaderFactory.makeForAssist(c, client: client)
        return (AssistPipeline(config: c, cookies: jar, state: state, downloader: downloader), jar)
    }

    private func assistState() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return assistStateLocked()
    }

    /// 快照里也带一份：Windows 端按快照轮询刷新，不必另开一条轮询
    private func assistStateLocked() -> [String: Any] {
        let rows = Array(assistRows.values).sorted { $0.seq < $1.seq }.map(Self.eventJSON)
        let minutes = cfg.assist?.autoRunMinutes ?? 0
        return ["running": busyAssist, "step": assistStep, "report": assistReport, "rows": rows,
                "autoRun": ["minutes": minutes,
                            "nextInMinutes": assistAutoRun.minutesLeft(minutes: minutes) as Any,
                            "lastRun": Self.dateText(assistAutoRun.lastRun.timeIntervalSince1970)]]
    }

    static func assistPhaseName(_ p: AssistPipeline.Status.Phase) -> String {
        switch p {
        case .working: return "working"
        case .verifying: return "verifying"
        case .done: return "done"
        case .failed: return "failed"
        case .skipped: return "skipped"
        }
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

        let (imported, kept, skipped) = importBackupRaws(rawsBySource)
        cookieMessage = "同步完成：导入 \(imported) 个站，保留 \(kept) 个"
            + (errors.isEmpty ? "" : "；\(errors.joined(separator: "；"))")
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

    /// 把两路备份拉到的 raw cookie 落到各站头上（同步与自动任务共用；测试也直接打这条）。
    /// 本地已检测有效的站不被备份覆盖；认不出是哪个站的 host 记进 skipped。
    @discardableResult
    func importBackupRaws(_ sources: [(label: String, raws: [String: String])])
        -> (imported: Int, kept: Int, skipped: Int) {
        var imported = 0, kept = 0, skipped = 0
        mutate {
            let sites = cfg.managedSites.isEmpty ? cfg.sourceSites : cfg.managedSites
            for (label, raws) in sources {
                for (host, raw) in raws where !raw.isEmpty {
                    guard let site = matchSite(host, in: sites) else { skipped += 1; continue }
                    if checkResults[site.id]?.ok == true {
                        kept += 1
                        continue                  // 本地这份是有效的，不被备份覆盖
                    }
                    if cookies.mergeRawString(host: Self.host(of: site), raw) {
                        imported += 1
                    } else {
                        kept += 1
                    }
                }
                note("cookie: \(label) 备份已拉取")
            }
        }
        persistCookies()
        return (imported, kept, skipped)
    }

    /// 备份里的 host 与配置里的站点匹配。先认完全相同的那个，再退一步按主域/子域认：
    /// 浏览器备份按 cookie 域分组，铂金家这类站点的 cookie 常记在 `pthome.net` 下，
    /// 站点配的却是 `www.pthome.net`，只比字符串会把这站整站判成「本地无 cookie」
    /// （mac 版一直是这么认的，两端这里必须一致）
    private func matchSite(_ host: String, in sites: [SiteConfig]) -> SiteConfig? {
        Self.matchBackupHost(host, in: sites)
    }

    /// 纯函数版（测试直接打这条）：完全相同的那个优先，其次才按主域/子域认
    static func matchBackupHost(_ backupHost: String, in sites: [SiteConfig]) -> SiteConfig? {
        let want = CookieRawMerge.norm(backupHost)
        if let exact = sites.first(where: { CookieRawMerge.norm(Self.host(of: $0)) == want }) {
            return exact
        }
        return sites.first { CookieRawMerge.hostMatches(want, CookieRawMerge.norm(Self.host(of: $0))) }
    }

    /// 手动填写弹窗的写入口：按站点凭据类型分流。
    /// 只看 cookie 罐的话，馒头这类 API 站会「保存成功，再打开输入框是空的」
    private func setSiteCredential(siteID: String, raw: String) throws -> [String: Any] {
        guard let site = cfg.site(siteID) else { throw Failure("未配置的站点 id: \(siteID)") }
        return Self.usesAPIKey(site) ? try setSiteAPIKey(siteID: siteID, raw: raw)
                                     : try setSiteCookie(siteID: siteID, raw: raw)
    }

    /// 手动填 API Key：覆盖旧值，非空就启用该站并当场复检
    private func setSiteAPIKey(siteID: String, raw: String) throws -> [String: Any] {
        guard let site = cfg.site(siteID) else { throw Failure("未配置的站点 id: \(siteID)") }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = ""
        mutate {
            guard let i = cfg.sourceSites.firstIndex(where: { $0.id == siteID }) else { return }
            cfg.sourceSites[i].apiKey = v.isEmpty ? nil : v
            if !v.isEmpty { cfg.sourceSites[i].enabled = true }
            message = v.isEmpty ? "已清空 \(site.name) 的 API Key"
                                : "已保存 \(site.name) 的 API Key，并启用该站"
            self.cookieMessage = message
            self.note("api: 单站 \(siteID) key 已更新")
        }
        save()
        if !v.isEmpty { checkCookiesAsync([siteID], force: true) }
        return ["message": message]
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
            // 同时在检的站点数（mac 版同一档）。不是「一批检完再检下一批」：
            // 那样每批都要等最慢的那个站，慢站多的时候整批被它拖住
            let slots = DispatchSemaphore(value: Self.cookieCheckConcurrency)
            let inflight = DispatchGroup()
            let counter = CheckCounter()
            for site in targets {
                inflight.enter()
                queue.async {
                    slots.wait()
                    defer { slots.signal(); inflight.leave() }
                    if self.lock.withLock({ self.checkGeneration != generation }) { return }
                    guard self.hasCredential(site) else {
                        self.recordCheck(site.id, ok: false, "本地无 cookie")
                        counter.bump()
                        self.emit("site", site.id, "\(site.name): 本地无 cookie", "", phase: "check", ok: false)
                        return
                    }
                    // 每站一个连接池 + 时长上限：卡死的站只作废它自己，也不占着别人
                    let cap = CookieCheck.timeout
                    let client = HTTPClient(cookies: self.cookies, userAgent: c.userAgent)
                    client.setRequestTimeout(cap)
                    self.markChecking([site.id])
                    let r = CookieCheck.check(site: site, client: client,
                                              budget: CookieCheck.Budget(
                                                  until: Date().addingTimeInterval(cap), seconds: cap))
                    self.clearChecking(site.id)
                    self.recordCheck(r.siteID, ok: r.ok, r.message)
                    counter.bump()
                    self.emit("site", r.siteID, "\(site.name): \(r.message)", "", phase: "check", ok: r.ok)
                }
            }
            inflight.wait()
            self.mutate {
                self.checkingSites.removeAll()
                self.busyCookieCheck = false
            }
            self.emit("note", nil, "cookie 检测完成：\(counter.value) 个站", "", phase: nil, ok: true)
        }
        return ["started": true, "checked": targets.count]
    }

    /// 同时在检的站点数（与 mac 版同一档）
    static let cookieCheckConcurrency = 4

    /// 检测完成数（多站同时往上加）
    private final class CheckCounter: @unchecked Sendable {
        private let l = NSLock()
        private var n = 0
        func bump() { l.lock(); n += 1; l.unlock() }
        var value: Int { l.lock(); defer { l.unlock() }; return n }
    }

    private func markChecking(_ ids: [String]) {
        mutate { checkingSites.formUnion(ids) }
    }

    private func clearChecking(_ id: String) {
        mutate { checkingSites.remove(id) }
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

    /// 弹窗预填用的凭据原文：API 站取站点 apiKey，其余取 cookie 罐里的请求头
    private func existingCredential(forID siteID: String) -> String {
        guard let site = cfg.site(siteID) else { return "" }
        if Self.usesAPIKey(site) { return site.apiKey ?? "" }
        return cookies.cookieHeader(forHost: Self.host(of: site)) ?? ""
    }

    // MARK: 下载器 / TMDB / 更新

    /// 测某台下载器连通（不带 id = 发种那台）
    private func testDownloader(id: String?) throws -> [String: Any] {
        let c = cfg
        let target = c.downloaderEntry(id: id ?? c.reseedDownloaderID)
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
            let info = try DownloaderFactory.make(target, client: client).testConnection()
            mutate { self.downloaderMessage = "连接成功（\(target.label)）：\(info)" }
            emit("note", nil, "下载器连接成功", info, phase: nil, ok: true)
            return ["ok": true, "message": "连接成功：\(info)"]
        } catch {
            let why = "连接失败（\(target.label)）：\(error.localizedDescription)"
            mutate { self.downloaderMessage = why }
            emit("error", nil, "下载器\(why)", "", phase: nil, ok: false)
            return ["ok": false, "message": why]
        }
    }

    /// SSH 上传测速：核心层跑一遍，mac 与 Windows 界面都能点（调用方自己丢后台线程，会等几十秒）
    private func testSSHSpeed() throws -> [String: Any] {
        guard let scfg = cfg.ssh, scfg.isConfigured else {
            throw Failure("没填服务器地址和用户名")
        }
        mutate { self.busySSH = true }
        defer { mutate { self.busySSH = false } }
        do {
            let r = try SSHSpeedTest.runTest(scfg)
            emit("info", nil, "服务器测速：" + r.summaryLine, "", phase: nil, ok: true)
            return ["ok": true, "mbps": r.peakMBps, "text": r.summaryLine,
                    "rounds": r.roundsText, "probeURL": r.probeURL,
                    "serverInfo": r.serverInfo,
                    "low": r.peakMBps < SSHConfig.throttlingHintMBps]
        } catch {
            let why = error.localizedDescription
            emit("error", nil, "服务器测速失败", why, phase: nil, ok: false)
            return ["ok": false, "mbps": 0.0, "text": why, "rounds": "",
                    "probeURL": scfg.resolvedProbeURL, "serverInfo": "", "low": false]
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

    static func host(of site: SiteConfig) -> String {
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
                "checking": checkingSites.contains(s.id),
                "upLimitMB": c.reseedDownloader.siteUpLimits[s.id].map { Int($0 / 1_048_576) } ?? 0,
                "warning": siteWarnings[s.id] ?? "",
                "needsSourceQuote": SiteRegistry.needsSourceQuoteField(s),
                "supportsAutoFree": c.siteSupportsAutoFree(s.id),
                "autoFree": c.siteAutoFree(s.id),
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
        d["key"] = e.key
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
