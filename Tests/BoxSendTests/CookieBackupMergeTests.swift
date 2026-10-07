import XCTest
@testable import BoxSendKit

/// 备份来源（CookieCloud / PT-depiler Gist）的 cookie 合并
final class CookieBackupMergeTests: XCTestCase {

    private func entries(_ o: [[String: Any]]) -> [[String: Any]] { o }

    /// 同一站点的 cookie 常分散在 `.example.com` 与 `example.com` 两个分组键里，
    /// 直接按 host 建字典会后写的覆盖先写的（cf_clearance 整条丢失）。
    func testDottedAndBareHostKeysMerge() throws {
        let map: [String: Any] = [
            ".longpt.org": entries([["name": "cf_clearance", "value": "CF1", "expirationDate": 1822833863]]),
            "longpt.org": entries([["name": "c_secure_pass", "value": "JWT1", "expirationDate": 1803136058]]),
        ]
        let out = CookieRawMerge.rawStrings(map: map)
        XCTAssertEqual(out.count, 1, "两个分组键应合并到同一站点")
        let raw = try XCTUnwrap(out["longpt.org"])
        XCTAssertTrue(raw.contains("cf_clearance=CF1"), raw)
        XCTAssertTrue(raw.contains("c_secure_pass=JWT1"), raw)
    }

    /// 同名 cookie 出现在多个分组键：保留过期更晚（即更新）的那份
    func testSameNameKeepsLaterExpiry() {
        let map: [String: Any] = [
            "ptsbao.club": entries([["name": "c_secure_pass", "value": "OLD", "expirationDate": 1803134519]]),
            ".ptsbao.club": entries([["name": "c_secure_pass", "value": "NEW", "expirationDate": 1822446507]]),
        ]
        let raw = try! XCTUnwrap(CookieRawMerge.rawStrings(map: map)["ptsbao.club"])
        XCTAssertEqual(raw, "c_secure_pass=NEW")
    }

    /// 备份时间戳缺失时保持后写覆盖（与旧行为一致），不做无谓的丢弃
    func testEntriesWithoutExpiry() {
        let map: [String: Any] = [
            "a.club": entries([["name": "uid", "value": "1"], ["name": "pass", "value": "x"]]),
        ]
        let raw = try! XCTUnwrap(CookieRawMerge.rawStrings(map: map)["a.club"])
        XCTAssertEqual(Set(raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }),
                       Set(["uid=1", "pass=x"]))
    }
}
