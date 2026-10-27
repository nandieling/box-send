import XCTest
@testable import BoxSendKit

/// bencode 值树往返 + 馒头那条「種子檔案含有非法檔名」的改名重写
final class TorrentRenameTests: XCTestCase {
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
        return try Data(contentsOf: URL(fileURLWithPath: url.path))
    }

    /// 单文件种子（源站那种一条 .mkv 直接当 info.name）
    private func single(_ name: String) -> Data {
        enc(["info": ["name": name, "piece length": 262144, "pieces": "0000", "private": 1],
             "announce": "https://tracker.invalid/announce", "created by": "boxsend-test"])
    }

    // MARK: - 值树本身

    /// 真种子往返：解码再编码，hash 必须一模一样，不然改一次名就把 hash 搅了两次
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

    // MARK: - 改名

    /// 出问题的真名：冒号是 Windows 与站方都不认的字符，改名后整单才传得上去
    func testColonInInternalNameGetsRenamed() throws {
        let raw = "南家三姐妹 再来一碗.Minami-ke: Okawari.2008.S02E04.1080p.Blu-Ray.Remux"
            + ".AVC.LPCM 2.0-LuckAni.mkv"
        let data = single(raw)
        let fixed = try XCTUnwrap(Unit3DAdapter.legalizeTorrentNames(data))
        XCTAssertEqual(fixed.renames.count, 1)
        let newName = try XCTUnwrap(Bencode.infoName(fixed.data))
        XCTAssertEqual(newName, "南家三姐妹 再来一碗.Minami-ke. Okawari.2008.S02E04.1080p"
                       + ".Blu-Ray.Remux.AVC.LPCM 2.0-LuckAni.mkv", newName)
        XCTAssertFalse(newName.contains(":"), newName)
        XCTAssertNotNil(fixed.data.range(of: Data("南家三姐妹".utf8)), "中文要留着，站方不拦中文")
        XCTAssertNotEqual(Bencode.infoHash(fixed.data), Bencode.infoHash(data), "改名就是换种")
        XCTAssertEqual(Bencode.announceURLs(fixed.data), Bencode.announceURLs(data), "announce 别丢")
        XCTAssertEqual(Bencode.totalLength(fixed.data), Bencode.totalLength(data), "内容体积别变")
    }

    /// 本来合法的种子一个字节都不动：改一次名换一次 hash，白换就亏了跨站复用的 hash
    func testLegalTorrentUntouched() {
        XCTAssertNil(Unit3DAdapter.legalizeTorrentNames(
            single("Some.Movie.2020.1080p.BluRay.x264-GRP.mkv")))
    }

    /// 多文件种子：根目录名与每个 files[].path 都要洗
    func testMultiFileNamesAllRewritten() throws {
        let data = enc([
            "info": ["name": "Show S01 <2008>",
                     "piece length": 262144, "pieces": "0000",
                     "files": [["length": 10, "path": ["S01E01?.mkv"] as [Any]],
                               ["length": 20, "path": ["sub", "S01E02*.mkv"] as [Any]]
                                as [String: Any]]],
            "announce": "https://tracker.invalid/announce",
        ])
        let fixed = try XCTUnwrap(Unit3DAdapter.legalizeTorrentNames(data))
        XCTAssertEqual(fixed.renames.count, 3, "\(fixed.renames)")
        // 换出来的点与原有的点并成一个，首尾的点去掉（Windows 连这些都不认）
        XCTAssertEqual(Bencode.infoName(fixed.data), "Show S01 .2008")
        let paths = try XCTUnwrap(Bencode.fileList(fixed.data)).map { $0.path }
        XCTAssertEqual(paths, ["Show S01 .2008/S01E01.mkv", "Show S01 .2008/sub/S01E02.mkv"])
    }

    /// 老种子常是 GBK 命名：解码成 String 再编回去会改字节，所以改名必须按字节走
    func testNonUTF8BytesSurviveRename() throws {
        let gbk = Data([0xC4, 0xCF, 0xBC, 0xD2])                  // 「南家」的 GBK 字节
        let name = gbk + Data(":movie.mkv".utf8)
        let data = enc(["info": ["name": name, "piece length": 262144, "pieces": "0000"],
                        "announce": "https://tracker.invalid/announce"])
        let fixed = try XCTUnwrap(Unit3DAdapter.legalizeTorrentNames(data))
        // 按字节比：Bencode.infoName 会把非法 UTF-8 收成空串，看不出字节有没有动
        let newName = try XCTUnwrap(BValue.decode(fixed.data)?.dict("info")?.dict("name")?.bytesValue)
        XCTAssertEqual([UInt8](newName),
                       [UInt8](gbk) + [UInt8](Data(".movie.mkv".utf8)),
                       "GBK 那几个字节得原样留着")
    }

    /// path 允许 unpaired 编码（一段是 [utf8, 原字节]），两串都得洗
    func testUnpairedPathPairsRewritten() throws {
        let data = enc([
            "info": ["name": "Movie", "piece length": 262144, "pieces": "0000",
                     "files": [["length": 10,
                                "path": [[Data("a?.mkv".utf8), Data("a?.mkv".utf8)]] as [Any]]
                               as [String: Any]]],
        ])
        let fixed = try XCTUnwrap(Unit3DAdapter.legalizeTorrentNames(data))
        XCTAssertEqual(fixed.renames.count, 2, "\(fixed.renames)")
        XCTAssertEqual(try XCTUnwrap(Bencode.fileList(fixed.data)).first?.path, "Movie/a.mkv")
    }

    /// 上传用的 .torrent 文件名：馒头这条路径以前只去斜杠，中文名照样传上去
    func testUnit3DUploadFilenameIsASCII() {
        let out = Unit3DAdapter.uploadFilename("[LuckPT].南家三姐妹 再来一碗.Minami-ke: Okawari")
        XCTAssertFalse(out.unicodeScalars.contains { $0.value > 127 }, out)
        XCTAssertTrue(out.hasSuffix(".torrent"), out)
        XCTAssertEqual(Unit3DAdapter.uploadFilename("南"), "boxsend.torrent")
    }

    /// 内部文件名的底线：非法字符才动，合法名返回 nil（不然 hash 白白换掉）
    func testLegalComponentOnlyReportsChanges() {
        XCTAssertNil(SiteFileName.legalComponent(Data("Movie.2020 1080p.mkv".utf8)))
        XCTAssertEqual(SiteFileName.legalComponent(Data("A:B|C?.mkv".utf8)),
                       Data("A.B.C.mkv".utf8))
        // 首尾的点与 Windows 同样不认；全是非法字符时兜一个能用的名字
        XCTAssertEqual(SiteFileName.legalComponent(Data("::".utf8)), Data("file".utf8))
        XCTAssertEqual(SiteFileName.legalComponent(Data("片名|中字.mkv".utf8)),
                       Data("片名.中字.mkv".utf8))
        // 全角冒号是普通汉字区字符，Windows 与站方都不拦：这种名字一个字节都不该动
        XCTAssertNil(SiteFileName.legalComponent(Data("片名：中字.mkv".utf8)))
    }
}
