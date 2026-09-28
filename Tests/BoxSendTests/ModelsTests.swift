import XCTest
@testable import BoxSendKit

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

    func testQualityTokensMedium() {
        XCTAssertEqual(QualityTokens.medium(from: "Movie.2024.1080p.BluRay.REMUX.AVC.DTS-HD.MA.5.1", kind: .other), "remux")
        XCTAssertEqual(QualityTokens.medium(from: "Movie.2024.2160p.UHD.BluRay.x265.DDP5.1", kind: .other), "uhdbd")
        XCTAssertEqual(QualityTokens.medium(from: "Movie.2024.2160p.WEB-DL.x265.DDP5.1", kind: .other), "webdl")
        XCTAssertEqual(QualityTokens.medium(from: "Movie.2024.1080p.BluRay.x264.DTS", kind: .other), "bluray")
        XCTAssertEqual(QualityTokens.medium(from: "Movie.2024.1080p.x265.AAC", kind: .other), "encode")
        XCTAssertEqual(QualityTokens.medium(from: "Movie.2019.1080i.HDTV.x264", kind: .other), "hdtv")
        XCTAssertEqual(QualityTokens.medium(from: "Artist.Album.2020.FLAC.24bit", kind: .music), "track")
        XCTAssertEqual(QualityTokens.medium(from: "Movie.8K.4320p.BluRay", kind: .other), "uhdbd8k")
    }

    func testQualityTokensCatProfile() {
        XCTAssertEqual(QualityTokens.catProfile(from: "Movie.2024.1080p.BluRay.REMUX", kind: .other), "remux")
        XCTAssertEqual(QualityTokens.catProfile(from: "Movie.2024.2160p.BluRay.x265", kind: .other), "uhd-bd")
        XCTAssertEqual(QualityTokens.catProfile(from: "Movie.2024.2160p.WEB-DL.x265", kind: .other), "2160p")
        XCTAssertEqual(QualityTokens.catProfile(from: "Movie.2024.1080p.x265", kind: .other), "1080p")
        XCTAssertEqual(QualityTokens.catProfile(from: "Show.S01E01.1080i.WEB", kind: .series), "1080i")
        XCTAssertEqual(QualityTokens.catProfile(from: "Artist.Album.2020.FLAC", kind: .music), nil)
    }

    func testQualityTokensAudioCodec() {
        XCTAssertEqual(QualityTokens.audio(from: "Movie.2019.1080p.BluRay.REMUX.AVC.DTS-HD.MA.5.1"), "dtsma")
        XCTAssertEqual(QualityTokens.audio(from: "Movie.2024.2160p.WEB-DL.DDP5.1.Atmos.x265"), "eac3 atmos")
        XCTAssertEqual(QualityTokens.audio(from: "Artist.Album.2020.FLAC.24bit"), "flac")
        XCTAssertEqual(QualityTokens.codec(from: "Movie.2019.1080p.BluRay.REMUX.AVC"), "avc")
        XCTAssertEqual(QualityTokens.codec(from: "Movie.2024.2160p.x265"), "hevc")
        XCTAssertEqual(QualityTokens.standard(from: "Movie.2024.2160p.WEB-DL"), "2160p")
        XCTAssertEqual(QualityTokens.standard(from: "Movie.2019.1080p.BluRay"), "1080p")
    }

    func testSiteOverrideNewFieldsDecode() throws {
        let jsonStr = "{\"uploadActionPath\":\"takeupload.php\",\"titleField\":\"name\",\"imdbField\":\"url\",\"categoryField\":\"type\",\"fileField\":\"torrentfile\",\"titleMode\":\"torrentNameDotted\",\"categoryMap\":{\"movie\":401,\"movie/uhd-bd\":499},\"qualitySelects\":{\"medium_sel\":\"medium\"},\"qualityValueMaps\":{\"medium\":{\"remux\":3,\"uhdbd\":19}}}"
        let json = Data(jsonStr.utf8)
        let ov = try JSONDecoder().decode(SiteOverride.self, from: json)
        XCTAssertEqual(ov.uploadActionPath, "takeupload.php")
        XCTAssertEqual(ov.fileField, "torrentfile")
        XCTAssertEqual(ov.categoryMap?["movie/uhd-bd"], 499)
        XCTAssertEqual(ov.qualityValueMaps?["medium"]?["uhdbd"], 19)
    }
}
