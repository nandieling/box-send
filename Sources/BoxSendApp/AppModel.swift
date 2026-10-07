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
    /// 「批量转种」页的源站引用（可选）：勾选后把文本加在每个目标站简介最上面并引用包裹。
    /// 源站简介自带引用的站点不用勾，故为可选项
    @Published var sourceQuoteEnabled = false
    @Published var sourceQuoteText = ""
    /// 强制指定转种源站（nil = 按链接域名自动识别）：站点分组里添加过的站点都能当源站
    @Published var sourceSiteID: String? = nil

    /// 源站菜单纯文案：自动识别时顺带显示识别到的站点，方便确认链接归属
    var sourceSiteLabel: String {
        if let id = sourceSiteID, let s = config.site(id) { return s.name }
        let u = detailURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = config.site(forURL: u) { return "自动（\(s.name)）" }
        return "自动识别"
    }

    @Published var running = false
    @Published var runningStep = ""
    @Published var lastReport: String = ""
    /// 逐站实时状态（运行页卡片显示）：siteID -> 转种状态 / 该站种子推送状态 / 源站推送状态
    @Published var reseedEvents: [String: TargetEvent] = [:]
    @Published var pushEvents: [String: TargetEvent] = [:]
    @Published var sourcePushEvent: TargetEvent? = nil

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
    private var zipTimer: Timer?
    /// 当前背景图片（nil = 纯渐变主题）
    private(set) var backgroundNSImage: NSImage?

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

        // 数据目录以 GUI 自己的 AppPaths.dir 为准：配置里可能留着历史相对值（".boxsend"），
        // 相对路径会让转种失败现场（debug/ 下的响应页与字段清单）落到 GUI 进程的工作目录（"/"）而静默丢失
        config.dataDir = dataDir
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
        sourceQuoteEnabled = config.sourceQuoteEnabled
        sourceQuoteText = config.sourceQuoteText
        reloadBackgroundImage()
        refreshCookieStats()
        if config.gistSync != nil {
            lastGistSyncText = state.lastGistSync.map { Self.dateText($0) } ?? "从未同步"
        }
        if config.zipWatch?.enabled == true {
            zipAuto = true
            startZipTimer()
        }
    }

    static func dateText(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
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

    /// 重命名分组（组内站点与排序不受影响）；重名时自动追加数字后缀
    func renameGroup(at index: Int, name: String) {
        guard config.groups.indices.contains(index) else { return }
        let base = name.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return }
        var finalName = base
        var n = 2
        while config.groups.enumerated().contains(where: { $0.offset != index && $0.element.name == finalName }) {
            finalName = "\(base)\(n)"
            n += 1
        }
        config.groups[index].name = finalName
        saveConfig()
    }

    func removeGroup(at index: Int) {
        guard config.groups.indices.contains(index) else { return }
        let members = config.groups[index].sites
        config.groups.remove(at: index)
        // 组内站点移回「批量添加站点」列表：按名称默认序插入排序，不产生「无分组」区块
        var returned: [String] = []
        for id in members where config.site(id)?.managed == true {
            if let i = config.sourceSites.firstIndex(where: { $0.id == id }) {
                config.sourceSites[i].managed = false
            }
            selectedTargets.remove(id)
            returned.append(id)
        }
        reinsertUnmanagedOrder(returned)
        saveConfig()
    }

    /// 站点移回「批量添加站点」列表：按名称默认序插入手动排序（无手动排序 = 恢复名称默认序，
    /// 有手动排序 = 其余站点排序不变、返回站点插到其名称序位置），不追加到末尾
    private func reinsertUnmanagedOrder(_ returnedIDs: [String]) {
        let unmanaged = Set(config.sourceSites.filter { !$0.managed }.map { $0.id })
        let returned = returnedIDs.filter { unmanaged.contains($0) }
        guard !returned.isEmpty else { return }
        let valid = config.unmanagedSiteOrder.filter { unmanaged.contains($0) }
        config.unmanagedSiteOrder = NameSort.reinsert(returned, into: valid, name: { config.site($0)?.name ?? $0 })
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

    // MARK: 主题 / 背景图片 / 透明度

    var theme: AppTheme {
        AppTheme.all.first { $0.id == config.appearance.themeID } ?? AppTheme.default
    }

    func setTheme(_ id: String) {
        config.appearance.themeID = id
        saveConfig()
    }

    func setBackgroundOpacity(_ v: Double) {
        config.appearance.bgOpacity = min(max(v, 0), 1)
        saveConfig()
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.allowsMultipleSelection = false
        panel.message = "选择背景图片（覆盖显示，不改变窗口与弹窗大小）"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let img = NSImage(data: data) else { return }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let name = "background.\(ext)"
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: dataDir).appendingPathComponent(name))
        config.appearance.bgImage = name
        backgroundNSImage = img
        saveConfig()
    }

    func clearBackgroundImage() {
        if let name = config.appearance.bgImage {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dataDir).appendingPathComponent(name))
        }
        config.appearance.bgImage = nil
        backgroundNSImage = nil
        saveConfig()
    }

    private func reloadBackgroundImage() {
        guard let name = config.appearance.bgImage,
              let data = try? Data(contentsOf: URL(fileURLWithPath: dataDir).appendingPathComponent(name)),
              let img = NSImage(data: data) else { return }
        backgroundNSImage = img
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
            c.sourceQuoteEnabled = sourceQuoteEnabled
            c.sourceQuoteText = sourceQuoteText
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
        state.clearAllCookieChecks()
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
        state.clearCookieCheck(siteID)
        let n = cookies.snapshot()[host]?.count ?? 0
        state.note("cookies: 单站添加 \(site.id) -> \(n) 条")
        cookieMessage = "已保存 \(site.name)（\(host)）\(n) 条 cookie，已覆盖该站原有 cookie，并启用该站"
        recheckSiteJustSaved(siteID)
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
        state.clearCookieCheck(siteID)
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

    /// 从站点列表移除（保留 cookie 与启用状态，之后可再次添加；站点移回批量添加列表，按名称默认序插入排序）
    func removeManagedSite(_ id: String) {
        guard let i = config.sourceSites.firstIndex(where: { $0.id == id }) else { return }
        config.sourceSites[i].managed = false
        for g in config.groups.indices { config.groups[g].sites.removeAll { $0 == id } }
        selectedTargets.remove(id)
        reinsertUnmanagedOrder([id])
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
        // 检测顺序 = 界面上分组的排列顺序（组内按卡片顺序，未分组最后）
        let ordered = sites.sortedBySiteGroup(groups: config.groups, id: { $0.id })
        let pending = ordered.filter { site in
            site.enabled
                && !siteChecking.contains(site.id)
                && (force || siteCheckResults[site.id] == nil)
                && hasCredential(for: site, jar: cookieJar)
        }
        guard !pending.isEmpty else { onDone?(); return }
        let gen = checkGeneration &+ 1
        checkGeneration = gen
        let ids = pending.map(\.id)
        siteChecking.formUnion(ids)
        Task.detached {
            var i = 0
            while i < pending.count {
                let batch = Array(pending[i..<min(i + 4, pending.count)])
                var results: [String: SiteCookieCheckResult] = [:]
                await withTaskGroup(of: (String, Bool, String).self) { group in
                    for site in batch {
                        group.addTask {
                            // 每站一个连接池 + 时长上限：卡死的站不拖累同批其它站
                            let r = await CookieCheck.checked(site: site, cookies: cookieJar,
                                                             userAgent: cfg.userAgent)
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
                var stopped = false
                await MainActor.run {
                    stopped = self.checkGeneration != gen
                    for (id, res) in r {
                        self.siteCheckResults[id] = res
                        self.state.setCookieCheck(siteID: id, ok: res.ok, message: res.message)
                    }
                    self.siteChecking.subtract(r.keys)
                    if isLast || stopped {
                        // 停止检测：清掉本轮全部待检站的「检测中」状态（已完成批次的结果保留），并照常回调 onDone
                        self.siteChecking.subtract(ids)
                        onDone?()
                    }
                }
                if stopped { break }
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

    /// 是否有可检测凭据：API Key 站（馒头等）看 key；cookie 站看 cookie
    private func hasCredential(for site: SiteConfig, jar: CookieStore) -> Bool {
        if siteUsesAPIKey(site) {
            return !(site.apiKey ?? "").isEmpty
        }
        return jar.cookieHeader(forHost: siteHost(site)) != nil
    }

    /// 批量检测代号：每轮检测开始 +1；旧的批次循环比对它决定是否退出（「停止检测」）
    private var checkGeneration = 0

    /// 停止当前批量检测：进行中的批次仍会完成，其余站点回到「未检测」
    func stopChecking() { checkGeneration &+= 1 }

    func groupChecking(_ gi: Int) -> Bool {
        groupMembers(gi).contains { siteChecking.contains($0.id) }
    }

    func hasCookie(for site: SiteConfig) -> Bool {
        cookies.cookieHeader(forHost: siteHost(site)) != nil
    }

    /// 该站已有 cookie 原文（「手动添加」弹窗预填用）
    func existingCookieHeader(for site: SiteConfig) -> String {
        cookies.cookieHeader(forHost: siteHost(site)) ?? ""
    }

    // MARK: API Key（M-Team 等 API 连接站点）

    func siteUsesAPIKey(_ site: SiteConfig) -> Bool {
        // 参考内置表合并后的 override（馒头等 API 站用户配置里未必带 overrides）
        let es = SiteRegistry.effectiveSite(site)
        return (es.overrides?.apiBase ?? "") != "" || (es.overrides?.usesAPIKey == true)
    }

    func siteAPIKey(_ site: SiteConfig) -> String {
        site.apiKey ?? ""
    }

    func setSiteAPIKey(_ value: String, siteID: String) {
        guard let i = config.sourceSites.firstIndex(where: { $0.id == siteID }) else { return }
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        config.sourceSites[i].apiKey = v.isEmpty ? nil : v
        saveConfig()
    }

    /// 弹窗保存 API Key：覆盖旧值、启用该站、作废旧检测结果（与 addSiteCookie 行为对齐）
    func saveSiteAPIKey(siteID: String, raw: String) {
        guard let site = config.site(siteID) else {
            cookieMessage = "未配置的站点 id: \(siteID)"
            return
        }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else {
            cookieMessage = "先粘贴该站的 API Key"
            return
        }
        var cfg = config
        if let i = cfg.sourceSites.firstIndex(where: { $0.id == siteID }) {
            cfg.sourceSites[i].apiKey = v
            cfg.sourceSites[i].enabled = true
            cfg.sourceSites[i].managed = true
        }
        if !cfg.targetSites.contains(siteID) { cfg.targetSites.append(siteID) }
        config = cfg
        selectedTargets.insert(siteID)
        saveConfig()
        siteCheckResults[siteID] = nil
        state.clearCookieCheck(siteID)
        state.note("api: 单站 \(site.id) key 已更新")
        cookieMessage = "已保存 \(site.name) 的 API Key，并启用该站"
  
        recheckSiteJustSaved(siteID)
    }

    /// 弹窗保存后立刻单站复检：卡片状态当场反映凭据真假，不用等全局检测排到它
    private func recheckSiteJustSaved(_ siteID: String) {
        guard let fresh = config.site(siteID) else { return }
        checkSitesCookies([fresh], force: true)
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

    enum CookieSource { case gist, cookieCloud, both }

    func gistSyncNow() { syncCookies(from: .gist) }

    /// 互补同步：
    /// 1. 后台拉取来源备份（不阻塞主线程）
    /// 2. 本地 cookie 已检测为有效 → 保留本地，不被备份中的旧值覆盖（同步不新增失效）
    /// 3. 其余站点导入备份值
    /// 4. 全部重检后，仍失效的站点自动用「另一来源」补充
    func syncCookies(from source: CookieSource) {
        guard !cookieSyncBusy else { return }
        let cfg = config
        let label: String
        switch source {
        case .gist: label = "Gist"
        case .cookieCloud: label = "CookieCloud"
        case .both: label = "Cookie"
        }
        cookieSyncBusy = true
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let raws: [String: String]
                let timeText: String
                var failedNotes: [String] = []
                var alternates: [String: String] = [:]
                var alternateLabel = "CookieCloud"
                if source == .both {
                    let f = try Self.fetchBothSources(cfg: cfg)
                    raws = f.raws
                    alternates = f.alternates
                    alternateLabel = f.alternateLabel
                    timeText = f.timeText
                    failedNotes = f.failedNotes
                    if f.gistOK {
                        await MainActor.run {
                            self.state.setLastGistSync(Date().timeIntervalSince1970)
                            self.lastGistSyncText = Self.dateText(self.state.lastGistSync ?? 0)
                        }
                    }
                } else {
                    let f = try Self.fetchSourceRaw(source: source, cfg: cfg)
                    raws = f.raws
                    timeText = f.timeText
                    if source == .gist {
                        await MainActor.run {
                            self.state.setLastGistSync(Date().timeIntervalSince1970)
                            self.lastGistSyncText = Self.dateText(self.state.lastGistSync ?? 0)
                        }
                    }
                }
                await MainActor.run {
                    let (imported, kept, keptValid) = self.mergedImportCookies(raws)
                    let removed = self.trimCookiesToEnabled()
                    self.persistCookies()
                    self.refreshCookieStats()
                    var msg = "\(label) 同步成功：导入/更新 \(imported) 个站点"
                    if keptValid > 0 { msg += "，本地有效无需变更 \(keptValid) 个" }
                    if kept - keptValid > 0 { msg += "，其余无变化 \(kept - keptValid) 个" }
                    if !timeText.isEmpty { msg += "（\(timeText)）" }
                    if removed > 0 { msg += "；已清理 \(removed) 个未启用站点的 cookie" }
                    if !failedNotes.isEmpty { msg += "；部分来源未成功：\(failedNotes.joined(separator: "；"))" }
                    self.cookieMessage = msg
                    self.checkSitesCookies(self.managedSites, force: true) {
                        if source == .both {
                            // 两个来源都导入完了，但同名 cookie 只能留一份：
                            // 检测仍失败的站点用另一来源那份重试，谁被站点认可就用谁
                            self.rescueInvalidSites(alternates: alternates, label: alternateLabel, cfg: cfg) { ids in
                                Task { @MainActor in
                                    self.cookieSyncBusy = false
                                    guard !ids.isEmpty else { return }
                                    self.persistCookies()
                                    self.refreshCookieStats()
                                    let names = ids.compactMap { cfg.site($0)?.name }.joined(separator: "、")
                                    self.cookieMessage = msg + "；\(ids.count) 个失效站点改用 \(alternateLabel) 的 cookie 后通过：\(names)"
                                    self.checkSitesCookies(self.managedSites.filter { ids.contains($0.id) }, force: true)
                                }
                            }
                        } else {
                            let other: CookieSource = (source == .gist) ? .cookieCloud : .gist
                            Task { @MainActor in
                                self.crossFillInvalid(from: other, baseMessage: msg)
                            }
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

    /// 同时拉取 Gist + CookieCloud（Gist 优先，CookieCloud 补齐 Gist 没有的条目）；单来源失败不中断。
    /// 被压住的另一份（同站点另一来源的值）留在 alternates 里：本地检测失败时拿它重试（见 rescueInvalidSites）。
    nonisolated private static func fetchBothSources(cfg: AppConfig) throws -> (raws: [String: String], alternates: [String: String], alternateLabel: String, timeText: String, failedNotes: [String], gistOK: Bool) {
        var merged: [String: String] = [:]
        var alternates: [String: String] = [:]
        var alternateLabel = "CookieCloud"
        var timeText = ""
        var failedNotes: [String] = []
        var gistOK = false
        do {
            let g = try fetchSourceRaw(source: .gist, cfg: cfg)
            merged = g.raws
            timeText = g.timeText
            gistOK = true
        } catch {
            failedNotes.append("Gist（\(error.localizedDescription)）")
        }
        do {
            let c = try fetchSourceRaw(source: .cookieCloud, cfg: cfg)
            for (k, v) in c.raws {
                if merged[k] == nil { merged[k] = v }
                else if merged[k] != v { alternates[k] = v }     // 同名不同值：留待实测裁决
            }
        } catch {
            failedNotes.append("CookieCloud（\(error.localizedDescription)）")
        }
        if !gistOK, let g = try? fetchSourceRaw(source: .gist, cfg: cfg) {
            // Gist 这次没拉到，但 CookieCloud 拉到了：Gist 独有的站点照常导入，
            // 两边都有的站点先按 CookieCloud 装，冲突值留给实测裁决
            for (k, v) in g.raws {
                if merged[k] == nil { merged[k] = v } else { alternates[k] = v }
            }
            alternateLabel = "Gist"
        }
        guard !merged.isEmpty else {
            throw BoxSendError.badInput(failedNotes.joined(separator: "；"))
        }
        return (merged, alternates, alternateLabel, timeText, failedNotes, gistOK)
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
        case .both:
            fatalError("fetchBothSources 会拆分为两个单来源拉取")
        }
    }

    /// Gist 解密后的 {host: [cookie...]} JSON → {host: "k=v; k=v"}
    nonisolated static func rawStrings(from cookieJSON: Data) throws -> [String: String] {
        guard let obj = (try? JSONSerialization.jsonObject(with: cookieJSON)) as? [String: Any] else {
            throw BoxSendError.badInput("Gist 备份解密内容不是 JSON（备份密码可能不正确）")
        }
        let map = (obj["cookies"] as? [String: Any]) ?? obj
        return CookieRawMerge.rawStrings(map: map.filter { !$0.key.lowercased().hasPrefix("http") })
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

    /// 互补合并导入（按单条 cookie 名称做并集，不再整站替换）：
    /// - 本地无 cookie -> 导入备份全量
    /// - 本地有 cookie -> 同名取备份新值（刷新 cf_clearance 一类会过期的令牌），
    ///   仅本地存在的名称保留（防止不完整备份把本地有效 cookie 冲掉，如备份只有 cf_clearance）
    /// 返回 (导入/更新站点数, 无变化保留站点数, 其中已检测有效的数)
    func mergedImportCookies(_ raws: [String: String]) -> (imported: Int, kept: Int, keptValid: Int) {
        var imported = 0
        var kept = 0
        var keptValid = 0
        for (host, raw) in raws {
            guard !raw.isEmpty else { continue }
            guard let site = managedSites.first(where: { Self.hostMatches(siteHost($0), host) }) else { continue }
            // API 站点（馒头）照旧同步 cookie：取种/检测走 API Key，但发种（/api/torrent/createOredit）只有 web 会话可用
            let changed = cookies.mergeRawString(host: siteHost(site), raw)
            if changed {
                imported += 1
            } else {
                kept += 1
                if siteCheckResults[site.id]?.ok == true || (state.cookieCheck(site.id)?.ok ?? false) {
                    keptValid += 1
                }
            }
        }
        return (imported: imported, kept: kept, keptValid: keptValid)
    }

    /// 检测仍失效的站点：用另一来源那份 cookie 在副本上重试检测，站点认它才写回本地。
    /// Gist（PT-depiler 云端备份）与 CookieCloud（浏览器实时备份）谁新谁旧没有规律，
    /// 固定优先级必然把过期那份留下（烧包实测：浏览器已换新 cookie，Gist 里还是旧的），
    /// 所以让站点自己裁决。
    func rescueInvalidSites(alternates: [String: String], label: String, cfg: AppConfig,
                            onDone: @escaping ([String]) -> Void) {
        let cases: [(site: SiteConfig, host: String, raw: String)] = managedSites.compactMap { site in
            guard site.enabled, siteCheckResults[site.id]?.ok == false else { return nil }
            guard let raw = alternates.first(where: { Self.hostMatches(siteHost(site), $0.key) })?.value else { return nil }
            return (site, siteHost(site), raw)
        }
        guard !cases.isEmpty else { onDone([]); return }
        let jar = cookies
        Task.detached {
            var rescued: [String] = []
            for item in cases {
                let trial = CookieStore()
                if let data = jar.exportBackupJSON() { _ = try? trial.importBackupJSON(data) }
                _ = trial.mergeRawString(host: item.host, item.raw)
                let r = await CookieCheck.checked(site: item.site, cookies: trial, userAgent: cfg.userAgent)
                if r.ok {
                    _ = jar.mergeRawString(host: item.host, item.raw)
                    rescued.append(item.site.id)
                }
            }
            await MainActor.run { onDone(rescued) }
        }
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
                    let (filled, _, _) = self.mergedImportCookies(subset)
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

    // MARK: cookie 检测
    @Published var cookieChecking = false
    @Published var cookieCheckLines: [String] = []
    public struct SiteCookieCheckResult: Equatable {
        public var ok: Bool
        public var message: String
        /// 站点超时 / 5xx / 连不上：不能判定 cookie 是否失效（检测文案统一带「未确认」）
        public var unconfirmed: Bool { !ok && message.contains("未确认") }
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
            // 单站检测同样有时长上限
            let r = await CookieCheck.checked(site: site, cookies: cookieJar, userAgent: cfg.userAgent)
            await MainActor.run {
                self.siteChecking.remove(siteID)
                self.siteCheckResults[siteID] = SiteCookieCheckResult(ok: r.ok, message: r.message)
                self.state.setCookieCheck(siteID: siteID, ok: r.ok, message: r.message)
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
                for (id, res) in results {
                    self.state.setCookieCheck(siteID: id, ok: res.ok, message: res.message)
                }
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
        let quote = sourceQuoteEnabled ? sourceQuoteText : ""
        let pickedSource = sourceSiteID
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
            o.sourceQuote = quote
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
                let report = try pipeline.run(detailURL: url, sourceSiteID: pickedSource, opts: o)
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
