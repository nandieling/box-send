import Foundation

/// Web 控制台：页面 + REST API
///
///   GET  /                 控制台页面
///   GET  /api/config       {"ok":true,"raw":"<boxsend.json 原文>"}
///   POST /api/config       {"raw":"..."} 校验后原子写盘并重载
///   GET  /api/status       cookie 站点数 / 上次 gist 同步 / 最近日志 / 下载器
///   POST /api/gist-sync    立即执行一轮 Gist cookie 同步
///   POST /api/run          {detail, site?, skipReseed, skipPush?, targets?} 同步执行
///
/// 认证：设置 webToken（配置或 --token）后，/api/* 需要请求头 X-BoxSend-Token 或 ?token=。
public final class ServeApp {
    private let configPath: String
    private var config: AppConfig
    private let cookies: CookieStore
    private let state: StateStore
    private let client: HTTPClient
    private let dataDir: String
    private let token: String?

    private let cfgLock = NSLock()
    private let busyLock = NSLock()
    private var busy = false
    private var cookieFileMTime: Double = 0
    private let server = HTTPServer()

    public init(config: AppConfig, configPath: String, cookies: CookieStore,
         state: StateStore, client: HTTPClient, dataDir: String, token: String?) {
        self.config = config
        self.configPath = (configPath as NSString).expandingTildeInPath
        self.cookies = cookies
        self.state = state
        self.client = client
        self.dataDir = dataDir
        self.token = (token?.isEmpty == false) ? token : nil
    }

    private var currentConfig: AppConfig {
        cfgLock.lock(); defer { cfgLock.unlock() }
        return config
    }

    // MARK: 启动

    public func start(host: String, port: Int) throws {
        try server.start(host: host, port: port) { [weak self] req in
            self?.handle(req) ?? .notFound
        }
        print("box-send web 控制台: http://\(host):\(server.assignedPort)")
        if let t = token {
            print("已启用访问令牌: \(t)（页面里输入一次即可，或 URL 带 ?token=）")
        } else {
            print("未设置访问令牌。本地回环地址可用；对公网暴露前建议加 --token")
        }
    }

    /// 阻塞 accept 循环
    public func run() { server.run() }

    // MARK: 路由

    private func handle(_ req: HTTPServer.Request) -> HTTPServer.Response {
        if req.method == "GET" && req.path == "/" { return UI.index }
        guard req.path.hasPrefix("/api/") else { return .notFound }
        if let t = token {
            let supplied = req.headers["x-boxsend-token"] ?? req.query["token"]
            if supplied != t { return .unauthorized }
        }
        switch (req.method, req.path) {
        case ("GET", "/api/config"):
            return apiGetConfig()
        case ("POST", "/api/config"):
            return apiSaveConfig(req)
        case ("GET", "/api/status"):
            return apiStatus()
        case ("POST", "/api/gist-sync"):
            return apiGistSync()
        case ("POST", "/api/test-downloader"):
            return apiTestDownloader()
        case ("POST", "/api/run"):
            return apiRun(req)
        default:
            return .notFound
        }
    }

    // MARK: API

    private func apiGetConfig() -> HTTPServer.Response {
        guard let raw = try? String(contentsOf: URL(fileURLWithPath: configPath), encoding: .utf8) else {
            return .json(["ok": false, "error": "无法读取配置文件"], status: 400)
        }
        return .json(["ok": true, "raw": raw])
    }

    private func apiSaveConfig(_ req: HTTPServer.Request) -> HTTPServer.Response {
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let raw = obj["raw"] as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .json(["ok": false, "error": "缺少 raw 字段"], status: 400)
        }
        guard let data = raw.data(using: .utf8) else {
            return .json(["ok": false, "error": "编码错误"], status: 400)
        }
        do {
            let cfg = try JSONDecoder().decode(AppConfig.self, from: data)
            let url = URL(fileURLWithPath: configPath)
            try FileManager.default.createDirectory(
                atPath: url.deletingLastPathComponent().path, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            cfgLock.lock(); config = cfg; cfgLock.unlock()
            state.note("web: 配置已保存")
            return .json(["ok": true])
        } catch {
            return .json(["ok": false, "error": "校验失败: \(error.localizedDescription)"], status: 400)
        }
    }

