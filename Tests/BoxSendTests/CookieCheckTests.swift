import XCTest
@testable import BoxSendKit

/// 馒头 API Key 检测：走 api.m-team.cc 新网关（POST /api/member/profile + x-api-key 头）
final class CookieCheckTests: XCTestCase {
    /// 原始配置不带 overrides（用户配置常见形态）：effectiveSite 需补上馒头的 apiBase
    private func rawMTeam(key: String) -> SiteConfig {
        var site = SiteConfig(id: "mteam", name: "馒头", url: "https://kp.m-team.cc/",
                              framework: .unit3D, enabled: true)
        site.apiKey = key
        return site
    }

    private func stub(_ body: String, status: Int = 200, capture: ((URLRequest) -> Void)? = nil) -> HTTPClient {
        let client = HTTPClient(cookies: CookieStore(), userAgent: "boxsend-test")
        client.performOverride = { req in
            capture?(req)
            return HTTPClient.Response(status: status, data: Data(body.utf8),
                                       headers: [:], finalURL: req.url!.absoluteString)
        }
        return client
    }

    /// 有效 Key：{"code":"0","message":"SUCCESS",data.username}
    func testMTeamAPIKeyValid() {
        var reqPath = ""
        var reqMethod = ""
        var headerKey: String?
        var contentType = ""
        let client = stub(#"{"code":"0","message":"SUCCESS","data":{"username":"tester","id":"295053"}}"#) { req in
            reqPath = req.url!.path
            reqMethod = req.httpMethod ?? ""
            headerKey = req.value(forHTTPHeaderField: "x-api-key")
            contentType = req.value(forHTTPHeaderField: "Content-Type") ?? ""
        }
        let r = CookieCheck.check(site: rawMTeam(key: "85404ae5-f258-40f4-9a72-8307eb568a65"), client: client)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.message.contains("tester"), r.message)
        XCTAssertEqual(reqPath, "/api/member/profile")
        XCTAssertEqual(reqMethod, "POST")
        XCTAssertEqual(headerKey, "85404ae5-f258-40f4-9a72-8307eb568a65")
        XCTAssertTrue(contentType.contains("json"), contentType)
        // 回归：旧实现用 ?api_key= 查询参数鉴权，新网关一律 code=401（把有效 Key 判成失效）
        XCTAssertFalse(reqPath.contains("api_key"))
    }

    /// 无效 Key：{"code":1,"message":"key無效"}
    func testMTeamAPIKeyRejected() {
        let client = stub(#"{"code":1,"message":"key無效","data":null}"#)
        let r = CookieCheck.check(site: rawMTeam(key: "bogus"), client: client)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("无效或已过期"), r.message)
    }

    /// 缺凭证：{"code":401,...}
    func testMTeamAPIKeyUnauthorized() {
        let client = stub(#"{"code":401,"message":"Full authentication is required to access this resource","data":null}"#)
        let r = CookieCheck.check(site: rawMTeam(key: "whatever"), client: client)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("未通过鉴权"), r.message)
    }

    /// 网关返回非 JSON（如被 CDN/UA 拦截跳登录页）：不能武断说 Key 失效
    func testMTeamAPIKeyNonJSONResponse() {
        let client = stub("<html><head><title>Just a moment...</title></head></body>")
        let r = CookieCheck.check(site: rawMTeam(key: "whatever"), client: client)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("未返回 JSON"), r.message)
    }

    /// 未配置 Key
    func testMTeamAPIKeyMissing() {
        let client = stub("{}")
        let r = CookieCheck.check(site: rawMTeam(key: ""), client: client)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("未配置"), r.message)
    }

    /// 返回码兼容字符串/数字（馒头用 "0"）
    func testAPICodeAcceptsStringAndNumber() {
        XCTAssertEqual(CookieCheck.apiCode(["code": "0"]), 0)
        XCTAssertEqual(CookieCheck.apiCode(["code": 1]), 1)
        XCTAssertEqual(CookieCheck.apiCode(["code": 401.0]), 401)
        XCTAssertNil(CookieCheck.apiCode(["message": "x"]))
    }
}
