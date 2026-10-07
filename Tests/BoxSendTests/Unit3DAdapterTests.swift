import XCTest
@testable import BoxSendKit

/// 馒头（Unit3D 型 API 站点）适配器：真实网关为 POST + x-api-key + 字符串成功码
final class Unit3DAdapterTests: XCTestCase {
    private static let detailName = "Yuru Yuri S03 2011 1080p BluRay Remux AVC LPCM 2.0 2Audios-LuckAni"
    private static let detailJSON =
        #"{"code":"0","message":"SUCCESS","data":{"id":"1264571","name":"\#(Unit3DAdapterTests.detailName)","smallDescr":"摇曳百合 第三季 全12集 [内封中字]","descr":"","size":"87153469249","category":"453","labelsNew":["中字"],"douban":"https://movie.douban.com/subject/26339249/","imdb":"https://www.imdb.com/title/tt5420420/","bangumi":"https://bangumi.tv/subject/14588"}}"#

    private func site() -> SiteConfig {
        var raw = SiteConfig(id: "mteam", name: "馒头", url: "https://kp.m-team.cc/",
                             framework: .unit3D, enabled: true)
        raw.apiKey = "test-key"
        return SiteRegistry.effectiveSite(raw)
    }

    private func client(_ handler: @escaping (URLRequest) -> HTTPClient.Response) -> HTTPClient {
        let c = HTTPClient(cookies: CookieStore(), userAgent: "boxsend-test")
        c.performOverride = { req in handler(req) }
        return c
    }

    private func resp(_ body: String) -> HTTPClient.Response {
        HTTPClient.Response(status: 200, data: Data(body.utf8), headers: [:], finalURL: "https://api.m-team.cc/x")
    }

    /// 详情：multipart 表单（JSON 会被站方判「參數錯誤」）+ 结构化字段解析
    func testDetailUsesMultipartAndStructuredFields() throws {
        var path = ""
        var method = ""
        var key: String?
        var contentType = ""
        var body = Data()
        let adapter = Unit3DAdapter(site: site(), client: client { req in
            path = req.url!.path
            method = req.httpMethod ?? ""
            key = req.value(forHTTPHeaderField: "x-api-key")
            contentType = req.value(forHTTPHeaderField: "Content-Type") ?? ""
            body = req.httpBody ?? Data()
            return self.resp(Self.detailJSON)
        })
        let info = try adapter.fetchDetail(detailURL: "https://kp.m-team.cc/detail/1264571")
        XCTAssertEqual(path, "/api/torrent/detail")
        XCTAssertEqual(method, "POST")
        XCTAssertEqual(key, "test-key")
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data"), contentType)
        XCTAssertTrue(String(data: body, encoding: .utf8)!.contains("name=\"id\""))
        XCTAssertEqual(info.name, Self.detailName)
        XCTAssertEqual(info.imdb, "tt5420420")
        XCTAssertEqual(info.douban, "26339249")
        XCTAssertEqual(info.size, 87153469249)
        XCTAssertEqual(info.kind, .anime)          // category 453 = 站方动画分类
        // 副标题优先站方 smallDescr，站方标签只在没有 smallDescr 时兜底
        XCTAssertEqual(info.subtitle, "摇曳百合 第三季 全12集 [内封中字]")
        XCTAssertEqual(info.bangumi, "https://bangumi.tv/subject/14588")   // 转发到其它站时直接复用
    }

