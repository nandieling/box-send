import XCTest
@testable import BoxSendKit

/// 测试用的小 bencode 编码器：造「同一批文件、站点重新打包」的种子
enum BEnc {
    /// 字符串：`<字节数>:<内容>`（键和值都用它）
    private static func str(_ s: String) -> Data {
        let b = Data(s.utf8)
        return Data("\(b.count):".utf8) + b
    }

    static func enc(_ o: Any) -> Data {
        if let d = o as? [String: Any] {
            var out = Data("d".utf8)
            for k in d.keys.sorted() { out += str(k) + enc(d[k]!) }
            out += Data("e".utf8); return out
        }
        if let l = o as? [Any] {
            var out = Data("l".utf8)
            for v in l { out += enc(v) }
            out += Data("e".utf8); return out
        }
        if let s = o as? String { return str(s) }
        if let i = o as? Int { return Data("i\(i)e".utf8) }
        if let i = o as? Int64 { return Data("i\(i)e".utf8) }
        fatalError("unsupported")
    }
}

/// .torrent 文件清单解析（辅种逐文件比对的地基）
final class BencodeFileListTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    /// 猫站那份《Food Inc》：一个文件的种子，但仍是「一个目录装一个 mkv」的打包
    /// （info.name 是目录名，不带 .mkv），清单里路径要带目录名
    func testSingleFileTorrent() throws {
        let data = try fixture("food.torrent")
        let files = try XCTUnwrap(Bencode.fileList(data))
        let root = "Food Inc 2009 1080p BluRay REMUX VC-1 DTS-HD MA 5.1-Ursuya@LuckDocu"
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(Bencode.infoName(data), root)
        XCTAssertEqual(files[0].path, root + "/Food Inc 2009 1080p BluRay REMUX VC-1 DTS-HD MA 5.1-Ursuya@LuckDocu.mkv")
        XCTAssertEqual(files[0].size, 18_060_925_144)
    }

    /// 多文件种子：每条路径都带上根目录名，总大小对得上
    func testMultiFileTorrent() throws {
        let data = try fixture("hdsky-550491.torrent")
        let files = try XCTUnwrap(Bencode.fileList(data))
        XCTAssertEqual(files.count, 30)
        let root = try XCTUnwrap(Bencode.infoName(data))
        XCTAssertTrue(files[0].path.hasPrefix(root + "/"), "路径要带根目录: \(files[0].path)")
        XCTAssertEqual(files[0].path, root + "/凡人修仙传.The.Immortal.Ascension.S01E01.2025.2160p.WEB-DL.AAC.H265-Pure@HDSWEB.mkv")
        XCTAssertEqual(files.reduce(Int64(0)) { $0 + $1.size }, 35_636_503_068)
    }

    func testYemaSingleFile() throws {
        let files = try XCTUnwrap(Bencode.fileList(try fixture("yema_sample.torrent")))
        XCTAssertEqual(files.map(\.size), [27_575_942_540])
    }

    /// 合成用例：两级目录 + `.` 段 + 反斜杠
    func testSyntheticMultiLevelPaths() throws {
        let info: [String: Any] = [
            "name": "Show.S01",
            "piece length": 262144,
            "files": [
                ["length": 100, "path": ["CD1", "disc.bin"]],
                ["length": 200, "path": ["Subs", "zh.srt"]],
            ],
            "pieces": "0000",
        ]
        let data = BEnc.enc(["info": info, "announce": "https://t/announce"])
        let files = try XCTUnwrap(Bencode.fileList(data))
        XCTAssertEqual(files.map(\.path), ["Show.S01/CD1/disc.bin", "Show.S01/Subs/zh.srt"])
        XCTAssertEqual(files.map(\.size), [100, 200])
    }

    /// 解析不出（不是 bencode）时返回 nil，别让调用方以为「清单为空」
    func testGarbageReturnsNil() {
        XCTAssertNil(Bencode.fileList(Data("<html>nope</html>".utf8)))
    }
}

/// 站点那条和本地这条是不是同一段文件
final class AssistMatcherTests: XCTestCase {

