import Foundation
import Combine
import BoxSendKit
import SwiftUI
import AppKit

/// GUI 应用核心模型：配置读写 / cookie 导入 / 转种执行 / 日志
@MainActor
final class AppModel: ObservableObject {

    // MARK: 配置
    @Published var config: AppConfig
    @Published var configError: String? = nil

    // MARK: cookie
    @Published var cookieHosts: [String] = []
    @Published var cookieCounts: [String: Int] = [:]
    /// 底部提示条与 cookie 卡片共用这一条：写入即重新计时，几分钟后自己收
    /// （时长由核心的 StickyMessage 定），界面末尾还有个「关闭」可以立刻收掉
    @Published var cookieMessage: String? = nil {
        didSet {
            if suppressStickyRecord { return }
            if let v = cookieMessage, !v.isEmpty { cookieSticky.show(v) } else { cookieSticky.dismiss() }
        }
    }
    private var cookieSticky = StickyMessage()
    /// 计时器回写显示值时别再被 didSet 当成「新提示」重新计时
    private var suppressStickyRecord = false
    private var cookieExpireTimer: Timer?
    @Published var lastGistSyncText: String = ""
    @Published var gistAuto: Bool = false

    // MARK: 运行
    /// 逐站实时状态（转种 / 推送两行）：短文案 + 阶段 + 完整详情，见 ReseedPipeline.SiteStatus
    typealias TargetEvent = ReseedPipeline.SiteStatus
    /// 转种成功但需要人工注意的提示（siteID -> 文案）
    @Published var siteWarnings: [String: String] = [:]
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
    /// 正在测哪一台（卡片上显示「测试中…」）
    @Published var testingDownloaderID: String? = nil
    /// 逐台连接检测结果：下载器 id -> 一句话
    @Published var downloaderTestResults: [String: String] = [:]
    @Published var testingTMDB = false
    @Published var tmdbTestResult: String? = nil

    // MARK: 服务器 SSH 测速
    /// 「测试上传速度」（批量转种页）/「测试连接并测速」（下载器页）进行中
    @Published var testingSSH = false
    /// 测速结果一句话（成功=速度信息，失败=原因）；两页共用这一句，避免两套措辞
    @Published var sshTestResult: String? = nil

    // MARK: 软件更新
    @Published var checkingUpdate = false
    @Published var updateResult: String? = nil
    @Published var updateRelease: SoftwareUpdate.Release? = nil

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

