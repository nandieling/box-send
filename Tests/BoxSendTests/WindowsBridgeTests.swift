import XCTest
#if canImport(FoundationNetworking)
// Linux / Windows 上 URLSession、URLRequest 这些在 FoundationNetworking 里，Foundation 不带
import FoundationNetworking
#endif
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

    /// 模板会预置一个「默认分组」，分组用例要从空分组开始
    private func clearGroups(_ svc: AppService) throws {
        while !((svc.snapshot()["groups"] as! [[String: Any]]).isEmpty) {
            _ = try svc.invoke("groups.remove", ["index": 0])
        }
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

    func testSiteCandidatesOrderAndPatch() throws {
        let (svc, _) = try makeService()
        let rows = try svc.invoke("sites.candidates")["sites"] as! [[String: Any]]
        let managed = Set((svc.snapshot()["sites"] as! [[String: Any]])
            .filter { ($0["managed"] as? Bool) == true }.map { $0["id"] as! String })
        XCTAssertFalse(rows.isEmpty, "模板之外应该还有很多内置站待添加")
        XCTAssertTrue(rows.allSatisfy { !managed.contains($0["id"] as! String) }, "已纳管的站不该出现在待添加列表")

        // 手动排序（unmanagedSiteOrder）里排过的，弹窗要按那份顺序放前面
        let ids = rows.map { $0["id"] as! String }
        let pick = Array(ids.suffix(2))
        _ = try svc.invoke("config.patch", ["patch": ["unmanagedSiteOrder": Array(pick.reversed())]])
        let again = (try svc.invoke("sites.candidates")["sites"] as! [[String: Any]])
            .map { $0["id"] as! String }
        XCTAssertEqual(again.prefix(2).map { $0 }, Array(pick.reversed()), "手动排序要顶到最前面")
    }

    /// 辅种弹窗的候选不受转种分组影响：已纳管的站照样能辅种，加过之后才从弹窗消失
    func testAssistCandidatesIgnoreReseedGroups() throws {
        let (svc, _) = try makeService()
        let id = ((try svc.invoke("sites.candidates")["sites"] as! [[String: Any]])[0])["id"] as! String
        _ = try svc.invoke("sites.add", ["ids": [id], "group": -1])

        let plain = ((try svc.invoke("sites.candidates"))["sites"] as! [[String: Any]]).map { $0["id"] as! String }
        XCTAssertFalse(plain.contains(id), "转种弹窗里已纳管的站照旧不重复出现")
        let forAssist = ((try svc.invoke("sites.candidates", ["assist": true]))["sites"] as! [[String: Any]])
            .map { $0["id"] as! String }
        XCTAssertTrue(forAssist.contains(id), "辅种弹窗要能选到已在转种分组里的站")

        _ = try svc.invoke("assist.addSites", ["ids": [id]])
        let after = ((try svc.invoke("sites.candidates", ["assist": true]))["sites"] as! [[String: Any]])
            .map { $0["id"] as! String }
        XCTAssertFalse(after.contains(id), "已经加进辅种的站要从弹窗移除")
        let group = (try svc.invoke("sites.add", ["ids": ["__none__"], "group": -1]))["sites"] as! [[String: Any]]
        XCTAssertEqual(group.first(where: { ($0["id"] as? String) == id })?["managed"] as? Bool, true,
                       "辅种不改动转种纳管状态")
    }

    /// 辅种区块：站点入池但不进分组，也不重复出现在未分组区块（mac 与 Windows 共用这套判定）    /// 辅种区块：站点入池但不进分组，也不重复出现在未分组区块（mac 与 Windows 共用这套判定）
    func testAssistSitesJoinPoolWithoutGroup() throws {
        let (svc, dir) = try makeService()
        try clearGroups(svc)
        let id = ((try svc.invoke("sites.candidates")["sites"] as! [[String: Any]])[0])["id"] as! String

        let rows = try svc.invoke("assist.addSites", ["ids": [id]])["sites"] as! [[String: Any]]
        guard let row = rows.first(where: { ($0["id"] as? String) == id }) else {
            return XCTFail("辅种站点应该在站点行里")
        }
        XCTAssertEqual(row["managed"] as? Bool, true, "辅种站点要进站点池，cookie 与限速才管得住")
        XCTAssertEqual(row["group"] as? Int, -1, "辅种站点不进任何转种分组")
        XCTAssertEqual(row["assist"] as? Bool, true, "行上要有辅种标记，界面才知道画进辅种区块")
        // 两处区块的划分口径也在核心：辅种站点只出现在辅种区块，未分组区块不再列它
        let saved = try XCTUnwrap(AppConfig.load(path: dir + "/boxsend.json"))
        XCTAssertEqual(saved.assistManagedSites.map(\.id), [id])
        XCTAssertTrue(saved.unassignedManagedSites.isEmpty, "辅种站点不该在未分组区块再列一遍")

        let cfg = (try svc.invoke("config.get"))["config"] as! [String: Any]
        let assistIDs = ((cfg["assist"] as? [String: Any])?["siteIDs"] as? [String]) ?? []
        XCTAssertEqual(assistIDs, [id], "辅种白名单要落到配置里")

        let after = try svc.invoke("assist.removeSite", ["id": id])["sites"] as! [[String: Any]]
        let gone = after.first(where: { ($0["id"] as? String) == id })!
        XCTAssertEqual(gone["managed"] as? Bool, false, "退出辅种又不在任何分组，应一并移出站点池")

        let cfg2 = (try svc.invoke("config.get"))["config"] as! [String: Any]
        XCTAssertEqual(((cfg2["assist"] as? [String: Any])?["siteIDs"] as? [String]) ?? [], [],
                       "退出辅种要清掉白名单")
    }

    /// 转种页那行「源站：自动（某站）」靠它，匹配规则必须留在核心（界面不自己抄一份）
    func testMatchURLIdentifiesSourceSite() throws {
        let (svc, _) = try makeService()
        let rows = try svc.invoke("sites.candidates")["sites"] as! [[String: Any]]
        guard let row = rows.first(where: { (($0["url"] as? String) ?? "").contains("//") })
        else { return XCTFail("候选站应该带网址") }
        let url = row["url"] as! String
        guard let host = URL(string: url)?.host else { return XCTFail("候选站网址该能解析：\(url)") }
        let hit = try svc.invoke("sites.matchURL", ["url": "https://\(host)/details.php?id=1"])
        XCTAssertEqual(hit["name"] as? String, row["name"] as? String)
        let miss = try svc.invoke("sites.matchURL", ["url": "https://example.invalid/x"])
        XCTAssertEqual(miss["name"] as? String, "", "认不出时给空名，界面回落「自动识别」")
    }

    func testAutoFreeFlagAndSSHTestContract() throws {
        let (svc, _) = try makeService()
        let sites = svc.snapshot()["sites"] as! [[String: Any]]
        XCTAssertTrue(sites.allSatisfy { ($0["supportsAutoFree"] as? Bool) != nil
                                     && ($0["autoFree"] as? Bool) != nil },
                      "快照要带上「站内有没有免费入口」，卡片才知道放不放开关")
        guard let cat = sites.first(where: { ($0["supportsAutoFree"] as? Bool) == true })
        else { return XCTFail("内置表里应该有支持自动免费的站点") }
        let id = cat["id"] as! String
        _ = try svc.invoke("sites.add", ["ids": [id], "group": -1])
        let out = try svc.invoke("sites.setAutoFree", ["id": id, "on": true])
        let row = (out["sites"] as! [[String: Any]]).first { ($0["id"] as? String) == id }!
        XCTAssertEqual(row["autoFree"] as? Bool, true, "开关要落进配置")
        let off = try svc.invoke("sites.setAutoFree", ["id": id, "on": false])
        let row2 = (off["sites"] as! [[String: Any]]).first { ($0["id"] as? String) == id }!
        XCTAssertEqual(row2["autoFree"] as? Bool, false)

        // 没配 SSH 服务器：测速要给一句人话，不能崩
        XCTAssertThrowsError(try svc.invoke("ssh.test"), "没填服务器时应该给一句报错")
        // 版本接口要给测速默认值，界面两端不必各抄一份
        let v = try svc.invoke("version")
        let d = v["sshDefaults"] as? [String: Any]
        XCTAssertNotNil(d?["keyPath"], "ssh 默认私钥路径要随版本接口给出")
        XCTAssertNotNil(d?["testMB"])
    }

    /// 手动填凭据弹窗的读写要对得上：API 站存站点 apiKey，cookie 站存 cookie 罐
    /// （以前只看 cookie 罐，馒头这类站「保存成功，再点开输入框是空的」）
    func testManualCredentialRoundTripBySiteKind() throws {
        let (svc, _) = try makeService()
        _ = try svc.invoke("sites.add", ["ids": ["mteam", "hdsky"], "group": -1])

        let saved = try svc.invoke("cookies.setRaw", ["id": "mteam", "raw": "  key-abc123 \n"])
        XCTAssertTrue((saved["message"] as? String)?.contains("API Key") == true,
                      "API 站的回话要说清存的是 API Key，不是 cookie")
        let read = try svc.invoke("cookies.getRaw", ["id": "mteam"])
        XCTAssertEqual(read["raw"] as? String, "key-abc123", "回读要拿到刚存进去的 Key")
        XCTAssertEqual(read["usesAPIKey"] as? Bool, true)
        let row = (svc.snapshot()["sites"] as! [[String: Any]]).first { ($0["id"] as? String) == "mteam" }!
        XCTAssertEqual(row["hasAPIKey"] as? Bool, true)
        XCTAssertEqual(row["enabled"] as? Bool, true, "填了 Key 要顺手启用该站")

        _ = try svc.invoke("cookies.setRaw", ["id": "mteam", "raw": "   "])
        XCTAssertEqual(try svc.invoke("cookies.getRaw", ["id": "mteam"])["raw"] as? String, "",
                       "清空按钮要真的清掉 Key")

        _ = try svc.invoke("cookies.setRaw", ["id": "hdsky", "raw": "uid=1; pass=hash"])
        let raw = try svc.invoke("cookies.getRaw", ["id": "hdsky"])["raw"] as? String ?? ""
        XCTAssertTrue(raw.contains("uid=1"), "cookie 站照旧读写 cookie 罐")
        XCTAssertEqual(try svc.invoke("cookies.getRaw", ["id": "hdsky"])["usesAPIKey"] as? Bool, false)
    }

    func testLegacyConfigWithoutGroupsGetsOne() throws {
        // 旧配置：站点都纳管了却一个分组都没有 → 读进来要补一个默认分组，别悬着「未分组」
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boxsend-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("boxsend.json")
        var cfg = AppConfig.template()
        cfg.groups = []
        try JSONEncoder().encode(cfg).write(to: file)

        let loaded = try XCTUnwrap(AppConfig.load(path: file.path))
        XCTAssertEqual(loaded.groups.count, 1)
        XCTAssertEqual(loaded.groups[0].name, "默认分组")
        XCTAssertTrue(loaded.unassignedManagedSites.isEmpty, "补组后不该还有未分组站点")
    }

    func testTemplateSeedsDefaultGroup() throws {
        // 首次安装：优先站要落在预置分组里，界面上不该冒出「未分组」
        let cfg = AppConfig.template()
        XCTAssertEqual(cfg.groups.count, 1)
        XCTAssertEqual(cfg.groups[0].name, "默认分组")
        XCTAssertEqual(Set(cfg.groups[0].sites),
                       Set(cfg.sourceSites.filter { $0.managed }.map(\.id)),
                   "模板里所有已纳管站点都要有归属分组")
        XCTAssertTrue(cfg.unassignedManagedSites.isEmpty, "不该出现未分组站点")
    }

    func testGroupAddRenameRemove() throws {
        let (svc, _) = try makeService()
        try clearGroups(svc)
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
        try clearGroups(svc)
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
        try clearGroups(svc)
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
