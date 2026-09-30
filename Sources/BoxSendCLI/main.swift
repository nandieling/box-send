import Foundation
import BoxSendKit

// box-send: PT 批量转种 + 推送下载器（限速）
// 用法见 `box-send help`

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { return nil }
    return args[i + 1]
}
func has(_ name: String) -> Bool { args.contains(name) }
func required(_ name: String) -> String {
    guard let v = opt(name) else { die("\(name) 缺失") }
    return v
}

func die(_ m: String) -> Never {
    print("错误: \(m)")
    exit(2)
}

let configPath = opt("--config") ?? "Config/boxsend.json"
let command = args.first ?? "help"
// 没有配置文件时只有 template 可跑（负责生成它）
let config: AppConfig
if let loaded = AppConfig.load(path: configPath) {
    config = loaded
} else if command == "template" {
    config = AppConfig.template()
} else {
    print("找不到配置文件 \(configPath)（当前目录: \(FileManager.default.currentDirectoryPath)）")
    print("先执行 `box-send template` 生成模板（或复制 Config/boxsend.example.json 为 boxsend.json），或用 --config 指定路径")
    exit(1)
}

let dataDir = (config.dataDir as NSString).expandingTildeInPath
try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
let state = StateStore(dataDir: dataDir)
let cookies = CookieStore()
// 恢复上次 gist 同步的本地 cookie（若存在）
let localCookieFile = URL(fileURLWithPath: dataDir).appendingPathComponent("cookies.json")
if let data = try? Data(contentsOf: localCookieFile),
   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let arr = dict["cookies"] {
    if let raw = try? JSONSerialization.data(withJSONObject: arr) {
        _ = try? cookies.importBackupJSON(raw)
    }
}

let client = HTTPClient(cookies: cookies, userAgent: config.userAgent)

func makeDownloader() -> Downloader {
    DownloaderFactory.make(config, client: client)
}

