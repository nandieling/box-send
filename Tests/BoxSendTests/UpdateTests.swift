import XCTest
@testable import BoxSendKit

/// 软件更新：GitHub Releases 的解析、版本比较，以及版本号只有一个来源（Version.swift）
final class UpdateTests: XCTestCase {
    private let releaseJSON = """
    {"tag_name":"1.1","name":"BoxSend 1.1",
     "html_url":"https://github.com/nandieling/box-send/releases/tag/1.1",
     "assets":[{"name":"BoxSend.dmg","browser_download_url":"https://github.com/nandieling/box-send/releases/download/1.1/BoxSend.dmg"}]}
    """

    func testParseLatestRelease() throws {
        let rel = try XCTUnwrap(SoftwareUpdate.parse(Data(releaseJSON.utf8)))
        XCTAssertEqual(rel.version, "1.1")
        XCTAssertEqual(rel.title, "BoxSend 1.1")
        XCTAssertEqual(rel.url, "https://github.com/nandieling/box-send/releases/tag/1.1")
        XCTAssertEqual(rel.downloadURL,
                       "https://github.com/nandieling/box-send/releases/download/1.1/BoxSend.dmg")
    }

    func testParseToleratesTagsAndMissingAssets() throws {
        let tagged = SoftwareUpdate.parse(
            Data(#"{"tag_name":"v1.2.0","html_url":"https://x/rel"}"#.data(using: .utf8)!))
        XCTAssertEqual(tagged?.version, "1.2.0")
        XCTAssertEqual(tagged?.downloadURL, nil)
        XCTAssertEqual(tagged?.url, "https://x/rel")
        // zip 资产也算安装包
        let zipped = SoftwareUpdate.parse(Data(
            """
            {"tag_name":"1.2","assets":[{"name":"BoxSend-mac.zip","browser_download_url":"https://x/a.zip"},
                                        {"name":"notes.txt","browser_download_url":"https://x/n.txt"}]}
            """.data(using: .utf8)!))
        XCTAssertEqual(zipped?.downloadURL, "https://x/a.zip")
        XCTAssertNil(SoftwareUpdate.parse(Data("{}".utf8)))
        XCTAssertNil(SoftwareUpdate.parse(Data("<html>rate limited</html>".utf8)))
    }

    func testVersionCompare() {
        XCTAssertTrue(SoftwareUpdate.isNewer("1.1", than: "1.0"))
        XCTAssertTrue(SoftwareUpdate.isNewer("1.10", than: "1.9"))          // 按数字段比，不按字符串
        XCTAssertTrue(SoftwareUpdate.isNewer("v2.0", than: "1.9.9"))
        XCTAssertTrue(SoftwareUpdate.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(SoftwareUpdate.isNewer("1.0", than: "1.0"))
        XCTAssertFalse(SoftwareUpdate.isNewer("1.0.0", than: "1.0"))
        XCTAssertFalse(SoftwareUpdate.isNewer("1.0", than: "1.1"))
        XCTAssertFalse(SoftwareUpdate.isNewer("", than: "1.0"))
    }

    /// 更新提示要对得上打包时写进 Info.plist 的那个版本号
    func testCurrentVersion() {
        XCTAssertEqual(BoxSendVersion.version, "1.1")
        XCTAssertFalse(SoftwareUpdate.isNewer("1.0", than: BoxSendVersion.version), "1.0 不该提示更新")
        XCTAssertTrue(SoftwareUpdate.isNewer("1.2", than: BoxSendVersion.version))
        XCTAssertEqual(SoftwareUpdate.releasesURL, "https://github.com/nandieling/box-send/releases")
        XCTAssertEqual(SoftwareUpdate.latestAPIURL,
                       "https://api.github.com/repos/nandieling/box-send/releases/latest")
    }

    /// 实站验证（BOXSEND_LIVE=1）：真接口的返回要能解析出版本号
    func testLiveLatestReleaseParses() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BOXSEND_LIVE"] == nil, "实站验证需 BOXSEND_LIVE=1")
        let client = HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest")
        switch SoftwareUpdate.latest(client: client) {
        case .found(let rel):
            print("LIVE-UPDATE: 最新 \(rel.version) | \(rel.url) | \(rel.downloadURL ?? "-")")
            XCTAssertFalse(rel.version.isEmpty)
        case .failed(let err):
            XCTFail("实站检查更新失败：\(err)")
        }
    }

    func testOldConfigWithoutUpdateFieldStillLoads() throws {
        // 1.0 的配置文件没有 autoUpdateCheck 字段：缺省按"自动检查"处理，且不能影响其它字段解码
        let cfg = AppConfig.template()
        var json = try JSONEncoder().encode(cfg)
        guard let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              var dict = obj as? [String: Any] else { return XCTFail("配置不是 JSON 对象") }
        dict.removeValue(forKey: "autoUpdateCheck")
        json = try JSONSerialization.data(withJSONObject: dict)
        let back = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertTrue(back.autoUpdateCheck)
        XCTAssertEqual(back.userAgent, cfg.userAgent)
    }
}
