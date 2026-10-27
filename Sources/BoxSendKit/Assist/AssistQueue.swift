import Foundation

extension AssistPipeline {
    /// 待处理队列里的一条：不点一下就不会往前走的格子。
    /// 光有「失败 N 条」这个数不够——人要知道是哪条、为什么砸的、点哪个按钮能往前走。
    public struct QueueItem: Identifiable, Equatable {
        public var siteID: String
        public var siteName: String
        public var hash: String
        public var torrentName: String
        public var status: RowStatus
        /// 为什么在这儿（站点回话、校验百分比、否决理由…）
        public var why: String
        /// 什么时候的事（由调用方按本地格式翻好，两端同一份文案）
        public var timeText: String
        public var time: Double
        public var key: String { "\(siteID)|\(hash)" }
        public var id: String { key }
        /// 站内那条种子的详情页（失败/否决时也可能知道）
        public var url: String

        public init(siteID: String, siteName: String, hash: String, torrentName: String,
                    status: RowStatus, why: String, timeText: String, time: Double,
                    url: String = "") {
            self.siteID = siteID
            self.siteName = siteName
            self.hash = hash
            self.torrentName = torrentName
            self.status = status
            self.why = why
            self.timeText = timeText
            self.time = time
            self.url = url
        }

        /// 格子上的两个字（两端同一份文案）
        public var statusText: String { status.label }

        /// 这一条能做什么
        public var canAdopt: Bool { status == .manual }
        public var canRetry: Bool { status == .failed }
        public var canRecheck: Bool { status == .review }
        public var canUndo: Bool { status == .rejected }
        /// 已否决的只留一个「撤销」，别的按钮都是空话
        public var canReject: Bool { status != .rejected }
        /// 人已经表过态的（否决）：界面上收进「已处理」，不再跟待办混在一列
        public var handled: Bool { status == .rejected }

        /// 排在队列第几档：能立刻动手的排前面
        var rank: Int {
            switch status {
            case .manual: return 0
            case .review: return 1
            case .failed: return 2
            default: return 3
            }
        }
    }

    /// 状态表里的历史记录 + 这一轮的实时进展 → 待处理清单。
    /// 下载器里已经被删掉的组合不进清单：那条种子都不在了，没什么可处理的。
    public static func queueItems(_ entries: [AssistQueueEntry],
                                 live: [String: LiveRow] = [:],
                                 siteNames: (String) -> String,
                                 torrents: [String: LocalTorrent],
                                 timeText: (Double) -> String,
                                 limit: Int = 200) -> [QueueItem] {
        var items: [QueueItem] = []
        var seen = Set<String>()
        for e in entries {
            let hash = e.hash.lowercased()
            guard let t = torrents[hash] else { continue }
            let st: RowStatus
            switch e.kind {
            case .review: st = .review
            case .failed: st = .failed
            case .rejected: st = .rejected
            }
            let key = "\(e.siteID)|\(hash)"
            seen.insert(key)
            items.append(QueueItem(siteID: e.siteID, siteName: siteNames(e.siteID), hash: hash,
                                   torrentName: t.name, status: st, why: e.why,
                                   timeText: timeText(e.time), time: e.time,
                                   url: e.url))
        }
        // 「待人工确认」只活在跑的那一轮里，从实时进展里补
        for (key, row) in live {
            guard status(live: row) == .manual, !seen.contains(key) else { continue }
            let parts = key.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let hash = String(parts[1]).lowercased()
            guard let t = torrents[hash] else { continue }
            items.append(QueueItem(siteID: String(parts[0]), siteName: siteNames(String(parts[0])),
                                   hash: hash, torrentName: t.name, status: .manual,
                                   why: row.text, timeText: "本轮",
                                   time: Date().timeIntervalSince1970, url: ""))
        }
        items.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.time != $1.time { return $0.time > $1.time }
            return $0.siteName < $1.siteName
        }
        return Array(items.prefix(max(1, limit)))
    }
}
