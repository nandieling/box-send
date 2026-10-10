import XCTest
@testable import BoxSendKit

/// Windows 移植相关改动的回归：无头服务的 JSON 契约、配置编辑规则、
/// 平台接缝（宿主注入解压 / 纯 Swift AES / IPv4 解析 / HTTP 服务往返）。
final class WindowsBridgeTests: XCTestCase {

    private func makeService() throws -> (AppService, String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boxsend-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let svc = try AppService(configPath: dir.appendingPathComponent("boxsend.json").path,
                                 dataDir: dir.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (svc, dir.path)
    }

    private func json(_ v: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: v)
    }

    // MARK: 契约

    func testVersionAndSnapshotShape() throws {
        let (svc, dir) = try makeService()
        let v = try svc.invoke("version")
        XCTAssertEqual(v["platform"] as? String, Platform.osName)
        XCTAssertEqual(v["version"] as? String, BoxSendVersion.version)
        XCTAssertEqual(v["configPath"] as? String, dir + "/boxsend.json")
        XCTAssertFalse((v["themes"] as? [[String: Any]])!.isEmpty, "主题表要随版本接口给出")

        let s = svc.snapshot()
        for key in ["config", "cookies", "sites", "groups", "run", "busy", "messages", "logs"] {
            XCTAssertNotNil(s[key], "快照缺少 \(key)")
        }
        let sites = s["sites"] as! [[String: Any]]
        XCTAssertFalse(sites.isEmpty)
        XCTAssertNotNil(sites.first?["group"])
        XCTAssertNotNil(sites.first?["check"])
        // 首次运行要把配置落到磁盘，界面下次能读到
        XCTAssertNotNil(AppConfig.load(path: dir + "/boxsend.json"))
    }

