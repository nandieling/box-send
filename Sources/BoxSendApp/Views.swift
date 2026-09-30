import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BoxSendKit

// MARK: - 主框架

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            RunView()
                .tabItem { Label("运行", systemImage: "paperplane.fill") }
                .tag(0)
            SitesView()
                .tabItem { Label("站点与限速", systemImage: "server.rack") }
                .tag(1)
            CookiesView()
                .tabItem { Label("Cookie", systemImage: "key.fill") }
                .tag(2)
            DownloaderView()
                .tabItem { Label("下载器", systemImage: "arrow.down.circle") }
                .tag(3)
            LogsView()
                .tabItem { Label("日志", systemImage: "list.bullet") }
                .tag(4)
            RSSView()
                .tabItem { Label("RSS", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(5)
        }
        .safeAreaInset(edge: .bottom) { statusBar }
    }

    @ViewBuilder
    private var statusBar: some View {
        let msg = model.configError ?? model.cookieMessage
        if let msg {
            HStack(spacing: 8) {
                Image(systemName: model.configError != nil ? "exclamationmark.triangle.fill" : "info.circle")
                Text(msg).textSelection(.enabled).lineLimit(2)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}

/// 整数输入框（限速用）：可全部删空后重输；空 = 0（不限速）；只允许数字
struct IntLimitField: View {
    @State private var text: String
    private let commit: (Int?) -> Void
    @FocusState private var focused: Bool

    init(initial: Int, commit: @escaping (Int?) -> Void) {
        _text = State(initialValue: initial == 0 ? "" : String(initial))
        self.commit = commit
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .onChange(of: text) { v in
                let filtered = v.filter { $0.isNumber }
                if filtered != v { text = filtered }
            }
            .onChange(of: focused) { isFocused in
                if !isFocused { commit(Int(text)) }
            }
    }
}

// MARK: - 运行

struct RunView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("种子链接") {
                HStack(spacing: 0) {
                    TextField("", text: $model.detailURL)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity)
                }
                HStack(spacing: 20) {
                    Toggle("转种到目标站", isOn: $model.doReseed)
                    Toggle("推送到下载器", isOn: $model.doPush)
                    Button(model.running ? "运行中…" : "开始运行") { model.run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.running)
                }
            }
            Section("转种目标站（勾选参与本次转种）") {
                if model.config.sourceSites.contains(where: { $0.enabled }) {
                    ForEach(model.config.sourceSites.filter { $0.enabled }, id: \.id) { s in
                        Toggle(s.name, isOn: targetBinding(s.id))
                    }
                } else {
                    Text("还没有开启的站点：到「站点与限速」页打开站点开关。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.running {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(model.runningStep).foregroundStyle(.secondary)
                    }
                }
            }
            Section("最近一次结果") {
                Text(model.lastReport.isEmpty ? "（还没有运行记录）" : model.lastReport)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .formStyle(.grouped)
    }

    private func targetBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.selectedTargets.contains(id) },
                set: { on in
                    if on { model.selectedTargets.insert(id) } else { model.selectedTargets.remove(id) }
                    model.saveConfig()
                })
    }
}

extension AppModel {
    func siteName(_ id: String) -> String { config.site(id)?.name ?? id }
}

// MARK: - 站点与限速

struct SitesView: View {
    @EnvironmentObject var model: AppModel
    @State private var newGroupName = ""
    @State private var newGroupMB = ""