    /// 下载：先取一次性签名地址，再 GET
    func testDownloadUsesGenDlToken() throws {
        var seen: [String] = []
        let torrent = "d4:infod6:lengthi100e4:name1:aee"
        let adapter = Unit3DAdapter(site: site(), client: client { req in
            seen.append(req.url!.absoluteString)
            if req.url!.path == "/api/torrent/genDlToken" {
                return self.resp(#"{"code":"0","message":"SUCCESS","data":"https://api.m-team.cc/api/rss/dlv2?sign=abc&t=1"}"#)
            }
            return self.resp(torrent)
        })
        var info = ReleaseInfo(siteID: "mteam", detailURL: "https://kp.m-team.cc/detail/1264571",
                               name: Self.detailName, kind: .anime)
        info.torrentName = Self.detailName + ".torrent"
        let (data, filename) = try adapter.downloadTorrentFile(info)
        XCTAssertEqual(seen.first, "https://api.m-team.cc/api/torrent/genDlToken")
        XCTAssertEqual(seen.count, 2)
        XCTAssertTrue(seen[1].contains("sign=abc"), seen[1])
        XCTAssertEqual(String(data: data, encoding: .utf8), torrent)
        XCTAssertEqual(filename, Self.detailName + ".torrent")
    }

    /// 查重：搜索接口返回字符串 id + data.data 行
    func testSearchExistsReturnsDetailURL() throws {
        let body = #"{"code":"0","message":"SUCCESS","data":{"pageNumber":"1","total":"1","data":[{"id":"998877","name":"\#(Unit3DAdapterTests.detailName)","size":"1"}]}}"#
        var path = ""
        var sentBody = Data()
        let adapter = Unit3DAdapter(site: site(), client: client { req in
            path = req.url!.path
            sentBody = req.httpBody ?? Data()
            return self.resp(body)
        })
        let info = ReleaseInfo(siteID: "mteam", detailURL: "https://kp.m-team.cc/detail/1", name: Self.detailName)
        XCTAssertEqual(try adapter.searchExists(info), "https://kp.m-team.cc/detail/998877")
        XCTAssertEqual(path, "/api/torrent/search")
        XCTAssertTrue(String(data: sentBody, encoding: .utf8)!.contains("keyword"))
    }

    /// 站方不认的 Key：抛 apiKeyInvalid（而不是「HTTP 200 成功」）
    func testInvalidKeyThrows() {
        let adapter = Unit3DAdapter(site: site(), client: client { _ in
            self.resp(#"{"code":1,"message":"key無效","data":null}"#)
        })
        XCTAssertThrowsError(try adapter.fetchTorrentList()) { err in
            guard case BoxSendError.apiKeyInvalid = err else { return XCTFail("期望 apiKeyInvalid，实际 \(err)") }
        }
    }

    // MARK: - 发种（/api/torrent/createOredit）

    private static let bangumiRows =
        #"{"code":"0","message":"SUCCESS","data":[{"id":127573,"name":"ゆるゆり さん☆ハイ！","name_cn":"摇曳百合 3☆High!","date":"2015-10-05","type":2,"nsfw":false},{"id":14588,"name":"ゆるゆり","name_cn":"摇曳百合","date":"2011-07-04","type":2,"nsfw":false}]}"#

    /// 发种时的请求：路径、分类、必填字段与 Bangumi 条目
    private func captureUpload(info: ReleaseInfo, uploadBody: String =
                                #"{"code":"0","message":"SUCCESS","data":{"id":"1290001"}}"#)
        throws -> (path: String, body: String, outcome: UploadOutcome) {
        var path = ""
        var body = ""
        let adapter = Unit3DAdapter(site: site(), client: client { req in
            let p = req.url!.path
            path = p
            let data = req.httpBody ?? Data()
            if p.hasSuffix("bangumi/search") {
                XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("name=\"keyword\""), "关键词应为 multipart 字段")
                return self.resp(Self.bangumiRows)
            }
            body = String(data: data, encoding: .utf8) ?? ""
            return self.resp(uploadBody)
        })
        let outcome = try adapter.upload(info, torrentData: Data("d4:infod6:lengthi100e4:name1:aee".utf8),
                                        filename: "ignored.torrent")
        return (path, body, outcome)
    }

    private func animeRelease(name: String = "摇曳百合.第三季.Yuru.Yuri.S03.2015.1080p.BluRay.Remux.AVC.LPCM.2.0-LuckAni",
                              descr: String = #"<p>简介</p><img src="/a.png">"#) -> ReleaseInfo {
        ReleaseInfo(siteID: "luckpt", detailURL: "https://pt.luckpt.de/detail.php?id=56812",
                    name: name, descr: descr, kind: .anime, subtitle: "摇曳百合 第三季 [内封中字]",
                    sourceName: "幸运")
    }

    /// 动画发种：走 createOredit、分类按源介质分 405/453、自动补 Bangumi 与中字标签
    func testUploadAnimeFillsBangumiAndCategory() throws {
        let (path, body, outcome) = try captureUpload(info: animeRelease())
        XCTAssertEqual(path, "/api/torrent/createOredit")
        XCTAssertTrue(outcome.success && !outcome.alreadyExists)
        XCTAssertEqual(outcome.detailURL, "https://kp.m-team.cc/detail/1290001")
        XCTAssertTrue(body.contains("name=\"category\"\r\n\r\n453"), String(body.suffix(600)))   // BluRay 动画
        XCTAssertTrue(body.contains("name=\"name\"\r\n\r\n摇曳百合.第三季.Yuru.Yuri"))
        XCTAssertTrue(body.contains("name=\"descr\""))
        XCTAssertTrue(body.contains("name=\"bangumi\"\r\n\r\nhttps://bangumi.tv/subject/127573"), String(body.suffix(600)))
        XCTAssertTrue(body.contains("name=\"labelsNew\"\r\n\r\n中字"), String(body.suffix(600)))
        XCTAssertTrue(body.contains("name=\"scope\"\r\n\r\nNORMAL"))
        XCTAssertTrue(body.contains("filename=\"摇曳百合.第三季.Yuru.Yuri.S03.2015.1080p.BluRay.Remux.AVC.LPCM.2.0-LuckAni.torrent\""),
                      String(body.suffix(600)))
    }

    /// 在线动画（非原盘）应落在「动画」而不是「动画-BluRay」
    func testUploadWebDLAnimeUsesPlainAnimeCategory() throws {
        let (_, body, _) = try captureUpload(info: animeRelease(name: "Yuru.Yuri.S03.2015.1080p.WEB-DL.AAC-LuckAni"))
        XCTAssertTrue(body.contains("name=\"category\"\r\n\r\n405"), String(body.suffix(400)))
    }

    /// 站点提示同 hash 已存在：算成功但标记「已存在」，交给流水线推送已有种子
    func testUploadTreatsExistingTorrentAsAlreadyExists() throws {
        let (_, _, outcome) = try captureUpload(info: animeRelease(),
                                               uploadBody: #"{"code":"1","message":"種子已存在(1,264,571)"}"#)
        XCTAssertTrue(outcome.success)
        XCTAssertTrue(outcome.alreadyExists)
        XCTAssertTrue(outcome.message.contains("已存在"), outcome.message)
    }

    /// 检索不到条目时不能静默漏填：报错要说明按什么词查过
    func testUploadAnimeFailsLoudlyWhenBangumiNotFound() {
        let adapter = Unit3DAdapter(site: site(), client: client { req in
            if req.url!.path.hasSuffix("bangumi/search") { return self.resp(#"{"code":"0","message":"SUCCESS","data":[]}"#) }
            return self.resp("{}")
        })
        XCTAssertThrowsError(try adapter.upload(animeRelease(descr: ""),
                                               torrentData: Data("d".utf8), filename: "x.torrent")) { err in
            let text = String(describing: err)
            XCTAssertTrue(text.contains("Bangumi"), text)
            XCTAssertTrue(text.contains("摇曳百合"), text)
        }
    }

    /// 非动画分类不需要 Bangumi，也不该多跑一次检索
    func testUploadMovieSkipsBangumiSearch() throws {
        var searched = false
        let adapter = Unit3DAdapter(site: site(), client: client { req in
            if req.url!.path.hasSuffix("bangumi/search") { searched = true }
            return self.resp(#"{"code":"0","message":"SUCCESS","data":{"id":"2"}}"#)
        })
        let info = ReleaseInfo(siteID: "luckpt", detailURL: "https://x/t",
                              name: "Some.Movie.2024.1080p.BluRay.x264-GRP", kind: .movie)
        _ = try adapter.upload(info, torrentData: Data("d".utf8), filename: "x.torrent")
        XCTAssertFalse(searched)
    }

    /// 预览（CLI info --preview mteam）：字段与实际提交一致，动画含 Bangumi
    func testPreviewListsUploadFields() throws {
        let adapter = Unit3DAdapter(site: site(), client: client { _ in self.resp(Self.bangumiRows) })
        let fields = try adapter.previewUploadFields(animeRelease())
        let names = fields.map { $0.0 }
        for want in ["file", "category", "name", "descr", "scope", "bangumi"] {
            XCTAssertTrue(names.contains(want), "\(names)")
        }
    }

    /// 站方频控要重试一次，不能直接判失败
    func testUploadRetriesOnceOnRateLimit() throws {
        var calls = 0
        let adapter = Unit3DAdapter(site: site(), client: client { req in
            let p = req.url!.path
            if p.hasSuffix("bangumi/search") { return self.resp(Self.bangumiRows) }
            calls += 1
            return self.resp(calls == 1 ? #"{"code":4,"message":"請求過於頻繁"}"#
                                        : #"{"code":"0","message":"SUCCESS","data":{"id":"7"}}"#)
        })
        let outcome = try adapter.upload(animeRelease(), torrentData: Data("d".utf8), filename: "x.torrent")
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(outcome.success)
    }
}
