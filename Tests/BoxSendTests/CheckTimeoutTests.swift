import Foundation
import XCTest
@testable import BoxSendKit

/// cookie / API Key 检测的时长上限：慢站只影响自己那一格，不拖住整批
final class CheckTimeoutTests: XCTestCase {
    private func site(_ id: String) -> SiteConfig {
        SiteConfig(id: id, name: id, url: "https://\(id).example/", framework: .nexusPHP, enabled: true)
    }

    /// 注入响应：到点失败模拟连接池超时；同时记录请求次数
    private func client(delay: TimeInterval, fail: Bool, body: String, calls: @escaping () -> Void) -> HTTPClient {
        let c = HTTPClient(cookies: CookieStore(), userAgent: "box-send-test")
        c.performOverride = { _ in
            calls()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if fail { throw URLError(.timedOut) }
            return HTTPClient.Response(status: 200, data: Data(body.utf8), headers: [:],
                                       finalURL: "https://example.example/")
        }
        return c
    }

    func testExpiredBudgetReportsTimeout() {
        var n = 0
        let c = client(delay: 0, fail: true, body: "", calls: { n += 1 })
        let budget = CookieCheck.Budget(until: Date().addingTimeInterval(-0.1), seconds: 12)
        let r = CookieCheck.check(site: site("slow"), client: c, budget: budget)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.unconfirmed, r.message)
        XCTAssertTrue(r.message.contains("未确认"), r.message)
        XCTAssertEqual(n, 1, "超时后不再二次探测")
    }

    func testTimeLeftSkipsSecondProbe() {
        var n = 0
        // 首页没有登录/未登录标记 -> 本来会再探 userdetails；时间用尽时直接记超时
        let c = client(delay: 0, fail: false, body: "<html>种子列表</html>", calls: { n += 1 })
        let budget = CookieCheck.Budget(until: Date().addingTimeInterval(-0.1), seconds: 8)
        let r = CookieCheck.check(site: site("slow2"), client: c, budget: budget)
        XCTAssertTrue(r.message.contains("未确认"), r.message)
        XCTAssertEqual(n, 1, "预算用尽时不发起第二次请求")
    }

    func testNormalCheckWithinBudget() {
        var n = 0
        let c = client(delay: 0, fail: false, body: "usercp 欢迎回来", calls: { n += 1 })
        let budget = CookieCheck.Budget(until: Date().addingTimeInterval(10), seconds: 12)
        let r = CookieCheck.check(site: site("fast"), client: c, budget: budget)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.message.contains("已登录"), r.message)
    }

    func testRequestTimeoutFloorAndResourceTimeout() {
        let c = HTTPClient(cookies: CookieStore(), userAgent: "t")
        c.setRequestTimeout(3)
        XCTAssertEqual(c.timeout, 3)
        XCTAssertEqual(c.resourceTimeout, 3, "整请求总时长也压到同一上限")
        c.setRequestTimeout(0)
        XCTAssertEqual(c.timeout, 1, "下限保护：不能设成 0 让所有请求立刻失败")
    }
}
