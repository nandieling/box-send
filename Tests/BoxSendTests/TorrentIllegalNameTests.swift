import XCTest
@testable import BoxSendKit

/// bencode 值树往返 + 馒头那条「種子檔案含有非法檔名」：只检测、只报错，不代改包内文件名
final class TorrentIllegalNameTests: XCTestCase {
    /// 自己的小编码器：要能塞原始字节（GBK 命名的老种子），BEnc 只认 String
    private func enc(_ o: Any) -> Data {
        if let d = o as? [String: Any] {
            var out = Data("d".utf8)
            for k in d.keys.sorted() { out += enc(Data(k.utf8)) + enc(d[k]!) }
            out += Data("e".utf8); return out
        }
        if let l = o as? [Any] {
            var out = Data("l".utf8)
            for v in l { out += enc(v) }
            out += Data("e".utf8); return out
        }
        if let b = o as? Data { return Data("\(b.count):".utf8) + b }
        if let s = o as? String { return enc(Data(s.utf8)) }
        if let i = o as? Int { return Data("i\(i)e".utf8) }
        fatalError("unsupported: \(type(of: o))")
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    /// 单文件种子（源站那种一条 .mkv 直接当 info.name）
    private func single(_ name: String) -> Data {
        enc(["info": ["name": name, "piece length": 262144, "pieces": "0000", "private": 1],
             "announce": "https://tracker.invalid/announce", "created by": "boxsend-test"])
    }

    // MARK: - 值树本身

    /// 真种子往返：解码再编码，hash 必须一模一样
    func testRoundTripOnRealTorrent() throws {
        for name in ["food.torrent", "hdsky-550491.torrent", "yema_sample.torrent"] {
            let data = try fixture(name)
            guard let v = BValue.decode(data) else { XCTFail("\(name) 解不开"); continue }
            let again = v.encoded()
            XCTAssertEqual(Bencode.infoHash(again), Bencode.infoHash(data), "\(name) hash 变了")
            XCTAssertEqual(Bencode.fileList(again)?.map { $0.path },
                           Bencode.fileList(data)?.map { $0.path }, "\(name) 文件清单变了")
            XCTAssertEqual(Bencode.fileList(again)?.map { $0.size },
                           Bencode.fileList(data)?.map { $0.size }, "\(name) 条目体积变了")
            XCTAssertEqual(Bencode.announceURLs(again), Bencode.announceURLs(data), "\(name) tracker 变了")
        }
    }

    func testDecodeRejectsGarbage() {
        XCTAssertNil(BValue.decode(Data([0x64, 0x30])))          // 截断
        XCTAssertNil(BValue.decode(Data("not bencode".utf8)))
        XCTAssertNil(BValue.decode(Data()))
    }

    // MARK: - 检测

    /// 出问题的真名：冒号是 Windows 与站方都不认的字符，要能点名报出来
    func testColonInInternalNameGetsBlamed() throws {
        let raw = "南家三姐妹 再来一碗.Minami-ke: Okawari.2008.S02E04.1080p.Blu-Ray.Remux"
            + ".AVC.LPCM 2.0-LuckAni.mkv"
        let bad = Unit3DAdapter.illegalTorrentNames(single(raw))
        XCTAssertEqual(bad, [raw], "\(bad)")
    }

    /// 本来合法的种子一条都不点名：这类站占绝大多数，别拦住发种
    func testLegalTorrentHasNoComplaints() {
        XCTAssertEqual(Unit3DAdapter.illegalTorrentNames(
            single("Some.Movie.2020.1080p.BluRay.x264-GRP.mkv")), [])
        // 真种子（含 unpaired 之外各种写法）也不该被误伤
        for name in ["food.torrent", "hdsky-550491.torrent", "yema_sample.torrent"] {
            XCTAssertEqual(try Unit3DAdapter.illegalTorrentNames(fixture(name)).count, 0, name)
        }
    }

    /// 多文件种子：根目录名与每个 files[].path 都得点名
    func testMultiFileEntriesAllReported() throws {
        let data = enc([
            "info": ["name": "Show S01 <2008>",
                     "piece length": 262144, "pieces": "0000",
                     "files": [["length": 10, "path": ["S01E01?.mkv"] as [Any]],
                               ["length": 20, "path": ["sub", "S01E02*.mkv"] as [Any]]
                                as [String: Any]]],
            "announce": "https://tracker.invalid/announce",
        ])
        XCTAssertEqual(Set(Unit3DAdapter.illegalTorrentNames(data)),
                       Set(["Show S01 <2008>", "S01E01?.mkv", "S01E02*.mkv"]))
    }

    /// unpaired 编码（一段是 [utf8, 原字节]）：两个串都查，但同一个名字只点一次名
    func testUnpairedPairsBlamedOnce() throws {
        let pair = Data("a?.mkv".utf8)
        let data = enc([
            "info": ["name": "Movie", "piece length": 262144, "pieces": "0000",
                     "files": [["length": 10,
                                "path": [[pair, pair]] as [Any]] as [String: Any]]],
        ])
        XCTAssertEqual(Unit3DAdapter.illegalTorrentNames(data), ["a?.mkv"])
    }

    /// 老种子常是 GBK 命名：按字节也认得出非法字符，且解码失败不该把整份清单判坏
    func testGBKNameStillDetected() throws {
        let gbk = Data([0xC4, 0xCF, 0xBC, 0xD2])                  // 「南家」的 GBK 字节
        let data = enc(["info": ["name": gbk + Data(":movie.mkv".utf8),
                                 "piece length": 262144, "pieces": "0000"],
                        "announce": "https://tracker.invalid/announce"])
        XCTAssertEqual(Unit3DAdapter.illegalTorrentNames(data).count, 1)
    }

    // MARK: - 给人看的两句

    /// 卡在哪几个字符、能改成什么，报错里都得带着
    func testIllegalCharsAndSuggestedFix() {
        XCTAssertEqual(String(SiteFileName.illegalChars(Data("A:B|C?.mkv".utf8))), ":|?")
        XCTAssertNil(SiteFileName.legalComponent(Data("Movie.2020 1080p.mkv".utf8)))
        XCTAssertEqual(SiteFileName.legalComponent(Data("A:B|C?.mkv".utf8)),
                       Data("A.B.C.mkv".utf8))
        // 换出来的点与原有的点并成一个，首尾的点去掉（Windows 连这些都不认）
        XCTAssertEqual(SiteFileName.legalComponent(Data("::".utf8)), Data("file".utf8))
        XCTAssertEqual(SiteFileName.legalComponent(Data("片名|中字.mkv".utf8)),
                       Data("片名.中字.mkv".utf8))
        // 全角冒号是普通汉字区字符，站方不拦：这种名字一个字符都不该被点名
        XCTAssertEqual(SiteFileName.illegalChars(Data("片名：中字.mkv".utf8)), [])
    }

    /// 上传用的 .torrent 文件名：馒头这条路径以前只去斜杠，中文名照样传上去
    func testUnit3DUploadFilenameIsASCII() {
        let out = Unit3DAdapter.uploadFilename("[LuckPT].南家三姐妹 再来一碗.Minami-ke: Okawari")
        XCTAssertFalse(out.unicodeScalars.contains { $0.value > 127 }, out)
        XCTAssertTrue(out.hasSuffix(".torrent"), out)
        XCTAssertEqual(Unit3DAdapter.uploadFilename("南"), "boxsend.torrent")
    }
}
