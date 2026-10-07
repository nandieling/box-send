import XCTest
@testable import BoxSendKit

/// TTG（totheglory.im）：详情页里 .torrent 直链是 /dl/<id>/<随机号>，整页不出现 download.php；
/// 站点把「名称 [副标题]」连写在 h1/title 里。
final class TTGDetailTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func adapter() -> NexusPHPAdapter {
        let site = SiteConfig(id: "ttg", name: "TTG", url: "https://totheglory.im/",
                              framework: .nexusPHP, enabled: true)
        return NexusPHPAdapter(site: SiteRegistry.effectiveSite(site),
                               client: HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest"))
    }

    func testParseTorrentLinkAndTitle() throws {
        let info = try adapter().parseDetail(html: try fixture("ttg-detail-836735.html"),
                                            detailURL: "https://totheglory.im/details.php?id=836735")
        XCTAssertEqual(info.name, "Food Inc 2009 1080p BluRay REMUX VC-1 DTS-HD MA 5 1-Ursuya@LuckDocu",
                       "标题取种子名，方括号里那串是副标题；实际：\(info.name)")
        XCTAssertTrue(info.subtitle.contains("毒食难肥"), "方括号内容应作为副标题：\(info.subtitle)")
        XCTAssertEqual(info.torrentURL, "https://totheglory.im/dl/836735/8735",
                       "应取「下载种子文件」那条（锚文本以 .torrent 结尾），不是 zip 附件或种子链接")
        XCTAssertTrue(info.torrentName.hasSuffix(".torrent"), "锚文本就是文件名：\(info.torrentName)")
    }

    /// 老 NexusPHP 失败页（h1 + p）要把站点原文报出来，而不是「未识别的返回」
    func testUploadErrorFromLegacyErrorPage() throws {
        let body = """
        <html><head><title>TLFBits :: 上传失败！</title></head><body>
        <h1>上传失败！</h1>
        <p>请填写必填项目</p>
        </body></html>
        """
        XCTAssertEqual(NexusPHPAdapter.extractUploadError(body: body, status: 200), "请填写必填项目")
        XCTAssertTrue(NexusPHPAdapter.looksLikeLostPOST("请填写必填项目"),
                      "「必填项目缺失」要能触发重投（多为请求体未送达）")
    }
}

/// 站点强制 https（吐鲁番 http 会 301 到 https）：POST 跟跳转会丢请求体，必须用 https 原样重发
final class HTTPPostSchemeUpgradeTests: XCTestCase {
    func testPOSTReissuedOverHTTPS() throws {
        let client = HTTPClient(cookies: CookieStore(), userAgent: "BoxSendTest")
        let req = try client.multipartRequest(
            url: "http://pt.eastgame.org/takeupload.php",
            fields: [HTTPClient.MultipartField("name", "Food Inc")], files: [])
        let up = try XCTUnwrap(HTTPClient.httpsUpgradedRequest(req, finalURL: "https://pt.eastgame.org/takeupload.php"),
                              "带请求体的 POST 在 http→https 跳转后要用 https 重发，否则站点只收到空表单")
        XCTAssertEqual(up.url?.absoluteString, "https://pt.eastgame.org/takeupload.php")
        XCTAssertEqual(up.httpBody, req.httpBody, "重发要带上同一份请求体")
        // 跳到别的域（城市 HDCITY 的独立上传域名）不算 scheme 升级，交给各适配器自己处理
        XCTAssertNil(HTTPClient.httpsUpgradedRequest(req, finalURL: "https://hctres.leniter.org/upload"))
        // GET / 空请求体跟跳转都不丢东西，无需重发
        var get = URLRequest(url: URL(string: "http://pt.eastgame.org/upload.php")!)
        get.httpMethod = "GET"
        XCTAssertNil(HTTPClient.httpsUpgradedRequest(get, finalURL: "https://pt.eastgame.org/upload.php"))
        var empty = URLRequest(url: URL(string: "http://pt.eastgame.org/takeupload.php")!)
        empty.httpMethod = "POST"
        XCTAssertNil(HTTPClient.httpsUpgradedRequest(empty, finalURL: "https://pt.eastgame.org/takeupload.php"))
    }

    /// 老配置里遗留的 http 地址：内置表已改 https 的同域名站点自动升级
    func testStoredHTTPSiteURLUpgradedFromBuiltInTable() {
        let stored = SiteConfig(id: "tlf", name: "吐鲁番", url: "http://pt.eastgame.org/",
                                framework: .nexusPHP, enabled: true)
        XCTAssertEqual(SiteRegistry.effectiveSite(stored).url, "https://pt.eastgame.org/")
    }
}
