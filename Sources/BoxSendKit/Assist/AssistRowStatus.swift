import Foundation

extension AssistPipeline {
    /// 界面上一个「种子 × 站点」小格子的结论。
    ///
    /// 归类放核心库：mac 与 Windows 只按这个上色、贴标签，免得两端各写一套判断，
    /// 同一个下载器跑出两个数。
    public enum RowStatus: String, CaseIterable, Equatable {
        /// 已推下载器并校验到 100%
        case assisted
        /// 还没轮到 / 排队中 / 本轮预算用完
        case pending
        /// 真做砸了：读不到站点那条、推下载器失败、校验不满被删
        case failed
        /// 已推进下载器，这一轮正在等校验
        case verifying
        /// 上一轮推进了下载器却没等到结果：种子还暂停着，等「回查校验」收尾
        case review
        /// 只有名字对得上，等人拍板
        case manual
        /// 站内检索没有这条种子
        case missing
        /// 检索到了一条，人比对过说不是同一种子：永久不再问
        case rejected
        /// 这份文件已经在该站做种，本来就不用辅
        case seeding
        /// 站点没有可用的检索入口
        case unsupported
        /// 这个站设了筛选规则，这条按规则不该辅
        case filtered
        /// 这个站被手动暂停：还没轮到，先不去敲门（不算有结论）
        case paused

        /// 站点卡片上的短标签
        public var label: String {
            switch self {
            case .assisted: return "已辅种"
            case .pending: return "待辅种"
            case .failed: return "失败"
            case .verifying: return "校验中"
            case .review: return "待复核"
            case .manual: return "待确认"
            case .review: return "待复核"
            case .missing: return "不存在"
            case .rejected: return "已否决"
            case .seeding: return "已做种"
            case .unsupported: return "不支持检索"
            case .filtered: return "本站不辅"
            case .paused: return "已暂停"
            }
        }

        /// 统计行上的完整说法
        public var statLabel: String {
            switch self {
            case .assisted: return "已完成辅种"
            case .pending: return "待辅种"
            case .failed: return "失败辅种"
            case .verifying: return "校验中"
            case .review: return "待复核（校验没跑完）"
            case .manual: return "待人工确认"
            case .missing: return "站内不存在"
            case .rejected: return "人工已否决"
            case .seeding: return "已在该站做种"
            case .unsupported: return "不支持站内检索"
            case .filtered: return "按本站筛选不辅"
            case .paused: return "本站已暂停"
            }
        }
    }

    /// 一行的实时进展。只要阶段与那句话就够归类了，不必把整个 Status 递给界面。
    public struct LiveRow: Equatable {
        public var phase: Status.Phase
        public var text: String
        public init(phase: Status.Phase, text: String) {
            self.phase = phase
            self.text = text
        }
    }

    /// 统计：一条种子 × 一个站算一格
    public struct Tally: Equatable {
        public var counts: [RowStatus: Int] = [:]
        public init() {}
        public mutating func increase(_ status: RowStatus, _ n: Int = 1) {
            counts[status, default: 0] += n
        }

        public mutating func decrease(_ status: RowStatus, _ n: Int = 1) {
            counts[status, default: 0] = max(0, counts[status, default: 0] - n)
        }
        public func count(_ status: RowStatus) -> Int { counts[status, default: 0] }
        public var total: Int { counts.values.reduce(0, +) }
        /// 固定顺序，0 也列出来：只列非零项会让人以为某一类还没开始跑
        public var lines: [(status: RowStatus, count: Int)] {
            RowStatus.allCases.map { ($0, count($0)) }
        }

        /// 已经有结论、不用再去站内敲门的格子
        public var resolved: Int {
            count(.assisted) + count(.seeding) + count(.missing) + count(.rejected)
                + count(.filtered)
        }

        /// 暂停站里压着的格子：没结论，但这一轮不会去检索
        public var paused: Int { count(.paused) }

        /// 还没结论的格子（含要重试的失败、要人拍板的、要回查的、暂停站里压着的）
        public var unresolved: Int { max(0, total - resolved) }

        /// 还要发多少次检索才铺完：待辅种 + 上次失败的（失败的下次会重搜）。
        /// 暂停站里那些不算：这一轮根本不会去敲门
        public var searchesLeft: Int { count(.pending) + count(.failed) }

        /// 等人动手的格子：失败、待确认、待复核
        public var needsAction: Int { count(.failed) + count(.manual) + count(.review) }
    }