    private func apiStatus() -> HTTPServer.Response {
        maybeReloadCookies()
        var hosts: [String: Int] = [:]
        var count = 0
        for (h, arr) in cookies.snapshot() { hosts[h] = arr.count; count += arr.count }
        let d = currentConfig.downloader
        var dict: [String: Any] = [
            "ok": true,
            "cookieHosts": hosts,
            "cookieCount": count,
            "notes": Array(state.recentNotes.suffix(10)),
            "downloader": "\(d.type.rawValue) @ \(d.url)",
            "lastGistSync": NSNull(),
        ]
        if let t = state.lastGistSync { dict["lastGistSync"] = t }
        return .json(dict)
    }

    private func apiGistSync() -> HTTPServer.Response {
        let cfg = currentConfig
        guard let g = cfg.gistSync, !g.gistID.isEmpty, !g.token.isEmpty else {
            return .json(["ok": false, "error": "未配置 gistSync：先填写「Gist Cookie 同步」并保存"], status: 400)
        }
        guard beginBusy() else {
            return .json(["ok": false, "error": "已有任务在执行，请稍候"], status: 409)
        }
        defer { endBusy() }
        do {
            let sync = GistSync(config: g, client: client)
            let r = try sync.pull(into: cookies, state: state)
            try writeCookiesLocal()
            state.note("web: gist 同步 \(r.cookieCount) 条 cookie")
            return .json(["ok": true,
                          "message": "同步完成: \(r.cookieCount) 条 cookie, hosts=\(r.hosts.joined(separator: ", ")) (备份时间 \(r.backupTime))"])
        } catch {
            return .json(["ok": false, "error": error.localizedDescription], status: 500)
        }
    }

    private func apiTestDownloader() -> HTTPServer.Response {
        let cfg = currentConfig
        let d = DownloaderFactory.make(cfg, client: client)
        do {
            let msg = try d.testConnection()
            state.note("web: 下载器连接测试通过 (\(msg))")
            return .json(["ok": true, "message": msg])
        } catch {
            return .json(["ok": false, "error": error.localizedDescription], status: 500)
        }
    }

    private func apiRun(_ req: HTTPServer.Request) -> HTTPServer.Response {
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            return .json(["ok": false, "error": "请求体需为 JSON"], status: 400)
        }
        guard let detail = obj["detail"] as? String,
              !detail.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .json(["ok": false, "error": "detail（详情页 URL）为空"], status: 400)
        }
        guard beginBusy() else {
            return .json(["ok": false, "error": "已有任务在执行，请稍候"], status: 409)
        }
        defer { endBusy() }
        maybeReloadCookies()
        let cfg = currentConfig
        var o = ReseedPipeline.Options()
        o.skipReseed = obj["skipReseed"] as? Bool ?? false
        o.skipPush = obj["skipPush"] as? Bool ?? false
        if let t = obj["targets"] as? [String], !t.isEmpty { o.targets = t }
        let pipeline = ReseedPipeline(config: cfg, cookies: cookies, state: state,
                                      downloader: DownloaderFactory.make(cfg, client: client))
        do {
            let report = try pipeline.run(detailURL: detail, sourceSiteID: obj["site"] as? String, opts: o)
            state.note("web: run \(detail) 完成")
            return .json(["ok": true, "report": report.description])
        } catch {
            state.note("web: run \(detail) 失败: \(error.localizedDescription)")
            return .json(["ok": false, "error": error.localizedDescription], status: 500)
        }
    }

    // MARK: 辅助

    private func beginBusy() -> Bool {
        busyLock.lock(); defer { busyLock.unlock() }
        guard !busy else { return false }
        busy = true
        return true
    }

    private func endBusy() {
        busyLock.lock(); defer { busyLock.unlock() }
        busy = false
    }

    private var localCookieFile: URL {
        URL(fileURLWithPath: dataDir).appendingPathComponent("cookies.json")
    }

    private func writeCookiesLocal() throws {
        guard let data = cookies.exportBackupJSON() else { return }
        try data.write(to: localCookieFile, options: .atomic)
        cookieFileMTime = (try? localCookieFile.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
    }

    /// gist-sync --loop 服务会持续更新本地 cookies.json；这里按 mtime 热加载，
    /// 保证 web 控制台始终使用最新 cookie（无需重启）。
    private func maybeReloadCookies() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: localCookieFile.path),
              let mt = attrs[.modificationDate] as? Date,
              mt.timeIntervalSince1970 > cookieFileMTime else { return }
        guard let data = try? Data(contentsOf: localCookieFile),
              (try? cookies.replace(from: data)) != nil else { return }
        cookieFileMTime = mt.timeIntervalSince1970
    }
}
