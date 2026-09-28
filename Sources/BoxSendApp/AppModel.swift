import Foundation
import Combine
import BoxSendKit
import SwiftUI

/// GUI 应用核心模型：配置读写 / cookie 导入 / 转种执行 / 日志
@MainActor
final class AppModel: ObservableObject {

    // MARK: 配置
    @Published var config: AppConfig
    @Published var configError: String? = nil

    // MARK: cookie
    @Published var cookieHosts: [String] = []
    @Published var cookieCounts: [String: Int] = [:]
    @Published var cookieMessage: String? = nil
    @Published var lastGistSyncText: String = ""
    @Published var gistAuto: Bool = false

    // MARK: 运行
    @Published var detailURL: String = ""
    @Published var selectedTargets: Set<String> = []
    @Published var doReseed = true
    @Published var doPush = true
    @Published var running = false
    @Published var runningStep = ""
    @Published var lastReport: String = ""

    // MARK: 下载器
    @Published var testingDownloader = false
    @Published var downloaderTestResult: String? = nil

    // MARK: 日志
    @Published var notes: [String] = []

    let configPath: String
    let dataDir: String
    private var cookies = CookieStore()
    private let state: StateStore
    private var gistTimer: Timer?

    init() {
        dataDir = AppPaths.dir
        configPath = AppPaths.configFile
        var cfg = AppConfig.load(path: AppPaths.configFile)
        if cfg == nil {
            // 首次运行：从内置优先站模板生成
            cfg = AppConfig.template()
            if let data = try? JSONEncoder().encode(cfg!) {
                try? FileManager.default.createDirectory(atPath: AppPaths.dir, withIntermediateDirectories: true)
                try? data.write(to: URL(fileURLWithPath: AppPaths.configFile))
            }
        }
        config = cfg!

        // 恢复本地 cookie 缓存
        let cookieFile = URL(fileURLWithPath: dataDir).appendingPathComponent("cookies.json")
        if let data = try? Data(contentsOf: cookieFile) {
            _ = try? cookies.replace(from: data)
        }

        state = StateStore(dataDir: dataDir)
        state.onNote = { [weak self] line in
            DispatchQueue.main.async {
                guard let self else { return }
                self.notes.append(line)
                if self.notes.count > 300 {
                    self.notes.removeFirst(self.notes.count - 300)
                }
            }
        }
        notes = state.recentNotes
        selectedTargets = Set(config.targetSites)
        refreshCookieStats()
        if config.gistSync != nil {
            lastGistSyncText = state.lastGistSync.map { Self.dateText($0) } ?? "从未同步"
        }
    }

