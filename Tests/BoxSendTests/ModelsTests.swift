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

    func testBencodeSingleFile() {
        // {"info": {"length": 123456}}
        var b = "d4:info"
        b += "d6:length"
        b += "i123456e"
        b += "ee"
        XCTAssertEqual(Bencode.totalLength(Data(b.utf8)), 123456)
    }

    func testBencodeMultiFile() {
        // {"info": {"lengths": [1000, 2000, 3000]}, "name": "file"}
        var b = "d4:info"
        b += "d7:lengths"
        b += "l"
        b += "i1000ei2000ei3000e"
        b += "ee4:name4:filee"
        let data = Data(b.utf8)
        XCTAssertEqual(Bencode.totalLength(data), 6000)
    }

    func testBencodeFilesArray() {
        // {"info": {"files": [{"length": 70000, "path": ["a"]}, {"length": 80000, "path": ["b"]}]}}
        var b = "d4:info"
        b += "d5:files"
        b += "l"
        b += "d6:lengthi70000e4:pathl1:aee"
        b += "d6:lengthi80000e4:pathl1:bee"
        b += "eee"
        XCTAssertEqual(Bencode.totalLength(Data(b.utf8)), 150000)
    }

    func testBencodeGarbage() {
        XCTAssertNil(Bencode.totalLength(Data("not bencode".utf8)))
        XCTAssertNil(Bencode.totalLength(Data()))
    }

    func testAppConfigDecodesWithoutGroups() throws {
        let jsonStr = #"{"dataDir":"d","sourceSites":[],"targetSites":[],"downloader":{"type":"qbittorrent","url":"u","username":"","password":"","savePath":null,"category":null,"skipChecking":true,"defaultUpLimit":0,"siteUpLimits":{},"pushPolicy":"always"},"userAgent":"ua"}"#
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(jsonStr.utf8))
        XCTAssertEqual(cfg.groups, [])
        XCTAssertNil(cfg.gistSync)
        XCTAssertNil(cfg.webToken)
    }

    func testGroupEffectiveUpLimit() {
        let dl = DownloaderConfig(type: .qbittorrent, url: "u", username: "", password: "",
                                  savePath: nil, category: nil, skipChecking: true,
                                  defaultUpLimit: 0,
                                  siteUpLimits: ["a": 5 * 1_048_576, "c": 5 * 1_048_576],
                                  pushPolicy: .always)
        let g1 = GroupConfig(name: "g1", sites: ["b", "c"], upLimitMB: 2)
        let g2 = GroupConfig(name: "g2", sites: ["d"], upLimitMB: 0)
        let cfg = AppConfig(dataDir: "d", sourceSites: [], targetSites: [], downloader: dl,
                            gistSync: nil, userAgent: "ua", webToken: nil, groups: [g1, g2])
        // 仅站点限速
        XCTAssertEqual(cfg.effectiveUpLimit(siteID: "a"), 5 * 1_048_576)
        // 仅分组上限
        XCTAssertEqual(cfg.effectiveUpLimit(siteID: "b"), 2 * 1_048_576)
        // 两者取小
        XCTAssertEqual(cfg.effectiveUpLimit(siteID: "c"), 2 * 1_048_576)
        // 站点与分组都未设 = 不限
        XCTAssertEqual(cfg.effectiveUpLimit(siteID: "d"), 0)
    }

}
