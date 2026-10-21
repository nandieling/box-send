import XCTest
@testable import BoxSendKit

/// Transmission 当辅种下载器时扫描返回 0 条：RPC 回的是
/// `{"arguments":{"torrents":[…]},"result":"success"}`，而老代码把整包响应当成了
/// `arguments`、又把 `arguments` 当成了种子数组，于是永远解析出空表；
/// 连「连不上」也会被吞成空清单。用户那份下载器有 12470 条已下完的种子。
final class TransmissionAssistTests: XCTestCase {
    private func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    /// 真机响应形状（percentDone 是整数 1、labels 是数组、trackers 是对象数组）
    private let response = """
    {"arguments":{"torrents":[
      {"downloadDir":"/电影","hashString":"0A0A78CE3A622236B8C434E6D9D16424FF3BC550","id":1,
       "labels":["站点/LuckPT","PT"],"name":"学生会的第二季 2012 1080p BluRay Remux",
       "percentDone":1,"totalSize":49748352628,
       "trackers":[{"announce":"https://pt.luckpt.de/announce?passkey=7f63","announceState":200,
                    "downloadCount":3,"id":0,"scrape":"","tier":0},
                   {"announce":"http://tracker.public:2710/announce","id":1,"tier":1}]}
    ]},"result":"success","tag":7}
    """

    func testArgumentsUnwrapDropsEnvelope() throws {
        let args = try Transmission.arguments(of: json(response), method: "torrent-get", status: 200)
        XCTAssertEqual((args["torrents"] as? [[String: Any]])?.count, 1, "种子在 arguments.torrents 里")
    }

    func testTransportFailureThrowsInsteadOfEmptyList() throws {
        do {
            _ = try Transmission.arguments(of: nil, method: "torrent-get", status: -1)
            XCTFail("连不上必须报错，不能当成「没有种子」")
        } catch let e as BoxSendError {
            XCTAssertTrue(e.errorDescription?.contains("连不上") == true, "\(e.errorDescription ?? "-")")
        }
        do {
            _ = try Transmission.arguments(of: ["result": "no torrent id", "arguments": [:]],
                                          method: "torrent-get", status: 200)
            XCTFail("result 非 success 要报错")
        } catch let e as BoxSendError {
            XCTAssertTrue(e.errorDescription?.contains("no torrent id") == true)
        }
    }

    func testTorrentListParsesRealShape() throws {
        let args = try Transmission.arguments(of: json(response), method: "torrent-get", status: 200)
        let list = Transmission.localTorrents(args["torrents"] as? [[String: Any]] ?? [])
        guard let t = list.first else { return XCTFail("应该解析出一条种子") }
        XCTAssertEqual(t.hash, "0a0a78ce3a622236b8c434e6d9d16424ff3bc550", "hash 统一小写")
        XCTAssertEqual(t.totalSize, 49_748_352_628, "50 GB 级别的 size 不能被截成 Int32")
        XCTAssertEqual(t.progress, 1.0, "percentDone 写成整数 1 也要认成下完")
        XCTAssertEqual(t.savePath, "/电影")
        XCTAssertEqual(t.category, "站点/LuckPT", "TR 的第一个 label 当分类")
        XCTAssertEqual(t.tags, ["站点/LuckPT", "PT"], "其余 label 也要能参与分类筛选")
        XCTAssertEqual(t.trackerHosts, ["pt.luckpt.de", "tracker.public"],
                       "站点检索预筛靠这份 host 名单")
    }

    /// 辅种校验循环认的是 qBittorrent 那几个状态词：TR 正在校验时必须报成 checking，
    /// 否则一条大种子会被当成「校验后只到 0%」直接删掉
    func testVerifyStatesMapToChecking() {
        XCTAssertEqual(Transmission.stateName(3), "checking", "3 = 正在校验")
        XCTAssertEqual(Transmission.stateName(2), "checking", "2 = 排队校验")
        XCTAssertEqual(Transmission.stateName(5), "downloading", "5 = 正在下载：文件对不上")
        XCTAssertEqual(Transmission.stateName(6), "seeding")
    }
}