do {
    switch command {
    case "help", "-h", "--help":
        print(
            """
            box-send - PT 批量转种 + 推送下载器（按源站点限速）

            命令:
              sites                 列出配置的站点
              info --detail <url>   解析源站详情页（只解析，不上传）
              run --detail <url> [--site <id>] [--targets a,b] [--skip-reseed] [--skip-push]
                                    转种 + 推下载器
              push --detail <url>   只推下载器（不转种）
              list --site <id>      拉取源站种子列表
              rss-sync              轮询一次 RSS：自动转种 + 推下载器（需在配置里启用 rss）
              gist-sync [--loop]     从 PT-depiler Gist 备份同步 cookie（--loop 常驻轮询）
              import-zip --file <PTD_backup_*.zip> [--password <备份密码>]
                                    导入 PT-depiler「本地备份」zip
              import-watch          扫描配置的备份目录，自动导入新出现的 PTD_backup*.zip（需在配置里启用 zipWatch）
              serve [--port 8088] [--host 127.0.0.1] [--token xxx]
                                    Web 控制台：网页编辑 boxsend.json / 手动转种 / 同步
              test-downloader       测试下载器连接（登录检测）
              cookies               查看本地 cookie 状态
              check-cookies [--site <id>]   检测各站 cookie 是否仍然登录（SPA 站走 API 判定）
              add-cookie --site <id> --cookie "k1=v1; k2=v2"
                                    手动添加/覆盖单个站点的 cookie（浏览器 Cookie 头原文）
              remove-cookie --site <id>     删除单个站点的本地 cookie
              template              生成模板配置 Config/boxsend.json
              notes                 查看最近运行日志

            全局:
              --config <path>       配置文件路径（默认 Config/boxsend.json）
            """
        )

    case "template":
        var c = config
        if c.sourceSites.isEmpty { c.sourceSites = SiteRegistry.prioritySites }
        if let data = try? JSONEncoder().encode(c) {
            let url = URL(fileURLWithPath: configPath)
            try FileManager.default.createDirectory(atPath: url.deletingLastPathComponent().path, withIntermediateDirectories: true)
            try data.write(to: url)
            print("已写入 \(configPath)")
        }

    case "sites":
        for s in config.sourceSites {
            let mark = s.enabled ? "on " : "off"
            print("[\(mark)] \(s.id) (\(s.framework.rawValue)) \(s.url)")
        }
        print("targets: \(config.targetSites.joined(separator: ", "))")
        let d = config.downloader
        print("downloader: \(d.type) @ \(d.url) defaultUpLimit=\(d.defaultUpLimit) siteUpLimits=\(d.siteUpLimits)")

    case "info":
        let detail = required("--detail")
        let pid = opt("--site")
        let p = ReseedPipeline(config: config, cookies: cookies, state: state, downloader: makeDownloader())
        let report = try p.run(detailURL: detail, sourceSiteID: pid, opts: .init(skipReseed: true, skipPush: true))
        print(report.release.summary)
        print("  imdb: \(report.release.imdb ?? "-")  douban: \(report.release.douban ?? "-")  size: \(report.release.size.map { String(format: "%.2f GiB", Double($0) / 1073741824) } ?? "-")")
        print("  kind: \(report.release.kind?.rawValue ?? "-")  genre: \(report.release.genre.isEmpty ? "-" : report.release.genre)  region: \(report.release.region.isEmpty ? "-" : report.release.region)  subtitle: \(report.release.subtitle.isEmpty ? "-" : report.release.subtitle)  forbid: \(report.release.isForbidReseed)")
        let mi = report.release.mediainfo
        let miPreview = mi.isEmpty ? "无" : String(mi.prefix(60)).replacingOccurrences(of: "\n", with: " ")  // 文件内为真实换行
        print("  mediainfo: \(miPreview) …（\(mi.count) 字符）")
        print("  torrent: \(report.release.torrentURL)")
        print("  torrentName: \(report.release.torrentName)  hash: \(Bencode.infoHash(report.torrentData) ?? "-")")
        if let previewSite = opt("--preview") {
            guard let s2 = config.site(previewSite) else { die("未知站点 \(previewSite)") }
            let a2 = SiteRegistry.adapter(for: s2, client: client, debugDir: dataDir)
            print("--- 预览 \(previewSite) 上传字段 ---")
            for (k, v) in try a2.previewUploadFields(report.release) {
                let shown = v.count > 120 ? String(v.prefix(120)) + "…(\(v.count))" : v
                print("  \(k) = \(shown.replacingOccurrences(of: "\\n", with: "\\n    "))")
            }
        }

    case "run", "push":
        let detail = required("--detail")
        var o = ReseedPipeline.Options()
        if command == "push" { o.skipReseed = true }
        if has("--skip-reseed") { o.skipReseed = true }
        if has("--skip-push") { o.skipPush = true }
        if let t = opt("--targets") { o.targets = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        let p = ReseedPipeline(config: config, cookies: cookies, state: state, downloader: makeDownloader())
        let report = try p.run(detailURL: detail, sourceSiteID: opt("--site"), opts: o)
        print(report)

    case "list":
        let sid = required("--site")
        guard let s = config.site(sid) else { die("未知站点 \(sid)") }
        let a = SiteRegistry.adapter(for: s, client: client)
        for r in try a.fetchTorrentList() {
            print("\(r.name)  ->  \(r.detailURL)")
        }

    case "rss-sync":
        guard let rss = config.rss, rss.enabled else { die("配置中未启用 rss（填写 rss.enabled=true 与各源站 passkey）") }
        let poller = RssPoller(config: config, cookies: cookies, state: state, downloader: makeDownloader())
        let results = poller.pollOnce()
        if results.isEmpty {
            print("无新种子")
        }
        for r in results {
            print("\(r.ok ? "OK  " : "FAIL") [\(r.siteID)] \(r.title.prefix(80))")
            print("       \(r.message)")
        }

    case "gist-sync":
        guard let g = config.gistSync else { die("配置中无 gistSync") }
        if g.gistID.isEmpty || g.token.isEmpty { die("gistSync.gistID / token 为空，请先填 Config/boxsend.json") }
        let loop = has("--loop")
        repeat {
            do {
                let sync = GistSync(config: g, client: client)
                let r = try sync.pull(into: cookies, state: state)
                // 本地落盘（web 控制台会按 mtime 热加载该文件）
                if let data = cookies.exportBackupJSON() {
                    try data.write(to: localCookieFile)
                }
                print("[\(ISO8601Time.stamp())] 同步完成: \(r.cookieCount) 条 cookie, hosts=\(r.hosts.joined(separator: ", ")) (备份时间 \(r.backupTime))")
            } catch {
                print("[\(ISO8601Time.stamp())] 同步失败: \(error.localizedDescription)")
            }
            if loop {
                let mins = max(5, g.pollMinutes)
                Thread.sleep(forTimeInterval: Double(mins) * 60)
            }
        } while loop

    case "test-downloader":
        let d = DownloaderFactory.make(config, client: client)
        do {
            print("连接测试: \(try d.testConnection())")
        } catch {
            print("连接测试失败: \(error.localizedDescription)")
            exit(1)
        }

    case "import-zip":
        // 导入 PT-depiler「本地备份」zip（PTD_backup_*.zip）
        let file = required("--file")
        let pw = opt("--password") ?? ""
        let n = try PTDZipImport.importZip(
            url: URL(fileURLWithPath: (file as NSString).expandingTildeInPath),
            password: pw, into: cookies)
        if let data = cookies.exportBackupJSON() {
            try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
            try data.write(to: localCookieFile)
        }
        print("导入完成: \(n) 条 cookie, hosts=\(cookies.hosts().count)")

    case "import-watch":
        guard let zw = config.zipWatch else { die("配置中无 zipWatch（填写 zipWatch.enabled=true 与 dir）") }
        let n = ZipWatcher.scanOnce(dir: zw.dir, password: zw.password, store: cookies, state: state)
        if n.isEmpty {
            print("无新备份")
        } else {
            for f in n { print("已导入: \(f)") }
            if let data = cookies.exportBackupJSON() {
                try? data.write(to: localCookieFile)
            }
        }

    case "cookies":
        if cookies.isEmpty {
            print("本地无 cookie。执行 `box-send gist-sync` 或先配置 gistSync")
        } else {
            for h in cookies.hosts() {
                print("\(h): \(cookies.snapshot()[h]?.count ?? 0) 条")
            }
        }

    case "check-cookies":
        let only = opt("--site")
        let checkClient = HTTPClient(cookies: cookies, userAgent: config.userAgent)
        let sites = config.sourceSites.filter { only == nil || $0.id == only }
        var any = false
        for site in sites {
            guard cookies.cookieHeader(forHost: (URL(string: site.url)?.host ?? site.url)) != nil else {
                print("SKIP [\(site.id)] 本地无该站 cookie")
                continue
            }
            any = true
            let r = CookieCheck.check(site: site, client: checkClient)
            print("\(r.ok ? "OK  " : "FAIL") [\(site.id)] \(r.message)")
        }
        if !any { die("没有可检测的站点 cookie（--site 或同步 cookie 后重试）") }

    case "add-cookie":
        let siteID = required("--site")
        let raw = required("--cookie")
        guard let site = config.site(siteID) else { die("配置里没有站点 id: \(siteID)（用 `box-send sites` 查看）") }
        let host = (URL(string: site.url)?.host ?? site.url).lowercased()
        cookies.importRawString(host: host, raw)
        if let data = cookies.exportBackupJSON() {
            try? data.write(to: localCookieFile, options: .atomic)
        }
        let n = cookies.snapshot()[host]?.count ?? 0
        print("已保存 \(site.name)（\(host)）\(n) 条 cookie（覆盖该站旧值），写入 \(localCookieFile.path)")

    case "remove-cookie":
        let siteID = required("--site")
        guard let site = config.site(siteID) else { die("配置里没有站点 id: \(siteID)") }
        let host = (URL(string: site.url)?.host ?? site.url).lowercased()
        if cookies.removeHost(host) {
            if let data = cookies.exportBackupJSON() {
                try? data.write(to: localCookieFile, options: .atomic)
            }
            print("已删除 \(site.name)（\(host)）的 cookie")
        } else {
            print("\(site.name)（\(host)）本地没有 cookie")
        }

    case "notes":
        for n in state.recentNotes { print(n) }

    case "serve":
        let app = ServeApp(config: config, configPath: configPath, cookies: cookies,
                           state: state, client: client, dataDir: dataDir,
                           token: opt("--token") ?? config.webToken)
        do {
            try app.start(host: opt("--host") ?? "127.0.0.1",
                          port: Int(opt("--port") ?? "8088") ?? 8088)
            app.run()
        } catch {
            die(error.localizedDescription)
        }

    default:
        print("未知命令 \(command)，见 box-send help")
        exit(1)
    }
} catch {
    print("错误: \(error.localizedDescription)")
    exit(1)
}
