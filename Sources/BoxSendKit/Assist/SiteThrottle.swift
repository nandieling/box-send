import Foundation

/// 站内检索节流。辅种是「拿下载器里的每条种子去每个站搜一遍」，
/// 种子数 × 站点数轻松上千次请求，而 PT 站普遍对检索有频控（CC 防护、搜索冷却），
/// 打太快既给站点添负载，又会被限流甚至警告。这里把节奏收在一处：
///
/// - 整轮串行（全局并发默认 1）：同一时刻只对一个站发一次检索；
/// - 每站最小间隔（默认 8 秒）+ 抖动：同一站两次请求之间至少隔这么久，
///   抖动是防止一批种子按固定节拍敲站点，看着像脚本；
/// - 站点喊「太频繁」/429/503 时该站间隔翻倍（上限 maxInterval），下一轮再慢慢回落；
/// - 单轮请求预算：用完就收工，剩下的下次接着跑（辅种本来就是可增量重跑的活）。
///
/// 时钟与等待都可注入，单测不用真睡觉。
public final class SiteThrottle: @unchecked Sendable {
    public struct Limits: Equatable {
        /// 同一站两次请求的最小间隔（秒）
        public var perSiteInterval: TimeInterval
        /// 间隔上再加 0…jitter 的随机量
        public var jitter: TimeInterval
        /// 站点报限流后该站间隔翻倍的上限
        public var maxInterval: TimeInterval
        /// 单轮允许的站点请求次数（含检索、详情、种子文件）
        public var roundBudget: Int

        public init(perSiteInterval: TimeInterval = 8, jitter: TimeInterval = 3,
                    maxInterval: TimeInterval = 240, roundBudget: Int = 200) {
            self.perSiteInterval = perSiteInterval
            self.jitter = jitter
            self.maxInterval = maxInterval
            self.roundBudget = roundBudget
        }
    }

    private var limits: Limits
    private let now: () -> Date
    private let pause: (TimeInterval) -> Void
    private let lock = NSLock()
    private var lastUse: [String: Date] = [:]
    private var penalty: [String: TimeInterval] = [:]
    private var requests = 0

    public init(limits: Limits = Limits(), now: @escaping () -> Date = { Date() },
                pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.limits = limits
        self.now = now
        self.pause = pause
    }

    public private(set) var used: Int = 0

    /// 本轮还剩几次请求
    public var remaining: Int {
        lock.lock(); defer { lock.unlock() }
        return max(0, limits.roundBudget - requests)
    }

    /// 拿到一次对 siteID 的请求许可：预算用完返回 false；否则按该站的节奏等到点。
    /// 调用方把 fetchDetail / downloadTorrentFile 也算一次，站点的负载是按请求算的，
    /// 不按「是不是搜索页」区分。
    public func acquire(_ siteID: String, random: () -> Double = { Double.random(in: 0...1) }) -> Bool {
        lock.lock()
        guard requests < limits.roundBudget else { lock.unlock(); return false }
        let floor = max(limits.perSiteInterval, penalty[siteID] ?? 0)
        let wait: TimeInterval
        if let last = lastUse[siteID] {
            let elapsed = now().timeIntervalSince(last)
            wait = max(0, floor - elapsed)
        } else {
            wait = 0
        }
        let extra = limits.jitter > 0 ? random() * limits.jitter : 0
        requests += 1
        used += 1
        lock.unlock()

        if wait > 0 { pause(wait) }
        lock.lock()
        // 等待期间也算进「上次使用时间」，抖动跟在本次之后
        lastUse[siteID] = now().addingTimeInterval(extra)
        lock.unlock()
        if extra > 0 { pause(extra) }
        return true
    }

    /// 本轮预算：已用 / 上限（上限能中途追加）
    public var budget: (used: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        return (requests, limits.roundBudget)
    }

    /// 追加本轮预算：人在界面上看着这一轮跑得顺，想让它多跑一会儿，
    /// 不必等这轮收工再点一次。逐站间隔照旧，追加的只是次数上限。
    public func addBudget(_ n: Int) {
        lock.lock(); defer { lock.unlock() }
        limits.roundBudget += max(0, n)
    }

    /// 站点回 429/503 或写明「搜索太频繁/请稍后再试」：该站间隔翻倍，别接着敲
    public func penalize(_ siteID: String) {
        lock.lock(); defer { lock.unlock() }
        let base = max(limits.perSiteInterval, penalty[siteID] ?? 0)
        penalty[siteID] = min(limits.maxInterval, base * 2)
    }

    /// 该站当前的实际间隔（单测与日志用）
    public func interval(for siteID: String) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return max(limits.perSiteInterval, penalty[siteID] ?? 0)
    }
}
