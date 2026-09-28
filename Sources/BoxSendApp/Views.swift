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
                TextField("粘贴源站详情页 URL，如 https://pt.luckpt.de/details.php?id=…", text: $model.detailURL)
                HStack(spacing: 20) {
                    Toggle("转种到目标站", isOn: $model.doReseed)
                    Toggle("推送到下载器", isOn: $model.doPush)
                    Button(model.running ? "运行中…" : "开始运行") { model.run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.running)
                }
            }
            Section("转种目标站") {
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
                })
    }
}

extension AppModel {
    func siteName(_ id: String) -> String { config.site(id)?.name ?? id }
}

// MARK: - 站点与限速

struct SitesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(Array(model.config.sourceSites.enumerated()), id: \.offset) { idx, s in
                    HStack(spacing: 12) {
                        Toggle(isOn: enabledBinding(idx)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.name).fontWeight(.medium)
                                Text(s.url).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        TextField("0", text: limitBinding(s.id))
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                        Text("MB/s").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("左侧启用/停用源站；限速是「该站作为源站」推送到下载器的上传速度上限，0 = 不限速（避免限速过低被判做种无效，或过高被站管盯上）。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("源站（限速按源站生效）")
            }
            Section {
                HStack {
                    TextField("0", text: defaultLimitBinding)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                    Text("MB/s — 默认上传限速（未单独设置的源站）").foregroundStyle(.secondary)
                }
                Picker("推送策略", selection: $model.config.downloader.pushPolicy) {
                    Text("总是推送（转种失败也推）").tag(PushPolicy.always)
                    Text("仅全部转种成功时推送").tag(PushPolicy.onSuccess)
                }
            } header: {
                Text("全局")
            }
            Section("转种目标站（在「运行」页勾选参与本次转种）") {
                ForEach(model.config.sourceSites, id: \.id) { s in
                    Toggle("\(s.name)（\(s.id)）", isOn: targetBinding(s.id))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func enabledBinding(_ idx: Int) -> Binding<Bool> {
        Binding(get: { model.config.sourceSites[idx].enabled },
                set: { model.config.sourceSites[idx].enabled = $0 })
    }
    private func limitBinding(_ id: String) -> Binding<String> {
        Binding(get: { model.siteUpLimitMB[id] ?? "0" },
                set: { model.setSiteUpLimitMB($0, siteID: id) })
    }
    private var defaultLimitBinding: Binding<String> {
        Binding(get: {
            let v = model.config.downloader.defaultUpLimit
            return v == 0 ? "0" : String(Double(v) / 1048576.0)
        }, set: {
            let d = Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0
            model.config.downloader.defaultUpLimit = Int64(d * 1048576.0)
        })
    }
    private func targetBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.selectedTargets.contains(id) },
                set: { on in
                    if on { model.selectedTargets.insert(id) } else { model.selectedTargets.remove(id) }
                })
    }
}

// MARK: - Cookie

struct CookiesView: View {
    @EnvironmentObject var model: AppModel
    @State private var zipPassword = ""

    var body: some View {
        Form {
            Section("当前状态") {
                LabeledContent("站点数", value: "\(model.cookieHosts.count)")
                LabeledContent("Cookie 总数", value: "\(model.cookieTotal)")
                if !model.cookieHosts.isEmpty {
                    Text(model.cookieHosts.joined(separator: "  "))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !model.lastGistSyncText.isEmpty {
                    LabeledContent("上次 Gist 同步", value: model.lastGistSyncText)
                }
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
                Text("可选方式：与 PT-depiler 的 Gist 备份联动，无需手动导入。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Gist 同步（可选）")
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
