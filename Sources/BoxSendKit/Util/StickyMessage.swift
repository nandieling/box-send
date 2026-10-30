import Foundation

/// 底部提示条那类一次性提示：显示几分钟就自己收起，界面上另有「关闭」可以立刻收。
///
/// 规则只写这一份：核心里的 cookie 提示用它，mac 界面侧那份也用它，
/// 两端不会各掐一个表、出现「mac 五分钟就收、Windows 挂一整天」这种事。
public struct StickyMessage {
    /// 显示时长：够看完一条同步结果，又不至于长期占着底部那条
    public static let ttl: TimeInterval = 5 * 60

    private var text: String = ""
    private var shownAt: Date?

    public init() {}

    /// 记一条新提示并重新计时；传空串等于收回
    public mutating func show(_ s: String, at now: Date = Date()) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            dismiss()
        } else {
            text = t   // 存裁好的那份：底部那条不该带首尾空白
            shownAt = now
        }
    }

    /// 当前该显示的字；过期就顺手清掉（下次再问还是空，不会自己复活）
    public mutating func current(now: Date = Date()) -> String? {
        guard let at = shownAt else { return nil }
        guard now.timeIntervalSince(at) <= Self.ttl else {
            dismiss()
            return nil
        }
        return text
    }

    public mutating func dismiss() {
        text = ""
        shownAt = nil
    }
}
