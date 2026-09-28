import XCTest
@testable import BoxSend

final class ModelsTests: XCTestCase {

    func testCookieStoreHeader() {
        let store = CookieStore()
        store.importCookies(host: "hdhome.org", cookies: [
            Cookie(name: "uid", value: "42", domain: "hdhome.org", path: "/"),
            Cookie(name: "pass", value: "abc def", domain: "hdhome.org", path: "/"),
        ])
        XCTAssertEqual(store.cookieHeader(forHost: "hdhome.org"), "uid=42; pass=abc def")
        // 子域请求带上父域 cookie
        XCTAssertEqual(store.cookieHeader(forHost: "img.hdhome.org"), "uid=42; pass=abc def")
        XCTAssertNil(store.cookieHeader(forHost: "other.org"))
    }

    func testCookieStoreSetCookie() {
        let store = CookieStore()
        store.importSetCookie("SID=abcdef; path=/; HttpOnly", host: "127.0.0.1")
        XCTAssertEqual(store.cookieHeader(forHost: "127.0.0.1"), "SID=abcdef")
        // 同名覆盖
        store.importSetCookie("SID=newvalue; path=/", host: "127.0.0.1")
        XCTAssertEqual(store.cookieHeader(forHost: "127.0.0.1"), "SID=newvalue")
    }

    func testImportBackupJSON() throws {
        let json = Data(#"{"example.org":[{"name":"a","value":"1"}]}"#.utf8)
        let store = CookieStore()
        let n = try store.importBackupJSON(json)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(store.cookieHeader(forHost: "example.org"), "a=1")
    }

    func testReleaseKindInfer() {
        XCTAssertEqual(ReleaseKind.infer(from: "Show.Name.2024.S01E05.1080p.WEB"), .series)
        XCTAssertEqual(ReleaseKind.infer(from: "Movie.Name.2024.2160p.UHD.BluRay.x265"), .other)
        XCTAssertEqual(ReleaseKind.infer(from: "Some.Anime.S01E01.1080p"), .series)
    }

    func testDownloderUpLimitLookup() {
        let d = DownloaderConfig(type: .qbittorrent, url: "u", username: "", password: "",
                                 savePath: nil, category: nil, skipChecking: true,
                                 defaultUpLimit: 100, siteUpLimits: ["cmct": 200], pushPolicy: .always)
        XCTAssertEqual(d.upLimitFor(originSiteID: "cmct"), 200)
        XCTAssertEqual(d.upLimitFor(originSiteID: "ttg"), 100)
    }
}