    private func torrent(name: String, files: [(String, Int64)], source: String) -> Data {
        let info: [String: Any]
        if files.count == 1 {
            info = ["name": name, "piece length": 262144, "length": files[0].1,
                    "pieces": "0000", "private": 1, "source": source]
        } else {
            info = ["name": name, "piece length": 262144, "pieces": "0000", "private": 1,
                    "source": source,
                    "files": files.map { ["length": Int($0.1), "path": [$0.0] as [Any]] as [String: Any] }]
        }
        return BEnc.enc(["info": info, "announce": "https://t/announce"])
    }

    private func fingerprint(_ data: Data) -> TorrentFingerprint {
        try! XCTUnwrap(AssistMatcher.fingerprint(ofTorrent: data))
    }

    /// 站点没改内容：info hash 一致，直接 A 级
    func testSameHashWins() {
        let data = torrent(name: "Movie.2020", files: [("Movie.2020.mkv", 1 << 20)], source: "SiteA")
        let hash = Bencode.infoHash(data)!
        let (level, why) = AssistMatcher.judge(localHashes: [hash], local: fingerprint(data),
                                               siteTorrentData: data, siteName: "Movie.2020")
        XCTAssertEqual(level, .sameHash)
        XCTAssertTrue(why.contains("info hash"))
    }

    /// 站点重打种子（改了 source 标记 → hash 变了），但逐文件清单全等：B 级可辅
    func testSameFilesDifferentPacking() {
        let local = torrent(name: "Movie.2020", files: [("Movie.2020.mkv", 1 << 20)], source: "LuckPT")
        let site = torrent(name: "Movie.2020", files: [("Movie.2020.mkv", 1 << 20)], source: "TargetSite")
        XCTAssertNotEqual(Bencode.infoHash(local), Bencode.infoHash(site))
        let (level, why) = AssistMatcher.judge(localHashes: [Bencode.infoHash(local)!],
                                               local: fingerprint(local), siteTorrentData: site,
                                               siteName: "Movie.2020")
        XCTAssertEqual(level, .sameFiles, why)
    }

    /// 根目录名不同（站点写成另一个名字）不算内容差异 —— 那是路径问题，推送环节单判
    func testRootFolderNameIgnored() {
        let local = torrent(name: "Show.S01",
                            files: [("ep01.mkv", 100), ("ep02.mkv", 200)], source: "LuckPT")
        let site = torrent(name: "Show.S01.Chs",
                           files: [("ep01.mkv", 100), ("ep02.mkv", 200)], source: "TargetSite")
        let (level, _) = AssistMatcher.judge(localHashes: ["deadbeef"], local: fingerprint(local),
                                             siteTorrentData: site, siteName: "Show.S01.Chs")
        XCTAssertEqual(level, .sameFiles)
    }

    /// 站点多塞一个字幕文件：清单不等，只能进人工确认，并说清差在哪
    func testExtraSubtitleFileDowngrades() {
        let local = torrent(name: "Movie.2020", files: [("a.mkv", 100), ("b.mkv", 200)], source: "LuckPT")
        let site = torrent(name: "Movie.2020", files: [("a.mkv", 100), ("b.mkv", 200), ("zh.srt", 4000)],
                           source: "TargetSite")
        let (level, why) = AssistMatcher.judge(localHashes: ["deadbeef"], local: fingerprint(local),
                                               siteTorrentData: site, siteName: "Movie.2020")
        guard case .nameOnly = level else { return XCTFail("应判成待人工，实际 \(level)") }
        XCTAssertTrue(why.contains("只有站点有 1 个"), why)
    }

    /// 同路径文件大小不同：明确不是同一段文件
    func testSizeMismatchOnSamePath() {
        let local = torrent(name: "Movie.2020", files: [("a.mkv", 100)], source: "LuckPT")
        let site = torrent(name: "Movie.2020", files: [("a.mkv", 999)], source: "TargetSite")
        let (level, why) = AssistMatcher.judge(localHashes: ["deadbeef"], local: fingerprint(local),
                                               siteTorrentData: site, siteName: "Movie.2020")
        guard case .nameOnly = level else { return XCTFail("应判成待人工，实际 \(level)") }
        XCTAssertTrue(why.contains("大小不同"), why)
    }

