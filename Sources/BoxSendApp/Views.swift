import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BoxSendKit

// MARK: - 主题（渐变色）与外观

extension Color {
    /// "#rrggbb" 十六进制
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255)
    }
}

/// 内置渐变主题
struct AppTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let colorsHex: [String]
    let dark: Bool
    let accentHex: String

    var colors: [Color] { colorsHex.map { Color(hex: $0) } }
    var accent: Color { Color(hex: accentHex) }

    static let all: [AppTheme] = [
        AppTheme(id: "deepBlue", name: "深空蓝", colorsHex: ["#0f2027", "#203a43", "#2c5364"], dark: true, accentHex: "#4fc3f7"),
        AppTheme(id: "aurora", name: "极光紫", colorsHex: ["#1a0b2e", "#43227a", "#7b2ff7"], dark: true, accentHex: "#b39ddb"),
        AppTheme(id: "jade", name: "翡翠绿", colorsHex: ["#07271c", "#0f5132", "#198754"], dark: true, accentHex: "#34d399"),
        AppTheme(id: "sunset", name: "落日橙", colorsHex: ["#2b1106", "#8a3a12", "#d97706"], dark: true, accentHex: "#fbbf24"),
        AppTheme(id: "rose", name: "玫瑰粉", colorsHex: ["#2d0b1c", "#7a1f3d", "#c2185b"], dark: true, accentHex: "#f48fb1"),
        AppTheme(id: "cloud", name: "云端白", colorsHex: ["#dceafa", "#eef6fd", "#ffffff"], dark: false, accentHex: "#0284c7"),
    ]
    static let `default` = all[0]
}

extension Color {
    /// 功能区块表面：叠在主题渐变/壁纸之上的半透明色（主题色、壁纸与透明度透出，同时保证文字可读性）
    static func blockSurface(_ dark: Bool) -> Color { dark ? .black.opacity(0.38) : .white.opacity(0.62) }
    /// 文字密集区块表面（运行记录 / 日志）：不透明度更高，保证密集文字可读
    static func textSurface(_ dark: Bool) -> Color { dark ? .black.opacity(0.45) : .white.opacity(0.75) }
}

/// 功能区块背景：半透明表面，让主题渐变 + 壁纸 + 透明度覆盖到各功能区块（同时保证文字可读）
private struct BlockSurfaceModifier: ViewModifier {
    @EnvironmentObject var model: AppModel
    var dense: Bool = false
    func body(content: Content) -> some View {
        let dark = model.theme.dark
        content.background(dense ? Color.textSurface(dark) : Color.blockSurface(dark))
    }
}
extension View {
    /// 功能区块背景（主题/壁纸透出）；dense = 文字密集区（运行记录/日志）
    func blockSurface(_ dense: Bool = false) -> some View { modifier(BlockSurfaceModifier(dense: dense)) }
}

/// 全局背景层：主题渐变 + 可选背景图片（透明度由设置控制）；只填充窗口，不改变窗口/弹窗尺寸
struct BoxSendBackground: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let t = model.theme
        ZStack {
            LinearGradient(colors: t.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            if let img = model.backgroundNSImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .opacity(model.config.appearance.bgOpacity)
            }
        }
        .ignoresSafeArea()
    }
}

/// 统一外观：渐变/背景图 + 主题强调色 + 明暗模式（主题色与背景覆盖所有窗口与区块）
private struct BoxSendAppearanceModifier: ViewModifier {
    @EnvironmentObject var model: AppModel
    func body(content: Content) -> some View {
        content
            .background(BoxSendBackground())
            .tint(model.theme.accent)
            .preferredColorScheme(model.theme.dark ? .dark : .light)
    }
}

extension View {
    func boxsendAppearance() -> some View { modifier(BoxSendAppearanceModifier()) }
}

/// 打开「批量添加站点」弹窗的请求（item 驱动，避免 sheet(isPresented:) 闭包读到过期状态）
struct AddSitesRequest: Identifiable {
    let id = UUID()
    /// -1 = 未指定分组（弹窗内可选）；>=0 = 锁定该分组
    let group: Int
}