    /// 覆盖率与预计：把「还剩多少」翻成人能安排的话。
    /// 估算按逐站间隔串行累加——执行本来就是按站轮着来的，不是并发。
    public struct Coverage: Equatable {
        public var total = 0
        public var resolved = 0
        public var unresolved = 0
        /// 还要发多少次站内检索
        public var searchesLeft = 0
        /// 等人处理：失败 / 待确认 / 待复核
        public var needsAction = 0
        /// 不间断跑完还要多久（nil = 没有可检索的格子，或没设间隔）
        public var secondsLeft: TimeInterval?
        /// 按单轮预算还要跑多少轮
        public var roundsLeft = 0
        public var siteCount = 0
        /// 压在暂停站里没轮的格子（不计检索，也不算有结论）
        public var paused = 0

        public var percent: Double { total == 0 ? 0 : Double(resolved) / Double(total) }

        /// 一句人话：既给百分比，也给「照现在这个节奏要多久」
        public var line: String {
            var parts: [String] = []
            parts.append("已判定 \(grouped(resolved)) / \(grouped(total))（\(String(format: "%.1f", percent * 100))%）")
            if searchesLeft > 0 {
                parts.append("还要站内检索 \(grouped(searchesLeft)) 次"
                    + (roundsLeft > 0 ? "，按单轮预算要 \(grouped(roundsLeft)) 轮" : ""))
            } else {
                parts.append("站内检索已经铺完")
            }
            if let s = secondsLeft { parts.append("不间断跑完约 " + Self.duration(s)) }
            if paused > 0 { parts.append("暂停站里压着 \(grouped(paused)) 格") }
            if needsAction > 0 { parts.append("等人处理 \(grouped(needsAction)) 条") }
            if siteCount > 0 { parts.append("在跑的站 \(grouped(siteCount)) 个") }
            return parts.joined(separator: "；") + "。"
        }

        static func duration(_ t: TimeInterval) -> String {
            let sec = Int(t.rounded())
            if sec < 90 { return "\(sec) 秒" }
            let min = sec / 60
            if min < 90 { return "\(min) 分钟" }
            let hr = min / 60
            if hr < 48 { return min % 60 == 0 ? "\(hr) 小时" : "\(hr) 小时 \(min % 60) 分" }
            let day = hr / 24
            return hr % 24 == 0 ? "\(day) 天" : "\(day) 天 \(hr % 24) 小时"
        }
    }

    /// 千分位：三四万条组合不加逗号根本数不清
    public static func grouped(_ n: Int) -> String {
        let s = String(n)
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0 && (s.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return out
    }

    /// 一行在界面上的结论：跑过的以进展为准，没跑过的按计划
    public static func status(of row: PlanRow, live: LiveRow?) -> RowStatus {
        if let now = status(live: live) { return now }
        if let planned = row.planned { return planned }
        return status(plan: row)
    }

    /// 只有进展、没有计划行时（计划表之外的行）
    public static func status(ofLive live: LiveRow) -> RowStatus {
        status(live: live) ?? .pending
    }

    public static func status(plan row: PlanRow) -> RowStatus {
        status(skipReason: row.skipReason)
    }

    public static func status(skipReason: String?) -> RowStatus {
        guard let why = skipReason else { return .pending }
        return status(why: why) ?? .pending
    }

    /// 进展 → 结论。「跳过」这句话里带的原因才算数（站内没有 / 已做种 / 不支持检索…）
    public static func status(live: LiveRow?) -> RowStatus? {
        guard let live else { return nil }
        switch live.phase {
        case .done: return .assisted
        case .failed: return .failed
        case .verifying: return .verifying
        case .review: return .review
        case .working: return nil                 // 还在跑：照计划的结论显示
        case .skipped: return status(why: live.text)
        }
    }

    /// 预筛原因与事件文案用的是同一批词，一处归类
    private static func status(why: String) -> RowStatus? {
        if why.contains("站内无此种子") || why.contains("站内没有") { return .missing }
        if why.contains("不支持站内检索") { return .unsupported }
        if why.contains("已在该站做种") { return .seeding }
        if why.contains("此前已辅过") { return .assisted }
        if why.contains("待人工确认") { return .manual }
        if why.contains("待复核") { return .review }
        if why.contains("不是同一种子") { return .rejected }
        if why.contains("筛选不辅") { return .filtered }
        if why.contains("本站已暂停") { return .paused }
        return nil
    }

    /// 全量计划 + 当前进展 → 计数。计划行上万，整表重算也就几微秒，
    /// 比「只搬增量」少一类对不齐的 bug。
    public static func tally(rows: [PlanRow], live: [String: LiveRow] = [:]) -> Tally {
        var t = Tally()
        for row in rows { t.increase(status(of: row, live: live[row.rowKey])) }
        return t
    }
}

extension AssistPipeline.Status {
    public var liveRow: AssistPipeline.LiveRow {
        AssistPipeline.LiveRow(phase: phase, text: text)
    }
}