    /// 十秒一次问核心那份规则「这条提示还在时限内吗」，过期就把界面清空
    private func startCookieExpireTimer() {
        cookieExpireTimer?.invalidate()
        cookieExpireTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickCookieMessage() }
        }
    }

    private func tickCookieMessage() {
        let next = cookieSticky.current()
        guard next != cookieMessage else { return }
        suppressStickyRecord = true
        cookieMessage = next
        suppressStickyRecord = false
    }

    /// 底部提示条末尾那个「关闭」：cookie 提示与配置报错一起收，
    /// 下次真出事会重新冒出来，不会一按就永久哑掉
    func dismissBottomMessage() {
        suppressStickyRecord = true
        cookieSticky.dismiss()
        cookieMessage = nil
        configError = nil
        suppressStickyRecord = false
    }

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

        // 底部那条 cookie 提示到点自己收（显示时长在核心的 StickyMessage 里）
        startCookieExpireTimer()

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
        startAssistAutoTimer()
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
        // 启动后顺手查一次更新（可在「设置 → 软件更新」里关掉）：只弹一行结果，不打扰
        if config.autoUpdateCheck {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.checkForUpdate(silent: true)
            }
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
            let v = config.reseedDownloader.siteUpLimits[s.id] ?? 0
            out[s.id] = Int((Double(v) / 1048576.0).rounded())
        }
        return out
    }

    func setSiteUpLimitMBInt(_ mb: Int?, siteID: String) {
        config.mutateReseedDownloader { $0.siteUpLimits[siteID] = Int64(mb ?? 0) * 1_048_576 }
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

    /// 本次批次实际会转种的站点：勾选 + 已开启（与 run() 取目标的口径一致）
    var runTargets: [SiteConfig] {
        config.targetSites.compactMap { config.site($0) }
            .filter { selectedTargets.contains($0.id) && $0.enabled }
    }

    /// 勾选覆盖到的分组名（组内至少有一个「已开启且被勾选」的站点；没归组的算「无分组」）
    var runSelectedGroupNames: [String] {
        var names: [String] = []
        for gi in config.groups.indices {
            if groupMembers(gi).contains(where: { $0.enabled && selectedTargets.contains($0.id) }) {
                names.append(config.groups[gi].name)
            }
        }
        if unassignedManagedSites.contains(where: { $0.enabled && selectedTargets.contains($0.id) }) {
            names.append("无分组")
        }
        return names
    }

    /// 运行页「开始运行」旁的批次概览：选了几个分组、几个站点（防止误选分组就跑）
    var runSelectionSummary: String {
        let sites = runTargets.count
        guard sites > 0 else { return "未选择站点" }
        let groups = runSelectedGroupNames.count
        return groups > 0 ? "已选 \(groups) 个分组 · \(sites) 个站点" : "已选 \(sites) 个站点"
    }

    /// 勾选的目标站中「附加信息 / 其它信息」只放手填源站引用的站点（cmct、劳改所）
    var targetsNeedingSourceQuote: [SiteConfig] {
        config.sourceSites.filter {
            $0.managed && selectedTargets.contains($0.id) && SiteRegistry.needsSourceQuoteField($0)
        }
    }

    /// 运行页提示：这些站的附加信息只由源站引用 + 源简介引用块组成，两处都没会留空
    var sourceQuoteHint: String? {
        let filled = sourceQuoteEnabled
            && !sourceQuoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !filled else { return nil }
        let names = targetsNeedingSourceQuote.map(\.name)
        guard !names.isEmpty else { return nil }
        return "\(names.joined(separator: "、")) 的「附加信息」= 源站引用 + 源简介自带引用块："
            + "两处都没有内容时该区块留空，可能被站方打回"
    }

    /// 未分组的已添加站点（辅种站点由核心一并排除）
    var unassignedManagedSites: [SiteConfig] { config.unassignedManagedSites }

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
        config.mutateReseedDownloader { d in
            for id in ids where d.siteUpLimits[id] == nil {
                d.siteUpLimits[id] = Int64(defaultMB) * 1_048_576
            }
        }
        guard changed else { return }
        saveConfig()
    }

    // MARK: 辅种站点（「站点分组」页底部的辅种区块，不进分组）

    // 名单读写都在核心 AppConfig 里（Windows 走桥接调同一份实现）
    var assistManagedSites: [SiteConfig] { config.assistManagedSites }

    /// 辅种区块的「添加站点」：入站点池但不进分组，并记入辅种白名单
    func addAssistSites(_ ids: [String]) {
        config.addAssistSites(ids)
        saveConfig()
    }

    /// 从辅种区块移除：退出辅种；站点不在任何分组时一并移出站点池
    func removeAssistSite(_ id: String) {
        config.removeAssistSite(id)
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
        config.assist?.siteIDs.removeAll { $0 == id }
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

    /// 是否有可检测凭据：API Key 站（馒头等）看 key；cookie 站看 cookie；
    /// 可乐这类两种都收的站，cookie 与 Key 任有一样就算有凭据
    private func hasCredential(for site: SiteConfig, jar: CookieStore) -> Bool {
        if modelOnlyAPIKey(site) {
            return !(site.apiKey ?? "").isEmpty
        }
        let hasCookie = jar.cookieHeader(forHost: siteHost(site)) != nil
        if siteAcceptsAPIKey(site) { return hasCookie || !(site.apiKey ?? "").isEmpty }
        return hasCookie
    }

    /// 只认 API Key 的站（馒头、肉丝）：cookie 对它没意义
    private func modelOnlyAPIKey(_ site: SiteConfig) -> Bool {
        let es = SiteRegistry.effectiveSite(site)
        return (es.overrides?.apiBase ?? "") != "" || (es.overrides?.usesAPIKey == true)
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

    /// 界面当前按哪种凭据显示：key-only 站是 Key；可乐这类站填过 Key 就按 Key，否则按 cookie
    func siteUsesAPIKey(_ site: SiteConfig) -> Bool {
        if modelOnlyAPIKey(site) { return true }
        return siteAcceptsAPIKey(site) && !siteAPIKey(site).isEmpty
    }

    /// 该站能不能填 API Key（可乐：cookie 与 Key 都收，界面要多给一个 Key 页签）
    func siteAcceptsAPIKey(_ site: SiteConfig) -> Bool {
        modelOnlyAPIKey(site) || siteAcceptsOptionalAPIKey(site)
    }

    /// 该站是否「cookie 与 API Key 都收」（可乐）：状态行要说「能转种」，别说「API 已连接」
    func siteAcceptsOptionalAPIKey(_ site: SiteConfig) -> Bool {
        SiteRegistry.effectiveSite(site).overrides?.apiKeyOptional == true
    }

    func siteAPIKey(_ site: SiteConfig) -> String {
        site.apiKey ?? ""
    }

    /// 清空该站的某种凭据（手动弹窗里把文本删空再保存就会走到这儿）
    func clearSiteCredential(siteID: String, apiKey: Bool) {
        guard let site = config.site(siteID) else {
            cookieMessage = "未配置的站点 id: \(siteID)"
            return
        }
        if apiKey {
            guard !(site.apiKey ?? "").isEmpty else {
                cookieMessage = "\(site.name) 本来就没填 API Key"
                return
            }
            var cfg = config
            if let i = cfg.sourceSites.firstIndex(where: { $0.id == siteID }) {
                cfg.sourceSites[i].apiKey = nil
            }
            config = cfg
            cookieMessage = "已清空 \(site.name) 的 API Key"
        } else {
            let host = siteHost(site)
            guard cookies.cookieHeader(forHost: host) != nil else {
                cookieMessage = "\(site.name) 本地没有 cookie 可清"
                return
            }
            _ = cookies.removeHost(host)
            cookieMessage = "已清空 \(site.name) 的 cookie"
        }
        // 凭据变了，旧的检测结论不能再留着显示
        siteCheckResults[siteID] = nil
        state.clearCookieCheck(siteID)
        state.note("api: 单站 \(siteID) \(apiKey ? "key" : "cookie") 已清空")
    }

    func setSiteAPIKey(_ value: String, siteID: String) {
        guard let i = config.sourceSites.firstIndex(where: { $0.id == siteID }) else { return }
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        config.sourceSites[i].apiKey = v.isEmpty ? nil : v
        saveConfig()
    }

    /// 弹窗保存 API Key：覆盖旧值、启用该站、作废旧检测结果（与 addSiteCookie 行为对齐）。
    /// 文本删空再保存 = 清空这把 Key（可乐那类站要能在 Key / cookie 之间来回切，
    /// 清不掉就只能一直撞「Key 没发种权限」那面墙）。
    func saveSiteAPIKey(siteID: String, raw: String) {
        guard let site = config.site(siteID) else {
            cookieMessage = "未配置的站点 id: \(siteID)"
            return
        }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty {
            clearSiteCredential(siteID: siteID, apiKey: true)
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

    func setVpsFreeGB(_ gb: Int?, downloaderID: String) {
        updateDownloader(downloaderID) { $0.vpsFreeGB = (gb == nil || (gb ?? 0) <= 0) ? nil : gb }
    }
    func setVpsFreeMargin(_ gb: Int?, downloaderID: String) {
        updateDownloader(downloaderID) { $0.sizeGuardMarginGB = max(0, gb ?? 0) }
    }

    // MARK: 多下载器
    //
    // 发种推的那台和辅种扫的那台经常不是同一台机器：VPS 上只放正在做的片，家里那台存全量。
    // 主下载器一直存在 config.downloader（id = "main"），附加的进 config.downloaders。

    var downloaderList: [DownloaderConfig] { config.allDownloaders }
    /// 界面上摆哪几台：多下载器本就是为辅种才需要的，辅种收起时只摆发种那台
    var visibleDownloaders: [DownloaderConfig] {
        AssistFeature.enabled ? config.allDownloaders : [config.reseedDownloader]
    }
    func downloader(_ id: String) -> DownloaderConfig { config.downloaderEntry(id: id) }
    /// 主下载器不可删（老配置就这一台，删了整个软件就没下载器了）
    func canRemoveDownloader(_ id: String) -> Bool { id != config.downloader.id }

    /// 每台都直接显示、直接改，不再需要先选「正在编辑哪一台」
    func updateDownloader(_ id: String, _ change: (inout DownloaderConfig) -> Void) {
        var d = config.downloaderEntry(id: id)
        change(&d)
        config.updateDownloader(d)
        saveConfig()
    }

    /// 新建一台：照主下载器抄一份骨架，地址与账号留空让人填（新卡片立刻出现在列表里）
    func addDownloader() {
        let id = "dl-" + String(Int(Date().timeIntervalSince1970 * 1000) % 1_000_000_000)
        var d = config.downloader.copiedAs(id: id, name: config.nextDownloaderName())
        d.url = ""
        d.username = ""
        d.password = ""
        d.vpsFreeGB = nil
        config.updateDownloader(d)
        saveConfig()
    }

    func removeDownloader(_ id: String) {
        guard canRemoveDownloader(id) else { return }
        config.removeDownloader(id: id)
        downloaderTestResults[id] = nil
        if testingDownloaderID == id { testingDownloaderID = nil }
        saveConfig()
    }

    /// 某个用途改用哪台（role: reseed / assist）
    func assignDownloader(role: String, id: String) {
        config.assignDownloader(role: role, id: id)
        saveConfig()
    }

    /// 下载器页下拉显示用的当前指派
    func downloaderID(forRole role: String) -> String {
        (role == "assist" ? config.assistDownloader : config.reseedDownloader).id
    }

    /// 逐台测连接：结果按下载器 id 存，卡片各显示各的
    func testDownloader(_ id: String) {
        saveConfig()
        testingDownloaderID = id
        downloaderTestResults[id] = nil
        Task {
            do {
                let client = HTTPClient(cookies: cookies, userAgent: config.userAgent)
                let target = config.downloaderEntry(id: id)
                let d = DownloaderFactory.make(target, client: client)
                downloaderTestResults[id] = "成功（\(target.label)）: " + (try d.testConnection())
            } catch {
                downloaderTestResults[id] = "失败（\(config.downloaderEntry(id: id).label)）: "
                    + error.localizedDescription
            }
            testingDownloaderID = nil
        }
    }

    // MARK: TMDB 反查 / 站点自动免费

    /// TMDB 配置（用户没配过时给一份默认值，界面上直接改）
    var tmdbConfig: TMDBConfig { config.tmdb ?? TMDBConfig() }

    func updateTMDB(_ mutate: (inout TMDBConfig) -> Void) {
        var c = config.tmdb ?? TMDBConfig()
        mutate(&c)
        config.tmdb = c
        saveConfig()
    }

    /// 站点是否支持「发种后自动免费一天」（内置表里配了站内免费链接特征的站，目前只有猫站）
    func siteSupportsAutoFree(_ s: SiteConfig) -> Bool { config.siteSupportsAutoFree(s.id) }

    func siteAutoFree(_ s: SiteConfig) -> Bool { config.siteAutoFree(s.id) }

    func setSiteAutoFree(_ on: Bool, siteID: String) {
        config.setSiteAutoFree(on, siteID: siteID)
        saveConfig()
    }

    /// 拿一条站内已知条目试查（银魂剧场版：tt2374144 / 豆瓣 11615927），验证网关与 key 通不通
    func testTMDB() {
        saveConfig()
        var cfg = tmdbConfig
        cfg.enabled = true
        testingTMDB = true
        tmdbTestResult = nil
        Task {
            let client = HTTPClient(cookies: cookies, userAgent: config.userAgent)
            let r = TMDBResolver(client: client, config: cfg)
            if let link = r.resolve(imdb: "tt2374144", douban: "11615927",
                                    name: "Gekijouban Gintama Kanketsu-hen 2013 1080p Blu-ray") {
                tmdbTestResult = "成功: \(link)"
            } else {
                tmdbTestResult = "失败: " + (r.lastError ?? "TMDB 没有匹配条目")
            }
            testingTMDB = false
        }
    }

    // MARK: 服务器 SSH 测速

    /// SSH 配置（用户没配过时给一份默认值，界面上直接改）
    var sshConfig: SSHConfig { config.ssh ?? SSHConfig() }

    func updateSSH(_ mutate: (inout SSHConfig) -> Void) {
        var c = config.ssh ?? SSHConfig()
        mutate(&c)
        config.ssh = c
        saveConfig()
    }

    /// 选私钥文件：只记路径，不拷进数据目录（ssh 要用原文件本身与它的权限）
    func chooseSSHKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "选择 SSH 私钥（id_ed25519、id_rsa 这类，不带 .pub）"
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if FileManager.default.fileExists(atPath: dir.path) { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateSSH { $0.keyPath = url.path }
    }

    /// 设置页「测试连接并测速」
    func testSSH() {
        saveConfig()
        let cfg = sshConfig
        guard cfg.isConfigured else {
            sshTestResult = "失败: 请先填写服务器地址与用户名"
            return
        }
        testingSSH = true
        sshTestResult = nil
        Task.detached(priority: .utility) {
            // 只报测速信息本身（速度、每轮、连的是哪台机器），转不转由人看一眼决定
            let text: String
            do {
                text = "成功: " + SSHSpeedTest.gateText(try SSHSpeedTest.runTest(cfg),
                                                        loginTarget: cfg.loginTarget).message
            } catch {
                text = "失败: " + SSHSpeedTest.gateFailure(error.localizedDescription,
                                                           loginTarget: cfg.loginTarget).message
            }
            await MainActor.run {
                self.testingSSH = false
                self.sshTestResult = text
            }
        }
    }

    // MARK: 运行

    /// 检查 GitHub Releases 的最新版本。silent = 启动时自动查：没有新版本就什么都不显示。
    func checkForUpdate(silent: Bool = false) {
        saveConfig()
        checkingUpdate = true
        if !silent {
            updateResult = nil
            updateRelease = nil
        }
        let client = HTTPClient(cookies: cookies, userAgent: config.userAgent)
        let current = BoxSendVersion.version
        // GitHub 直连可能要等十几秒，放到后台线程，别冻住界面
        Task.detached(priority: .utility) {
            let outcome = SoftwareUpdate.latest(client: client)
            await MainActor.run {
                self.checkingUpdate = false
                switch outcome {
                case .found(let rel):
                    self.updateRelease = rel
                    if SoftwareUpdate.isNewer(rel.version, than: current) {
                        self.updateResult = "发现新版本 \(rel.version)（当前 \(current)）：\(rel.title)"
                    } else if silent {
                        self.updateResult = nil
                    } else {
                        self.updateResult = "已是最新版本 \(current)"
                    }
                case .failed(let err):
                    if !silent { self.updateResult = "检查失败：\(err)" }
                }
            }
        }
    }

    /// 在默认浏览器里打开链接（发布页 / 安装包）
    func openURL(_ s: String) {
        guard let u = URL(string: s) else { return }
        NSWorkspace.shared.open(u)
    }

    /// 开始一批转种。测速是旁边那个独立按钮，不做成开转的前置条件：不测也能直接跑。
    func run() {
        let url = detailURL.trimmingCharacters(in: .whitespaces)
        guard url.hasPrefix("http") else {
            configError = "请先粘贴一个种子详情页链接（如 https://…/details.php?id=…）"
            return
        }
        saveConfig()
        guard !running else { return }
        startRun(url: url)
    }

    private func startRun(url: String) {
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
        siteWarnings = [:]
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
            o.onSiteEvent = { [weak self] e in
                Task { @MainActor in self?.reseedEvents[e.siteID] = e }
            }
            o.onSitePush = { [weak self] e in
                Task { @MainActor in self?.pushEvents[e.siteID] = e }
            }
            o.onSourcePush = { [weak self] e in
                Task { @MainActor in self?.sourcePushEvent = e }
            }
            o.onSiteWarning = { [weak self] siteID, text in
                Task { @MainActor in
                    self?.siteWarnings[siteID] = text
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

    // MARK: 辅种
    //
    // 辅种不发新种：拿下载器里已有的文件去目标站找同一种子，把站内那条挂到本账号下。
    // 站点请求节奏由 AssistPipeline 里的节流器统一收口，界面只负责发起与显示。

    /// 下载器里扫出来的候选种子
    /// 最近一次扫描的摘要（种子集合变化、各站已辅数）
    @Published var assistSummary: AssistPipeline.ScanSummary? = nil
    /// 本轮计划（当前这一页的格子：一条种子 × 一个站）
    @Published var assistCells: [AssistPipeline.PlanRow] = []
    /// 全量目录计划：去重后的种子目录、各站分桶与整轮计数都在里面
    @Published var assistPlan: AssistPipeline.CatalogPlan?
    /// 界面当前页（0 起）
    @Published var assistPage = 0
    /// 去重前的候选条数（提示「下载器里 N 条，去掉重复后 M 条」）
    @Published var assistTorrentRaw = 0
    /// 逐行进展，key = 站点|种子 hash
    @Published var assistRows: [String: AssistPipeline.Status] = [:]
    @Published var assistScanning = false
    @Published var assistRunning = false
    @Published var assistMessage: String? = nil
    /// 只报告不动下载器
    @Published var assistDryRun = false
    /// 定时自动跑的钟：构造即「刚跑过」，开机后先等满一个周期再自己动
    private var assistAutoRun = AssistAutoRun()
    /// 回查校验 / 否决之后重算计划用的下载器（只建对象，不发请求）
    private func assistPipe(_ cfg: AppConfig, _ jar: CookieStore) -> AssistPipeline {
        AssistPipeline(config: cfg, cookies: jar, state: state,
                       downloader: DownloaderFactory.makeForAssist(cfg, client:
                           HTTPClient(cookies: jar, userAgent: cfg.userAgent)))
    }
    private var assistAutoTimer: Timer?

    var assistConfig: AssistConfig { config.assist ?? AssistConfig(siteIDs: []) }

    /// 逐行进展（交给核心库归类用）
    var assistLive: [String: AssistPipeline.LiveRow] {
        assistRows.mapValues { $0.liveRow }
    }

    /// 界面上的计划：存的那份按扫描那一刻的暂停名单算，界面上按了暂停就按当前
    /// 名单推平一遍再拿去算数，否则点了暂停要重新扫描才看得出来
    private var assistLivePlan: AssistPipeline.CatalogPlan? {
        assistPlan?.applyingPaused(Set(assistConfig.pausedSites))
    }

    /// 顶部那几个数：全量目录 × 当前进展
    var assistStats: AssistPipeline.Tally {
        assistLivePlan?.adjusted(live: assistLive) ?? AssistPipeline.Tally()
    }

    /// 逐站进度：一站一行（铺了多少格、判定多少、还要检索几次、是不是暂停）
    var assistSiteProgress: [AssistPipeline.CatalogPlan.SiteProgress] {
        assistLivePlan?.siteProgress(live: assistLive) ?? []
    }

    /// 正在跑的那条流水线：「停止本轮」按钮拿它递话
    private var assistRunner: AssistPipeline?

    /// 停止本轮：处理完手头这一格就收摊，状态表原样留着
    func assistStop() { assistRunner?.requestStop() }

    /// 本轮请求「已用 / 上限」：跑起来那句「预算还剩多少」用它
    var assistBudget: (used: Int, total: Int) {
        assistRunner?.budget ?? (used: 0, total: assistConfig.roundBudget)
    }

    /// 追加本轮请求预算（只追次数上限，逐站间隔照旧）
    func assistAddBudget(_ n: Int = 200) { assistRunner?.addBudget(max(1, n)) }

    /// 覆盖率与预计：把「还剩多少」翻成「照现在这个节奏还要跑多久」
    var assistCoverage: AssistPipeline.Coverage? {
        guard let plan = assistLivePlan else { return nil }
        return plan.coverage(live: assistLive)
    }

    /// 待处理队列：失败 / 待复核 / 待人工确认 / 已否决，一条一行带按钮
    var assistQueue: [AssistPipeline.QueueItem] {
        guard let plan = assistPlan else { return [] }
        let conf = config
        return AssistPipeline.queueItems(
            state.assistQueueEntries(), live: assistLive,
            siteNames: { id in conf.site(id).map { SiteRegistry.effectiveSite($0).name } ?? id },
            torrents: plan.byHash, timeText: { AppModel.dateText($0) })
    }

    /// 一列几条（设置里改）
    var assistPageSize: Int { max(1, assistConfig.listPageSize) }

    var assistPageCount: Int {
        max(1, ((assistPlan?.torrents.count ?? 0) + assistPageSize - 1) / assistPageSize)
    }

    /// 整库候选条数（去重后）
    var assistTorrentTotal: Int { assistPlan?.torrents.count ?? 0 }

    /// 这一页列出的种子
    var assistShownTorrents: [LocalTorrent] {
        guard let plan = assistPlan else { return [] }
        return Array(plan.torrents.dropFirst(assistPage * assistPageSize).prefix(assistPageSize))
    }

    /// 翻到某一页：只换格子，不重读下载器（上万条要好几秒）
    func assistGoPage(_ page: Int) {
        guard let plan = assistPlan else { return }
        assistPage = min(max(0, page), assistPageCount - 1)
        assistCells = plan.rows(Array(plan.torrents
            .dropFirst(assistPage * assistPageSize).prefix(assistPageSize)))
    }

    /// 改「单页列表条数」并就地重算这一页的格子
    func assistSetPageSize(_ n: Int) {
        assistUpdate { $0.listPageSize = max(1, min(200, n)) }
        assistGoPage(assistPage)
    }

    /// 扫描完 / 跑完一轮后统一发布：目录、页码、这一页的格子
    private func publishAssist(_ plan: AssistPipeline.CatalogPlan, page: Int, raw: Int,
                               summary: AssistPipeline.ScanSummary? = nil) {
        assistPlan = plan
        assistTorrentRaw = raw
        if let summary { assistSummary = summary }
        assistPage = min(max(0, page),
                         max(0, (plan.torrents.count + assistPageSize - 1) / assistPageSize))
        assistCells = plan.rows(Array(plan.torrents
            .dropFirst(assistPage * assistPageSize).prefix(assistPageSize)))
    }

    /// 一格（一条种子 × 一个站）在界面上的结论
    func assistStatus(_ row: AssistPipeline.PlanRow) -> AssistPipeline.RowStatus {
        AssistPipeline.status(of: row, live: assistRows[row.rowKey]?.liveRow)
    }

    /// 回查校验：只问下载器，不发站点请求，随时能点。
    /// 上一轮「推进了下载器却没等到校验结果」的那些条靠它收尾。
    func assistRecheck(keys: Set<String> = []) {
        guard !assistRunning, !assistScanning else { return }
        assistRunning = true
        assistMessage = nil
        let pipe = assistPipe(config, cookies)
        let names: [String: String] = (assistPlan?.byHash ?? [:]).mapValues { $0.name }
        let ids = assistPlan?.siteIDs
        Task.detached(priority: .utility) {
            let report = pipe.recheckReviews(siteIDs: ids, keys: keys, names: names) { s in
                Task { @MainActor in self.assistRows[s.rowKey] = s }
            }
            await MainActor.run {
                self.assistRunning = false
                self.assistMessage = report.text
                self.rebuildAssistPlan()
            }
        }
    }

    /// 重试一条失败的组合：只重跑这一格
    func assistRetry(key: String) {
        let parts = key.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, let t = assistPlan?.byHash[parts[1].lowercased()] else { return }
        runAssist(siteIDs: [String(parts[0])], forceKeys: [], scope: [t])
    }

    /// 人工否决 / 撤销否决一条组合：改状态表后重算这一页的格子
    func assistReject(key: String, rejected: Bool = true) {
        let parts = key.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return }
        let site = String(parts[0]), hash = String(parts[1])
        if rejected {
            state.markAssistReject(site: site, hash: hash)
            assistRows.removeValue(forKey: key)
        } else {
            state.clearAssistReject(site: site, hash: hash)
        }
        rebuildAssistPlan()
    }

    /// 用现有目录重算计划（状态表刚变过，格子结论得跟着变；不重读下载器，那一下要好几秒）
    private func rebuildAssistPlan() {
        guard let old = assistPlan else { return }
        let pipe = assistPipe(config, cookies)
        Task.detached(priority: .utility) {
            let fresh = pipe.planCatalog(old.torrents, siteIDs: old.siteIDs)
            await MainActor.run {
                self.publishAssist(fresh, page: self.assistPage, raw: self.assistTorrentRaw)
            }
        }
    }

    /// 辅种用的是哪台（没填地址时提示去「下载器」页补，免得扫描半天连不上）
    var assistDownloaderName: String {
        let d = config.assistDownloader
        return d.url.isEmpty ? "\(d.label)（还没填地址）" : "\(d.label) · \(d.url)"
    }

    /// 暂停 / 恢复一个辅种站点：改名单之外，把现有计划里的派生数就地推平
    /// （待辅种 ↔ 已暂停、每站还要检索几次、整站归组），点一下卡片立刻变脸，
    /// 不用重跑那一下要好几秒的扫描
    func assistSetPaused(_ siteID: String, paused: Bool) {
        assistUpdate { a in
            if paused {
                if !a.pausedSites.contains(siteID) { a.pausedSites.append(siteID) }
            } else {
                a.pausedSites.removeAll { $0 == siteID }
            }
        }
        guard let next = assistLivePlan else { return }
        assistPlan = next
        assistCells = next.rows(Array(next.torrents
            .dropFirst(assistPage * assistPageSize).prefix(assistPageSize)))
    }

    /// 改辅种设置并落盘（配置里没有 assist 段时先补一份默认值）
    func assistUpdate(_ change: (inout AssistConfig) -> Void) {
        var a = config.assist ?? AssistConfig(siteIDs: [])
        change(&a)
        config.assist = a
        saveConfig()
    }

    /// 扫描下载器并生成本轮计划（不发站点请求）
    func assistScan() {
        guard AssistFeature.enabled else { return }
        guard !assistRunning, !assistScanning else { return }
        assistScanning = true
        assistMessage = nil
        let cfg = config
        let jar = cookies
        let st = state
        Task.detached(priority: .utility) {
            let out: (AssistPipeline.ScanSummary?, AssistPipeline.CatalogPlan?, String)
            let client = HTTPClient(cookies: jar, userAgent: cfg.userAgent)
            let pipe = AssistPipeline(config: cfg, cookies: jar, state: st,
                                      downloader: DownloaderFactory.makeForAssist(cfg, client: client))
            do {
                // 整库都要能翻，所以目录不裁条数；计数走集合运算，上万条也不慢
                let scan = try pipe.scanAndRecord()
                out = (scan, pipe.planCatalog(scan.torrents), "")
            } catch {
                out = (nil, nil, "扫描下载器失败：\(error.localizedDescription)")
            }
            await MainActor.run {
                if let scan = out.0, let plan = out.1 {
                    self.publishAssist(plan, page: 0, raw: scan.count, summary: scan)
                }
                self.assistRows = [:]
                self.assistScanning = false
                self.assistMessage = out.2.isEmpty ? out.0?.deltaText : out.2
            }
        }
    }

    /// 执行辅种（跑配置里勾选的站点）。跑完顺手重算一次计划，
    /// 「已辅过 / 站内没有」这些标记才会跟着变。
    func assistRun() {
        let ids = enabledAssistSites
        guard !ids.isEmpty else {
            assistMessage = "先在「站点分组」页的辅种区块添加站点"
            return
        }
        // 只跑当前这一页：整库上万条一次跑不完，跑眼前这批更可控
        runAssist(siteIDs: ids, forceKeys: [], scope: assistShownTorrents)
    }

    /// 人工采纳一条「待人工确认」：只重跑被点名的这一条，负缓存与「已辅过」预筛都让路
    func assistConfirm(key: String) {
        let site = String(key.split(separator: "|").first ?? "")
        guard !site.isEmpty else { return }
        runAssist(siteIDs: [site], forceKeys: [key])
    }

    /// 一分钟一次的表：到点自己扫一遍再辅一轮。定时跑没人先点「扫描」，
    /// 所以扫描放在执行体里，不依赖界面上的候选。
    func assistTick() {
        let minutes = assistConfig.autoRunMinutes
        guard AssistFeature.enabled, minutes > 0, !assistRunning, !assistScanning,
              assistAutoRun.due(minutes: minutes), !enabledAssistSites.isEmpty else { return }
        assistAutoRun.noteRun()
        runAssist(siteIDs: enabledAssistSites, forceKeys: [])
    }

    /// 距下一轮定时辅种还有几分钟（没开定时返回 nil）
    var assistAutoNext: Int? {
        assistAutoRun.minutesLeft(minutes: assistConfig.autoRunMinutes)
    }

    func startAssistAutoTimer() {
        // 辅种收起时这把钟根本不开：到点不该有人替用户去敲站点的门
        guard AssistFeature.enabled else { return }
        guard assistAutoTimer == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.assistTick() }
        RunLoop.main.add(t, forMode: .common)
        assistAutoTimer = t
    }

    private var enabledAssistSites: [String] {
        assistConfig.siteIDs.filter { id in config.site(id)?.enabled == true }
    }

    /// forceKeys 非空 = 人工采纳的单条重跑：不清空别的行进展，也不重画整表计划
    private func runAssist(siteIDs ids: [String], forceKeys: Set<String>,
                           scope: [LocalTorrent]? = nil) {
        guard !assistRunning, !assistScanning else { return }
        assistRunning = true
        assistMessage = forceKeys.isEmpty ? nil : "已采纳，重新核对这一条…"
        if forceKeys.isEmpty { assistRows = [:] }
        let cfg = config
        let jar = cookies
        let st = state
        let dry = assistDryRun
        let forceHashes = Set(forceKeys.compactMap { $0.split(separator: "|").last }.map(String.init))
        // 流水线在主线程建好并记下来：跑到一半时「停止本轮」才找得到它
        let pipe = assistPipe(cfg, jar)
        assistRunner = pipe
        Task.detached(priority: .utility) {
            var o = AssistPipeline.Options()
            o.siteIDs = ids
            o.dryRun = dry
            o.forceKeys = forceKeys
            o.onEvent = { s in
                Task { @MainActor in self.assistRows[s.rowKey] = s }
            }
            let all: [LocalTorrent]
            do {
                all = try pipe.scanCandidates()
            } catch {   // 整份清单只用来记账，本轮跑的是裁过的那批
                await MainActor.run {
                    self.assistRunning = false
                    self.assistRunner = nil
                    self.assistMessage = "扫描下载器失败：\(error.localizedDescription)"
                }
                return
            }
            let picked: [LocalTorrent] = forceHashes.isEmpty
                ? (scope ?? AssistPipeline.roundCandidates(all))
                : all.filter { forceHashes.contains($0.hash) }
            // 格子始终按配置里的辅种站点铺（单条采纳也只重跑一条，不该把表缩成一个站）
            var planIDs = cfg.assist?.siteIDs ?? ids
            for id in ids where !planIDs.contains(id) { planIDs.append(id) }
            planIDs = planIDs.filter { cfg.site($0)?.enabled == true }
            // 先按计划铺一版目录：跑的过程中进展就往格子上盖
            let opening = pipe.planCatalog(all, siteIDs: planIDs)
            Task { @MainActor in self.publishAssist(opening, page: self.assistPage, raw: all.count) }
            let report = pipe.run(torrents: picked, opts: o)
            // 目录按新状态重算：已辅过 / 站内没有 这两张表都会变，页码原地不动
            let fresh = pipe.planCatalog(all, siteIDs: planIDs)
            let summary = pipe.recordScan(torrents: all)
            let text = (dry ? "预演结束：" : "辅种结束：")
                + "成功 \(report.assistedCount)，待人工确认 \(report.pendingCount)，"
                + "跳过 \(report.skippedCount)，站点请求 \(report.requests) 次"
                + (pipe.relaxedHits > 0 ? "，其中 \(pipe.relaxedHits) 条换宽松查询词才找到" : "")
                + (report.stopped ? "（已手动停止本轮）" : "")
            await MainActor.run {
                self.cookies.mergeFrom(jar)
                self.publishAssist(fresh, page: self.assistPage, raw: all.count, summary: summary)
                self.assistRunning = false
                self.assistRunner = nil
                self.assistMessage = text
                self.notes = st.recentNotes
                if let data = self.cookies.exportBackupJSON() {
                    try? data.write(to: URL(fileURLWithPath: self.dataDir).appendingPathComponent("cookies.json"),
                                    options: .atomic)
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