// MARK: - 主框架

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = Int(ProcessInfo.processInfo.environment["BOXSEND_START_TAB"] ?? "") ?? 0

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
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(6)
        }
        .padding(.top, 12)   // 全屏时顶部留白
        .safeAreaInset(edge: .bottom) { statusBar }
        .boxsendAppearance()
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

/// 带「显示」按钮的密码输入框（默认黑点，点右侧眼睛切换明文 / 黑点）
struct RevealField: View {
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if revealed { TextField("", text: $text) } else { SecureField("", text: $text) }
            }
            .textFieldStyle(.roundedBorder)
            Button { revealed.toggle() } label: {
                Image(systemName: revealed ? "eye.slash.fill" : "eye.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(revealed ? "隐藏" : "显示")
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
        let allSelected = !members.isEmpty && members.allSatisfy { model.selectedTargets.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(allSelected ? "全不选" : "全选") {
                    for m in members {
                        if allSelected { model.selectedTargets.remove(m.id) } else { model.selectedTargets.insert(m.id) }
                    }
                    model.saveConfig()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(allSelected ? "取消该分组全部站点" : "选中该分组全部站点作为转种目标")
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

    /// 目标站点卡片：名称 + 上传限速 + 转种/推送实时状态（点击卡片选中，加深色 = 已选中）
    private func targetSiteCard(_ s: SiteConfig) -> some View {
        let limit = model.config.effectiveUpLimit(siteID: s.id)
        let selected = model.selectedTargets.contains(s.id)
        return VStack(alignment: .leading, spacing: 5) {
            Text(s.name).fontWeight(selected ? .semibold : .medium).lineLimit(1)
            Text(limit > 0 ? "上传限速 \(Int((Double(limit) / 1048576.0).rounded())) MB/s" : "上传限速 不限速")
                .font(.caption).foregroundStyle(.secondary)
            if let e = model.reseedEvents[s.id] { eventChip(e) }
            if let e = model.pushEvents[s.id] { eventChip(e) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Color.blockSurface(model.theme.dark)
            Color.accentColor.opacity(selected ? 0.3 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if selected { model.selectedTargets.remove(s.id) } else { model.selectedTargets.insert(s.id) }
            model.saveConfig()
        }
        .help(selected ? "已选中为转种目标，点击取消" : "点击选中为转种目标")
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
                    .blockSurface(true)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: bindings / 状态提示

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
            .blockSurface()
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
    @State private var addSheetReq: AddSitesRequest?
    @State private var manualCookiePick: SitePick?
    @State private var confirmReq: ConfirmRequest?
    @State private var showConfirm1 = false
    @State private var showConfirm2 = false
    @State private var draggingSite: String?
    @State private var siteSortNum: [String: String] = [:]

    /// 自适应列宽：常规窗口一行 4 张，全屏窗口自动放更多
    private let cardColumns = [GridItem(.adaptive(minimum: 172, maximum: 400), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("添加分组和站点").font(.headline)
                    HStack(spacing: 10) {
                        Text("分组名").foregroundStyle(.secondary)
                        TextField("", text: $newGroupName, prompt: Text("分组名"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                            // 固定宽度下长文本只显示末尾（看似偏右），宽度随输入扩展以保证始终居中
                            .frame(width: CGFloat(max(150, min(360, newGroupName.count * 14 + 44))))
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
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Button(model.cookieSyncBusy ? "同步中…" : "同步 Cookie") {
                            model.syncCookies(from: .both)
                        }
                        .font(.caption)
                        .disabled(model.cookieSyncBusy)
                        .help("同时同步 PT-depiler Gist 与 CookieCloud 的 cookie 备份（互为补充：本地已检测有效的保留，同步后自动重检并用另一来源补充仍失效的站点）")
                        Button(model.anyChecking ? "检测中…" : "检测 Cookie") {
                            model.checkAllManagedCookies()
                        }
                        .font(.caption)
                        .disabled(model.anyChecking)
                        .help("批量检测所有分组已添加站点的 cookie 有效性")
                        Spacer()
                    }
                }
                .runCard()

                ForEach(model.config.groups.indices, id: \.self) { gi in
                    let gname = model.config.groups[gi].name
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Text("分组：\(gname)").font(.headline)
                            Button {
                                addSheetReq = AddSitesRequest(group: gi)
                            } label: {
                                Label("添加站点", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("为此分组添加站点（弹窗中无需再选分组）")
                            Button {
                                confirmReq = ConfirmRequest(kind: .removeGroup, index: gi,
                                                            name: gname,
                                                            count: model.groupMembers(gi).count)
                                showConfirm1 = true
                            } label: {
                                Label("移除分组", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.red)
                            .help("删除分组（组内站点移到无分组），需两次确认")
                            Spacer()
                        }
                        groupToolbar(gi)
                        siteCardGrid(model.groupMembers(gi), gi: gi)
                        if model.groupMembers(gi).isEmpty {
                            Text("该分组还没有站点：点分组名旁的「添加站点」添加。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .runCard()
                }

                if !model.unassignedManagedSites.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("无分组").font(.headline)
                        groupToolbar(-1)
                        siteCardGrid(model.unassignedManagedSites, gi: -1)
                    }
                    .runCard()
                }

                if model.managedSites.isEmpty {
                    Text("还没有添加站点：点分组卡片上的「添加站点」批量选择。")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .runCard()
                }
            }
            .padding(16)
        }
        .sheet(item: $addSheetReq) { req in
            AddSitesSheet(fixedGroup: req.group)
        }
        .sheet(item: $manualCookiePick) { pick in
            ManualCookieSheet(sites: pick.sites)
        }
        .alert(confirmReq?.firstTitle ?? "确认", isPresented: $showConfirm1) {
            Button("取消", role: .cancel) {
                showConfirm1 = false
                confirmReq = nil
            }
            Button("继续", role: .destructive) {
                showConfirm1 = false
                showConfirm2 = true
            }
        } message: {
            Text(confirmReq?.firstMessage ?? "")
        }
        .alert("再次确认", isPresented: $showConfirm2) {
            Button("取消", role: .cancel) {
                showConfirm2 = false
                confirmReq = nil
            }
            Button("确定移除", role: .destructive) {
                confirmReq?.perform(model)
                showConfirm2 = false
                confirmReq = nil
            }
        } message: {
            Text(confirmReq?.secondMessage ?? "")
        }
        .onAppear { model.autoCheckSites() }
    }

    /// 分组工具栏：N 站 / 全选（切换） / 手动添加 / 移除站点
    private func groupToolbar(_ gi: Int) -> some View {
        let members = model.groupMembers(gi)
        let enabledMembers = members.filter(\.enabled)
        let allOn = !members.isEmpty && members.allSatisfy(\.enabled)
        return HStack(spacing: 8) {
            Text("\(members.count) 站").font(.caption).foregroundStyle(.secondary)
            Button(allOn ? "全不选" : "全选") { model.setGroupSitesEnabled(gi, on: !allOn) }
                .font(.caption)
                .disabled(members.isEmpty)
                .help(allOn ? "停用该分组全部站点" : "开启该分组全部站点")
            Button("手动添加") {
                manualCookiePick = SitePick(sites: enabledMembers)
            }
            .font(.caption)
            .disabled(enabledMembers.isEmpty)
            .help("为选中（加深色）的站点手动填写 cookie")
            Button("移除站点") {
                let gname = gi >= 0 && gi < model.config.groups.count ? model.config.groups[gi].name : "无分组"
                confirmReq = ConfirmRequest(kind: .removeSites, index: gi,
                                            name: gname, count: enabledMembers.count)
                showConfirm1 = true
            }
            .font(.caption)
            .disabled(enabledMembers.isEmpty)
            .help("移除当前选中（加深色）的站点，保留 cookie 与设置，需两次确认")
            Spacer()
        }
    }

    private func siteCardGrid(_ sites: [SiteConfig], gi: Int) -> some View {
        LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 10) {
            ForEach(sites, id: \.id) { s in
                siteCard(s, gi: gi)
            }
        }
    }

    /// 站点卡片：名称 / 序号 / 地址 / cookie 有效性 / 上传限速
    /// 点击卡片开启 / 停用（加深色 = 已开启）；组内可拖拽或输入序号排序
    private func siteCard(_ s: SiteConfig, gi: Int) -> some View {
        let on = s.enabled
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).fontWeight(on ? .semibold : .medium).lineLimit(1)
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                    Text(s.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { model.setSiteEnabled(siteID: s.id, !on) }
                TextField("", text: siteNumBinding(s.id), prompt: Text("\(siteOrderHint(s, gi: gi))"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 40)
                    .font(.caption)
                    .onSubmit { applySiteSort(gi) }
                    .help("输入排序序号，回车重排组内卡片")
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 16)
                    .onDrag {
                        draggingSite = s.id
                        return NSItemProvider(object: s.id as NSString)
                    }
                    .help("按住拖拽调整组内位置")
            }
            cookieStatusView(for: s)
            HStack(spacing: 6) {
                Text("上传限速").font(.caption).foregroundStyle(.secondary)
                IntLimitField(initial: model.siteUpLimitMBInt[s.id] ?? 0, center: true) { mb in
                    model.setSiteUpLimitMBInt(mb, siteID: s.id)
                    model.saveConfig()
                }
                .frame(width: 60)
                Text("MB/s").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Color.blockSurface(model.theme.dark)
            Color.accentColor.opacity(on ? 0.3 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(on || draggingSite == s.id ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: on || draggingSite == s.id ? 1.5 : 1)
        )
        .opacity(draggingSite == s.id ? 0.4 : 1)
        .help(on ? "已开启（加深色），点击停用" : "未开启，点击开启")
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
    @State private var targetGroup: Int
    @State private var order: [String] = []
    /// >= 0：从分组头部「添加站点」进入，弹窗锁定该分组，不再显示分组选择
    let fixedGroup: Int

    init(fixedGroup: Int = -1) {
        self.fixedGroup = fixedGroup
        _targetGroup = State(initialValue: fixedGroup)
    }
    @State private var sortNum: [String: String] = [:]
    @State private var dragging: String?
    @State private var dupAlert = ""
    @State private var showDupAlert = false

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

    private var allChecked: Bool {
        !displayIDs.isEmpty && displayIDs.allSatisfy { checked.contains($0) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(fixedGroup >= 0
                     ? "批量添加站点（加入分组：\(model.config.groups[fixedGroup].name)）"
                     : "批量添加站点").font(.headline)
                Spacer()
                Text("已选 \(checked.count)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索站名 / id / 地址", text: $query)
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                if fixedGroup < 0 {
                    Picker("加入分组", selection: $targetGroup) {
                        Text("无分组").tag(-1)
                        ForEach(model.config.groups.indices, id: \.self) { i in
                            Text(model.config.groups[i].name).tag(i)
                        }
                    }
                    .frame(maxWidth: 140)
                }
                Button(allChecked ? "全不选" : "全选") {
                    if allChecked { checked.removeAll() } else { checked = Set(displayIDs) }
                }
                .font(.caption)
                .help("一键选中 / 取消当前列表中全部站点")
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
                Text("点击卡片选中要添加的站点（加深色 = 已选中）；拖拽把手或输入序号排序；添加后默认开启（限速默认取分组上传限速，未设 = 10 MB/s）。")
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
        .onAppear {
            // 默认排序：数字开头的名称在前，其余按拼音字母顺序
            order = model.config.sourceSites
                .filter { !$0.managed }
                .sorted { NameSort.isBefore($0.name, $1.name) }
                .map { $0.id }
        }
        .alert("序号重复", isPresented: $showDupAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(dupAlert)
        }
        .boxsendAppearance()
    }

    private func card(_ id: String) -> some View {
        let s = model.config.sourceSites.first { $0.id == id }
        return Group {
            if let s {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name)
                                .fontWeight(checked.contains(id) ? .semibold : .medium)
                                .lineLimit(1)
                            Text(s.url)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
                        }
                        TextField("", text: numBinding(id), prompt: Text("序"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                            .font(.caption)
                            .frame(width: 38)
                            .onSubmit { applySortNumbers() }
                            .help("输入数字 = 排到该序号位置（如 2 = 第 2 位），回车生效")
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 16)
                            .onDrag {
                                dragging = id
                                return NSItemProvider(object: id as NSString)
                            }
                            .help("按住拖拽调整顺序")
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    Color.blockSurface(model.theme.dark)
                    Color.accentColor.opacity(checked.contains(id) ? 0.3 : 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder((checked.contains(id) || dragging == id) ? Color.accentColor : Color(nsColor: .separatorColor),
                                      lineWidth: (checked.contains(id) || dragging == id) ? 1.5 : 1)
                )
            }
        }
        .opacity(dragging == id ? 0.4 : 1)
        .onDrop(of: [.text], delegate: SiteReorderDrop(target: id, dragging: $dragging, order: $order))
    }

    private func siteName(_ id: String) -> String {
        model.config.sourceSites.first { $0.id == id }?.name ?? id
    }

    private func numBinding(_ id: String) -> Binding<String> {
        Binding(get: { sortNum[id] ?? "" },
                set: { sortNum[id] = $0.filter { $0.isNumber } })
    }

    private func applySortNumbers() {
        // 序号 = 目标位置：输入 N 将该站点排到第 N 位；位置冲突时顺移/回移；未输入序号的保持相对顺序填充剩余位置
        var nums: [String: Int] = [:]
        for (k, v) in sortNum { if let n = Int(v), n > 0 { nums[k] = n } }
        guard !nums.isEmpty else { return }
        // 重复检测：多个站点填了同一序号 → 弹窗提醒（与哪个站点、哪个序号重复），不重排
        var dupParts: [String] = []
        for (n, ids) in Dictionary(grouping: nums.keys, by: { nums[$0]! }).sorted(by: { $0.key < $1.key }) where ids.count > 1 {
            dupParts.append("「\(ids.map { siteName($0) }.joined(separator: "、"))」都填了序号 \(n)")
        }
        if !dupParts.isEmpty {
            dupAlert = "序号重复：\(dupParts.joined(separator: "；"))。请修改重复序号后再回车排序。"
            showDupAlert = true
            return
        }
        let count = order.count
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        let numbered = order.filter { nums[$0] != nil }
            .sorted { a, b in
                let na = nums[a]!, nb = nums[b]!
                if na != nb { return na < nb }
                return index[a]! < index[b]!
            }
        var final: [String?] = Array(repeating: nil, count: count)
        for id in numbered {
            let target = min(max(nums[id]! - 1, 0), count - 1)
            var t = target
            while t < count && final[t] != nil { t += 1 }
            if t == count {
                t = target
                while t > 0 && final[t] != nil { t -= 1 }
            }
            final[t] = id
        }
        var un = order.filter { nums[$0] == nil }.makeIterator()
        for i in 0..<count where final[i] == nil { final[i] = un.next() }
        withAnimation { order = final.compactMap { $0 } }
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

/// 手动添加站点 cookie（分组工具栏「手动添加」按钮弹出；选中多个站点时可在弹窗内切换）
struct ManualCookieSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let sites: [SiteConfig]
    @State private var siteID: String = ""
    @State private var text = ""

    private var current: SiteConfig? {
        sites.first(where: { $0.id == siteID }) ?? sites.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let c = current {
                Text("添加 \(c.name)（\(model.siteHost(c))）的 cookie")
                    .font(.headline)
            }
            if sites.count > 1 {
                Picker("站点", selection: $siteID) {
                    ForEach(sites) { s in
                        Text(s.name).tag(s.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 220)
            }
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
                    if let c = current {
                        model.addSiteCookie(siteID: c.id, raw: text)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || current == nil)
            }
        }
        .padding()
        .frame(width: 480)
        .onAppear { siteID = sites.first?.id ?? "" }
        .boxsendAppearance()
    }
}

/// 手动添加 cookie 的站点集合（点击选中卡片后点「手动添加」弹出）
struct SitePick: Identifiable {
    let id = UUID()
    let sites: [SiteConfig]
}

/// 两次确认请求（移除分组 / 移除站点）：第一次确认 → 「继续」→ 第二次确认 → 「确定移除」
struct ConfirmRequest {
    enum Kind { case removeGroup, removeSites }
    var kind: Kind
    var index: Int
    var name: String
    var count: Int

    var firstTitle: String { kind == .removeGroup ? "移除分组" : "移除站点" }
    var firstMessage: String {
        switch kind {
        case .removeGroup:
            return "将移除分组「\(name)」，组内 \(count) 个站点会移到「无分组」区块。"
        case .removeSites:
            return "将移除分组「\(name)」中当前选中（加深色）的 \(count) 个站点（保留 cookie 与限速设置）。"
        }
    }
    var secondMessage: String {
        switch kind {
        case .removeGroup:
            return "再次确认：确定移除分组「\(name)」？此操作不可撤销。"
        case .removeSites:
            return "再次确认：确定移除选中的 \(count) 个站点？此操作不可撤销。"
        }
    }
    @MainActor func perform(_ model: AppModel) {
        switch kind {
        case .removeGroup: model.removeGroup(at: index)
        case .removeSites: model.removeEnabledSitesInGroup(index)
        }
    }
}


/// Cookie / 下载器页自定义卡片区块（Form 会把行内 TextField 抽到右列，这里用自定义布局保证：功能名上一行、输入框下一行、内容居左）
private struct CardSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .blockSurface()
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// 功能名称在上一行、输入框在下一行（输入框全宽、内容居左）
private struct LabeledRow<Field: View>: View {
    let label: String
    let field: Field
    init(_ label: String, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            field
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Cookie

struct CookiesView: View {
    @EnvironmentObject var model: AppModel
    @State private var zipPassword = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CardSection("PT-depiler Gist 同步") {
                    LabeledRow("gistID") {
                        TextField("", text: gistStringBinding(\.gistID)).textFieldStyle(.roundedBorder)
                    }
                    LabeledRow("GitHub token") {
                        RevealField(text: gistStringBinding(\.token))
                    }
                    LabeledRow("PT-depiler 备份密码") {
                        SecureField("", text: gistStringBinding(\.encryptionKey)).textFieldStyle(.roundedBorder)
                    }
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("轮询（自动同步间隔，分钟，最小 5）").font(.caption).foregroundStyle(.secondary)
                            TextField("", text: pollBinding).textFieldStyle(.roundedBorder).frame(width: 60)
                        }
                        Toggle("自动定时同步", isOn: autoBinding)
                        Button(model.cookieSyncBusy ? "同步中…" : "立即同步") { model.gistSyncNow() }
                            .disabled(model.cookieSyncBusy)
                    }
                    if !model.lastGistSyncText.isEmpty {
                        LabeledContent("上次 Gist 同步", value: model.lastGistSyncText)
                    }
                    Text("与 PT-depiler 的 Gist 备份联动；「立即同步」只拉取本来源，站点分组页顶部「同步 Cookie」同时同步 Gist 与 CookieCloud（互为补充）。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CardSection("CookieCloud 同步") {
                    LabeledRow("服务器地址") {
                        TextField("", text: ccStringBinding(\.host), prompt: Text("http://vps:8088 或 https://cookiecloud.xxx")).textFieldStyle(.roundedBorder)
                    }
                    LabeledRow("KEY（UUID）") {
                        RevealField(text: ccStringBinding(\.key))
                    }
                    LabeledRow("端对端加密密码") {
                        RevealField(text: ccStringBinding(\.password))
                    }
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("轮询（自动同步间隔，分钟，最小 5）").font(.caption).foregroundStyle(.secondary)
                            TextField("", text: ccPollBinding).textFieldStyle(.roundedBorder).frame(width: 60)
                        }
                        Toggle("自动定时同步", isOn: ccAutoBinding)
                        Button(model.cookieSyncBusy ? "同步中…" : "立即同步") { model.cookieCloudNow() }
                            .disabled(model.cookieSyncBusy)
                    }
                    if let msg = model.cookieMessage, !msg.isEmpty {
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("用 CookieCloud 扩展（easychen/CookieCloud）生成的 KEY（UUID）+ 端对端加密密码连接：服务器只存密文，解密在本地，拉取后覆盖本地 cookie。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CardSection("PT-depiler 本地备份") {
                    LabeledRow("备份密码") {
                        SecureField("", text: $zipPassword).textFieldStyle(.roundedBorder)
                    }
                    Button("导入 PTD_backup_*.zip …") { pickZip() }
                    Text("在 PT-depiler 中「备份 → 本地备份」导出 zip 后导入；导入会整体替换本地 cookie。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("清空本地 Cookie", role: .destructive) { model.clearCookies() }
                }
                CardSection("备份目录监控") {
                    LabeledRow("监控目录") {
                        TextField("", text: Binding(get: { model.zipDir() }, set: { model.setZipDir($0) })).textFieldStyle(.roundedBorder)
                    }
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("备份密码").font(.caption).foregroundStyle(.secondary)
                            SecureField("", text: Binding(get: { model.zipPassword() }, set: { model.setZipPassword($0) })).textFieldStyle(.roundedBorder).frame(width: 180)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("轮询（分钟）").font(.caption).foregroundStyle(.secondary)
                            IntLimitField(initial: model.config.zipWatch?.pollMinutes ?? 5) { model.setZipPollMinutes($0 ?? 5) }.frame(width: 60)
                        }
                        Toggle("启用备份目录监控", isOn: Binding(get: { model.zipAuto }, set: { model.setZipAuto($0) }))
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
                }
            }
            .padding(20)
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
        Binding(get: { model.config.cookieCloud?[keyPath: kp] ?? "" },
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CardSection("qBittorrent / Transmission（VPS 上）") {
                    LabeledRow("类型") {
                        Picker("", selection: $model.config.downloader.type) {
                            Text("qBittorrent").tag(DownloaderType.qbittorrent)
                            Text("Transmission").tag(DownloaderType.transmission)
                        }
                        .labelsHidden()
                    }
                    LabeledRow("URL（VPS 隧道地址）") {
                        TextField("", text: $model.config.downloader.url).textFieldStyle(.roundedBorder)
                    }
                    LabeledRow("用户名") {
                        TextField("", text: $model.config.downloader.username).textFieldStyle(.roundedBorder)
                    }
                    LabeledRow("密码") {
                        RevealField(text: $model.config.downloader.password)
                    }
                    LabeledRow("保存路径（空 = 下载器默认）") {
                        TextField("", text: optBinding(\.savePath)).textFieldStyle(.roundedBorder)
                    }
                    LabeledRow("分类（空 = 无）") {
                        TextField("", text: optBinding(\.category)).textFieldStyle(.roundedBorder)
                    }
                    Toggle("添加后跳过校验（skipChecking）", isOn: $model.config.downloader.skipChecking)
                }
                CardSection("连接检测") {
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
                }
                CardSection("种子大小检测") {
                    LabeledRow("VPS 剩余空间（GB，空 = 不做大小检测）") {
                        IntLimitField(initial: model.config.downloader.vpsFreeGB ?? 0) { model.setVpsFreeGB($0) }.frame(width: 60)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("超过剩余空间时").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Picker("", selection: $model.config.downloader.sizeGuardMode) {
                                Text("提醒（继续转种）").tag(SizeGuardMode.warn)
                                Text("跳过（不转种不推送）").tag(SizeGuardMode.skip)
                            }
                            .labelsHidden()
                            IntLimitField(initial: model.config.downloader.sizeGuardMarginGB) { model.setVpsFreeMargin($0) }
                                .frame(width: 50)
                            Text("安全边际（GB）").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("可用空间 = 剩余 - 边际；剩余空间需手动维护（qB WebAPI 无磁盘接口），空间变化大时记得更新。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
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
            .blockSurface(true)
        }
        .padding()
    }
}

// MARK: - 主题

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var showTutorial = false

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CardSection("使用教程") {
                    HStack(spacing: 10) {
                        Button {
                            showTutorial = true
                        } label: {
                            Label("查看使用教程", systemImage: "book.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        Text("图文教程：添加站点分组、配置 Cookie、批量转种、推送下载器与外观设置。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                CardSection("主题（渐变色）") {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(AppTheme.all) { t in
                            themeCard(t)
                        }
                    }
                    Text("点击卡片切换主题；主题渐变、强调色与明暗模式覆盖所有窗口与区块，保持风格统一。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CardSection("背景图片") {
                    HStack(spacing: 10) {
                        Button(model.config.appearance.bgImage == nil ? "选择图片…" : "更换图片…") {
                            model.chooseBackgroundImage()
                        }
                        .buttonStyle(.borderedProminent)
                        if model.config.appearance.bgImage != nil {
                            Button("移除背景图片", role: .destructive) { model.clearBackgroundImage() }
                                .controlSize(.small)
                        }
                    }
                    HStack(spacing: 10) {
                        Text("背景图片透明度").font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { model.config.appearance.bgOpacity },
                                              set: { model.setBackgroundOpacity($0) }),
                               in: 0...1)
                        Text("\(Int((model.config.appearance.bgOpacity * 100).rounded()))%")
                            .font(.caption).frame(width: 44, alignment: .trailing)
                    }
                    .disabled(model.config.appearance.bgImage == nil)
                    Text("背景图片铺满窗口（cover 裁切），不改变窗口与各弹窗的大小比例；主题色、背景图片与透明度覆盖所有窗口与区块，风格统一。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $showTutorial) {
            TutorialSheet()
        }
    }

    private func themeCard(_ t: AppTheme) -> some View {
        let selected = model.config.appearance.themeID == t.id
        return VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: t.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(height: 64)
            Text(t.name)
                .font(.caption)
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .padding(6)
        .blockSurface()
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? t.accent : Color(nsColor: .separatorColor), lineWidth: selected ? 3 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { model.setTheme(t.id) }
        .help("切换到「\(t.name)」主题")
    }
}

/// 使用教程弹窗（图文教程，配图打包于 Resources/tutorial/）
struct TutorialSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 10) {
            Text("BoxSend 使用教程").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("1. 添加站点与分组", image: "sites", steps: [
                        "「站点分组」页顶部输入分组名并设置上传限速（默认 10 MB/s），点「添加分组」。",
                        "点分组名旁的「添加站点」批量添加：搜索站点、点击卡片选中（加深色 = 已选），拖拽或输入序号排序（序号重复会弹窗提示），点「添加」。",
                        "点击站点卡片开启 / 停用该站；「全选」一键切换分组内全部站点；「手动添加」为选中站点填写 cookie。",
                        "「检测 Cookie」批量检查 cookie 有效性；「移除站点」「移除分组」均需两次确认。",
                    ])
                    section("2. 配置与备份 Cookie", image: "cookies", steps: [
                        "PT-depiler Gist 同步：填写 GitHub Token 与 Gist ID，可开启自动同步 / 自动扫描并设置间隔秒数。",
                        "CookieCloud 同步备份：填写用户 KEY、UUID 与端对端加密密码。",
                        "两路备份互为补充：某一站点在一处的 cookie 失效时，同步后自动用另一来源补充。",
                        "「同步 Cookie」立即执行两路同步；「立即扫描」检查 PT-depiler 备份目录。",
                    ])
                    section("3. 批量转种", image: "run", steps: [
                        "「批量转种」页粘贴种子详情页链接，勾选「转种到目标站」与「推送到下载器」。",
                        "勾选转种分组（「全选」= 全部分组）后点「开始运行」。",
                        "按分组顺序执行：获取种子 → 依次上传到组内已开启站点（限速取分组上传限速）→ 转种成功的种子自动推送到下载器。",
                        "点「运行记录」展开查看每个站点的转种 / 推送结果。",
                    ])
                    section("4. 推送到 VPS 下载器", image: "downloader", steps: [
                        "填写下载器（qBittorrent Web UI）地址、端口与密码，通常经 de5 隧道连接 VPS。",
                        "「检验连接」验证可用性；勾选「跳过检验」后推送时不再校验。",
                        "转种成功的种子会自动推送到下载器开始下载。",
                    ])
                    section("5. 外观设置", image: "settings", steps: [
                        "「设置」页选择渐变主题；主题渐变、强调色与明暗模式覆盖所有窗口与区块。",
                        "可添加背景图片（PNG/JPG/HEIC）并用滑块调整透明度，不改变窗口与各弹窗的大小比例。",
                        "「使用教程」按钮可随时查看本图文教程。",
                    ])
                }
                .padding(2)
            }
            HStack {
                Text("提示：截图为深色主题示例，实际外观随「设置」页的主题 / 壁纸变化。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 800, height: 640)
        .boxsendAppearance()
    }

    private func section(_ title: String, image: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).fontWeight(.semibold)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(i + 1).").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .trailing)
                    Text(step).font(.caption)
                }
            }
            tutorialImage(image)
                .padding(.top, 4)
        }
    }

    private func tutorialImage(_ name: String) -> some View {
        Group {
            if let url = Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "tutorial"),
               let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Label("教程配图缺失（Resources/tutorial/\(name).jpg）", systemImage: "photo")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