    /// 路径归一化：反斜杠、`.` 段、大小写、根目录名都要抹平
    func testPathNormalization() {
        XCTAssertEqual(AssistMatcher.normalizedPath("Show.S01/./CD1/Disc.BIN", root: "Show.S01"),
                       "cd1/disc.bin")
        XCTAssertEqual(AssistMatcher.normalizedPath("Show.S01\\Subs\\zh.srt", root: "Show.S01"),
                       "show.s01\\subs\\zh.srt".replacingOccurrences(of: "\\", with: "/"))
    }
}

/// 站内检索节流：宁慢勿快，站点喊停就退避
final class SiteThrottleTests: XCTestCase {

    /// 假时钟：时间只在 pause 时前进，测试不真睡觉
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var slept: [TimeInterval] = []
        func date() -> Date { now }
        func sleep(_ t: TimeInterval) { slept.append(t); now = now.addingTimeInterval(t) }
    }

    func testFirstRequestNoWaitSecondRespectsInterval() {
        let c = Clock()
        let t = SiteThrottle(limits: .init(perSiteInterval: 8, jitter: 0, maxInterval: 240,
                                          roundBudget: 50),
                             now: { c.date() }, pause: { c.sleep($0) })
        XCTAssertTrue(t.acquire("haidan", random: { 0 }))
        XCTAssertTrue(t.acquire("haidan", random: { 0 }))
        XCTAssertEqual(c.slept.count, 1, "第二次要先补足间隔")
        XCTAssertEqual(c.slept[0], 8, accuracy: 0.001)
    }

    /// 不同站之间不互相等（各自有间隔），但都算进单轮预算
    func testDifferentSitesDontBlockEachOther() {
        let c = Clock()
        let t = SiteThrottle(limits: .init(perSiteInterval: 8, jitter: 0, roundBudget: 50),
                             now: { c.date() }, pause: { c.sleep($0) })
        XCTAssertTrue(t.acquire("haidan", random: { 0 }))
        XCTAssertTrue(t.acquire("pter", random: { 0 }))
        XCTAssertTrue(c.slept.isEmpty, "第一次访问某站不用等")
        XCTAssertEqual(t.remaining, 48)
    }

    /// 预算用完就收工：辅种本来就是可增量重跑的活
    func testRoundBudgetStopsAcquiring() {
        let c = Clock()
        let t = SiteThrottle(limits: .init(perSiteInterval: 0, jitter: 0, roundBudget: 2),
                             now: { c.date() }, pause: { c.sleep($0) })
        XCTAssertTrue(t.acquire("pter", random: { 0 }))
        XCTAssertTrue(t.acquire("pter", random: { 0 }))
        XCTAssertFalse(t.acquire("pter", random: { 0 }), "预算用完要停")
        XCTAssertEqual(t.remaining, 0)
    }

    /// 站点回「太频繁」后该站间隔翻倍，别的站不受影响
    func testPenalizeDoublesThatSitesInterval() {
        let c = Clock()
        let t = SiteThrottle(limits: .init(perSiteInterval: 8, jitter: 0, maxInterval: 60),
                             now: { c.date() }, pause: { c.sleep($0) })
        t.penalize("pter")
        XCTAssertEqual(t.interval(for: "pter"), 16)
        t.penalize("pter"); t.penalize("pter")
        XCTAssertEqual(t.interval(for: "pter"), 60, "翻倍要有上限")
        XCTAssertEqual(t.interval(for: "haidan"), 8, "别站不变")
        XCTAssertTrue(t.acquire("pter", random: { 0 }))
        XCTAssertTrue(t.acquire("pter", random: { 0 }))
        XCTAssertEqual(c.slept.last ?? 0, 60, accuracy: 0.001)
    }

    /// 抖动：让请求不要按固定节拍敲站点
    func testJitterAddedAfterSlot() {
        let c = Clock()
        let t = SiteThrottle(limits: .init(perSiteInterval: 8, jitter: 3),
                             now: { c.date() }, pause: { c.sleep($0) })
        XCTAssertTrue(t.acquire("pter", random: { 0.5 }))
        XCTAssertEqual(c.slept, [1.5], "抖动 = random × jitter，排在本次请求之后")
    }
}
