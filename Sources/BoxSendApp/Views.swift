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

// MARK: - 运行

struct RunView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("种子链接") {
                Text("粘贴源站种子详情页链接，一次运行处理一条，如 https://pt.luckpt.de/details.php?id=…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                TextField("https://…", text: $model.detailURL)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 20) {
                    Toggle("转种到目标站", isOn: $model.doReseed)
                    Toggle("推送到下载器", isOn: $model.doPush)
                    Button(model.running ? "运行中…" : "开始运行") { model.run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.running)
                }
            }
            Section("转种目标站（本次运行勾选参与）") {
                ForEach(model.config.targetSites, id: \.self) { id in
                    Toggle(model.siteName(id), isOn: targetBinding(id))
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
    @State private var newGroupGB = ""

    var body: some View {
        Form {
            Section {
                ForEach(Array(model.config.sourceSites.enumerated()), id: \.offset) { idx, s in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(s.name).fontWeight(.medium)
                            Text(s.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Picker("分组", selection: groupBinding(s.id)) {
                                Text("无分组").tag(-1)
                                ForEach(model.config.groups.indices, id: \.self) { i in
                                    Text(model.config.groups[i].name).tag(i)
                                }
                            }
                            .frame(maxWidth: 150)
                        }
                        HStack(spacing: 8) {
                            Toggle("源站", isOn: enabledBinding(idx))
                            Toggle("转种目标", isOn: targetBinding(s.id))
                            Spacer()
                            TextField("0", text: limitBinding(s.id))
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                            Text("MB/s").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("「源站」= 可作为转种/推送来源；「转种目标」= 可被转发种子。限速 = 该站种子推送到下载器后的上传速度上限（推送时生效），0 = 不限速；与所属分组的带宽上限取更严格者。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("站点（源站 / 转种目标 / 限速 / 分组）")
            }
            Section {
                if model.config.groups.isEmpty {
                    Text("还没有分组。把多个目标站放入同一分组，可共用带宽上限与单日上传量上限，避免 VPS 上传带宽或单日上传量超限。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(model.config.groups.enumerated()), id: \.offset) { idx, g in
                    HStack(spacing: 6) {
                        TextField("分组名", text: groupNameBinding(idx))
                            .frame(maxWidth: 120)
                        TextField("0", text: groupMBBinding(idx))
                            .frame(width: 56)
                            .multilineTextAlignment(.trailing)
                        Text("MB/s").font(.caption).foregroundStyle(.secondary)
                        TextField("0", text: groupGBBinding(idx))
                            .frame(width: 56)
                            .multilineTextAlignment(.trailing)
                        Text("GB/天").font(.caption).foregroundStyle(.secondary)
                        Text("\(g.sites.count) 站")
                            .font(.caption).foregroundStyle(.secondary)
                        if g.dailyGB > 0 {
                            Text("今日 \(String(format: "%.1f", model.groupUsedTodayGB(groupName: g.name)))/\(g.dailyGB) GB")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { model.removeGroup(at: idx) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack(spacing: 6) {
                    TextField("新分组名", text: $newGroupName)
                        .frame(maxWidth: 120)
                    TextField("0", text: $newGroupMB)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Text("MB/s").font(.caption).foregroundStyle(.secondary)
                    TextField("0", text: $newGroupGB)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Text("GB/天").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("添加分组") {
                        model.addGroup(name: newGroupName,
                                       upLimitMB: Int(newGroupMB) ?? 0,
                                       dailyGB: Int(newGroupGB) ?? 0)
                        newGroupName = ""
                        newGroupMB = ""
                        newGroupGB = ""
                    }
                    .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("带宽上限 0 = 不限；单日量按推送成功的种子实际内容量累计，超限的种子不再推送（日志记录原因）。单日量 0 = 不限。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("目标站分组（带宽 / 单日上传量）")
            }
            Section {
                HStack {
                    TextField("0", text: defaultLimitBinding)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
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
    }

    private func enabledBinding(_ idx: Int) -> Binding<Bool> {
        Binding(get: { model.config.sourceSites[idx].enabled },
                set: { model.config.sourceSites[idx].enabled = $0; model.saveConfig() })
    }
    private func limitBinding(_ id: String) -> Binding<String> {
        Binding(get: { model.siteUpLimitMB[id] ?? "0" },
                set: { model.setSiteUpLimitMB($0, siteID: id); model.saveConfig() })
    }
    private func groupBinding(_ id: String) -> Binding<Int> {
        Binding(get: { model.groupIndex(of: id) },
                set: { model.setGroup(index: $0, for: id) })
    }
    private func groupNameBinding(_ idx: Int) -> Binding<String> {
        Binding(get: { model.config.groups[idx].name },
                set: { model.config.groups[idx].name = $0; model.saveConfig() })
    }
    private func groupMBBinding(_ idx: Int) -> Binding<String> {
        Binding(get: { String(model.config.groups[idx].upLimitMB) },
                set: { model.config.groups[idx].upLimitMB = max(0, Int($0) ?? 0); model.saveConfig() })
    }
    private func groupGBBinding(_ idx: Int) -> Binding<String> {
        Binding(get: { String(model.config.groups[idx].dailyGB) },
                set: { model.config.groups[idx].dailyGB = max(0, Int($0) ?? 0); model.saveConfig() })
    }
    private var defaultLimitBinding: Binding<String> {
        Binding(get: {
            let v = model.config.downloader.defaultUpLimit
            return v == 0 ? "0" : String(Double(v) / 1048576.0)
        }, set: {
            let d = Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0
            model.config.downloader.defaultUpLimit = Int64(d * 1048576.0)
            model.saveConfig()
        })
    }
    private func targetBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.selectedTargets.contains(id) },
                set: { on in
                    if on { model.selectedTargets.insert(id) } else { model.selectedTargets.remove(id) }
                    model.saveConfig()
                })
    }
}

// MARK: - Cookie

struct CookiesView: View {
    @EnvironmentObject var model: AppModel
    @State private var zipPassword = ""

    var body: some View {
        Form {
            Section {
                TextField("gistID", text: gistStringBinding(\.gistID))
                SecureField("GitHub token", text: gistStringBinding(\.token))
                SecureField("PT-depiler 备份密码", text: gistStringBinding(\.encryptionKey))
                HStack {
                    TextField("轮询分钟", text: pollBinding)
                        .frame(width: 70)
                    Text("（自动同步间隔，最小 5 分钟）").font(.caption).foregroundStyle(.secondary)
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
                HStack {
                    Button("导入 PTD_backup_*.zip …") { pickZip() }
                    SecureField("PT-depiler 备份密码", text: $zipPassword)
                        .frame(maxWidth: 220)
                }
                Text("在 PT-depiler 中「备份 → 本地备份」导出 zip 后导入；导入会整体替换本地 cookie。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("清空本地 Cookie", role: .destructive) { model.clearCookies() }
            } header: {
                Text("PT-depiler 本地备份")
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
            }
        }
        .formStyle(.grouped)
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
                TextField("用户名", text: $model.config.downloader.username)
                SecureField("密码", text: $model.config.downloader.password)
                TextField("保存路径（空 = 下载器默认）", text: optBinding(\.savePath))
                TextField("分类（空 = 无）", text: optBinding(\.category))
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
