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
    public struct TargetEvent: Equatable {
        public var text: String
        public var ok: Bool?    // nil = 进行中
    }
    @Published var detailURL: String = ""
    @Published var selectedTargets: Set<String> = []
    @Published var doReseed = true
    @Published var doPush = true
    @Published var running = false
    @Published var runningStep = ""
    @Published var lastReport: String = ""
    /// 逐站实时状态（运行页卡片显示）：siteID -> 转种状态 / 该站种子推送状态 / 源站推送状态
    @Published var reseedEvents: [String: TargetEvent] = [:]
    @Published var pushEvents: [String: TargetEvent] = [:]
    @Published var sourcePushEvent: TargetEvent? = nil

    // MARK: RSS 自动转种
    @Published var rssAuto = false
    @Published var rssRunning = false
    @Published var rssMessage: String? = nil

    // MARK: 备份目录监控
    @Published var zipAuto = false
    @Published var zipRunning = false
    @Published var zipMessage: String? = nil

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
    private var rssTimer: Timer?
    private var zipTimer: Timer?

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
        if config.rss?.enabled == true {
            rssAuto = true
            startRssTimer()
        }
        if config.zipWatch?.enabled == true {
            zipAuto = true
            startZipTimer()
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

    /// 拖拽排序分组：把名为 dragged 的分组移到 target 之前
    func moveGroup(named dragged: String, before target: String) {
        guard dragged != target,
              let from = config.groups.firstIndex(where: { $0.name == dragged }),
              let to = config.groups.firstIndex(where: { $0.name == target }) else { return }
        config.groups.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        saveConfig()
    }

    /// 分组内站点排序：把 siteID 移到 targetID 之前（无分组时在 sourceSites 整体顺序中移动）
    func moveSite(_ siteID: String, before targetID: String) {
        guard siteID != targetID else { return }
        let gi = groupIndex(of: siteID)
        if gi >= 0 {
            let sites = config.groups[gi].sites
            guard let from = sites.firstIndex(of: siteID),
                  let to = sites.firstIndex(of: targetID) else { return }
            config.groups[gi].sites.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        } else {
            let ids = config.sourceSites.map { $0.id }
            guard let from = ids.firstIndex(of: siteID),
                  let to = ids.firstIndex(of: targetID) else { return }
            config.sourceSites.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        saveConfig()
    }

    /// 按序号排序分组内站点卡片（gi = -1 为无分组区块）
    func sortGroupSites(_ gi: Int, by nums: [String: Int]) {
        func stableSorted(_ ids: [String]) -> [String] {
            let indexed = ids.enumerated().map { (offset: $0.offset, id: $0.element) }
            return indexed.sorted { a, b in
                let na = nums[a.id] ?? Int.max
                let nb = nums[b.id] ?? Int.max
                if na != nb { return na < nb }
                return a.offset < b.offset
            }.map { $0.id }
        }
        if gi >= 0, config.groups.indices.contains(gi) {
            config.groups[gi].sites = stableSorted(config.groups[gi].sites)
        } else {
            let order = unassignedManagedSites.map { $0.id }
            var remaining = stableSorted(order)
            config.sourceSites = config.sourceSites.map { site in
                guard order.contains(site.id) else { return site }
                let newID = remaining.removeFirst()
                return config.sourceSites.first { $0.id == newID } ?? site
            }
        }
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
            // 勾选为目标即自动启用（内置表新站默认 enabled=false，避免还要手动开开关）
            c.sourceSites = c.sourceSites.map { site in
                var site = site
                if targets.contains(site.id) && !site.enabled { site.enabled = true }
                return site
            }
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
            let removed = trimCookiesToEnabled()
            persistCookies()
            refreshCookieStats()
            cookieMessage = "导入成功：\(n) 条 cookie（\(cookies.hosts().count) 个站点）" + (removed > 0 ? "；已清理 \(removed) 个未启用站点的 cookie" : "")
            state.note("cookies: 导入 PT-depiler 本地备份 \(url.lastPathComponent) -> \(n) 条")
        } catch {
            cookieMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    func clearCookies() {
        cookies.clear()
        siteCheckResults = [:]
        persistCookies()
        refreshCookieStats()
        cookieMessage = "已清空本地 cookie"
    }

    // MARK: 单站 cookie（手动添加 / 删除）

    func siteHost(_ site: SiteConfig) -> String {
        (URL(string: site.url)?.host ?? site.url).lowercased()
    }

    func addSiteCookie(siteID: String, raw: String) {
        guard let site = config.site(siteID) else {
            cookieMessage = "未配置的站点 id: \(siteID)"
            return
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            cookieMessage = "先粘贴该站的 cookie 内容"
            return
        }
        let host = siteHost(site)
        cookies.importRawString(host: host, text)
        // 添加 cookie 即视为使用该站：启用并加入转种目标（未勾选项下次运行前仍可取消）
        var cfg = config
        if let i = cfg.sourceSites.firstIndex(where: { $0.id == siteID }) {
            cfg.sourceSites[i].enabled = true
            cfg.sourceSites[i].managed = true
        }
        if !cfg.targetSites.contains(siteID) { cfg.targetSites.append(siteID) }
        config = cfg
        selectedTargets.insert(siteID)
        saveConfig()
        persistCookies()
        refreshCookieStats()
        siteCheckResults[siteID] = nil   // cookie 已变，旧检测结果作废
        let n = cookies.snapshot()[host]?.count ?? 0
        state.note("cookies: 单站添加 \(site.id) -> \(n) 条")
        cookieMessage = "已保存 \(site.name)（\(host)）\(n) 条 cookie，已覆盖该站原有 cookie，并启用该站"
    }

    func removeSiteCookies(siteID: String) {
        guard let site = config.site(siteID) else {
            cookieMessage = "未配置的站点 id: \(siteID)"
            return
        }
        let host = siteHost(site)
        guard cookies.removeHost(host) else {
            cookieMessage = "\(site.name)（\(host)）本地还没有 cookie"
            return
        }
        persistCookies()
        refreshCookieStats()
        siteCheckResults[siteID] = nil
        state.note("cookies: 单站删除 \(site.id)")
        cookieMessage = "已删除 \(site.name)（\(host)）的 cookie"
    }

    // MARK: 站点开关 / 排序 / 添加

    /// 开启/停用站点：停用的站不参与转种目标、cookie 检测与同步
    func setSiteEnabled(siteID: String, _ on: Bool) {
        guard let i = config.sourceSites.firstIndex(where: { $0.id == siteID }) else { return }
        config.sourceSites[i].enabled = on
        if !on {
            // 停用即移出本次运行勾选；saveConfig 会把 targetSites 一并修剪
            selectedTargets.remove(siteID)
        }
        saveConfig()
    }

    /// 用户已添加的站点（「站点」页展示；未添加的站只在内置名录中）
    var managedSites: [SiteConfig] { config.sourceSites.filter { $0.managed } }

    /// 未分组的已添加站点
    var unassignedManagedSites: [SiteConfig] {
        managedSites.filter { groupIndex(of: $0.id) < 0 }
    }

    /// 分组的已添加站点（按 group.sites 顺序）；gi = -1 返回未分组
    func groupMembers(_ gi: Int) -> [SiteConfig] {
        if gi < 0 { return unassignedManagedSites }
        guard config.groups.indices.contains(gi) else { return [] }
        return config.groups[gi].sites.compactMap { id in
            config.sourceSites.first { $0.id == id && $0.managed }
        }
    }

    /// 批量添加内置站点到指定分组（gi = -1 不分组）；添加即默认开启
    func addManagedSites(_ ids: [String], group gi: Int) {
        guard !ids.isEmpty else { return }
        var changed = false
        config.sourceSites = config.sourceSites.map { site in
            var site = site
            if ids.contains(site.id) {
                site.managed = true
                site.enabled = true
                changed = true
            }
            return site
        }
        if gi >= 0, config.groups.indices.contains(gi) {
            for other in config.groups.indices where other != gi {
                config.groups[other].sites.removeAll { ids.contains($0) }
            }
            for id in ids where !config.groups[gi].sites.contains(id) {
                config.groups[gi].sites.append(id)
            }
        }
        // 新增站点默认限速：取所在分组的「上传限速」（未设 = 10 MB/s）；已有单独设置的保留
        let defaultMB = (gi >= 0 && config.groups.indices.contains(gi) && config.groups[gi].upLimitMB > 0)
            ? config.groups[gi].upLimitMB : 10
        for id in ids where config.downloader.siteUpLimits[id] == nil {
            config.downloader.siteUpLimits[id] = Int64(defaultMB) * 1_048_576
        }
        guard changed else { return }
        saveConfig()
    }

    /// 分组内站点批量开启/关闭（gi = -1 未分组）
    func setGroupSitesEnabled(_ gi: Int, on: Bool) {
        for s in groupMembers(gi) where s.enabled != on {
            setSiteEnabled(siteID: s.id, on)
        }
    }

    /// 移除分组内当前已选中（开启）的站点（gi = -1 未分组），返回移除数
    @discardableResult
    func removeEnabledSitesInGroup(_ gi: Int) -> Int {
        let members = groupMembers(gi).filter { $0.enabled }
        for s in members { removeManagedSite(s.id) }
        return members.count
    }

    /// 从站点列表移除（保留 cookie 与启用状态，之后可再次添加）
    func removeManagedSite(_ id: String) {
        guard let i = config.sourceSites.firstIndex(where: { $0.id == id }) else { return }
        config.sourceSites[i].managed = false
        for g in config.groups.indices { config.groups[g].sites.removeAll { $0 == id } }
        selectedTargets.remove(id)
        saveConfig()
    }

    /// 手动排序：所在区块（分组内 / 未分组）上下移
    func moveManagedSite(_ siteID: String, delta: Int) {
        let gi = groupIndex(of: siteID)
        if gi >= 0 {
            let sites = config.groups[gi].sites
            guard let i = sites.firstIndex(of: siteID) else { return }
            let j = i + delta
            guard sites.indices.contains(j) else { return }
            config.groups[gi].sites.swapAt(i, j)
        } else {
            let order = unassignedManagedSites.map { s in s.id }
            guard let k = order.firstIndex(of: siteID) else { return }
            let kk = k + delta
            guard order.indices.contains(kk) else { return }
            let idA = config.sourceSites.firstIndex { $0.id == siteID }
            let idB = config.sourceSites.firstIndex { $0.id == order[kk] }
            if let a = idA, let b = idB { config.sourceSites.swapAt(a, b) }
        }
        saveConfig()
    }

    /// 区块内位置（上下按钮禁用判断）
    func managedSitePosition(_ siteID: String) -> (index: Int, count: Int) {
        let gi = groupIndex(of: siteID)
        if gi >= 0 {
            let sites = config.groups[gi].sites
            if let i = sites.firstIndex(of: siteID) { return (i, sites.count) }
        } else {
            let order = unassignedManagedSites.map { s in s.id }
            if let k = order.firstIndex(of: siteID) { return (k, order.count) }
        }
        return (-1, 0)
    }

    /// 批量 cookie 检测（每批 4 个并发）；force = 已检测过的也重新检测（分组「检测」按钮用）；
    /// onDone = 全部检测完成后在主线程回调（无可检站点时立即回调）
    func checkSitesCookies(_ sites: [SiteConfig], force: Bool = false, onDone: (() -> Void)? = nil) {
        let cookieJar = cookies
        let cfg = config
        let pending = sites.filter { site in
            site.enabled
                && !siteChecking.contains(site.id)
                && (force || siteCheckResults[site.id] == nil)
                && cookieJar.cookieHeader(forHost: siteHost(site)) != nil
        }
        guard !pending.isEmpty else { onDone?(); return }
        siteChecking.formUnion(pending.map(\.id))
        Task.detached {
            let client = HTTPClient(cookies: cookieJar, userAgent: cfg.userAgent)
            var i = 0
            while i < pending.count {
                let batch = Array(pending[i..<min(i + 4, pending.count)])
                var results: [String: SiteCookieCheckResult] = [:]
                await withTaskGroup(of: (String, Bool, String).self) { group in
                    for site in batch {
                        group.addTask {
                            let r = CookieCheck.check(site: site, client: client)
                            return (site.id, r.ok, r.message)
                        }
                    }
                    for await (id, ok, message) in group {
                        results[id] = SiteCookieCheckResult(ok: ok, message: message)
                    }
                }
                i += 4
                let r = results
                let isLast = i >= pending.count
                await MainActor.run {
                    for (id, res) in r { self.siteCheckResults[id] = res }
                    self.siteChecking.subtract(r.keys)
                    if isLast { onDone?() }
                }
            }
        }
    }

    /// 进入站点分组页时自动检测已添加且未检测的站
    func autoCheckSites() {
        checkSitesCookies(managedSites, force: false)
    }

    /// 分组批量检测（gi = -1 为无分组区块）
    func checkGroupCookies(_ gi: Int) {
        checkSitesCookies(groupMembers(gi), force: true)
    }

    /// 全局检测：所有分组已添加的站点（强制重检）
    func checkAllManagedCookies() {
        checkSitesCookies(managedSites, force: true)
    }

    var anyChecking: Bool { !siteChecking.isEmpty }

    func groupChecking(_ gi: Int) -> Bool {
        groupMembers(gi).contains { siteChecking.contains($0.id) }
    }

    func hasCookie(for site: SiteConfig) -> Bool {
        cookies.cookieHeader(forHost: siteHost(site)) != nil
    }

    /// 同步导入后只保留已启用站点的 cookie（PT-depiler 全量备份含用户未启用的站）；返回清理的站点数
    @discardableResult
    func trimCookiesToEnabled() -> Int {
        let hosts = Set(config.sourceSites.filter(\.enabled).map { siteHost($0) })
        var removed = 0
        for host in cookies.hosts() where !hosts.contains(host) {
            _ = cookies.removeHost(host)
            removed += 1
        }
        return removed
    }

    private func persistCookies() {
        if let data = cookies.exportBackupJSON() {
            try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: dataDir).appendingPathComponent("cookies.json"), options: .atomic)
        }
    }

    // MARK: Cookie 同步（Gist / CookieCloud 互为补充；拉取全程后台线程，不卡 UI）

    @Published var cookieSyncBusy = false

    enum CookieSource { case gist, cookieCloud }

    func gistSyncNow() { syncCookies(from: .gist) }

    /// 互补同步：
    /// 1. 后台拉取来源备份（不阻塞主线程）
    /// 2. 本地 cookie 已检测为有效 → 保留本地，不被备份中的旧值覆盖（同步不新增失效）
    /// 3. 其余站点导入备份值
    /// 4. 全部重检后，仍失效的站点自动用「另一来源」补充
    func syncCookies(from source: CookieSource) {
        guard !cookieSyncBusy else { return }
        let cfg = config
        let other: CookieSource = (source == .gist) ? .cookieCloud : .gist
        let label = (source == .gist) ? "Gist" : "CookieCloud"
        cookieSyncBusy = true
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let f = try Self.fetchSourceRaw(source: source, cfg: cfg)
                await MainActor.run {
                    let (imported, kept) = self.mergedImportCookies(f.raws)
                    if source == .gist {
                        self.state.setLastGistSync(Date().timeIntervalSince1970)
                        self.lastGistSyncText = Self.dateText(self.state.lastGistSync ?? 0)
                    }
                    let removed = self.trimCookiesToEnabled()
                    self.persistCookies()
                    self.refreshCookieStats()
                    var msg = "\(label) 同步成功：导入 \(imported) 个站点"
                    if kept > 0 { msg += "，保留本地有效 \(kept) 个" }
                    if !f.timeText.isEmpty { msg += "（\(f.timeText)）" }
                    if removed > 0 { msg += "；已清理 \(removed) 个未启用站点的 cookie" }
                    self.cookieMessage = msg
                    self.checkSitesCookies(self.managedSites, force: true) {
                        Task { @MainActor in
                            self.crossFillInvalid(from: other, baseMessage: msg)
                        }
                    }
                }
            } catch {
                Task { @MainActor in
                    self.cookieMessage = "\(label) 同步失败：\(error.localizedDescription)"
                    self.cookieSyncBusy = false
                }
            }
        }
    }

    /// 后台拉取来源 → {host: "k=v; k=v"}（timeText 仅 Gist 有备份时间）
    nonisolated private static func fetchSourceRaw(source: CookieSource, cfg: AppConfig) throws -> (raws: [String: String], timeText: String) {
        let client = HTTPClient(cookies: CookieStore(), userAgent: cfg.userAgent)
        switch source {
        case .gist:
            guard let g = cfg.gistSync, !g.gistID.isEmpty else {
                throw BoxSendError.badInput("先在 Cookie 页填写 Gist 配置（gistID + token + 备份密码）")
            }
            let f = try GistSync(config: g, client: client).fetch()
            return (try rawStrings(from: f.data), "备份时间 \(f.backupTime)")
        case .cookieCloud:
            guard let cc = cfg.cookieCloud,
                  !cc.host.trimmingCharacters(in: .whitespaces).isEmpty,
                  !cc.key.trimmingCharacters(in: .whitespaces).isEmpty,
                  !cc.password.isEmpty else {
                throw BoxSendError.badInput("先在 Cookie 页填写 CookieCloud 配置（服务器地址 + KEY + 加密密码）")
            }
            return (try CookieCloudSync(config: cc, client: client).fetch(), "")
        }
    }

    /// Gist 解密后的 {host: [cookie...]} JSON → {host: "k=v; k=v"}
    nonisolated static func rawStrings(from cookieJSON: Data) throws -> [String: String] {
        guard let obj = (try? JSONSerialization.jsonObject(with: cookieJSON)) as? [String: Any] else {
            throw BoxSendError.badInput("Gist 备份解密内容不是 JSON（备份密码可能不正确）")
        }
        let map = (obj["cookies"] as? [String: Any]) ?? obj
        var out: [String: String] = [:]
        for (host, value) in map where !host.lowercased().hasPrefix("http") {
            guard let arr = value as? [[String: Any]] else { continue }
            let raw = arr.compactMap { c -> String? in
                guard let n = c["name"] as? String, let v = c["value"] as? String else { return nil }
                return n + "=" + v
            }.joined(separator: "; ")
            if !raw.isEmpty { out[normHost(host)] = raw }
        }
        return out
    }

    nonisolated static func normHost(_ host: String) -> String {
        var h = host.lowercased().trimmingCharacters(in: .whitespaces)
        if h.hasPrefix(".") { h.removeFirst() }
        if let i = h.firstIndex(of: "/") { h = String(h[..<i]) }
        if let i = h.firstIndex(of: ":") { h = String(h[..<i]) }
        return h
    }

    nonisolated static func hostMatches(_ a: String, _ b: String) -> Bool {
        let na = normHost(a), nb = normHost(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        return na == nb || na.hasSuffix("." + nb) || nb.hasSuffix("." + na)
    }

    /// 互补合并导入：本地 cookie 已检测有效 → 保留（防止备份旧值覆盖成新的失效）；否则导入备份值。
    /// 返回 (导入站点数, 保留本地站点数)
    func mergedImportCookies(_ raws: [String: String]) -> (imported: Int, kept: Int) {
        var imported = 0
        var kept = 0
        for (host, raw) in raws {
            guard !raw.isEmpty else { continue }
            guard let site = managedSites.first(where: { Self.hostMatches(siteHost($0), host) }) else { continue }
            if hasCookie(for: site) && siteCheckResults[site.id]?.ok == true {
                kept += 1
                continue
            }
            cookies.importRawString(host: siteHost(site), raw)
            imported += 1
        }
        return (imported: imported, kept: kept)
    }

    /// 主同步后仍失效的站点 → 拉「另一来源」补充（另一来源未配置 / 无对应条目时静默结束）
    private func crossFillInvalid(from other: CookieSource, baseMessage: String) {
        let otherLabel = (other == .gist) ? "Gist" : "CookieCloud"
        let invalid = managedSites.filter { site in
            site.enabled
                && hasCookie(for: site)
                && siteCheckResults[site.id].map { !$0.ok } ?? false
        }
        let cfg = config
        guard !invalid.isEmpty else {
            cookieSyncBusy = false
            return
        }
        let hostSet = Set(invalid.map { Self.normHost(siteHost($0)) })
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let f = try Self.fetchSourceRaw(source: other, cfg: cfg)
                let subset = f.raws.filter { hostSet.contains(Self.normHost($0.key)) }
                guard !subset.isEmpty else {
                    Task { @MainActor in
                        self.cookieMessage = baseMessage + "；仍有失效站点，但 \(otherLabel) 没有这些站点的备份"
                        self.cookieSyncBusy = false
                    }
                    return
                }
                await MainActor.run {
                    let (filled, _) = self.mergedImportCookies(subset)
                    _ = self.trimCookiesToEnabled()
                    self.persistCookies()
                    self.refreshCookieStats()
                    self.cookieMessage = baseMessage + "；已用 \(otherLabel) 补充 \(filled) 个失效站点的 cookie"
                    self.checkSitesCookies(invalid, force: true) {
                        Task { @MainActor in self.cookieSyncBusy = false }
                    }
                }
            } catch {
                Task { @MainActor in self.cookieSyncBusy = false }
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

    // MARK: CookieCloud

    @Published var cookieCloudAuto = false
    private var cookieCloudTimer: Timer?

    func cookieCloudNow() { syncCookies(from: .cookieCloud) }

    func setCookieCloudAuto(_ on: Bool) {
        cookieCloudAuto = on
        cookieCloudTimer?.invalidate()
        cookieCloudTimer = nil
        if on {
            let mins = max(5, config.cookieCloud?.pollMinutes ?? 30)
            cookieCloudTimer = Timer.scheduledTimer(withTimeInterval: Double(mins) * 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.cookieCloudNow() }
            }
        }
    }

    // MARK: RSS

    func rssPasskey(_ siteID: String) -> String {
        config.rss?.passkeys[siteID] ?? ""
    }
    func setRssPasskey(_ siteID: String, _ v: String) {
        if config.rss == nil { config.rss = RssConfig() }
        config.rss?.passkeys[siteID] = v
        saveConfig()
    }
    func setRssPollMinutes(_ mins: Int) {
        if config.rss == nil { config.rss = RssConfig() }
        config.rss?.pollMinutes = max(1, mins)
        saveConfig()
        if rssAuto { startRssTimer() }   // 间隔变了，重启定时器
    }
    func setRssAuto(_ on: Bool) {
        rssAuto = on
        if config.rss == nil { config.rss = RssConfig() }
        config.rss?.enabled = on
        saveConfig()
        rssTimer?.invalidate()
        rssTimer = nil
        if on { startRssTimer() }
    }
    private func startRssTimer() {
        let mins = max(1, config.rss?.pollMinutes ?? 10)
        rssTimer = Timer.scheduledTimer(withTimeInterval: Double(mins) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rssPollNow() }
        }
    }
    func rssPollNow() {
        guard !rssRunning else { return }
        guard config.rss?.enabled == true else {
            rssMessage = "先在 RSS 页启用并填写源站 passkey"
            return
        }
        rssRunning = true
        rssMessage = "RSS 轮询中…"
        saveConfig()
        let cfg = config
        let cookieJar = cookies
        let st = state
        Task.detached {
            let d = DownloaderFactory.make(cfg, client: HTTPClient(cookies: cookieJar, userAgent: cfg.userAgent))
            let poller = RssPoller(config: cfg, cookies: cookieJar, state: st, downloader: d)
            let results = poller.pollOnce()
            await MainActor.run {
                self.cookies.mergeFrom(cookieJar)
                self.refreshCookieStats()
                self.persistCookies()
                self.rssRunning = false
                if results.isEmpty {
                    self.rssMessage = "RSS 轮询完成：无新种子"
                } else {
                    let ok = results.filter { $0.ok }.count
                    self.rssMessage = "RSS 轮询完成：\(results.count) 个新种，成功 \(ok) 个"
                }
                self.notes = st.recentNotes
            }
        }
    }

    // MARK: cookie 检测
    @Published var cookieChecking = false
    @Published var cookieCheckLines: [String] = []
    public struct SiteCookieCheckResult: Equatable {
        public var ok: Bool
        public var message: String
    }
    /// 「站点分组」页逐站检测的结果（siteID -> 结果）
    @Published var siteCheckResults: [String: SiteCookieCheckResult] = [:]
    @Published var siteChecking: Set<String> = []

    func checkCookie(siteID: String) {
        guard let site = config.site(siteID), !siteChecking.contains(siteID) else { return }
        let cookieJar = cookies
        let cfg = config
        siteChecking.insert(siteID)
        Task.detached {
            let client = HTTPClient(cookies: cookieJar, userAgent: cfg.userAgent)
            let r = CookieCheck.check(site: site, client: client)
            await MainActor.run {
                self.siteChecking.remove(siteID)
                self.siteCheckResults[siteID] = SiteCookieCheckResult(ok: r.ok, message: r.message)
            }
        }
    }

    func checkCookies() {
        guard !cookieChecking else { return }
        if cookies.isEmpty {
            cookieMessage = "本地还没有 cookie，先同步"
            return
        }
        cookieChecking = true
        cookieCheckLines = []
        let cookieJar = cookies
        let cfg = config
        Task.detached {
            let client = HTTPClient(cookies: cookieJar, userAgent: cfg.userAgent)
            var lines: [String] = []
            var results: [String: SiteCookieCheckResult] = [:]
            for site in cfg.sourceSites where site.enabled {
                guard cookieJar.cookieHeader(forHost: (URL(string: site.url)?.host ?? site.url)) != nil else { continue }
                let r = CookieCheck.check(site: site, client: client)
                lines.append("\(r.ok ? "OK  " : "FAIL") [\(site.id)] \(r.message)")
                results[site.id] = SiteCookieCheckResult(ok: r.ok, message: r.message)
            }
            await MainActor.run {
                self.cookieCheckLines = lines
                self.siteCheckResults.merge(results) { _, new in new }
                self.cookieChecking = false
            }
        }
    }

    // MARK: 备份目录监控

    func zipDir() -> String { config.zipWatch?.dir ?? "~/Downloads" }
    func setZipDir(_ v: String) {
        if config.zipWatch == nil { config.zipWatch = ZipWatchConfig() }
        config.zipWatch?.dir = v
        saveConfig()
    }
    func zipPassword() -> String { config.zipWatch?.password ?? "" }
    func setZipPassword(_ v: String) {
        if config.zipWatch == nil { config.zipWatch = ZipWatchConfig() }
        config.zipWatch?.password = v
        saveConfig()
    }
    func setZipPollMinutes(_ mins: Int) {
        if config.zipWatch == nil { config.zipWatch = ZipWatchConfig() }
        config.zipWatch?.pollMinutes = max(1, mins)
        saveConfig()
        if zipAuto { startZipTimer() }
    }
    func setZipAuto(_ on: Bool) {
        zipAuto = on
        if config.zipWatch == nil { config.zipWatch = ZipWatchConfig() }
        config.zipWatch?.enabled = on
        saveConfig()
        zipTimer?.invalidate()
        zipTimer = nil
        if on { startZipTimer() }
    }
    private func startZipTimer() {
        let mins = max(1, config.zipWatch?.pollMinutes ?? 5)
        zipTimer = Timer.scheduledTimer(withTimeInterval: Double(mins) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.zipScanNow() }
        }
    }
    func zipScanNow() {
        guard !zipRunning else { return }
        guard config.zipWatch?.enabled == true else {
            zipMessage = "先在 Cookie 页启用备份目录监控并填写目录"
            return
        }
        zipRunning = true
        zipMessage = "扫描备份目录…"
        saveConfig()
        let dir = config.zipWatch?.dir ?? "~/Downloads"
        let pw = config.zipWatch?.password ?? ""
        let cookieJar = cookies
        let st = state
        Task.detached {
            let imported = ZipWatcher.scanOnce(dir: dir, password: pw, store: cookieJar, state: st)
            await MainActor.run {
                self.cookies.mergeFrom(cookieJar)
                let removed = self.trimCookiesToEnabled()
                self.refreshCookieStats()
                self.persistCookies()
                self.zipRunning = false
                let base = imported.isEmpty ? "扫描完成：无新备份" : "扫描完成：已导入 \(imported.joined(separator: ", "))"
                self.zipMessage = base + (removed > 0 ? "；已清理 \(removed) 个未启用站点的 cookie" : "")
                self.notes = st.recentNotes
            }
        }
    }

    // MARK: 下载器

    func setVpsFreeGB(_ gb: Int?) {
        config.downloader.vpsFreeGB = (gb == nil || (gb ?? 0) <= 0) ? nil : gb
        saveConfig()
    }
    func setVpsFreeMargin(_ gb: Int?) {
        config.downloader.sizeGuardMarginGB = max(0, gb ?? 0)
        saveConfig()
    }

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
        let targets = config.targetSites.filter { selectedTargets.contains($0) && config.site($0)?.enabled == true }
        let cfg = config
        let cookieJar = cookies
        let st = state
        let doR = doReseed, doP = doPush
        reseedEvents = [:]
        pushEvents = [:]
        sourcePushEvent = nil
        Task.detached {
            let pipeline = ReseedPipeline(config: cfg, cookies: cookieJar, state: st,
                                          downloader: DownloaderFactory.make(cfg,
                                             client: HTTPClient(cookies: cookieJar, userAgent: cfg.userAgent)))
            var o = ReseedPipeline.Options()
            o.skipReseed = !doR
            o.skipPush = !doP
            o.targets = targets.isEmpty ? nil : targets
            o.onSiteEvent = { [weak self] siteID, text, ok in
                Task { @MainActor in
                    self?.reseedEvents[siteID] = TargetEvent(text: text, ok: ok)
                }
            }
            o.onSitePush = { [weak self] siteID, text, ok in
                Task { @MainActor in
                    self?.pushEvents[siteID] = TargetEvent(text: text, ok: ok)
                }
            }
            o.onSourcePush = { [weak self] text, ok in
                Task { @MainActor in
                    self?.sourcePushEvent = TargetEvent(text: text, ok: ok)
                }
            }
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