    static func dateText(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    // MARK: 配置

    /// 各站限速（整数 MB/s，0 = 不限速）
    var siteUpLimitMBInt: [String: Int] {
        var out: [String: Int] = [:]
        for s in config.sourceSites {
            let v = config.downloader.siteUpLimits[s.id] ?? 0
            out[s.id] = Int((Double(v) / 1048576.0).rounded())
        }
        return out
    }

    func setSiteUpLimitMBInt(_ mb: Int?, siteID: String) {
        config.downloader.siteUpLimits[siteID] = Int64(mb ?? 0) * 1_048_576
    }

    // MARK: 分组

    func groupIndex(of siteID: String) -> Int {
        config.groups.firstIndex { $0.sites.contains(siteID) } ?? -1
    }

    func setGroup(index: Int, for siteID: String) {
        for i in config.groups.indices where i != index {
            config.groups[i].sites.removeAll { $0 == siteID }
        }
        if index >= 0, index < config.groups.count,
           !config.groups[index].sites.contains(siteID) {
            config.groups[index].sites.append(siteID)
        }
        saveConfig()
    }

    func addGroup(name: String, upLimitMB: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        config.groups.append(GroupConfig(name: trimmed, upLimitMB: max(0, upLimitMB)))
        saveConfig()
    }

    func removeGroup(at index: Int) {
        guard config.groups.indices.contains(index) else { return }
        config.groups.remove(at: index)
        saveConfig()
    }

    func saveConfig() {
        do {
            var c = config
            var targets = config.targetSites.filter { selectedTargets.contains($0) }
            // 保持原有顺序，加入新勾选的
            for s in config.sourceSites where selectedTargets.contains(s.id) && !targets.contains(s.id) {
                targets.append(s.id)
            }
            c.targetSites = targets
            config = c
            let data = try JSONEncoder().encode(c)
            try FileManager.default.createDirectory(atPath: AppPaths.dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
            configError = nil
        } catch {
            configError = "配置保存失败: \(error.localizedDescription)"
        }
    }

    // MARK: cookie

    func refreshCookieStats() {
        let snap = cookies.snapshot()
        cookieHosts = snap.keys.sorted()
        cookieCounts = snap.mapValues { $0.count }
    }

    var cookieTotal: Int { cookieCounts.values.reduce(0, +) }

    func importZipFile(_ url: URL, password: String) {
        do {
            let n = try PTDZipImport.importZip(url: url, password: password, into: cookies)
            persistCookies()
            refreshCookieStats()
            cookieMessage = "导入成功：\(n) 条 cookie（\(cookies.hosts().count) 个站点）"
            state.note("cookies: 导入 PT-depiler 本地备份 \(url.lastPathComponent) -> \(n) 条")
        } catch {
            cookieMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    func clearCookies() {
        cookies.clear()
        persistCookies()
        refreshCookieStats()
        cookieMessage = "已清空本地 cookie"
    }

    private func persistCookies() {
        if let data = cookies.exportBackupJSON() {
            try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: dataDir).appendingPathComponent("cookies.json"), options: .atomic)
        }
    }

    func gistSyncNow() {
        guard let g = config.gistSync, !g.gistID.isEmpty else {
            cookieMessage = "先在上方填写 Gist 配置（gistID + token + 备份密码）"
            return
        }
        Task {
            do {
                let client = HTTPClient(cookies: CookieStore(), userAgent: config.userAgent)
                let r = try GistSync(config: g, client: client).pull(into: cookies, state: state)
                persistCookies()
                refreshCookieStats()
                cookieMessage = "Gist 同步成功：\(r.cookieCount) 条 cookie（备份时间 \(r.backupTime)）"
                lastGistSyncText = Self.dateText(state.lastGistSync ?? 0)
            } catch {
                cookieMessage = "Gist 同步失败：\(error.localizedDescription)"
            }
        }
    }

    func setGistAuto(_ on: Bool) {
        gistAuto = on
        gistTimer?.invalidate()
        gistTimer = nil
        if on {
            let mins = max(5, config.gistSync?.pollMinutes ?? 30)
            gistTimer = Timer.scheduledTimer(withTimeInterval: Double(mins) * 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.gistSyncNow() }
            }
        }
    }

    // MARK: 下载器

    func testDownloader() {
        saveConfig()
        testingDownloader = true
        downloaderTestResult = nil
        Task {
            do {
                let client = HTTPClient(cookies: cookies, userAgent: config.userAgent)
                let d = DownloaderFactory.make(config, client: client)
                downloaderTestResult = "成功: " + (try d.testConnection())
            } catch {
                downloaderTestResult = "失败: " + error.localizedDescription
            }
            testingDownloader = false
        }
    }

    // MARK: 运行

    func run() {
        let url = detailURL.trimmingCharacters(in: .whitespaces)
        guard url.hasPrefix("http") else {
            configError = "请先粘贴一个种子详情页链接（如 https://…/details.php?id=…）"
            return
        }
        saveConfig()
        guard !running else { return }
        running = true
        runningStep = "解析源站详情…"
        let targets = config.targetSites.filter { selectedTargets.contains($0) }
        let cfg = config
        let cookieJar = cookies
        let st = state
        let doR = doReseed, doP = doPush
        Task.detached {
            let pipeline = ReseedPipeline(config: cfg, cookies: cookieJar, state: st,
                                          downloader: DownloaderFactory.make(cfg,
                                             client: HTTPClient(cookies: cookieJar, userAgent: cfg.userAgent)))
            var o = ReseedPipeline.Options()
            o.skipReseed = !doR
            o.skipPush = !doP
            o.targets = targets.isEmpty ? nil : targets
            let reportText: String
            do {
                let report = try pipeline.run(detailURL: url, sourceSiteID: nil, opts: o)
                reportText = report.description
            } catch {
                reportText = "失败: \(error.localizedDescription)"
            }
            // 同步回主模型的 cookie（运行中可能刷新 Set-Cookie）
            await MainActor.run {
                self.cookies.mergeFrom(cookieJar)
                self.refreshCookieStats()
                self.lastReport = reportText
                self.running = false
                self.runningStep = ""
                self.notes = st.recentNotes
                if let data = self.cookies.exportBackupJSON() {
                    try? data.write(to: URL(fileURLWithPath: self.dataDir).appendingPathComponent("cookies.json"), options: .atomic)
                }
            }
        }
    }

    func clearNotes() { notes = [] }
}

extension CookieStore {
    /// 把另一个 jar 的全部 host 并入本 jar（运行期间 Set-Cookie 回写用）
    func mergeFrom(_ other: CookieStore) {
        for (host, cs) in other.snapshot() {
            importCookies(host: host, cookies: cs)
        }
    }
}