    var body: some View {
        Form {
            Section {
                ForEach(model.config.sourceSites, id: \.id) { s in
                    let idx = model.siteIndex(s.id)
                    HStack(spacing: 8) {
                        Toggle("", isOn: enabledBinding(s.id))
                            .labelsHidden()
                            .help(s.enabled ? "已开启：参与转种目标 / cookie 检测 / 同步" : "未开启：不参与转种 / 检测 / 同步")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).fontWeight(.medium)
                                .foregroundStyle(s.enabled ? Color.primary : Color.secondary)
                            Text(s.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        cookieStatusView(for: s)
                        Spacer()
                        Button(model.siteChecking.contains(s.id) ? "…" : "检测") {
                            model.checkCookie(siteID: s.id)
                        }
                        .font(.caption)
                        .frame(width: 40)
                        VStack(spacing: 0) {
                            Button { model.moveSite(siteID: s.id, delta: -1) } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(idx <= 0)
                            Button { model.moveSite(siteID: s.id, delta: 1) } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(idx >= model.config.sourceSites.count - 1)
                        }
                        .font(.caption2)
                        .frame(width: 18)
                        Picker("分组", selection: groupBinding(s.id)) {
                            Text("无分组").tag(-1)
                            ForEach(model.config.groups.indices, id: \.self) { i in
                                Text(model.config.groups[i].name).tag(i)
                            }
                        }
                        .frame(maxWidth: 110)
                        IntLimitField(initial: model.siteUpLimitMBInt[s.id] ?? 0) { mb in
                            model.setSiteUpLimitMBInt(mb, siteID: s.id)
                            model.saveConfig()
                        }
                        .frame(width: 70)
                        Text("MB/s").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("开关：未开启的站不作为转种站点（不参与转种目标 / cookie 检测 / 同步）。上下箭头手动调整站点顺序。「检测」验证该站 cookie 是否仍登录；限速 = 该站种子推送到下载器后的上传速度上限（整数 MB/s，空 = 不限速），与所属分组的带宽上限取更严格者。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("站点（开启 / 排序 / 限速 / 分组）")
            }
            Section {
                if model.config.groups.isEmpty {
                    Text("还没有分组。把多个目标站放入同一分组，可共用带宽上限，避免 VPS 上传带宽超限。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(model.config.groups.enumerated()), id: \.offset) { idx, g in
                    HStack(spacing: 8) {
                        TextField("", text: groupNameBinding(idx))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 140)
                        IntLimitField(initial: g.upLimitMB) { mb in
                            model.config.groups[idx].upLimitMB = max(0, mb ?? 0)
                            model.saveConfig()
                        }
                        .frame(width: 70)
                        Text("MB/s").font(.caption).foregroundStyle(.secondary)
                        Text("\(g.sites.count) 站").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) { model.removeGroup(at: idx) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack(spacing: 8) {
                    TextField("", text: $newGroupName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 140)
                    TextField("", text: $newGroupMB)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .onChange(of: newGroupMB) { v in
                            let filtered = v.filter { $0.isNumber }
                            if filtered != v { newGroupMB = filtered }
                        }
                    Text("MB/s").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("添加分组") {
                        model.addGroup(name: newGroupName, upLimitMB: Int(newGroupMB) ?? 0)
                        newGroupName = ""
                        newGroupMB = ""
                    }
                    .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("目标站分组（带宽）")
            }
            Section {
                HStack {
                    IntLimitField(initial: Int((Double(model.config.downloader.defaultUpLimit) / 1048576.0).rounded())) { mb in
                        model.config.downloader.defaultUpLimit = Int64(mb ?? 0) * 1_048_576
                        model.saveConfig()
                    }
                    .frame(width: 70)
                    Text("MB/s — 默认上传限速（未单独设置的站点）").foregroundStyle(.secondary)
                }
                Picker("推送策略", selection: $model.config.downloader.pushPolicy) {
                    Text("总是推送（转种失败也推）").tag(PushPolicy.always)
                    Text("仅全部转种成功时推送").tag(PushPolicy.onSuccess)
                }
            } header: {
                Text("全局")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.autoCheckSites() }
    }

    /// 行内 cookie 状态：未开启 / 无 cookie / 检测中 / 未检测 / 已登录 / 失效
    @ViewBuilder
    private func cookieStatusView(for s: SiteConfig) -> some View {
        if !s.enabled {
            Text("未开启").font(.caption).foregroundStyle(.tertiary)
        } else if model.siteChecking.contains(s.id) {
            Text("检测中…").font(.caption).foregroundStyle(.secondary)
        } else if !model.hasCookie(for: s) {
            Text("无 cookie").font(.caption).foregroundStyle(.secondary)
        } else if let r = model.siteCheckResults[s.id] {
            Text(r.ok ? "已登录" : "cookie 失效")
                .font(.caption)
                .foregroundStyle(r.ok ? Color.green : Color.red)
                .help(r.message)
        } else {
            Text("未检测").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.config.sourceSites.first { $0.id == id }?.enabled ?? false },
                set: { model.setSiteEnabled(siteID: id, $0) })
    }

    private func groupBinding(_ id: String) -> Binding<Int> {
        Binding(get: { model.groupIndex(of: id) },
                set: { model.setGroup(index: $0, for: id) })
    }
    private func groupNameBinding(_ idx: Int) -> Binding<String> {
        Binding(get: { model.config.groups[idx].name },
                set: { model.config.groups[idx].name = $0; model.saveConfig() })
    }
}

// MARK: - Cookie

struct CookiesView: View {
    @EnvironmentObject var model: AppModel
    @State private var singleCookieSite = ""
    @State private var singleCookieText = ""
    @State private var zipPassword = ""

    var body: some View {
        Form {
            Section {
                TextField("gistID", text: gistStringBinding(\.gistID))
                    .textFieldStyle(.roundedBorder)
                SecureField("GitHub token", text: gistStringBinding(\.token))
                    .textFieldStyle(.roundedBorder)
                SecureField("PT-depiler 备份密码", text: gistStringBinding(\.encryptionKey))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("轮询", text: pollBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("（自动同步间隔，分钟，最小 5）").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("自动定时同步", isOn: autoBinding)
                    Button("立即同步") { model.gistSyncNow() }
                }
                if !model.lastGistSyncText.isEmpty {
                    LabeledContent("上次 Gist 同步", value: model.lastGistSyncText)
                }
                Text("与 PT-depiler 的 Gist 备份联动，无需手动导入。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Gist 同步")
            }
            Section {
                HStack(spacing: 8) {
                    Button("导入 PTD_backup_*.zip …") { pickZip() }
                    Text("备份密码").font(.callout).foregroundStyle(.secondary)
                    SecureField("", text: $zipPassword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
                Text("在 PT-depiler 中「备份 → 本地备份」导出 zip 后导入；导入会整体替换本地 cookie。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("清空本地 Cookie", role: .destructive) { model.clearCookies() }
            } header: {
                Text("PT-depiler 本地备份")
            }
            Section {
                Picker("站点", selection: $singleCookieSite) {
                    ForEach(model.config.sourceSites, id: \.id) { site in
                        Text("\(site.name)（\(model.siteHost(site))）").tag(site.id)
                    }
                }
                TextField("name1=value1; name2=value2", text: $singleCookieText)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Button("保存（覆盖该站）") {
                        model.addSiteCookie(siteID: singleCookieSite, raw: singleCookieText)
                        singleCookieText = ""
                    }
                    .disabled(singleCookieText.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("删除该站 Cookie", role: .destructive) {
                        model.removeSiteCookies(siteID: singleCookieSite)
                    }
                }
                Text("浏览器开发者工具复制单站 Cookie 头后粘贴；保存即覆盖该站本地已有 cookie，适合只更新一个站而不导出整包备份。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("单站 Cookie（手动添加）")
            }
            Section {
                HStack {
                    Text("监控目录").font(.callout).foregroundStyle(.secondary)
                    TextField("", text: Binding(get: { model.zipDir() }, set: { model.setZipDir($0) }))
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("备份密码").font(.callout).foregroundStyle(.secondary)
                    SecureField("", text: Binding(get: { model.zipPassword() }, set: { model.setZipPassword($0) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    IntLimitField(initial: model.config.zipWatch?.pollMinutes ?? 5) { model.setZipPollMinutes($0 ?? 5) }
                        .frame(width: 60)
                    Text("（分钟）").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Toggle("启用备份目录监控", isOn: Binding(get: { model.zipAuto }, set: { model.setZipAuto($0) }))
                    Spacer()
                    Button("立即扫描") { model.zipScanNow() }
                        .disabled(model.zipRunning)
                }
                if model.zipRunning {
                    Text("扫描中…").font(.caption).foregroundStyle(.secondary)
                }
                if let m = model.zipMessage {
                    Text(m).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("目录出现新的 PTD_backup*.zip 时自动导入（整体替换本地 cookie），失败的下次重试。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("备份目录监控")
            }
            Section("已同步的 Cookie 详情") {
                LabeledContent("站点数", value: "\(model.cookieHosts.count)")
                LabeledContent("Cookie 总数", value: "\(model.cookieTotal)")
                if !model.cookieHosts.isEmpty {
                    Text(model.cookieHosts.joined(separator: "  "))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text("（还没有 cookie）").font(.caption).foregroundStyle(.secondary)
                }
                Button("检测登录状态") { model.checkCookies() }
                    .disabled(model.cookieChecking)
                if model.cookieChecking {
                    Text("检测中（逐站访问首页，需十几秒）…").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.cookieCheckLines, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if singleCookieSite.isEmpty {
                singleCookieSite = model.config.sourceSites.first?.id ?? ""
            }
        }
    }

    private func pickZip() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 PT-depiler 导出的 PTD_backup_*.zip"
        panel.allowedContentTypes = [UTType.zip]
        if panel.runModal() == .OK, let url = panel.url {
            model.importZipFile(url, password: zipPassword)
        }
    }

    private func gistStringBinding(_ kp: WritableKeyPath<GistSyncConfig, String>) -> Binding<String> {
        Binding(get: { model.config.gistSync?[keyPath: kp] ?? "" },
                set: { v in
                    var g = model.config.gistSync ?? GistSyncConfig.empty
                    g[keyPath: kp] = v
                    model.config.gistSync = g
                })
    }
    private var pollBinding: Binding<String> {
        Binding(get: { String(model.config.gistSync?.pollMinutes ?? 30) },
                set: { model.config.gistSync?.pollMinutes = max(5, Int($0) ?? 30) })
    }
    private var autoBinding: Binding<Bool> {
        Binding(get: { model.gistAuto }, set: { model.setGistAuto($0) })
    }
}

// MARK: - 下载器

struct DownloaderView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("类型", selection: $model.config.downloader.type) {
                    Text("qBittorrent").tag(DownloaderType.qbittorrent)
                    Text("Transmission").tag(DownloaderType.transmission)
                }
                TextField("URL（VPS 隧道地址）", text: $model.config.downloader.url)
                    .textFieldStyle(.roundedBorder)
                TextField("用户名", text: $model.config.downloader.username)
                    .textFieldStyle(.roundedBorder)
                SecureField("密码", text: $model.config.downloader.password)
                    .textFieldStyle(.roundedBorder)
                TextField("保存路径（空 = 下载器默认）", text: optBinding(\.savePath))
                    .textFieldStyle(.roundedBorder)
                TextField("分类（空 = 无）", text: optBinding(\.category))
                    .textFieldStyle(.roundedBorder)
                Toggle("添加后跳过校验（skipChecking）", isOn: $model.config.downloader.skipChecking)
            } header: {
                Text("qBittorrent / Transmission（VPS 上）")
            }
            Section {
                HStack(spacing: 12) {
                    Button(model.testingDownloader ? "测试中…" : "测试连接") { model.testDownloader() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.testingDownloader)
                    if model.testingDownloader { ProgressView() }
                }
                if let r = model.downloaderTestResult {
                    Text(r)
                        .foregroundStyle(r.hasPrefix("成功") ? .green : .red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("连接检测")
            }
            Section {
                HStack {
                    IntLimitField(initial: model.config.downloader.vpsFreeGB ?? 0) { model.setVpsFreeGB($0) }
                        .frame(width: 60)
                    Text("VPS 剩余空间（GB，空 = 不做大小检测）").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Picker("超过剩余空间时", selection: $model.config.downloader.sizeGuardMode) {
                        Text("提醒（继续转种）").tag(SizeGuardMode.warn)
                        Text("跳过（不转种不推送）").tag(SizeGuardMode.skip)
                    }
                    IntLimitField(initial: model.config.downloader.sizeGuardMarginGB) { model.setVpsFreeMargin($0) }
                        .frame(width: 50)
                    Text("安全边际（GB）").font(.caption).foregroundStyle(.secondary)
                }
                Text("可用空间 = 剩余 - 边际；剩余空间需手动维护（qB WebAPI 无磁盘接口），空间变化大时记得更新。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("种子大小检测")
            }
        }
        .formStyle(.grouped)
    }

    private func optBinding(_ kp: WritableKeyPath<DownloaderConfig, String?>) -> Binding<String> {
        Binding(get: { model.config.downloader[keyPath: kp] ?? "" },
                set: { v in model.config.downloader[keyPath: kp] = v.isEmpty ? nil : v })
    }
}

// MARK: - 日志

struct LogsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("运行日志").font(.headline)
                Spacer()
                Button("清空显示") { model.clearNotes() }
                    .disabled(model.notes.isEmpty)
            }
            ScrollView {
                Text(model.notes.isEmpty ? "（暂无日志）" : model.notes.reversed().joined(separator: "\n"))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .padding()
    }
}

// MARK: - RSS 自动转种

struct RSSView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("启用 RSS 自动转种（定时拉取新种并自动转种 + 推送）", isOn: Binding(
                    get: { model.rssAuto },
                    set: { model.setRssAuto($0) }
                ))
                HStack {
                    IntLimitField(initial: model.config.rss?.pollMinutes ?? 10) { model.setRssPollMinutes($0 ?? 10) }
                        .frame(width: 60)
                    Text("（轮询间隔，分钟）").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("立即轮询一次") { model.rssPollNow() }
                        .disabled(model.rssRunning)
                }
                if model.rssRunning {
                    Text("轮询进行中…").font(.caption).foregroundStyle(.secondary)
                }
                if let m = model.rssMessage {
                    Text(m).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("RSS 新种自动走完整转种流水线（查重、大小检测、按站限速推送）。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("RSS 自动转种")
            }
            Section("源站 passkey（留空的站点不参与轮询）") {
                ForEach(model.config.sourceSites, id: \.id) { s in
                    HStack {
                        Text(s.id).frame(width: 100, alignment: .leading)
                        TextField("passkey", text: Binding(
                            get: { model.rssPasskey(s.id) },
                            set: { model.setRssPasskey(s.id, $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
