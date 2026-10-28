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
    /// true = 辅种区块进来的：不加分组，添加即参与辅种
    var assist = false
}

// MARK: - 主框架

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    /// 起始页：截图脚本用 BOXSEND_START_TAB 指定；辅种收起时别停在一页不存在的标签上
    @State private var tab = ContentView.startTab()

    private static func startTab() -> Int {
        let want = Int(ProcessInfo.processInfo.environment["BOXSEND_START_TAB"] ?? "") ?? 0
        return want == 6 && !AssistFeature.enabled ? 0 : want
    }

    var body: some View {
        TabView(selection: $tab) {
            RunView()
                .tabItem { Label("批量转种", systemImage: "paperplane.fill") }
                .tag(0)
            // 辅种紧跟批量转种：两件事都在「把种子铺到更多站」这条线上。
            // 这一版先收起来（AssistFeature.enabled = false），页面代码整块留着
            if AssistFeature.enabled {
                AssistView()
                    .tabItem { Label("辅种", systemImage: "square.stack.3d.up.fill") }
                    .tag(6)
            }
            SitesView()
                .tabItem { Label("站点分组", systemImage: "server.rack") }
                .tag(1)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(5)
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
                sourceSiteMenu
                Spacer()
                if let e = model.sourcePushEvent { eventChip(e) }
            }
            TextField("粘贴种子详情页链接（如 https://…/details.php?id=…）", text: $model.detailURL)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Toggle("源站引用", isOn: $model.sourceQuoteEnabled)
                    .fixedSize()
                    .help("源站简介自带引用时不用勾选；勾选后右侧文本会加在每个目标站发种简介的最上面，并用 [quote][/quote] 引用包起来")
                TextField("加在简介最上面的引用文本（如：转载自LuckPT，感谢发布者）", text: $model.sourceQuoteText, prompt: Text("源站引用文本"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.sourceQuoteEnabled)
                    .frame(maxWidth: 560)
            }
            .onChange(of: model.sourceQuoteEnabled) { _ in model.saveConfig() }
            .onChange(of: model.sourceQuoteText) { _ in model.saveConfig() }
            if let hint = model.sourceQuoteHint {
                Text(hint).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 20) {
                Toggle("转种到目标站", isOn: $model.doReseed)
                Toggle("推送到下载器", isOn: $model.doPush)
                // 测速按钮挨着「开始运行」：转之前手点一次看速度，不点也照样能开转
                Button(model.testingSSH ? "测速中…" : "测试上传速度") { model.testSSH() }
                    .fixedSize()
                    .disabled(model.testingSSH || model.running || !model.sshConfig.isConfigured)
                    .help(model.sshConfig.isConfigured
                          ? "到服务器上量一次公网上行，实测速度显示在下一行；"
                            + "服务器信息填在「下载器」页「转种服务器」卡片里"
                          : "先到「下载器」页的「转种服务器」卡片填服务器地址与用户名，才能测速")
                Button(model.running ? "运行中…" : "开始运行") { model.run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.running)
                    .help("测不测速都能直接开转；想知道服务器有没有被限速，点左边的「测试上传速度」")
                // 批次概览：本批会转哪几个分组、几站，免得勾错分组就跑
                Text(model.runSelectionSummary)
                    .font(.callout)
                    .foregroundStyle(model.runTargets.isEmpty ? Color.orange : Color.secondary)
                    .fixedSize()
                    .help("勾选的转种分组：\(model.runSelectedGroupNames.isEmpty ? "无" : model.runSelectedGroupNames.joined(separator: "、"))\n"
                          + "勾选的站点：\(model.runTargets.map(\.name).joined(separator: "、"))")
                Spacer()
            }
            // 按钮下面这一行：运行进度与测速结果共用（测速完就把速度留在这儿）
            if model.running {
                Text(model.runningStep).font(.caption).foregroundStyle(.secondary)
            } else if model.testingSSH {
                Text("正在测试服务器上传速度…").font(.caption).foregroundStyle(.secondary)
            } else if let r = model.sshTestResult {
                Text(r).font(.caption)
                    .foregroundStyle(r.hasPrefix("失败") ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .runCard()
    }

    /// 源站菜单：默认按链接域名自动识别；站点分组里添加过的站点都能指定为源站
    private var sourceSiteMenu: some View {
        Menu {
            Button("自动识别（按链接域名）") { model.sourceSiteID = nil }
            Divider()
            ForEach(model.managedSites, id: \.id) { s in
                Button(s.name) { model.sourceSiteID = s.id }
            }
        } label: {
            Text("源站：\(model.sourceSiteLabel)")
                .font(.callout)
                .foregroundStyle(model.sourceSiteID == nil ? Color.secondary : Color.primary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.blockSurface(model.theme.dark))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("默认按链接域名识别源站；已添加的站点都可以指定为源站（例如站点换了域名、或同一站点有多个入口）")
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
            SiteFlow(minWidth: 104, maxWidth: 150, spacing: 8) {
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
            // 有转种信息才多占那一格：SiteFlow 每排都按当排最高的卡片重算行高，
            // 中途长高会把整排和分组外框一起顶开，不会盖到下面那排
            if let e = model.reseedEvents[s.id] { eventChip(e) }
            if let e = model.pushEvents[s.id] { eventChip(e) }
            if let link = seedPageURL(s) { seedButton(link) }
            detailLine(s)
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
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if selected { model.selectedTargets.remove(s.id) } else { model.selectedTargets.insert(s.id) }
            model.saveConfig()
        }
        .help(selected ? "已选中为转种目标，点击取消" : "点击选中为转种目标")
    }

    /// 站内那条种子的详情页：推送事件优先（它带的就是刚推的那条）
    private func seedPageURL(_ s: SiteConfig) -> String? {
        for e in [model.pushEvents[s.id], model.reseedEvents[s.id]].compactMap({ $0 })
        where !e.url.isEmpty { return e.url }
        return nil
    }

    // MARK: 运行记录（点开才显示：最近一次运行 + 运行日志，日志不再单独一页）

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    showHistory.toggle()
                } label: {
                    Label(showHistory ? "收起运行记录" : "运行记录",
                          systemImage: showHistory ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.bordered)
                if showHistory {
                    Button("清空日志") { model.clearNotes() }
                        .disabled(model.notes.isEmpty)
                        .help("清掉界面上显示的这些日志行（不影响转种记录）")
                }
                Spacer()
            }
            if showHistory {
                labeledBlock("最近一次运行", model.lastReport.isEmpty ? "（还没有运行记录）" : model.lastReport)
                labeledBlock("运行日志",
                             model.notes.isEmpty ? "（暂无日志）"
                                                 : model.notes.reversed().joined(separator: "\n"))
            }
        }
    }

    private func labeledBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .blockSurface(true)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
    // MARK: 站点卡片状态

    /// 状态胶囊：图标 + 短文案。窄卡片里让文字竖排换行（不截断），完整原因看悬浮提示
    private func eventChip(_ e: AppModel.TargetEvent) -> some View {
        chipView(Text(e.text), chipTint(e.phase), chipIcon(e.phase),
                 tip: e.detail.isEmpty ? e.text : e.detail)
    }

    private func chipView(_ text: Text, _ tint: Color, _ icon: String, tip: String) -> some View {
        HStack(alignment: .center, spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            text.font(.caption)
                .lineLimit(2).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.13)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(tip)
    }

    private func seedButton(_ link: String) -> some View {
        Button {
            model.openURL(link)
        } label: {
            Label("种子页", systemImage: "arrow.up.forward.app").font(.caption)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .tint(Color.accentColor)
        .help("在浏览器里打开站内那条种子：\(link)")
    }

    private func chipTint(_ p: AppModel.TargetEvent.Phase) -> Color {
        switch p {
        case .working: return .secondary
        case .done: return .green
        case .exists: return .blue
        case .failed: return .red
        }
    }

    private func chipIcon(_ p: AppModel.TargetEvent.Phase) -> String {
        switch p {
        case .working: return "circle.dashed"
        case .done: return "checkmark.circle"
        case .exists: return "arrow.down.circle"
        case .failed: return "xmark.circle"
        }
    }

    /// 卡片下方的说明行：失败原因允许换行（不截断成「…」），
    /// 更长的尾巴在悬浮提示与运行记录里。没有内容就不占高。
    @ViewBuilder
    private func detailLine(_ s: SiteConfig) -> some View {
        if let d = detailText(s) {
            Text(d.display).font(.caption2).foregroundStyle(d.tint)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .help(d.full)
        }
    }

    private struct Detail { var display: String; var full: String; var tint: Color }

    private func detailText(_ s: SiteConfig) -> Detail? {
        for e in [model.reseedEvents[s.id], model.pushEvents[s.id]].compactMap({ $0 }) where e.phase == .failed {
            guard !e.detail.isEmpty else { continue }
            return Detail(display: shortDetail(e.detail), full: e.detail, tint: .red)
        }
        if let w = model.siteWarnings[s.id] { return Detail(display: w, full: w, tint: .orange) }
        // 「站内已有」不再单独铺一行：卡片上那个「种子页」按钮带的就是那条种子，详情留在胶囊提示里
        return nil
    }

    /// 卡片上只留原因主体：调试页路径这类长尾巴收进悬浮提示
    private func shortDetail(_ s: String) -> String {
        guard let r = s.range(of: "（页面已存") else { return s }
        return String(s[..<r.lowerBound])
    }
}

