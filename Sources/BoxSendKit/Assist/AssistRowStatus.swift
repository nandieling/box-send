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
        /// 已推进下载器，等校验
        case verifying
        /// 只有名字对得上，等人拍板
        case manual
        /// 站内检索没有这条种子
        case missing
        /// 这份文件已经在该站做种，本来就不用辅
        case seeding
        /// 站点没有可用的检索入口
        case unsupported

        /// 站点卡片上的短标签
        public var label: String {
            switch self {
            case .assisted: return "已辅种"
            case .pending: return "待辅种"
            case .failed: return "失败"
            case .verifying: return "校验中"
            case .manual: return "待确认"
            case .missing: return "不存在"
            case .seeding: return "已做种"
            case .unsupported: return "不支持检索"
            }
        }

        /// 统计行上的完整说法
        public var statLabel: String {
            switch self {
            case .assisted: return "已完成辅种"
            case .pending: return "待辅种"
            case .failed: return "失败辅种"
            case .verifying: return "校验中"
            case .manual: return "待人工确认"
            case .missing: return "站内不存在"
            case .seeding: return "已在该站做种"
            case .unsupported: return "不支持站内检索"
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
