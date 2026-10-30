import XCTest
@testable import BoxSendKit

/// 底部那条 cookie 提示：显示几分钟自己收，界面上还有个「关闭」能立刻收。
/// 规则收在核心的 StickyMessage 里，两端共用，这里把规则和桥契约一起钉住。
final class StickyMessageTests: XCTestCase {

    private func makeService() throws -> AppService {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boxsend-sticky-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let svc = try AppService(configPath: dir.appendingPathComponent("boxsend.json").path,
                                 dataDir: dir.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return svc
    }

    // MARK: 时长规则

    func testStaysUntilTTLThenGoesAway() {
        var msg = StickyMessage()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        msg.show("同步完成：更新 6 个站点", at: at)
        XCTAssertEqual(msg.current(now: at.addingTimeInterval(60)), "同步完成：更新 6 个站点")
        XCTAssertEqual(msg.current(now: at.addingTimeInterval(StickyMessage.ttl)), "同步完成：更新 6 个站点",
                       "刚好到点还算在显示时间内")
        XCTAssertNil(msg.current(now: at.addingTimeInterval(StickyMessage.ttl + 1)))
    }

    func testExpiredMessageDoesNotComeBack() {
        var msg = StickyMessage()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        msg.show("同步完成", at: at)
        XCTAssertNil(msg.current(now: at.addingTimeInterval(StickyMessage.ttl * 2)))
        XCTAssertNil(msg.current(now: at.addingTimeInterval(StickyMessage.ttl * 3)),
                     "过期是永久的，不会过一会儿又自己冒出来")
    }

    func testNewMessageRestartsTheClock() {
        var msg = StickyMessage()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        msg.show("第一条", at: at)
        msg.show("第二条", at: at.addingTimeInterval(StickyMessage.ttl - 10))
        // 新的一条重新计时：按第一条的时间点早已过期，按第二条的还没
        XCTAssertEqual(msg.current(now: at.addingTimeInterval(StickyMessage.ttl + 30)), "第二条")
    }

    func testStoredTextIsTrimmed() {
        var msg = StickyMessage()
        // 曾经存的是没裁的那份，底部因此带着一串空白
        msg.show("  \n同步完成：更新 6 个站点  \n")
        XCTAssertEqual(msg.current(), "同步完成：更新 6 个站点")
    }

    func testBlankOrWhitespaceShowsNothing() {
        var msg = StickyMessage()
        msg.show("同步完成")
        msg.show("   \n ")
        XCTAssertNil(msg.current(), "空白等于收回，底部不留一条空带")
    }

    func testDismissIsImmediate() {
        var msg = StickyMessage()
        msg.show("同步完成")
        msg.dismiss()
        XCTAssertNil(msg.current())
    }

    /// 时长要够看完一条同步结果，又不能长期占着底部
    func testTTLIsAFewMinutes() {
        XCTAssertGreaterThanOrEqual(StickyMessage.ttl, 120)
        XCTAssertLessThanOrEqual(StickyMessage.ttl, 10 * 60)
    }

    // MARK: 桥契约（Windows 端靠这两条命令，mac 端界面自己那份走同一个类）

    func testVersionPublishesTheTTL() throws {
        let svc = try makeService()
        let version = try svc.invoke("version")
        XCTAssertEqual(version["cookieMessageTTL"] as? Int, Int(StickyMessage.ttl),
                       "界面自己顶的那几条也照这个时长收，别两端各写一个数")
    }

    func testCookieMessageRoundTripsThroughSnapshot() throws {
        let svc = try makeService()
        XCTAssertEqual(cookieLine(svc), "", "没提示时快照给空串")
        _ = try svc.invoke("cookie.message", ["text": "  已从 Gist 同步 cookie  "])
        XCTAssertEqual(cookieLine(svc), "已从 Gist 同步 cookie", "首尾空白不该进底部那条")
        _ = try svc.invoke("cookie.dismiss")
        XCTAssertEqual(cookieLine(svc), "", "末尾那个「关闭」按下去就得立刻收")
    }

    func testBlankMessageFromUIDismisses() throws {
        let svc = try makeService()
        _ = try svc.invoke("cookie.message", ["text": "同步完成"])
        _ = try svc.invoke("cookie.message", ["text": ""])
        XCTAssertEqual(cookieLine(svc), "")
    }

    private func cookieLine(_ svc: AppService) -> String {
        ((svc.snapshot()["messages"] as? [String: Any])?["cookie"] as? String) ?? ""
    }
}
