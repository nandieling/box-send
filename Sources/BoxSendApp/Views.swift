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
                .tabItem { Label("批量转种", systemImage: "paperplane.fill") }
                .tag(0)
            SitesView()
                .tabItem { Label("站点分组", systemImage: "server.rack") }
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
        .padding(.top, 12)   // 全屏时顶部留白
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
    private let center: Bool
    @FocusState private var focused: Bool

    init(initial: Int, center: Bool = false, commit: @escaping (Int?) -> Void) {
        _text = State(initialValue: initial == 0 ? "" : String(initial))
        self.commit = commit
        self.center = center
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(center ? .center : .trailing)
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
    @State private var showHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                seedCard
                targetsSection
                historySection
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 种子链接（左对齐输入框）

    private var seedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("种子链接").font(.headline)
                Spacer()
                if let e = model.sourcePushEvent { eventChip(e) }
            }
            TextField("粘贴种子详情页链接（如 https://…/details.php?id=…）", text: $model.detailURL)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 20) {
                Toggle("转种到目标站", isOn: $model.doReseed)
                Toggle("推送到下载器", isOn: $model.doPush)
                Toggle("跳过检验", isOn: skipCheckingBinding)
                    .help("推送 qBittorrent 时勾选 skip_checking（跳过种子完整性校验，直接开始下载）")
                Button(model.running ? "运行中…" : "开始运行") { model.run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.running)
                Spacer()
            }
            if model.running {
                Text(model.runningStep).font(.caption).foregroundStyle(.secondary)
            }
        }
        .runCard()
    }

    // MARK: 转种目标（分组卡片，组级选择 + 逐站微调）

    private var targetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("转种分组").font(.headline)
            if model.managedSites.filter(\.enabled).isEmpty {
                Text("还没有开启的站点：到「站点分组」页添加并开启。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.config.groups.indices, id: \.self) { gi in
                groupCard(gi)
            }
            if !model.groupMembers(-1).filter(\.enabled).isEmpty {
                groupCard(-1)
            }
        }
    }

    private func groupCard(_ gi: Int) -> some View {
        let g = gi >= 0 ? model.config.groups[gi] : GroupConfig(name: "无分组")
        let members = model.groupMembers(gi).filter(\.enabled)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("", isOn: groupAllBinding(gi, members: members))
                    .labelsHidden()
                    .help("整组选中 / 取消")
                Text(g.name).fontWeight(.semibold)
                Text("\(members.count) 站").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.running {
                    ProgressView().controlSize(.small)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6),
                      alignment: .leading, spacing: 8) {
                ForEach(members, id: \.id) { s in
                    targetSiteCard(s)
                }
            }
        }
        .runCard()
    }

    /// 目标站点卡片：名称 + 上传限速 + 转种/推送实时状态
    private func targetSiteCard(_ s: SiteConfig) -> some View {
        let limit = model.config.effectiveUpLimit(siteID: s.id)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Toggle("", isOn: siteBinding(s.id))
                    .labelsHidden()
                Text(s.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(limit > 0 ? "上传限速 \(Int((Double(limit) / 1048576.0).rounded())) MB/s" : "上传限速 不限速")
                .font(.caption).foregroundStyle(.secondary)
            if let e = model.reseedEvents[s.id] { eventChip(e) }
            if let e = model.pushEvents[s.id] { eventChip(e) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    // MARK: 运行记录（点开才显示）

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showHistory.toggle()
            } label: {
                Label(showHistory ? "收起运行记录" : "运行记录",
                      systemImage: showHistory ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.bordered)
            if showHistory {
                Text(model.lastReport.isEmpty ? "（还没有运行记录）" : model.lastReport)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: bindings / 状态提示

    private func groupAllBinding(_ gi: Int, members: [SiteConfig]) -> Binding<Bool> {
        Binding(
            get: { !members.isEmpty && members.allSatisfy { model.selectedTargets.contains($0.id) } },
            set: { on in
                for m in members {
                    if on { model.selectedTargets.insert(m.id) } else { model.selectedTargets.remove(m.id) }
                }
                model.saveConfig()
            }
        )
    }

    private func siteBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.selectedTargets.contains(id) },
                set: { on in
                    if on { model.selectedTargets.insert(id) } else { model.selectedTargets.remove(id) }
                    model.saveConfig()
                })
    }

    private var skipCheckingBinding: Binding<Bool> {
        Binding(get: { model.config.downloader.skipChecking },
                set: { model.config.downloader.skipChecking = $0; model.saveConfig() })
    }

    @ViewBuilder
    private func eventChip(_ e: AppModel.TargetEvent) -> some View {
        Text(e.text)
            .font(.caption)
            .foregroundStyle(e.ok == nil ? Color.secondary : (e.ok == true ? Color.green : Color.red))
            .lineLimit(1)
    }
}