/// 站点卡片的自适应流式排版。与 `LazyVGrid` 的差别只在行高：
/// 这里每一次排版都按当排最高的那张卡重新量，卡片中途长高（转种信息出现）会把整排
/// 连同分组外框一起顶开，而不是画到下面那排上面去；没信息的卡片保持本来的高度不动。
struct SiteFlow: Layout {
    var minWidth: CGFloat
    var maxWidth: CGFloat
    var spacing: CGFloat

    private struct Rows {
        var colWidth: CGFloat = 0
        var cols = 1
        var tops: [CGFloat] = []
        var height: CGFloat = 0
    }

    private func layout(_ subviews: Subviews, _ width: CGFloat) -> Rows {
        var r = Rows(colWidth: minWidth, height: 0)
        guard width > 0, !subviews.isEmpty else { return r }
        var cols = max(1, Int((width + spacing) / (minWidth + spacing)))
        var w = (width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        while w > maxWidth && cols < subviews.count {
            cols += 1
            w = (width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        }
        r.cols = cols
        r.colWidth = min(w, width)
        let hs = subviews.map { $0.sizeThatFits(.init(width: r.colWidth, height: nil)).height }
        var y: CGFloat = 0
        var i = 0
        while i < hs.count {
            let n = min(cols, hs.count - i)
            r.tops.append(contentsOf: Array(repeating: y, count: n))
            y += (hs[i..<(i + n)].max() ?? 0) + spacing
            i += n
        }
        r.height = max(0, y - spacing)
        return r
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let width = proposal.width, width.isFinite, width > 0 else {
            return CGSize(width: minWidth * CGFloat(max(1, subviews.count)), height: minWidth)
        }
        return CGSize(width: width, height: layout(subviews, width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let r = layout(subviews, bounds.width)
        for (i, sv) in subviews.enumerated() where i < r.tops.count {
            let x = bounds.minX + CGFloat(i % r.cols) * (r.colWidth + spacing)
            sv.place(at: CGPoint(x: x, y: bounds.minY + r.tops[i]), anchor: .topLeading,
                     proposal: .init(width: r.colWidth, height: nil))
        }
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
    @State private var renameIndex: Int? = nil
    @State private var renameName = ""

    /// 自适应列宽：常规窗口一行 4 张，全屏窗口自动放更多
    private let cardColumns = [GridItem(.adaptive(minimum: 172, maximum: 400), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("添加转种分组和站点").font(.headline)
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
                        .help("同时同步 PT-depiler Gist 与 CookieCloud 的 cookie 备份（互为补充：本地 cookie 只有被检测为失效后才用备份值替换，已检测有效或未检测的保留；同步后自动重检并用另一来源补充仍失效的站点）")
                        Button(model.anyChecking ? "检测中…" : "检测cookie或api key") {
                            model.checkAllManagedCookies()
                        }
                        .font(.caption)
                        .disabled(model.anyChecking)
                        .help("批量检测所有分组已添加站点的 cookie / API Key 有效性")
                        if model.anyChecking {
                            Button {
                                model.stopChecking()
                            } label: {
                                Label("停止检测", systemImage: "stop.circle")
                            }
                            .font(.caption)
                            .help("停止检测剩余站点；进行中的批次仍会完成")
                        }
                        Spacer()
                    }
                }
                .runCard()

                ForEach(model.config.groups.indices, id: \.self) { gi in
                    let gname = model.config.groups[gi].name
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Text("分组：\(gname)").font(.headline)
                            // 顺序：先加站点，再改名，最后才是那个要两次确认的移除
                            Button {
                                addSheetReq = AddSitesRequest(group: gi)
                            } label: {
                                Label("添加站点", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("为此分组添加站点（弹窗中无需再选分组）")
                            Button {
                                renameIndex = gi
                                renameName = gname
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("重命名该分组（组内站点与排序不受影响；重名自动加数字后缀）")
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
                            .help("删除分组（组内站点移回批量添加站点列表），需两次确认")
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

                // 辅种站点：不进转种分组，加进来就直接参与辅种（跑与节奏在「辅种」页）。
                // 辅种收起时这块跟着收起：留着会多一块只改名单、没地方用上的卡片墙
                if AssistFeature.enabled {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Text("辅种站点").font(.headline)
                            Button {
                                addSheetReq = AddSitesRequest(group: -1, assist: true)
                            } label: {
                                Label("添加站点", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("批量选择辅种站点（不进转种分组）")
                            Spacer()
                        }
                        Text("\(model.assistManagedSites.count) 站 · 辅种要逐条种子去站内检索，站点先少而后多")
                            .font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 10) {
                            ForEach(model.assistManagedSites, id: \.id) { site in
                                assistSiteCard(site)
                            }
                        }
                    }
                    .runCard()
                }

                if model.managedSites.isEmpty {
                    Text(AssistFeature.enabled
                         ? "还没有添加站点：点分组卡片或辅种区块上的「添加站点」批量选择。"
                         : "还没有添加站点：点分组卡片上的「添加站点」批量选择。")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .runCard()
                }
            }
            .padding(16)
        }
        .sheet(item: $addSheetReq) { req in
            AddSitesSheet(fixedGroup: req.group, assist: req.assist)
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
        .alert("重命名分组", isPresented: Binding(
            get: { renameIndex != nil },
            set: { if !$0 { renameIndex = nil } }
        )) {
            TextField("分组名", text: $renameName)
            Button("保存") {
                if let i = renameIndex { model.renameGroup(at: i, name: renameName) }
                renameIndex = nil
            }
            Button("取消", role: .cancel) { renameIndex = nil }
        } message: {
            Text("重命名立即生效，不影响组内站点；名称重复时自动追加数字后缀。")
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
            Button("手动添加cookie或api key") {
                manualCookiePick = SitePick(sites: enabledMembers)
            }
            .font(.caption)
            .disabled(enabledMembers.isEmpty)
            .help("为选中（加深色）的站点手动填写 cookie 或 API Key")
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

    /// 站点卡片：名称 / 序号 / 地址 / cookie 有效性 / 上传限速（+ 猫站免费一天开关单独一行）
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
                Spacer(minLength: 6)
            }
            // 单独一行显示，卡片窄时标签不会被压成竖排（fixedSize 保证文字完整）
            if model.siteSupportsAutoFree(s) {
                HStack(spacing: 6) {
                    Toggle("发种后免费一天", isOn: Binding(
                        get: { model.siteAutoFree(s) },
                        set: { on in model.setSiteAutoFree(on, siteID: s.id) }))
                        .font(.caption)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .fixedSize()
                        .help("发种成功后自动点一次站内「帖子免费1天」（要扣猫粮）；已在免费满一天就不重复扣")
                    Spacer(minLength: 6)
                }
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
                .strokeBorder(draggingSite == s.id ? Color.accentColor
                                                   : Color(nsColor: .separatorColor),
                              lineWidth: draggingSite == s.id ? 1.5 : 1)
        )
        .opacity(draggingSite == s.id ? 0.4 : 1)
        .help(on ? "已开启（加深色），点击停用" : "未开启，点击开启")
        .onDrop(of: [.text], delegate: GroupSiteDrop(target: s.id, dragging: $draggingSite,
            onMove: { from, to in model.moveSite(from, before: to) }))
    }

    /// 辅种站点卡片：点名字区开 / 停，「退出辅种」只把它移出辅种（还在分组里的照旧参与转种）
    private func assistSiteCard(_ s: SiteConfig) -> some View {
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
                Button("退出辅种") { model.removeAssistSite(s.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.red)
                    .help("把这个站移出辅种；它若还在某个转种分组里，分组不受影响")
            }
            cookieStatusView(for: s)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Color.blockSurface(model.theme.dark)
            Color.accentColor.opacity(on ? 0.3 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .help(on ? "已开启（加深色），点击停用" : "未开启，点击开启")
    }

    /// 卡片内 cookie 状态：未开启 / 无 cookie / 检测中 / 未检测 / 已登录 / 失效
    @ViewBuilder
    private func cookieStatusView(for s: SiteConfig) -> some View {
        if !s.enabled {
            Text("未开启").font(.caption).foregroundStyle(.tertiary)
        } else if model.siteUsesAPIKey(s) {
            if model.siteChecking.contains(s.id) {
                Text("检测中…").font(.caption).foregroundStyle(.secondary)
            } else if model.siteAPIKey(s).isEmpty {
                Text("未配置 API Key").font(.caption).foregroundStyle(.secondary)
                    .help("该站不走 cookie 同步；在分组工具栏「手动添加cookie或api key」中填写")
            } else if let r = model.siteCheckResults[s.id] {
                Text(r.ok ? "API 已连接" : "API Key 失效")
                    .font(.caption)
                    .foregroundStyle(r.ok ? Color.green : Color.red)
                    .help(r.message)
            } else {
                Text("API Key 已配置（未检测）").font(.caption).foregroundStyle(.secondary)
                    .help("点顶部「检测cookie或api key」验证")
            }
        } else if model.siteChecking.contains(s.id) {
            Text("检测中…").font(.caption).foregroundStyle(.secondary)
        } else if !model.hasCookie(for: s) {
            Text("无 cookie").font(.caption).foregroundStyle(.secondary)
        } else if let r = model.siteCheckResults[s.id] {
            Text(r.ok ? "已登录" : (r.unconfirmed ? "站点未响应" : "cookie 失效"))
                .font(.caption)
                .foregroundStyle(r.ok ? Color.green : (r.unconfirmed ? Color.secondary : Color.red))
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
        siteSortNum.removeAll()
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
    /// true = 从辅种区块进来：没有分组可选，添加即参与辅种
    let assist: Bool

    init(fixedGroup: Int = -1, assist: Bool = false) {
        self.fixedGroup = fixedGroup
        self.assist = assist
        _targetGroup = State(initialValue: fixedGroup)
    }
    @State private var sortNum: [String: String] = [:]
    @State private var dragging: String?
    @State private var dupAlert = ""
    @State private var showDupAlert = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    /// 辅种那份不受转种分组影响：已纳管的站也能再拉来辅种，只排掉已经在辅种名单里的
    private var allCandidateIDs: [String] {
        assist ? model.config.assistCandidateIDs
               : model.config.sourceSites.filter { !$0.managed }.map { $0.id }
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
                Text(assist ? "批量添加站点（辅种站点）"
                     : fixedGroup >= 0
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
                if fixedGroup < 0 && !assist {
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
                Text(assist
                     ? "点击卡片选中要添加的站点（加深色 = 已选中）；这里列全部站点，已在转种分组里的也能辅种，添加后直接进辅种区块。"
                     : "点击卡片选中要添加的站点（加深色 = 已选中）；拖拽把手或输入序号排序；添加后默认开启（限速默认取分组上传限速，未设 = 10 MB/s）。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加 \(checked.count) 个站点") {
                    let ids = displayIDs.filter { checked.contains($0) }
                    if assist { model.addAssistSites(ids) }
                    else { model.addManagedSites(ids, group: targetGroup) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(checked.isEmpty)
            }
        }
        .padding()
        .frame(width: 640, height: 540)
        .onAppear {
            // 优先沿用用户手动排序；未保存过的按名称默认排序（规则在核心，两端一份）
            order = assist ? model.config.assistDisplayOrder() : model.config.unmanagedDisplayOrder()
        }
        // 手动排序（拖拽 / 序号）持久化，关闭弹窗后不再恢复默认顺序。
        // 辅种那份会把已纳管的站也列进来，这份顺序就是两份弹窗共用的「弹窗显示顺序」
        .onChange(of: order) { _ in
            model.config.unmanagedSiteOrder = order
            model.saveConfig()
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
                        TextField("", text: numBinding(id), prompt: Text("\(position(of: id))"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                            .font(.caption)
                            .frame(width: 38)
                            .onSubmit { applySortNumbers() }
                            .help("数字 = 当前排序位置；输入新数字回车即排到该位置（如 2 = 第 2 位）")
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
                        .strokeBorder(dragging == id ? Color.accentColor
                                                     : Color(nsColor: .separatorColor),
                                      lineWidth: dragging == id ? 1.5 : 1)
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

    /// 站点在当前完整顺序中的位置（1 起），序号框常显该数字
    private func position(of id: String) -> Int {
        (order.firstIndex(of: id) ?? 0) + 1
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
        sortNum.removeAll()
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

    private var currentUsesAPIKey: Bool {
        current.map { model.siteUsesAPIKey($0) } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let c = current {
                Text(currentUsesAPIKey ? "添加 \(c.name)（\(model.siteHost(c))）的 API Key"
                                       : "添加 \(c.name)（\(model.siteHost(c))）的 cookie")
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
            inputEditor(currentUsesAPIKey
                        ? "站点 API Key（站点页「个人主页 → 设置 → API」获取，整段粘贴）"
                        : "name1=value1; name2=value2 …（浏览器 Cookie 头原文，整段粘贴）")
            HStack(alignment: .firstTextBaseline) {
                Text(currentUsesAPIKey
                     ? "保存即覆盖该站原有 API Key，并自动开启该站"
                     : "保存即覆盖该站原有 cookie，并自动开启该站")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    if let c = current {
                        if currentUsesAPIKey {
                            model.saveSiteAPIKey(siteID: c.id, raw: text)
                        } else {
                            model.addSiteCookie(siteID: c.id, raw: text)
                        }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || current == nil)
            }
        }
        .padding()
        .frame(width: 520)
        .onAppear {
            siteID = sites.first?.id ?? ""
            text = initialText(for: siteID)
        }
        .onChange(of: siteID) { id in
            text = initialText(for: id)
        }
        .boxsendAppearance()
    }

    /// 多行输入：一条 cookie 头常有上千字符，单行输入框看不到也改不了
    private func inputEditor(_ placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor))
            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3))
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
                    .padding(.leading, 12)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
        }
        .frame(height: 176)
    }

    /// 预填已有 cookie / API Key，便于覆盖前核对
    private func initialText(for id: String) -> String {
        guard let c = sites.first(where: { $0.id == id }) else { return "" }
        return model.siteUsesAPIKey(c) ? model.siteAPIKey(c) : model.existingCookieHeader(for: c)
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
            return "将移除分组「\(name)」，组内 \(count) 个站点会移回「批量添加站点」列表（按名称默认序插入，不打乱已有手动排序）。"
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
                .frame(maxWidth: 320, alignment: .leading)
        }
    }
}

// MARK: - Cookie

struct CookiesView: View {
    @EnvironmentObject var model: AppModel
    @State private var zipPassword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Cookie 同步与导入").font(.title3.weight(.semibold)).padding(.leading, 4)
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
                        HStack(spacing: 8) {
                            TextField("", text: Binding(get: { model.zipDir() }, set: { model.setZipDir($0) })).textFieldStyle(.roundedBorder)
                            Button("选择目录…") { pickZipDir() }
                                .controlSize(.small)
                        }
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

    private func pickZipDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 PT-depiler 备份 zip 所在的目录"
        panel.directoryURL = URL(fileURLWithPath: (model.zipDir() as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            model.setZipDir(url.path)
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

    /// 改指定那台：每台都直接显示、直接改，不再需要先切「正在编辑哪一台」
    private func dl<T>(_ id: String, _ kp: WritableKeyPath<DownloaderConfig, T>) -> Binding<T> {
        Binding(get: { model.downloader(id)[keyPath: kp] },
                set: { v in model.updateDownloader(id) { $0[keyPath: kp] = v } })
    }

    private func optBinding(_ id: String,
                            _ kp: WritableKeyPath<DownloaderConfig, String?>) -> Binding<String> {
        Binding(get: { model.downloader(id)[keyPath: kp] ?? "" },
                set: { v in model.updateDownloader(id) { $0[keyPath: kp] = v.isEmpty ? nil : v } })
    }

    /// 某个用途用哪台
    private func rolePicker(_ role: String) -> some View {
        Picker("", selection: Binding(get: { model.downloaderID(forRole: role) },
                                      set: { v in model.assignDownloader(role: role, id: v) })) {
            ForEach(model.downloaderList, id: \.id) { d in
                Text(d.label).tag(d.id)
            }
        }
        .labelsHidden()
    }

    private var rolesCard: some View {
        CardSection("下载器（可以有多台）") {
            HStack(spacing: 10) {
                Button("添加一台") { model.addDownloader() }
                Text("添加后立刻列在下面，直接改就行").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(alignment: .top, spacing: 24) {
                LabeledRow("批量发种推送用") { rolePicker("reseed") }
                // 辅种收起时不摆这栏：选一台没人在读的下载器只会让人犯迷糊
                if AssistFeature.enabled {
                    LabeledRow("辅种扫描用") { rolePicker("assist") }
                }
            }
            Text(AssistFeature.enabled
                 ? "辅种要读的那台得真有这些文件，否则加进去就是重下一遍。"
                     + "两台不是同一台时，「辅种」页顶部会写明现在用的哪台。"
                 : "推送按「批量发种推送用」这台，逐站限速照站点分组里设的走。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 一台一张卡片：连接参数 + 种子大小检测 + 逐台测连接 + 删除（主下载器不可删）
    private func downloaderCard(_ id: String) -> some View {
        let d = model.downloader(id)
        let testing = model.testingDownloaderID == id
        return CardSection("\(d.label)（\(d.url.isEmpty ? "还没填地址" : d.url)）") {
            HStack(alignment: .top, spacing: 12) {
                LabeledRow("名字（列表与用途下拉里显示）") {
                    TextField("如 VPS / 家里NAS", text: dl(id, \.name)).textFieldStyle(.roundedBorder)
                }
                LabeledRow("类型") {
                    Picker("", selection: dl(id, \.type)) {
                        Text("qBittorrent").tag(DownloaderType.qbittorrent)
                        Text("Transmission").tag(DownloaderType.transmission)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .fixedSize()
            }
            LabeledRow("URL（VPS 隧道地址）") {
                TextField("", text: dl(id, \.url)).textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .top, spacing: 12) {
                LabeledRow("用户名") {
                    TextField("", text: dl(id, \.username)).textFieldStyle(.roundedBorder)
                }
                LabeledRow("密码") { RevealField(text: dl(id, \.password)) }
            }
            HStack(alignment: .top, spacing: 12) {
                LabeledRow("保存路径（空 = 下载器默认）") {
                    TextField("", text: optBinding(id, \.savePath)).textFieldStyle(.roundedBorder)
                }
                LabeledRow("分类（空 = 无）") {
                    TextField("", text: optBinding(id, \.category)).textFieldStyle(.roundedBorder)
                }
            }
            Toggle("添加后跳过校验（skipChecking）", isOn: dl(id, \.skipChecking))
            Divider()
            HStack(alignment: .top, spacing: 12) {
                LabeledRow("VPS 剩余空间（GB，空 = 不做大小检测）") {
                    IntLimitField(initial: d.vpsFreeGB ?? 0) { mb in
                        model.setVpsFreeGB(mb, downloaderID: id)
                    }.frame(width: 60)
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: 4) {
                    Text("超过剩余空间时").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Picker("", selection: dl(id, \.sizeGuardMode)) {
                            Text("提醒（继续转种）").tag(SizeGuardMode.warn)
                            Text("跳过（不转种不推送）").tag(SizeGuardMode.skip)
                        }
                        .labelsHidden()
                        IntLimitField(initial: d.sizeGuardMarginGB) { gb in
                            model.setVpsFreeMargin(gb, downloaderID: id)
                        }.frame(width: 50)
                        Text("安全边际（GB）").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            Text("可用空间 = 剩余 - 边际；剩余空间需手动维护（qB WebAPI 无磁盘接口），空间变化大时记得更新。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(testing ? "测试中…" : "测试连接") { model.testDownloader(id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(testing)
                if testing { ProgressView() }
                if let r = model.downloaderTestResults[id] {
                    Text(r)
                        .foregroundStyle(r.hasPrefix("成功") ? .green : .red)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("删除这台") { model.removeDownloader(id) }
                    .disabled(!model.canRemoveDownloader(id))
                    .help("主下载器不能删")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("下载器").font(.title3.weight(.semibold)).padding(.leading, 4)
                rolesCard
                ForEach(model.downloaderList, id: \.id) { d in
                    downloaderCard(d.id)
                }
                CardSection("转种服务器（SSH 上传测速）") {
                    Text("「测试上传速度」按钮在「批量转种」页「开始运行」左边")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 12) {
                        LabeledRow("服务器地址") {
                            TextField("如 1.2.3.4 或 vps.example.com", text: Binding(
                                get: { model.sshConfig.host },
                                set: { v in model.updateSSH { $0.host = v } }))
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledRow("SSH 端口") {
                            IntLimitField(initial: model.sshConfig.port, center: true) { v in
                                model.updateSSH { $0.port = v ?? 22 }
                            }
                            .frame(width: 70)
                        }
                        .fixedSize()
                    }
                    HStack(alignment: .top, spacing: 12) {
                        LabeledRow("用户名") {
                            TextField("root", text: Binding(
                                get: { model.sshConfig.user },
                                set: { v in model.updateSSH { $0.user = v } }))
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledRow("登录方式") {
                            Picker("", selection: Binding(
                                get: { model.sshConfig.auth },
                                set: { v in model.updateSSH { $0.auth = v } })) {
                                Text("密钥").tag(SSHConfig.Auth.key)
                                Text("密码").tag(SSHConfig.Auth.password)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                        .fixedSize()
                    }
                    if model.sshConfig.auth == .key {
                        HStack(alignment: .bottom, spacing: 8) {
                            LabeledRow("私钥路径（留空 = 用默认密钥 / ssh-agent）") {
                                TextField("~/.ssh/id_ed25519", text: Binding(
                                    get: { model.sshConfig.keyPath },
                                    set: { v in model.updateSSH { $0.keyPath = v } }))
                                    .textFieldStyle(.roundedBorder)
                            }
                            Button("选择…") { model.chooseSSHKey() }
                                .controlSize(.small)
                                .fixedSize()
                        }
                    } else {
                        LabeledRow("密码") {
                            RevealField(text: Binding(
                                get: { model.sshConfig.password },
                                set: { v in model.updateSSH { $0.password = v } }))
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        LabeledRow("每轮测试数据量（MB）") {
                            IntLimitField(initial: model.sshConfig.testMB, center: true) { v in
                                model.updateSSH { $0.testMB = v ?? 64 }
                            }
                            .frame(width: 70)
                        }
                        .fixedSize()
                        LabeledRow("测速地址（服务器往这里 POST）") {
                            TextField(SSHConfig.defaultProbeURL, text: Binding(
                                get: { model.sshConfig.probeURL },
                                set: { v in model.updateSSH { $0.probeURL = v } }))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    HStack(spacing: 12) {
                        Button(model.testingSSH ? "测速中…" : "测试连接并测速") { model.testSSH() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.testingSSH || !model.sshConfig.isConfigured)
                        if model.testingSSH { ProgressView() }
                    }
                    if let r = model.sshTestResult {
                        Text(r)
                            .foregroundStyle(r.hasPrefix("成功") ? .green : .red)
                            .textSelection(.enabled)
                    }
                    Text("部分服务器 24 小时上传流量到 2T 后会把上行压到 20 MB/s 左右，批量转种时整批都慢。"
                         + "想确认这一批转不转，在「批量转种」页点「测试上传速度」：用 SSH 连上这台服务器，"
                         + "往公网推两轮测试数据量，实测速度显示在按钮下面那一行，不做自动判定。"
                         + "测速在服务器上进行，每轮只多花一份测试流量的上行（默认 64 MB），不占用本机。")
                        .font(.caption).foregroundStyle(.secondary)
                }
        }
    }
}

// MARK: - 辅种（辅种站点在「站点分组」页的辅种区块里维护，这一页只管跑）

struct AssistView: View {
    @EnvironmentObject var model: AppModel
    /// 每条种子手动改过的「某一类格子」展开状态（hash → 状态 → 是否展开）
    @State private var folded: [String: [AssistPipeline.RowStatus: Bool]] = [:]
    /// 展开细节的种子。没点过的按「这条种子有没有要人处理的东西」自动决定
    @State private var opened: Set<String> = []
    /// 人手动点过展开/收起的种子：不再自动改它
    @State private var touched: Set<String> = []
    /// 逐站进度只看有活儿的站（不支持检索的那些铺在这儿只是噪音）
    @State private var progressBusyOnly = false
    /// 否决过的条目默认收起
    @State private var showHandled = false
    /// 鼠标停在哪张站卡上（整张卡是暂停开关，得有哪儿能点的意思）
    @State private var hoveredSite: String? = nil

    /// 这一页只有三块：进度（含逐站）、待你处理、种子明细。
    /// 数字只出现在进度块，按钮只出现在待你处理，格子只在明细里。
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                progressCard
                queueCard
                torrentCard
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cfg: AssistConfig { model.assistConfig }

    /// 一条种子的站点格子按 hash 归堆
    private var rowsByHash: [String: [AssistPipeline.PlanRow]] {
        Dictionary(grouping: model.assistCells, by: { $0.hash })
    }

    // MARK: 顶部：扫描、跑这一页、运行状态

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                model.assistScan()
            } label: {
                Label("重新扫描（不发检索）", systemImage: "magnifyingglass")
            }
            .disabled(model.assistScanning || model.assistRunning)
            .help("重读下载器的种子列表与已做种站点：只更新目录，不去站内检索")

            Button {
                model.assistRun()
            } label: {
                Label(model.assistDryRun ? "预演这一页" : "跑这一页",
                      systemImage: "square.stack.3d.up.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.assistScanning || model.assistRunning || model.assistCells.isEmpty)
            .help("只处理这一页列出的种子；逐站间隔与单轮请求上限照「设置」里的节奏")

            Toggle("只预演", isOn: $model.assistDryRun)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("按真实流程走一遍，但不动下载器")

            if model.assistRunning {
                HStack(spacing: 6) {
                    Text("运行中，已请求 \(AssistPipeline.grouped(model.assistBudget.used)) / \(AssistPipeline.grouped(model.assistBudget.total))")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .help("站点请求：检索、详情、种子文件各算一次")
                    Button("停止") { model.assistStop() }
                        .controlSize(.small)
                        .help("处理完手头这一格就收摊；状态表原样留着，下一轮从没跑过的格子接着铺")
                    Button("追加 200 次") { model.assistAddBudget() }
                        .controlSize(.small)
                        .help("只追这一轮的请求次数上限，逐站间隔照旧")
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if model.assistScanning || model.assistRunning {
                ProgressView().controlSize(.small)
            }
            if let msg = model.assistMessage {
                Text(msg).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text("辅种站点：\(model.assistManagedSites.count) 个")
                .font(.caption2).foregroundStyle(.secondary)
                .help("在「站点分组」页底部的辅种区块里添加 / 退出")
            Text("辅种下载器：\(model.assistDownloaderName)")
                .font(.caption2).foregroundStyle(.primary)
                .help("在「设置」页的「辅种扫描用」里换一台")
        }
    }

    // MARK: 进度：覆盖率 + 5 组计数 + 逐站

    /// 整轮跑到哪儿了。12 个结论收成 5 组摆出来，细分说法挂在悬停提示里
    private var progressCard: some View {
        let tally = model.assistStats
        return CardSection("进度") {
            if model.assistPlan == nil {
                Text("扫描下载器后，这里给出覆盖率、5 组计数和逐站进度。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                if let cov = model.assistCoverage {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: cov.percent)
                            .frame(maxWidth: .infinity)
                        Text(cov.line).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(alignment: .top, spacing: 20) {
                    ForEach(Array(tally.buckets.enumerated()), id: \.offset) { _, b in
                        bucketBlock(b.bucket, b.count, tally)
                    }
                    Spacer(minLength: 8)
                }
                Divider()
                siteList
                Text(footline(tally)).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bucketBlock(_ bucket: AssistPipeline.Bucket, _ count: Int,
                             _ tally: AssistPipeline.Tally) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AssistPipeline.grouped(count))
                .font(.title2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(bucketTint(bucket))
            Text(bucket.label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 82, alignment: .leading)
        .help("\(bucket.label)：\(tally.breakdown(bucket))")
    }

    private func bucketTint(_ bucket: AssistPipeline.Bucket) -> Color {
        switch bucket {
        case .done: return .green
        case .action: return .orange
        case .trouble: return .red
        case .skip: return Color.secondary.opacity(0.65)
        case .waiting: return .secondary
        }
    }

    /// 一行说清本轮规模：全量组合、会检索多少、预算、上次扫描
    private func footline(_ tally: AssistPipeline.Tally) -> String {
        var parts: [String] = []
        if let plan = model.assistPlan {
            parts.append("全量 \(AssistPipeline.grouped(plan.total)) 个组合，"
                       + "其中 \(AssistPipeline.grouped(plan.willSearch)) 个会去站内检索")
        }
        parts.append("单轮预算 \(cfg.roundBudget) 次请求，用完下次接着跑")
        if model.assistTorrentRaw > model.assistTorrentTotal {
            parts.append("下载器里 \(model.assistTorrentRaw) 条符合，去掉各站重复后 \(model.assistTorrentTotal) 条")
        }
        if let last = model.assistSummary?.lastScan {
            parts.append("上次扫描 " + AppModel.dateText(last.timeIntervalSince1970))
        }
        return parts.joined(separator: "；") + "。"
    }

    /// 逐站那一截：一站一张卡片。一百多个站用行列表读不动，卡片靠底色挑问题
    private var siteList: some View {
        let rows = model.assistSiteProgress
            .filter { !progressBusyOnly || (!$0.unsupported && ($0.searches > 0 || $0.paused > 0)) }
            .sorted { lhs, rhs in
                if lhs.state.rank != rhs.state.rank { return lhs.state.rank < rhs.state.rank }
                if lhs.searches != rhs.searches { return lhs.searches > rhs.searches }
                return model.siteName(lhs.siteID) < model.siteName(rhs.siteID)
            }
        let resolved = rows.reduce(0) { $0 + $1.resolved }
        let cells = rows.reduce(0) { $0 + $1.total }
        let searches = rows.reduce(0) { $0 + $1.searches }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("逐站（\(rows.count)）").font(.caption).foregroundStyle(.secondary)
                Toggle("只显示还有活的站", isOn: $progressBusyOnly)
                    .toggleStyle(.switch).controlSize(.mini)
                Spacer()
                Text("合计 已判定 \(AssistPipeline.grouped(resolved)) / \(AssistPipeline.grouped(cells))"
                     + "　还要检索 \(AssistPipeline.grouped(searches))")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Text("扫描下载器后这里一站一卡；不想这一轮动某个站，点一下它的卡片。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 184), spacing: 6)],
                              alignment: .leading, spacing: 6) {
                        ForEach(rows, id: \.siteID) { p in
                            siteCard(p)
                        }
                    }
                    .padding(.top, 1)
                }
                .frame(maxHeight: 300)
                Text("底色说结论：红=这一站有检索或推送砸了，紫=有待复核，绿=这一站已铺完，"
                     + "灰=暂停或没有站内检索；有问题的排前面。点卡片＝暂停/恢复这一站，"
                     + "暂停只是这一轮不去敲门，那些格子仍算欠着。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 一站一卡：整张卡就是这一站的暂停开关，点一下停/放，卡上的数当场跟着变。
    /// 图标只报当前状态（实心＝暂停中），悬停描边说「这儿能点」
    private func siteCard(_ p: AssistPipeline.CatalogPlan.SiteProgress) -> some View {
        let paused = p.pausedSite
        let hovered = hoveredSite == p.siteID && !p.unsupported
        let edge = hovered ? siteTint(p.state).opacity(0.85) : siteEdge(p.state)
        return Button {
            model.assistSetPaused(p.siteID, paused: !paused)
        } label: {
            siteCardBody(p)
        }
        .buttonStyle(.plain)
        .disabled(p.unsupported)
        .background(siteCardBackground(p.state))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(edge, lineWidth: hovered ? 1.5 : 1))
        .opacity(p.state == .unsupported ? 0.65 : 1)
        .onHover { inside in
            hoveredSite = inside ? p.siteID : (hoveredSite == p.siteID ? nil : hoveredSite)
        }
        .help(siteCardTip(p))
    }

    /// 卡片正文拆成单独一个 View：整串修饰符堆一块儿编译器会算不动
    private func siteCardBody(_ p: AssistPipeline.CatalogPlan.SiteProgress) -> some View {
        let warn = p.warnLine
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(model.siteName(p.siteID)).font(.caption).lineLimit(1)
                Spacer(minLength: 2)
                if !p.unsupported {
                    Image(systemName: p.pausedSite ? "pause.circle.fill" : "pause.circle")
                        .font(.caption2)
                        .foregroundStyle(p.pausedSite ? Color.primary.opacity(0.55) : Color.secondary)
                }
            }
            if !p.unsupported {
                ProgressView(value: p.percent)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
            }
            Text(p.stateLine).font(.caption2).monospacedDigit()
                .foregroundStyle(.secondary).lineLimit(1)
            if !p.nextLine.isEmpty {
                Text(p.nextLine).font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            if !warn.isEmpty {
                Text(warn).font(.caption2).monospacedDigit().lineLimit(1)
                    .foregroundStyle(p.failed > 0 ? Color.red : Color.purple)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func siteCardBackground(_ state: AssistPipeline.SiteState) -> some View {
        ZStack {
            Color.blockSurface(model.theme.dark)
            siteWash(state)
        }
    }

    private func siteCardTip(_ p: AssistPipeline.CatalogPlan.SiteProgress) -> String {
        var lines = [model.siteName(p.siteID) + "｜" + p.state.label,
                     p.nextLine.isEmpty ? p.stateLine : p.stateLine + "　" + p.nextLine]
        if !p.warnLine.isEmpty { lines.append(p.warnLine) }
        if !p.unsupported {
            lines.append(p.pausedSite ? "点击恢复这一站：下一轮接着检索"
                                     : "点击暂停这一站：这一轮不去敲门，格子仍算欠着")
        }
        return lines.joined(separator: "\n")
    }

    private func siteTint(_ state: AssistPipeline.SiteState) -> Color {
        switch state {
        case .trouble: return .red
        case .review: return .purple
        case .done: return .green
        case .queued: return Color.accentColor
        case .paused, .unsupported: return Color.secondary.opacity(0.6)
        }
    }

    private func siteWash(_ state: AssistPipeline.SiteState) -> Color {
        switch state {
        case .trouble: return Color.red.opacity(0.16)
        case .review: return Color.purple.opacity(0.16)
        case .done: return Color.green.opacity(0.12)
        case .queued: return Color.secondary.opacity(0.06)
        case .paused: return Color.secondary.opacity(0.12)
        case .unsupported: return Color.secondary.opacity(0.08)
        }
    }

    private func siteEdge(_ state: AssistPipeline.SiteState) -> Color {
        switch state {
        case .trouble, .review, .done: return siteTint(state).opacity(0.45)
        case .queued: return Color(nsColor: .separatorColor)
        case .paused, .unsupported: return Color.secondary.opacity(0.3)
        }
    }

    // MARK: 待你处理：整页唯一动手的地方

    /// 一行一条、最多两个按钮。否决过的收进「已处理」，不跟待办混在一列
    private var queueCard: some View {
        let open = model.assistQueue.filter { !$0.handled }
        let handled = model.assistQueue.filter { $0.handled }
        let review = model.assistStats.count(.review)
        return CardSection("待你处理（\(open.count)）") {
            if model.assistPlan == nil {
                Text("扫描下载器后，要你点一下才往前走的条目列在这里。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                if open.isEmpty {
                    Text("没有等你处理的条目。").font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        Text("采纳＝按你的判断当成同一种子；重试＝只重跑这一格；回查＝问下载器校验完了没。")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if review > 0 {
                            Button("全部回查（\(review)）") { model.assistRecheck() }
                                .controlSize(.small).disabled(model.assistRunning)
                                .help("上一轮推进下载器却没等到校验结果的种子，回来问一次下载器：满了就启动，不满就回滚。只问下载器，不发站点请求")
                        }
                    }
                    ForEach(open) { item in
                        queueRow(item)
                    }
                }
                if !handled.isEmpty {
                    Button {
                        showHandled.toggle()
                    } label: {
                        Label("已处理（\(handled.count)）：你否决过的",
                              systemImage: showHandled ? "chevron.down" : "chevron.right")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    if showHandled {
                        ForEach(handled) { item in
                            queueRow(item)
                        }
                    }
                }
            }
        }
    }

    private func queueRow(_ item: AssistPipeline.QueueItem) -> some View {
        HStack(spacing: 8) {
            Button {
                model.openURL(item.url)
            } label: {
                Text(item.siteName).font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.theme.dark ? Color.white : Color.primary)
            .frame(width: 84, alignment: .leading)
            .disabled(item.url.isEmpty)
            .help(item.url.isEmpty ? item.siteName : "打开站内那条：\(item.url)")

            Text(item.statusText).font(.caption2).foregroundStyle(tintColor(item.status))
                .frame(width: 46, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.torrentName).font(.caption).lineLimit(1)
                Text(item.why).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.timeText).font(.caption2).foregroundStyle(.secondary)
                .fixedSize()

            // 主按钮按结论挑一个，右边再挂一个「否决」：一行最多两个按钮
            if item.canAdopt {
                Button("采纳") { model.assistConfirm(key: item.key) }
                    .controlSize(.small).disabled(model.assistRunning)
                    .help("按人工判断当成同一种子：加进下载器，校验到 100% 才算辅成")
            } else if item.canRetry {
                Button("重试") { model.assistRetry(key: item.key) }
                    .controlSize(.small).disabled(model.assistRunning)
                    .help("只重跑这一格：再检索一次站内，找到就重新推下载器")
            } else if item.canRecheck {
                Button("回查") { model.assistRecheck(keys: [item.key]) }
                    .controlSize(.small).disabled(model.assistRunning)
                    .help("问一次下载器那条校验完了没：满了就启动，不满就回滚")
            } else if item.canUndo {
                Button("撤销") { model.assistReject(key: item.key, rejected: false) }
                    .controlSize(.small)
                    .help("撤销否决：这条重新允许检索")
            }
            if item.canReject {
                Button("否决") { model.assistReject(key: item.key) }
                    .controlSize(.small)
                    .help("站内那条不是同一个种子：以后不再拿它烦你")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: 种子明细：只作台账，不在这儿动手

    /// 一条种子一行汇总，点开才是格子
    private var torrentCard: some View {
        CardSection("种子明细") {
            if model.assistShownTorrents.isEmpty {
                Text(model.assistScanning ? "正在读下载器…" : "（还没扫描，或下载器里没有可辅的种子）")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                pager
                ForEach(model.assistShownTorrents, id: \.hash) { t in
                    torrentBlock(t)
                    if t.hash != model.assistShownTorrents.last?.hash {
                        Divider()
                    }
                }
            }
        }
    }

    /// 分页条：整库按体积倒序摊开，一列几条在「设置 → 辅种搜索节奏」里改
    private var pager: some View {
        HStack(spacing: 8) {
            Button {
                model.assistGoPage(model.assistPage - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(model.assistPage == 0)
            Text("第 \(model.assistPage + 1) / \(model.assistPageCount) 页"
                 + "（共 \(model.assistTorrentTotal) 条，每页 \(model.assistPageSize) 条）")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button {
                model.assistGoPage(model.assistPage + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(model.assistPage >= model.assistPageCount - 1)
            Spacer()
            Text("要人处理的种子默认已展开")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func torrentBlock(_ t: LocalTorrent) -> some View {
        let rows = rowsByHash[t.hash] ?? []
        let tally = AssistPipeline.tally(rows: rows, live: model.assistLive)
        let open = isTorrentOpen(t.hash, tally)
        let shown = open ? visibleRows(rows, tally: tally) : []
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                toggleTorrent(t.hash, tally)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(t.name).font(.callout).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(tally.summaryLine).font(.caption2).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f GiB", Double(t.totalSize) / 1_073_741_824)
                         + "　已做种 \(t.trackerHosts.count) 站")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(t.name)
            if open {
                if rows.isEmpty {
                    Text("这条不在本轮计划里").font(.caption2).foregroundStyle(.secondary)
                } else {
                    // 计数条即筛选：点哪一类就只看那一类的格子，要人动手的默认已经展开
                    HStack(spacing: 5) {
                        ForEach(Array(tally.lines.enumerated()), id: \.offset) { _, line in
                            if line.count > 0 {
                                chip(t.hash, line.status, line.count, tally: tally)
                            }
                        }
                    }
                    if !shown.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 6)],
                                  alignment: .leading, spacing: 6) {
                            ForEach(shown, id: \.rowKey) { row in
                                siteCell(row)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 没点过的种子：有要人处理的（或出问题的）就自动展开，其余收起
    private func isTorrentOpen(_ hash: String, _ tally: AssistPipeline.Tally) -> Bool {
        if touched.contains(hash) { return opened.contains(hash) }
        return tally.count(.action) > 0 || tally.count(.trouble) > 0
    }

    private func toggleTorrent(_ hash: String, _ tally: AssistPipeline.Tally) {
        let now = isTorrentOpen(hash, tally)
        touched.insert(hash)
        if now {
            opened.remove(hash)
        } else {
            opened.insert(hash)
        }
    }

    /// 一类一格的小计数牌：底色说结论，数字说有几格
    private func chip(_ hash: String, _ status: AssistPipeline.RowStatus, _ count: Int,
                      tally: AssistPipeline.Tally) -> some View {
        let on = isOpen(hash, status, tally)
        return Button {
            toggle(hash, status, tally)
        } label: {
            HStack(spacing: 3) {
                Text(status.label)
                Text("\(count)").monospacedDigit().fontWeight(.semibold)
            }
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(on ? tintColor(status).opacity(0.26) : Color.clear)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(tintColor(status))
        .help("展开看\(status.statLabel)的格子")
    }

    /// 默认展开：失败、待确认、待复核。剩下的收成计数牌，不然满屏都是不用管的格子
    /// （这一类默认展开是有意为之：问题不该要人先去点标签才看得见）
    private func autoOpen(_ status: AssistPipeline.RowStatus, _ tally: AssistPipeline.Tally) -> Bool {
        switch status {
        case .failed, .manual, .review: return tally.count(status) > 0
        default: return false
        }
    }

    private func isOpen(_ hash: String, _ status: AssistPipeline.RowStatus,
                        _ tally: AssistPipeline.Tally) -> Bool {
        return folded[hash]?[status] ?? autoOpen(status, tally)
    }

    /// 点计数牌 = 按当前可见性反向记一次：自动展开的那类也能一指点收起
    private func toggle(_ hash: String, _ status: AssistPipeline.RowStatus,
                        _ tally: AssistPipeline.Tally) {
        var m = folded[hash] ?? [:]
        m[status] = !isOpen(hash, status, tally)
        folded[hash] = m
    }

    /// 这一条种子里要画出来的格子
    private func visibleRows(_ rows: [AssistPipeline.PlanRow],
                            tally: AssistPipeline.Tally) -> [AssistPipeline.PlanRow] {
        guard let hash = rows.first?.hash else { return [] }
        return rows.filter { isOpen(hash, model.assistStatus($0), tally) }
    }

    /// 一格：站名 + 结论；「待确认」的格子上带「采纳」「否决」
    private func siteCell(_ row: AssistPipeline.PlanRow) -> some View {
        let status = model.assistStatus(row)
        let live = model.assistRows[row.rowKey]
        return VStack(alignment: .leading, spacing: 3) {
            Text(model.siteName(row.siteID)).font(.caption).lineLimit(1)
            HStack(spacing: 4) {
                Text(status.label).font(.caption2).foregroundStyle(tintColor(status))
                if status == .manual {
                    Button("采纳") { model.assistConfirm(key: row.rowKey) }
                        .controlSize(.mini)
                        .disabled(model.assistRunning)
                        .help("按人工判断当成同一种子：加进下载器，校验到 100% 才算辅成")
                }
            }
            if status == .manual || status == .failed || status == .review {
                HStack(spacing: 4) {
                    if status != .rejected {
                        Button("否决") { model.assistReject(key: row.rowKey) }
                            .controlSize(.mini)
                            .help("站内那条不是同一个种子：以后不再拿它烦你")
                    }
                    if status == .review {
                        Button("回查") { model.assistRecheck(keys: [row.rowKey]) }
                            .controlSize(.mini)
                            .disabled(model.assistRunning)
                            .help("问一次下载器那条校验完了没")
                    }
                }
            }
            if status == .rejected {
                Button("撤销") { model.assistReject(key: row.rowKey, rejected: false) }
                    .controlSize(.mini)
                    .help("撤销否决：这条重新允许检索")
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // 底色即结论：绿=已辅、红=失败、蓝=校验中、橙=待确认、青=已在该站做种，
            // 待辅种与「不用查」的保持素底，一眼能挑出要动手的格子
            ZStack {
                Color.blockSurface(model.theme.dark)
                cellWash(status)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(cellEdge(status), lineWidth: 1))
        .opacity(status == .unsupported ? 0.55 : status == .missing ? 0.8 : 1)
        .help([model.siteName(row.siteID), row.torrentName,
               live?.detail ?? row.skipReason ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    /// 格子底色：结论色铺一层薄底；待辅种铺不出来（素底 = 不用管）
    private func cellWash(_ status: AssistPipeline.RowStatus) -> Color {
        switch status {
        case .assisted, .failed, .verifying, .review, .manual: return tintColor(status).opacity(0.18)
        case .seeding: return tintColor(status).opacity(0.14)
        // 「不用查」的几种也给个底：灰一档，跟「要动手」的素底分开
        case .missing, .rejected, .filtered: return Color.secondary.opacity(0.16)
        case .paused: return Color.secondary.opacity(0.12)
        case .unsupported: return Color.secondary.opacity(0.08)
        case .pending: return Color.clear
        }
    }

    private func cellEdge(_ status: AssistPipeline.RowStatus) -> Color {
        switch status {
        case .assisted, .failed, .verifying, .review, .manual: return tintColor(status).opacity(0.5)
        case .seeding: return tintColor(status).opacity(0.4)
        case .missing, .rejected, .filtered: return Color.secondary.opacity(0.35)
        case .paused: return Color.secondary.opacity(0.5)
        case .unsupported, .pending: return Color(nsColor: .separatorColor)
        }
    }

    private func tintColor(_ status: AssistPipeline.RowStatus) -> Color {
        switch status {
        case .assisted: return .green
        case .failed: return .red
        case .verifying: return Color.accentColor
        case .review: return .purple
        case .manual: return .orange
        case .seeding: return .teal
        case .pending: return .secondary
        case .missing, .rejected, .unsupported, .filtered, .paused: return Color.secondary.opacity(0.6)
        }
    }
}
/// 逐站筛选的一行：站名 + 包含/排除关键词 + 体积上下限。回车提交（与限速输入框同一套习惯）
private struct AssistFilterRow: View {
    let name: String
    let filter: AssistConfig.SiteFilter
    let commit: (AssistConfig.SiteFilter) -> Void
    @State private var include: String
    @State private var exclude: String
    @State private var minGB: String
    @State private var maxGB: String

    init(name: String, filter: AssistConfig.SiteFilter,
         commit: @escaping (AssistConfig.SiteFilter) -> Void) {
        self.name = name
        self.filter = filter
        self.commit = commit
        _include = State(initialValue: filter.include.joined(separator: "，"))
        _exclude = State(initialValue: filter.exclude.joined(separator: "，"))
        _minGB = State(initialValue: filter.minSizeGB > 0 ? String(Int(filter.minSizeGB)) : "")
        _maxGB = State(initialValue: filter.maxSizeGB > 0 ? String(Int(filter.maxSizeGB)) : "")
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(name).lineLimit(1).frame(width: 92, alignment: .leading)
            field($include, "不限") { include = $0; send() }
            field($exclude, "不排除") { exclude = $0; send() }
            field($minGB, "0", wide: false) { minGB = $0; send() }
            field($maxGB, "0", wide: false) { maxGB = $0; send() }
            if !filter.isEmpty {
                Button("清除") {
                    include = ""; exclude = ""; minGB = ""; maxGB = ""
                    commit(AssistConfig.SiteFilter())
                }
                .controlSize(.mini)
            }
            Spacer()
        }
        .font(.caption)
    }

    private func field(_ bind: Binding<String>, _ prompt: String, wide: Bool = true,
                       set: @escaping (String) -> Void) -> some View {
        TextField("", text: bind, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .frame(width: wide ? 190 : 52)
            .onSubmit { set(bind.wrappedValue); send() }
    }

    /// 关键词按逗号（中英文都算）切；数字留空当 0
    private func send() {
        var f = AssistConfig.SiteFilter(
            include: split(include), exclude: split(exclude),
            minSizeGB: Double(minGB) ?? 0, maxSizeGB: Double(maxGB) ?? 0)
        if f.include.isEmpty && exclude.isEmpty && minGB.isEmpty && maxGB.isEmpty {
            f = AssistConfig.SiteFilter()
        }
        commit(f)
    }

    private func split(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet(charactersIn: ",，、"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// 数值输入框：只收数字（小数点按需），空 = 0，回车或失焦提交；占位显示推荐值
struct NumField: View {
    @State private var text: String
    @FocusState private var focused: Bool
    private let commit: (Double) -> Void
    private let integer: Bool
    /// 清空后占位显示推荐值（默认值本身就是推荐值）
    private let recommendText: String

    init(value: Double, recommend: Double, integer: Bool = false,
         commit: @escaping (Double) -> Void) {
        self.commit = commit
        self.integer = integer
        self.recommendText = NumField.plain(recommend, integer: integer)
        _text = State(initialValue: NumField.plain(value, integer: integer))
    }

    private static func plain(_ v: Double, integer: Bool) -> String {
        if integer || v == v.rounded() { return String(Int(v)) }
        return String(format: "%.1f", v)
    }

    var body: some View {
        TextField("", text: $text, prompt: Text(recommendText))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .frame(width: 64)
            .focused($focused)
            .onChange(of: text) { v in
                let ok = CharacterSet(charactersIn: integer ? "0123456789" : "0123456789.")
                let filtered = String(v.unicodeScalars.filter { ok.contains($0) })
                if filtered != v { text = filtered }
            }
            .onSubmit { commit(Double(text) ?? 0) }
            .onChange(of: focused) { f in if !f { commit(Double(text) ?? 0) } }
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
                        Text("图文教程：添加站点分组、配置 Cookie、批量转种、推送下载器、TMDB 反查、软件更新与外观设置。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                CardSection("软件更新") {
                    HStack(spacing: 10) {
                        Text("当前版本 \(BoxSendVersion.version)")
                            .font(.callout.monospacedDigit())
                        Button(model.checkingUpdate ? "检查中…" : "检查更新") { model.checkForUpdate() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.checkingUpdate)
                        if model.checkingUpdate { ProgressView().controlSize(.small) }
                        if let rel = model.updateRelease, let d = rel.downloadURL,
                           SoftwareUpdate.isNewer(rel.version, than: BoxSendVersion.version) {
                            Button("下载 \(rel.version) 安装包") { model.openURL(d) }
                        }
                        Button("打开发布页") { model.openURL(SoftwareUpdate.releasesURL) }
                            .controlSize(.small)
                        Spacer()
                    }
                    if let r = model.updateResult {
                        Text(r)
                            .foregroundStyle(updateTint(r))
                            .textSelection(.enabled)
                    }
                    Toggle("启动时自动检查新版本", isOn: Binding(
                        get: { model.config.autoUpdateCheck },
                        set: { on in
                            model.config.autoUpdateCheck = on
                            model.saveConfig()
                        }))
                    Text("更新地址：\(SoftwareUpdate.repoURL) 。检查只读 GitHub 的发布接口；"
                         + "有新版本点「下载安装包」，双击 dmg 替换旧版本即可，站点、Cookie 与设置都在本机，不会被动到。")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                CardSection("TMDB 链接（豆瓣 / IMDb 反查）") {
                    Toggle("发种时自动补 TMDB 链接", isOn: Binding(
                        get: { model.tmdbConfig.enabled },
                        set: { on in model.updateTMDB { $0.enabled = on } }))
                    LabeledRow("API 代理网关地址") {
                        TextField(TMDBConfig.officialAPIBase, text: Binding(
                            get: { model.tmdbConfig.apiBase },
                            set: { v in model.updateTMDB { $0.apiBase = v } }))
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledRow("API Key（网关代填时留空）") {
                        RevealField(text: Binding(
                            get: { model.tmdbConfig.apiKey },
                            set: { v in model.updateTMDB { $0.apiKey = v } }))
                    }
                    HStack(spacing: 12) {
                        Button(model.testingTMDB ? "测试中…" : "测试查询") { model.testTMDB() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.testingTMDB)
                        if model.testingTMDB { ProgressView() }
                    }
                    if let r = model.tmdbTestResult {
                        Text(r)
                            .foregroundStyle(r.hasPrefix("成功") ? .green : .red)
                            .textSelection(.enabled)
                    }
                    Text("目标站把 TMDB 链接设为必填（如杜比）、而源站简介里没有时，用种子的 IMDb 号或豆瓣号去 TMDB 查条目号。"
                         + "国内直连 api.themoviedb.org 常不通：填自己的网关地址即可绕开，留空走官方接口。"
                         + "网关地址要写到版本号那一层（末尾带 /3，如 https://gw.example.com/tmdb0512/3），漏写软件会自动补一次再试。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // 辅种收起时这两块也不摆：搜不到入口的节奏设置留着只会让人乱改
                if AssistFeature.enabled {
                    paceCard
                    siteFilterCard
                }
                CookiesView()
                DownloaderView()
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
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showTutorial) {
            TutorialSheet()
        }
    }

    private var cfg: AssistConfig { model.assistConfig }

    /// 逐站已辅数（站点本身在「站点分组」页的辅种区块里加）
    private var assistedCountsLine: String {
        let pairs = (model.assistSummary?.assistedBySite ?? [:])
            .filter { $0.value > 0 }
            .sorted { $0.key < $1.key }
            .map { "\(model.config.site($0.key)?.name ?? $0.key) \($0.value)" }
        return pairs.isEmpty ? "还没有辅成功的记录" : "已辅：" + pairs.joined(separator: " · ")
    }

    /// 站点请求的节奏：所有对站点的请求都从这一个节流器过，界面只负责填数
    private var paceCard: some View {
        CardSection("辅种搜索节奏") {
            paceRow("每站最小间隔", dbl(\.perSiteIntervalSec, 0, 120), recommend: 8, unit: "秒")
            paceRow("随机抖动", dbl(\.jitterSec, 0, 30), recommend: 3, unit: "秒")
            paceRow("单轮请求预算", num(\.roundBudget, 1, 2000), recommend: 200, unit: "次")
            paceRow("查无结果保留", num(\.missTTLDays, 0, 90), recommend: 7, unit: "天")
            paceRow("定时自动跑", num(\.autoRunMinutes, 0, 1440), recommend: 0, unit: "分钟")
            paceRow("辅种页单页条数", Binding(get: { cfg.listPageSize },
                                             set: { model.assistSetPageSize($0) }),
                    recommend: 10, unit: "条")
            Toggle("站内查不到时换宽松查询词再问一次", isOn: flag(\.relaxedRetrySearch))
                .font(.callout)
            Toggle("站点重打包（文件全等）自动采纳", isOn: flag(\.autoAcceptSameFiles))
                .font(.callout)
            Toggle("校验不满 100% 时删掉刚加的种子", isOn: flag(\.removeOnVerifyFail))
                .font(.callout)
            Text(assistedCountsLine).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(cfg.autoRunMinutes == 0
                 ? "0 = 不自动跑。设成 60 之类，到点自己扫描并辅一轮。"
                 : "约 \(model.assistAutoNext ?? 0) 分钟后自动跑下一轮，请求仍受单轮预算约束。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("一次检索最多发 3 次站点请求（检索、详情、种子文件各一次）；"
                 + "严格查重没命中再问一次宽松的，那一格最多 4 次。"
                 + "辅种站点在「站点分组」页底部的辅种区块里添加。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 逐站筛选：站点名单铺满时首轮要检索几十天，能砍分母的就靠这条规则
    @State private var filterOnlySet = false

    private var siteFilterCard: some View {
        let ids = cfg.siteIDs
        let rows = ids.filter { filterOnlySet == false || cfg.assistFilter($0) != nil }
        return CardSection("辅种逐站筛选") {
            HStack(spacing: 10) {
                Toggle("只显示设过规则的站", isOn: $filterOnlySet)
                    .toggleStyle(.switch).controlSize(.small)
                Text("共 \(ids.count) 个辅种站，其中 \(ids.filter { cfg.assistFilter($0) != nil }.count) 个设了规则")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            if ids.isEmpty {
                Text("辅种站点在「站点分组」页底部的辅种区块里添加。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text("站点").frame(width: 92, alignment: .leading)
                    Text("只辅（含任一）").frame(width: 190, alignment: .leading)
                    Text("不辅（含任一）").frame(width: 190, alignment: .leading)
                    Text("下限/上限 GB")
                    Spacer()
                }
                .font(.caption).foregroundStyle(.secondary)
                // 站名一多这张卡能顶满整屏，规则列表自己滚，别把设置页撑没
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(rows, id: \.self) { id in
                            AssistFilterRow(name: model.siteName(id),
                                            filter: cfg.siteFilters[id] ?? AssistConfig.SiteFilter()) { f in
                                model.assistUpdate {
                                    if f.isEmpty { $0.siteFilters[id] = nil } else { $0.siteFilters[id] = f }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            Text("关键词不分大小写，逗号分隔；体积留空 = 跟全局设置。规则只拦「要不要去站内检索这一步」，"
                 + "已辅过、已在该站做种的照旧不动。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func num(_ keyPath: WritableKeyPath<AssistConfig, Int>, _ lo: Int,
                     _ hi: Int) -> Binding<Int> {
        Binding(get: { model.assistConfig[keyPath: keyPath] },
                set: { v in model.assistUpdate { $0[keyPath: keyPath] = min(hi, max(lo, v)) } })
    }

    private func dbl(_ keyPath: WritableKeyPath<AssistConfig, Double>, _ lo: Double,
                     _ hi: Double) -> Binding<Double> {
        Binding(get: { model.assistConfig[keyPath: keyPath] },
                set: { v in model.assistUpdate { $0[keyPath: keyPath] = min(hi, max(lo, v)) } })
    }

    private func flag(_ keyPath: WritableKeyPath<AssistConfig, Bool>) -> Binding<Bool> {
        Binding(get: { model.assistConfig[keyPath: keyPath] },
                set: { v in model.assistUpdate { $0[keyPath: keyPath] = v } })
    }

    private func paceRow(_ label: String, _ value: Binding<Double>, recommend: Double,
                         unit: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.callout)
            Spacer()
            NumField(value: value.wrappedValue, recommend: recommend) { value.wrappedValue = $0 }
            Text(unit).font(.caption).foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    private func paceRow(_ label: String, _ value: Binding<Int>, recommend: Int,
                         unit: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.callout)
            Spacer()
            NumField(value: Double(value.wrappedValue), recommend: Double(recommend), integer: true) {
                value.wrappedValue = Int($0.rounded())
            }
            Text(unit).font(.caption).foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

        /// 更新结果文案的配色：失败红、有新版本橙、其余（已最新）绿
    private func updateTint(_ r: String) -> Color {
        if r.hasPrefix("检查失败") { return .red }
        return r.hasPrefix("发现新版本") ? .orange : .green
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
                        "点击站点卡片开启 / 停用该站；「全选」一键切换分组内全部站点；「手动添加cookie或api key」为选中站点填写 cookie 或 API Key（馒头等 API 站的 key 不显示在卡片上，只在该弹窗里填写）。",
                        "「检测cookie或api key」批量检查 cookie / API Key 有效性，检测中右侧出现「停止检测」，点击可提前停止；「移除站点」「移除分组」均需两次确认。",
                        "支持「帖子免费1天」的站点（如猫站）卡片上会出现「发种后免费一天」开关：打开后发种成功就自动点一次站内免费按钮（要扣站内积分）；帖子已在免费满一天时不重复扣。",
                    ])
                    section("2. 配置与备份 Cookie", image: "cookies", steps: [
                        "PT-depiler Gist 同步：填写 GitHub Token 与 Gist ID，可开启自动同步 / 自动扫描并设置间隔秒数。",
                        "CookieCloud 同步备份：填写用户 KEY、UUID 与端对端加密密码。",
                        "两路备份互为补充：某一站点在一处的 cookie 失效时，同步后自动用另一来源补充。",
                        "「同步 Cookie」立即执行两路同步；「立即扫描」检查 PT-depiler 备份目录。",
                    ])
                    section("3. 批量转种", image: "run", steps: [
                        "「批量转种」页粘贴种子详情页链接，勾选「转种到目标站」与「推送到下载器」。",
                        "源站默认按链接域名识别（「种子链接」旁的「源站」菜单会显示识别结果）；站点分组里添加过的站点都能点名作源站。",
                        "勾选转种分组（「全选」= 全部分组）后点「开始运行」。",
                        "按分组顺序执行：获取种子 → 依次上传到组内已开启站点（限速取分组上传限速）→ 转种成功的种子自动推送到下载器。",
                        "需要注明转种来源时勾选「源站引用」并填写文本：软件会把这段文字用引用块加在每个目标站简介的最上面；源站自带引用的不用勾。cmct、劳改所的「附加信息」框只用这段文字，没勾选时留空并在站点卡片上提示。",
                        "点「运行记录」展开查看每个站点的转种 / 推送结果。",
                    ])
                    section("4. 推送到 VPS 下载器", image: "downloader", steps: [
                        "填写下载器（qBittorrent Web UI）地址、用户名与密码。",
                        "「检验连接」验证可用性；勾选「跳过检验」后推送时不再校验。",
                        "转种成功的种子会自动推送到下载器开始下载。",
                    ])
                    section("5. 转种服务器测速（SSH）", image: nil, steps: [
                        "部分服务器 24 小时上传流量到 2T 后，会把上行悄悄压到 20 MB/s 左右：站点照样能发种，但整批下载都变慢。",
                        "「下载器」页「转种服务器」卡片填写服务器地址、端口、用户名，选密钥或密码登录（密钥默认 ~/.ssh/id_ed25519，点「选择…」挑）。",
                        "「测试连接并测速」立刻连一次：显示服务器主机名、每轮实测速度。",
                        "「批量转种」页「开始运行」左边有「测试上传速度」：随时点一下，实测速度显示在按钮下面那一行，不做自动判定——速度不理想就等一等再转，不测也能直接开转。",
                        "测速是在服务器上往公网推数据（默认每轮 64 MB、共两轮），只多花这一份上行；测速地址可换成自己的接收端。",
                    ])
                    section("6. TMDB 链接自动反查", image: nil, steps: [
                        "部分站点（如杜比）把 TMDB 链接设为必填，源站简介里没有 TMDB 时发种会被拒。",
                        "「设置」页「TMDB 链接」卡片勾选「发种时自动补 TMDB 链接」：发种前用种子的 IMDb 号或豆瓣号去 TMDB 查条目号，填进目标站的 TMDB 输入框；查不到时留空，由你手动填写。",
                        "国内直连 api.themoviedb.org 常不通：在「API 代理网关地址」填自己的网关，留空即走官方接口；地址要写到版本号那一层（末尾带 /3，如 https://gw.example.com/tmdb0512/3），漏写会先按你填的试、404 再自动补 /3 重试。",
                        "网关只是转发时仍要填 TMDB 的 API Key；只有网关自己代填 Key 时才留空。",
                        "「测试查询」用一条固定片例验证网关是否可用。",
                    ])
                    section("7. 软件更新", image: nil, steps: [
                        "更新地址就是项目仓库 https://github.com/nandieling/box-send，「设置」页「软件更新」卡片能看到当前版本并检查新版本。",
                        "默认每次启动在后台查一次（只读 GitHub 的发布接口，不上传任何本机数据）；不想自动查就关掉「启动时自动检查新版本」，改成手动点「检查更新」。",
                        "发现新版本点「下载安装包」，双击 dmg 替换旧版本即可：站点、Cookie、限速与主题设置都存在本机，升级不会被动到。",
                        "直连 GitHub 不通时会提示连不上，此时点「打开发布页」自己下载最新 dmg。",
                    ])
                    section("8. 外观设置", image: "settings", steps: [
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

    private func section(_ title: String, image: String? = nil, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).fontWeight(.semibold)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(i + 1).").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .trailing)
                    Text(step).font(.caption)
                }
            }
            if let image {
                tutorialImage(image)
                    .padding(.top, 4)
            }
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