    func testInvokeJSONEnvelope() throws {
        let (svc, _) = try makeService()
        let ok = try JSONSerialization.jsonObject(
            with: Data(svc.invokeJSON(#"{"method":"snapshot","params":{}}"#).utf8)) as! [String: Any]
        XCTAssertTrue(ok["ok"] as! Bool)
        XCTAssertNotNil(ok["result"])

        let bad = try JSONSerialization.jsonObject(
            with: Data(svc.invokeJSON(#"{"method":"nope"}"#).utf8)) as! [String: Any]
        XCTAssertEqual(bad["ok"] as? Bool, false)
        XCTAssertTrue((bad["error"] as! String).contains("未知方法"))

        let garbage = try JSONSerialization.jsonObject(
            with: Data(svc.invokeJSON("not json").utf8)) as! [String: Any]
        XCTAssertEqual(garbage["ok"] as? Bool, false)
    }

    // MARK: 分组与站点排序

    func testGroupAddRenameRemove() throws {
        let (svc, _) = try makeService()
        _ = try svc.invoke("groups.add", ["name": "转种源", "upLimitMB": 8])
        var groups = svc.snapshot()["groups"] as! [[String: Any]]
        XCTAssertEqual(groups.count, 1, "同名分组允许共存（与 mac 版一致）")

        // 重命名撞名时自动加数字后缀
        _ = try svc.invoke("groups.add", ["name": "转种源", "upLimitMB": 0])
        _ = try svc.invoke("groups.rename", ["index": 0, "name": "转种源"])
        groups = svc.snapshot()["groups"] as! [[String: Any]]
        XCTAssertEqual(groups[0]["name"] as? String, "转种源2", "重命名重名要自动加数字后缀")

        _ = try svc.invoke("sites.add", ["ids": ["hdsky", "chdbits"], "group": 0])
        groups = (try svc.invoke("groups.remove", ["index": 0]))["groups"] as! [[String: Any]]
        XCTAssertEqual(groups.count, 1)
        // 站点退回未分组列表后仍能在界面上被重新添加
        let sites = (try svc.invoke("sites.add", ["ids": ["hdsky"], "group": -1]))["sites"] as! [[String: Any]]
        XCTAssertTrue(sites.first { ($0["id"] as? String) == "hdsky" }?["managed"] as? Bool == true)
    }

    func testAddSitesInheritsGroupLimit() throws {
        let (svc, _) = try makeService()
        _ = try svc.invoke("groups.add", ["name": "限速组", "upLimitMB": 3])
        let out = try svc.invoke("sites.add", ["ids": ["hdsky"], "group": 0])
        let site = (out["sites"] as! [[String: Any]]).first { ($0["id"] as? String) == "hdsky" }!
        XCTAssertEqual(site["upLimitMB"] as? Int, 3, "新增站点沿用所在分组的默认限速")
        XCTAssertEqual(site["enabled"] as? Bool, true, "添加即启用")

        _ = try svc.invoke("sites.setUpLimit", ["id": "hdsky", "upLimitMB": 0])
        let again = (svc.snapshot()["sites"] as! [[String: Any]]).first { ($0["id"] as? String) == "hdsky" }!
        XCTAssertEqual(again["upLimitMB"] as? Int, 0, "单独改限速要覆盖组默认值")
    }

    func testSortAndMoveWithinBlock() throws {
        let (svc, _) = try makeService()
        _ = try svc.invoke("groups.add", ["name": "g", "upLimitMB": 0])
        _ = try svc.invoke("sites.add", ["ids": ["hdsky", "chdbits", "cmct"], "group": 0])
        let out = try svc.invoke("groups.sortSites",
                                 ["group": 0, "order": ["cmct": 1, "hdsky": 2, "chdbits": 3]])
        var sites = (out["groups"] as! [[String: Any]])[0]["sites"] as! [String]
        XCTAssertEqual(sites, ["cmct", "hdsky", "chdbits"])

        _ = try svc.invoke("sites.move", ["id": "cmct", "delta": 1])
        sites = (svc.snapshot()["groups"] as! [[String: Any]])[0]["sites"] as! [String]
        XCTAssertEqual(sites, ["hdsky", "cmct", "chdbits"])
    }

    func testTargetsSetEnablesSite() throws {
        let (svc, _) = try makeService()
        _ = try svc.invoke("targets.set", ["ids": ["hdsky", "chdbits"]])
        let cfg = svc.snapshot()["config"] as! [String: Any]
        XCTAssertEqual(cfg["targetSites"] as? [String], ["hdsky", "chdbits"])
        let sites = svc.snapshot()["sites"] as! [[String: Any]]
        XCTAssertTrue(sites.filter { ($0["id"] as? String) == "hdsky" }.first?["enabled"] as? Bool == true)
    }

    // MARK: 配置

    func testConfigPatchKeepsUnrelatedFields() throws {
        let (svc, _) = try makeService()
        let before = svc.snapshot()["config"] as! [String: Any]
        _ = try svc.invoke("config.patch", ["patch": [
            "downloader": ["type": "transmission", "url": "http://127.0.0.1:9091",
                           "username": "u", "password": "p", "skipChecking": false,
                           "defaultUpLimit": 10485760, "siteUpLimits": [:] as [String: Int],
                           "pushPolicy": "onSuccess", "sizeGuardMode": "warn", "sizeGuardMarginGB": 20],
            "cookieCloud": ["host": "http://cc.local", "key": "K", "password": "P", "pollMinutes": 15],
        ]])
        let after = svc.snapshot()["config"] as! [String: Any]
        XCTAssertEqual(((after["downloader"] as! [String: Any])["type"]) as? String, "transmission")
        XCTAssertEqual(((after["cookieCloud"] as! [String: Any])["host"]) as? String, "http://cc.local")
        let names = { (cfg: [String: Any]) in
            ((cfg["sourceSites"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        }
        XCTAssertEqual(names(after), names(before), "打补丁不能丢站点表")
        XCTAssertEqual(after["userAgent"] as? String, before["userAgent"] as? String)
        // 落盘后重启能读回同样的值
        let reread = AppConfig.load(path: (svc.snapshot()["configPath"] as! String))
        XCTAssertEqual(reread?.cookieCloud?.pollMinutes, 15)
    }

    // MARK: 平台接缝

    func testZipImportUsesInjectedUnzip() throws {
        let (svc, _) = try makeService()
        defer { Platform.hooks = Platform.Hooks() }
        let manifest = #"{"encryption":false,"files":{"cookies":{"name":"cookies.json"}}}"#
        let cookies = #"{"cookies":[{"host":"hdsky.me","name":"uid","value":"1"}]}"#
        Platform.hooks.unzip = { _ in
            ["manifest.json": Data(manifest.utf8), "cookies.json": Data(cookies.utf8)]
        }
        let out = try svc.invoke("cookies.importZip",
                                 ["path": "/tmp/PTD_backup_test.zip", "password": ""])
        XCTAssertEqual(out["imported"] as? Int, 1)
        XCTAssertEqual((svc.snapshot()["cookies"] as! [String: Any])["total"] as? Int, 1)
    }

    func testZipImportReportsMissingManifest() throws {
        let (svc, _) = try makeService()
        defer { Platform.hooks = Platform.Hooks() }
        Platform.hooks.unzip = { _ in ["other.json": Data("{}".utf8)] }
        let out = try svc.invoke("cookies.importZip", ["path": "/tmp/a.zip"])
        XCTAssertEqual(out["imported"] as? Int, 0)
        XCTAssertTrue((out["message"] as! String).contains("manifest.json"),
                      "解压结果里没有 manifest 时要把原因带回界面")
    }

    func testZipScanWaitsForEnabledThenImportsOnce() throws {
        let (svc, dir) = try makeService()
        defer { Platform.hooks = Platform.Hooks() }
        let manifest = #"{"encryption":false,"files":{"cookies":{"name":"cookies.json"}}}"#
        let cookies = #"{"cookies":[{"host":"hdsky.me","name":"uid","value":"1"}]}"#
        Platform.hooks.unzip = { _ in
            ["manifest.json": Data(manifest.utf8), "cookies.json": Data(cookies.utf8)]
        }
        // 备份目录单独一个，模拟「PT-depiler 往下载目录里丢备份」
        let backup = dir + "/downloads"
        try FileManager.default.createDirectory(atPath: backup, withIntermediateDirectories: true)
        try Data("zip".utf8).write(to: URL(fileURLWithPath: backup + "/PTD_backup_1.zip"))

        // 没启用监控时不让扫，界面直接把这句显示出来
        XCTAssertThrowsError(try svc.invoke("zip.scan")) { err in
            XCTAssertTrue("\(err)".contains("启用"), "未启用时要说明去哪儿启用：\(err)")
        }

        _ = try svc.invoke("config.patch", ["patch": ["zipWatch": ["enabled": true, "dir": backup]]])
        XCTAssertEqual(try svc.invoke("zip.scan")["started"] as? Bool, true)
        XCTAssertTrue(waitZipMessage(svc)?.hasPrefix("扫描完成：已导入 PTD_backup_1.zip") == true,
                      "导入结果要回到界面消息里（未启用站点的 cookie 会被顺带清掉）")

        // 第二遍：同名备份已标记过不再重复导入；这次只提交 enabled，目录要还在
        _ = try svc.invoke("config.patch", ["patch": ["zipWatch": ["enabled": true]]])
        XCTAssertEqual(try svc.invoke("zip.scan")["started"] as? Bool, true)
        XCTAssertEqual(waitZipMessage(svc), "扫描完成：无新备份")
    }

    /// zip.scan 是后台跑的，界面上靠轮询取结果；测试里同样轮询，最多等 5 秒
    private func waitZipMessage(_ svc: AppService, _ expect: String? = nil) -> String? {
        for _ in 0..<100 {
            let msgs = (svc.snapshot()["messages"] as? [String: Any])?["zip"] as? String ?? ""
            let hit = expect.map { msgs.contains($0) } ?? true
            if !msgs.isEmpty, msgs != "扫描备份目录…", hit { return msgs }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    func testSeccodeUsesInjectedOCRAndKeepsTransliteration() {
        defer { Platform.hooks = Platform.Hooks() }
        Platform.hooks.ocr = { _ in ["К6КK"] }          // 西里尔 К 混在拉丁 K 里
        XCTAssertEqual(SeccodeOCR.code(Data([1, 2, 3])), "k6kk")
        Platform.hooks.ocr = { _ in ["ab"] }             // 位数不对 = 当作没认出
        XCTAssertNil(SeccodeOCR.code(Data([1, 2, 3])))
    }

    func testShotImagePassthroughWithoutBackend() {
        defer { Platform.hooks = Platform.Hooks() }
        let big = Data(repeating: 7, count: ShotImage.keepUnderBytes + 10)
        XCTAssertNil(ShotImage.jpeg(Data(repeating: 7, count: 100)), "小图原样发出去，不重编码")
        Platform.hooks.jpegReencode = { data, _, _ in Data(repeating: 1, count: 10) }
        XCTAssertEqual(ShotImage.jpeg(big)?.count, 10)
        Platform.hooks.jpegReencode = { _, _, _ in nil }
        XCTAssertNil(ShotImage.jpeg(big), "没有可用后端时返回 nil，调用方用原图")
    }

    func testAES128MatchesFIPS197Vector() throws {
        // FIPS-197 附录 B：key 000102...0f，明文 001122...ff -> 69c4e0d8...c55a
        let key = (0..<16).map { UInt8($0) }
        let plain = (0..<16).map { UInt8(0x00 + $0 * 0x11) }
        let cipher: [UInt8] = [0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30,
                               0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a]
        XCTAssertEqual(CryptoJSCompat._blockDec(cipher, key: key), plain)
    }

    func testAES128CBCRoundTripStripsPadding() throws {
        let key = (0..<16).map { UInt8($0 + 7) }
        let iv = [UInt8](repeating: 0, count: 16)
        let text = Data("{\"cookies\":[]}".utf8)
        let enc = try CryptoJSCompat.aes256CBCEncrypt(data: text, key: key, iv: iv)
        XCTAssertEqual(try CryptoJSCompat.aes128CBCDecrypt(data: enc, key: key, iv: iv), text)
    }

    func testIPv4ParseAndHTTPRoundTrip() throws {
        XCTAssertEqual(HTTPServer.parseIPv4("127.0.0.1"), UInt32(0x7F000001).bigEndian)
        XCTAssertNil(HTTPServer.parseIPv4("1.2.3"))
        XCTAssertNil(HTTPServer.parseIPv4("256.0.0.1"))
        XCTAssertNil(HTTPServer.parseIPv4("1.2.3.4.5"))

        let server = HTTPServer()
        try server.start(host: "127.0.0.1", port: 0) { req in
            .json(["echo": req.path, "q": req.query["n"] ?? ""])
        }
        XCTAssertGreaterThan(server.assignedPort, 0)
        Thread.detachNewThread { server.run() }

        let url = URL(string: "http://127.0.0.1:\(server.assignedPort)/api/x?n=42")!
        let sem = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: url) { data, _, _ in
            body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            sem.signal()
        }.resume()
        XCTAssertEqual(sem.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(body.contains("\"echo\":\"\\/api\\/x\"") || body.contains("\"echo\":\"/api/x\""))
        XCTAssertTrue(body.contains("42"))
    }

    func testEventsStreamAdvances() throws {
        let (svc, _) = try makeService()
        _ = try svc.invoke("logs.clear")
        let first = svc.events(since: 0)
        _ = try svc.invoke("groups.add", ["name": "事件组", "upLimitMB": 0])
        let since = first.isEmpty ? 0 : (first.last!["seq"] as! Int)
        // 分组操作本身不产事件，同步/检测/转种才产；这里用下载器测试失败来产事件
        _ = try? svc.invoke("downloader.test")
        let later = svc.events(since: since)
        XCTAssertFalse(later.isEmpty, "动作要能在事件流里看到")
        XCTAssertTrue(svc.events(since: 10_000_000).isEmpty, "游标之后的旧事件不再重发")
    }

    // MARK: 主题

    func testThemeCatalogMatchesConfigDefault() {
        XCTAssertEqual(ThemeCatalog.all.count, 6)
        XCTAssertEqual(Set(ThemeCatalog.all.map { $0.id }).count, 6)
        XCTAssertEqual(AppearanceConfig().themeID, ThemeCatalog.default.id)
        for t in ThemeCatalog.all {
            XCTAssertEqual(t.colorsHex.count, 3, "\(t.id) 需要三段渐变")
            for hex in t.colorsHex + [t.accentHex] {
                XCTAssertTrue(hex.hasPrefix("#") && hex.count == 7, "\(t.id) 色值格式 \(hex)")
            }
        }
    }
}