extension View {
    /// 运行页卡片样式
    func runCard() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}

extension AppModel {
    func siteName(_ id: String) -> String { config.site(id)?.name ?? id }
}

// MARK: - 站点分组

extension SiteConfig: Identifiable {}

struct SitesView: View {
    @EnvironmentObject var model: AppModel
    @State private var newGroupName = ""
    @State private var newGroupMB = "10"
    @State private var showAddSites = false
    @State private var manualCookieSite: SiteConfig?
    @State private var draggingSite: String?
    @State private var siteSortNum: [String: String] = [:]

    private let cardColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        Form {
            Section("添加分组和站点") {
                HStack(spacing: 10) {
                    Text("分组名").foregroundStyle(.secondary)
                    TextField("", text: $newGroupName, prompt: Text("分组名"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .frame(width: 150)
                    Text("上传限速").foregroundStyle(.secondary)
                    TextField("", text: $newGroupMB, prompt: Text("10"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .frame(width: 70)
                        .onChange(of: newGroupMB) { v in
                            let filtered = v.filter { $0.isNumber }
                            if filtered != v { newGroupMB = filtered }
                        }
                    Text("MB/s，默认=10").font(.caption).foregroundStyle(.secondary)
                    Button("添加分组") {
                        model.addGroup(name: newGroupName, upLimitMB: Int(newGroupMB) ?? 10)
                        newGroupName = ""
                        newGroupMB = "10"
                    }
                    .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button {
                        showAddSites = true
                    } label: {
                        Label("添加站点", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button(model.anyChecking ? "检测中…" : "检测 Cookie") {
                        model.checkAllManagedCookies()
                    }
                    .font(.caption)
                    .disabled(model.anyChecking)
                    .help("批量检测所有分组已添加站点的 cookie 有效性")
                    Text("检测所有已添加站点").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                Text("站点按分组区块以卡片显示；「添加站点」可从内置 \(model.config.sourceSites.count) 个站点中搜索并打勾添加（可指定加入分组，新增站点限速默认取分组上传限速，未设 = 10 MB/s）。分组内站点卡片可拖拽或输入序号排序。关闭站点开关后，该站不参与转种 / cookie 检测 / 同步。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.config.groups.indices, id: \.self) { gi in
                let gname = model.config.groups[gi].name
                Section {
                    HStack(spacing: 8) {
                        Text("\(model.groupMembers(gi).count) 站").font(.caption).foregroundStyle(.secondary)
                        Button("同步 Gist") {
                            model.gistSyncNow { model.checkGroupCookies(gi) }
                        }
                        .font(.caption)
                        .help("通过 Gist 批量同步所有站点 cookie，完成后重检该分组")
                        Button("按序号排序") { applySiteSort(gi) }
                            .font(.caption)
                            .help("按卡片内「序」输入的数字重排该分组的站点卡片")
                        Spacer()
                        Button(role: .destructive) { model.removeGroup(at: gi) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("删除分组（组内站点移到无分组）")
                    }
                    siteCardGrid(model.groupMembers(gi), gi: gi)
                    if model.groupMembers(gi).isEmpty {
                        Text("该分组还没有站点：「添加站点」时选择此分组。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("分组：\(gname)")
                }
            }
            if !model.unassignedManagedSites.isEmpty {
                Section("无分组") {
                    HStack(spacing: 8) {
                        Text("\(model.unassignedManagedSites.count) 站").font(.caption).foregroundStyle(.secondary)
                        Button("同步 Gist") {
                            model.gistSyncNow { model.checkGroupCookies(-1) }
                        }
                        .font(.caption)
                        .help("通过 Gist 批量同步所有站点 cookie，完成后重检无分组站点")
                        Button("按序号排序") { applySiteSort(-1) }
                            .font(.caption)
                            .help("按卡片内「序」输入的数字重排无分组区块的站点卡片")
                        Spacer()
                    }
                    siteCardGrid(model.unassignedManagedSites, gi: -1)
                }
            }
            if model.managedSites.isEmpty {
                Section {
                    Text("还没有添加站点：点上方「添加站点」批量选择。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAddSites) { AddSitesSheet() }
        .sheet(item: $manualCookieSite) { site in
            ManualCookieSheet(site: site)
        }
        .onAppear { model.autoCheckSites() }
    }

    private func siteCardGrid(_ sites: [SiteConfig], gi: Int) -> some View {
        LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 10) {
            ForEach(sites, id: \.id) { s in
                siteCard(s, gi: gi)
            }
        }
    }

    /// 站点卡片：名称 / 地址 / cookie 有效性 / 上传限速 / 序号（组内拖拽或按序号排序）
    private func siteCard(_ s: SiteConfig, gi: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle("", isOn: enabledBinding(s.id))
                    .labelsHidden()
                    .help(s.enabled ? "已开启：参与转种目标 / cookie 检测 / 同步" : "未开启：不参与转种 / 检测 / 同步")
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).fontWeight(.medium).lineLimit(1)
                        .foregroundStyle(s.enabled ? Color.primary : Color.secondary)
                    Text(s.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 16)
                    .onDrag {
                        draggingSite = s.id
                        return NSItemProvider(object: s.id as NSString)
                    }
                    .help("按住拖拽调整组内位置")
                Button { model.removeManagedSite(s.id) } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("从站点列表移除（保留 cookie 与配置）")
            }
            cookieStatusView(for: s)
            if let r = model.siteCheckResults[s.id], !r.ok {
                Button("手动添加") { manualCookieSite = s }
                    .font(.caption).buttonStyle(.bordered).controlSize(.small)
            }
            HStack(spacing: 6) {
                Text("上传限速").font(.caption).foregroundStyle(.secondary)
                IntLimitField(initial: model.siteUpLimitMBInt[s.id] ?? 0, center: true) { mb in
                    model.setSiteUpLimitMBInt(mb, siteID: s.id)
                    model.saveConfig()
                }
                .frame(width: 60)
                Text("MB/s").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("序").font(.caption).foregroundStyle(.secondary)
                TextField("", text: siteNumBinding(s.id), prompt: Text("\(siteOrderHint(s, gi: gi))"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 44)
                    .font(.caption)
                    .onSubmit { applySiteSort(gi) }
                    .help("输入排序序号，回车或点区块「按序号排序」重排卡片")
                Spacer()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(draggingSite == s.id ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: draggingSite == s.id ? 2 : 1)
        )
        .opacity(draggingSite == s.id ? 0.4 : 1)
        .onDrop(of: [.text], delegate: GroupSiteDrop(target: s.id, dragging: $draggingSite,
            onMove: { from, to in model.moveSite(from, before: to) }))
    }

    /// 卡片内 cookie 状态：未开启 / 无 cookie / 检测中 / 未检测 / 已登录 / 失效
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

    private func siteNumBinding(_ id: String) -> Binding<String> {
        Binding(get: { siteSortNum[id] ?? "" },
                set: { siteSortNum[id] = $0.filter { $0.isNumber } })
    }

    private func siteOrderHint(_ s: SiteConfig, gi: Int) -> Int {
        let members = model.groupMembers(gi)
        return (members.firstIndex { $0.id == s.id } ?? 0) + 1
    }

    private func applySiteSort(_ gi: Int) {
        var nums: [String: Int] = [:]
        for (k, v) in siteSortNum { if let n = Int(v), n > 0 { nums[k] = n } }
        guard !nums.isEmpty else { return }
        model.sortGroupSites(gi, by: nums)
    }
}

/// 分组内站点卡片拖拽排序（卡片把手 -> 目标卡片）
final class GroupSiteDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let onMove: (String, String) -> Void

    init(target: String, dragging: Binding<String?>, onMove: @escaping (String, String) -> Void) {
        self.target = target
        self._dragging = dragging
        self.onMove = onMove
    }

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target else { return }
        withAnimation { onMove(d, target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
}

/// 批量添加站点：卡片网格（只显示站名）+ 打勾添加 + 拖拽/序号排序
struct AddSitesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var checked = Set<String>()
    @State private var targetGroup = -1
    @State private var order: [String] = []
    @State private var sortNum: [String: String] = [:]
    @State private var dragging: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    private var allCandidateIDs: [String] {
        model.config.sourceSites.filter { !$0.managed }.map { $0.id }
    }

    private var displayIDs: [String] {
        let valid = Set(allCandidateIDs)
        let q = query.trimmingCharacters(in: .whitespaces)
        return order.filter { id in
            guard valid.contains(id) else { return false }
            if q.isEmpty { return true }
            guard let s = model.config.sourceSites.first(where: { $0.id == id }) else { return false }
            return s.name.localizedCaseInsensitiveContains(q)
                || s.id.localizedCaseInsensitiveContains(q)
                || s.url.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("批量添加站点").font(.headline)
                Spacer()
                Text("已勾选 \(checked.count)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索站名 / id / 地址", text: $query)
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                Picker("加入分组", selection: $targetGroup) {
                    Text("无分组").tag(-1)
                    ForEach(model.config.groups.indices, id: \.self) { i in
                        Text(model.config.groups[i].name).tag(i)
                    }
                }
                .frame(maxWidth: 140)
                Button("按序号排序") { applySortNumbers() }
                    .font(.caption)
                    .help("按输入的序号重排卡片；未填序号的保持相对顺序")
                Spacer()
            }
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(displayIDs, id: \.self) { id in
                        card(id)
                    }
                }
                .padding(2)
            }
            HStack {
                Text("打勾要添加的站点；拖拽卡片右侧把手或输入序号排序；添加后默认开启（限速默认取分组上传限速，未设 = 10 MB/s）。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加 \(checked.count) 个站点") {
                    model.addManagedSites(displayIDs.filter { checked.contains($0) }, group: targetGroup)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(checked.isEmpty)
            }
        }
        .padding()
        .frame(width: 640, height: 540)
        .onAppear { order = allCandidateIDs }
    }

    private func card(_ id: String) -> some View {
        let s = model.config.sourceSites.first { $0.id == id }
        return Group {
            if let s {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Toggle("", isOn: checkBinding(id))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        Text(s.name).fontWeight(.medium).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 16)
                            .onDrag {
                                dragging = id
                                return NSItemProvider(object: id as NSString)
                            }
                            .help("按住拖拽调整顺序")
                    }
                    HStack(spacing: 4) {
                        Text("序").font(.caption).foregroundStyle(.secondary)
                        TextField("", text: numBinding(id))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 46)
                            .multilineTextAlignment(.center)
                            .font(.caption)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(dragging == id ? Color.accentColor : Color(nsColor: .separatorColor),
                                      lineWidth: dragging == id ? 2 : 1)
                )
            }
        }
        .opacity(dragging == id ? 0.4 : 1)
        .onDrop(of: [.text], delegate: SiteReorderDrop(target: id, dragging: $dragging, order: $order))
    }

    private func checkBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { checked.contains(id) },
                set: { on in
                    if on { checked.insert(id) } else { checked.remove(id) }
                })
    }

    private func numBinding(_ id: String) -> Binding<String> {
        Binding(get: { sortNum[id] ?? "" },
                set: { sortNum[id] = $0.filter { $0.isNumber } })
    }

    private func applySortNumbers() {
        var nums: [String: Int] = [:]
        for (k, v) in sortNum { if let n = Int(v), n > 0 { nums[k] = n } }
        guard !nums.isEmpty else { return }
        let indexed = order.enumerated().map { (offset: $0.offset, id: $0.element) }
        let sorted = indexed.sorted { a, b in
            let na = nums[a.id] ?? Int.max
            let nb = nums[b.id] ?? Int.max
            if na != nb { return na < nb }
            return a.offset < b.offset
        }
        withAnimation { order = sorted.map { $0.id } }
    }
}

/// 添加站点弹窗卡片拖拽排序
final class SiteReorderDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    @Binding var order: [String]

    init(target: String, dragging: Binding<String?>, order: Binding<[String]>) {
        self.target = target
        self._dragging = dragging
        self._order = order
    }

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target,
              let from = order.firstIndex(of: d),
              let to = order.firstIndex(of: target) else { return }
        withAnimation {
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
}

/// 手动添加站点 cookie（卡片「手动添加」按钮弹出）
struct ManualCookieSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let site: SiteConfig
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加 \(site.name)（\(model.siteHost(site))）的 cookie")
                .font(.headline)
            TextField("name1=value1; name2=value2（浏览器 Cookie 头原文）", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            HStack(alignment: .firstTextBaseline) {
                Text("保存即覆盖该站原有 cookie，并自动开启该站")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    model.addSiteCookie(siteID: site.id, raw: text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 480)
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
                TextField("地址", text: ccStringBinding(\.baseURL), prompt: Text("https://cookiecloud.co"))
                    .textFieldStyle(.roundedBorder)
                SecureField("API Token", text: ccStringBinding(\.token))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("轮询", text: ccPollBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("（自动同步间隔，分钟，最小 5）").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("自动定时同步", isOn: ccAutoBinding)
                    Button("立即同步") { model.cookieCloudNow() }
                }
                if let msg = model.cookieMessage, !msg.isEmpty {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
                Text("从 CookieCloud 拉取全部站点 cookie 并覆盖本地备份。Token 在 cookiecloud.co「设置 → API Token」获取。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("CookieCloud 同步")
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
    private func ccStringBinding(_ kp: WritableKeyPath<CookieCloudConfig, String>) -> Binding<String> {
        Binding(get: { model.config.cookieCloud?[keyPath: kp] ?? (kp == \.baseURL ? "https://cookiecloud.co" : "") },
                set: { v in
                    var c = model.config.cookieCloud ?? CookieCloudConfig.empty
                    c[keyPath: kp] = v
                    model.config.cookieCloud = c
                })
    }
    private var ccPollBinding: Binding<String> {
        Binding(get: { String(model.config.cookieCloud?.pollMinutes ?? 30) },
                set: { model.config.cookieCloud?.pollMinutes = max(5, Int($0) ?? 30) })
    }
    private var ccAutoBinding: Binding<Bool> {
        Binding(get: { model.cookieCloudAuto }, set: { model.setCookieCloudAuto($0) })
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
