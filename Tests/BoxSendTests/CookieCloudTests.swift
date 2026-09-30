import XCTest
@testable import BoxSendKit

final class CookieCloudTests: XCTestCase {

    private let known: [(id: String, name: String, host: String)] = [
        (id: "hdhome", name: "家园", host: "hdhome.org"),
        (id: "hdsky", name: "天空", host: "hdsky.me"),
    ]

    func testParseEntriesPlainArray() throws {
        let json = """
        [
          {"name": "家园", "url": "https://hdhome.org", "cookies": "uid=1; pass=a"},
          {"name": "天空", "site": "https://hdsky.me", "cookies": "uid=2"}
        ]
        """
        let r = try CookieCloudSync.parseEntries(Data(json.utf8))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].name, "家园")
        XCTAssertEqual(r[0].url, "https://hdhome.org")
        XCTAssertEqual(r[0].cookies, "uid=1; pass=a")
        XCTAssertEqual(r[1].url, "https://hdsky.me")
    }

    func testParseEntriesObjectWrapped() throws {
        let json = """
        {"data": [{"name": "家园", "url": "https://hdhome.org", "cookies": "uid=1"}]}
        """
        let r = try CookieCloudSync.parseEntries(Data(json.utf8))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].url, "https://hdhome.org")
    }

    func testParseEntriesSkipsMissingCookies() throws {
        let json = """
        [
          {"name": "家园", "url": "https://hdhome.org"},
          {"name": "天空", "url": "https://hdsky.me", "cookies": "  "},
          {"name": "家园", "url": "https://hdhome.org", "cookies": "uid=1"}
        ]
        """
        let r = try CookieCloudSync.parseEntries(Data(json.utf8))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].name, "家园")
    }

    func testParseEntriesInvalidJSON() {
        XCTAssertThrowsError(try CookieCloudSync.parseEntries(Data("not json".utf8)))
        // 结构异常：既不是数组也没有已知的包裹键
        XCTAssertThrowsError(try CookieCloudSync.parseEntries(Data("#not-json".utf8)))
    }

    func testHostFor() {
        XCTAssertEqual(CookieCloudSync.hostFor(name: "家园", url: "https://hdhome.org/board", knownSites: known), "hdhome.org")
        XCTAssertEqual(CookieCloudSync.hostFor(name: "家园", url: "", knownSites: known), "hdhome.org")
        XCTAssertEqual(CookieCloudSync.hostFor(name: "hdsky", url: "", knownSites: known), "hdsky.me")
        XCTAssertNil(CookieCloudSync.hostFor(name: "未知站", url: "", knownSites: known))
    }

    func testPullImportsIntoStore() throws {
        let json = """
        [
          {"name": "家园", "url": "https://hdhome.org", "cookies": "uid=1; pass=a"},
          {"name": "天空", "url": "https://hdsky.me", "cookies": "uid=2"},
          {"name": "陌生站", "cookies": "uid=9"}
        ]
        """
        let client = HTTPClient(cookies: CookieStore(), userAgent: "t")
        var seenAuth = ""
        var seenURL = ""
        client.performOverride = { req in
            seenAuth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            seenURL = req.url?.absoluteString ?? ""
            return .init(status: 200, data: Data(json.utf8), headers: [:],
                         finalURL: req.url?.absoluteString ?? "")
        }
        let store = CookieStore()
        let r = try CookieCloudSync(config: .init(baseURL: "https://cookiecloud.co/", token: "tk"),
                                    client: client)
            .pull(into: store, knownSites: known)
        XCTAssertEqual(seenAuth, "Bearer tk")
        XCTAssertEqual(seenURL, "https://cookiecloud.co/api/cookies")
        XCTAssertEqual(r.imported, 2)
        XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(store.cookieHeader(forHost: "hdhome.org"), "uid=1; pass=a")
        XCTAssertEqual(store.cookieHeader(forHost: "hdsky.me"), "uid=2")
    }

    func testPullEmptyEntriesThrows() {
        let client = HTTPClient(cookies: CookieStore(), userAgent: "t")
        client.performOverride = { _ in
            .init(status: 200, data: Data("[]".utf8), headers: [:], finalURL: "")
        }
        XCTAssertThrowsError(try CookieCloudSync(config: .init(token: "tk"), client: client)
            .pull(into: CookieStore(), knownSites: known))
    }
}
