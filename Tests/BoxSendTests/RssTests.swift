import XCTest
@testable import BoxSendKit

final class RssTests: XCTestCase {

    func testRssFeedParse() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>t</title><link>https://x/</link>
        <item>
          <guid isPermaLink="false">42211</guid>
          <link>https://pt.luckpt.de/details.php?id=42211</link>
          <title>  Food Inc 2009 1080p REMUX </title>
          <pubDate>Mon, 28 Sep 2026 10:00:00 +0800</pubDate>
        </item>
        <item>
          <link>https://hdsky.me/torrents.php?id=999</link>
          <title>NoGuid</title>
        </item>
        <item><title>EmptyNoLink</title></item>
        </channel></rss>
        """
        let items = RssFeed.parse(xml)
        // 第 3 个 item 无 link 也无 guid，应被丢弃
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].guid, "https://pt.luckpt.de/details.php?id=42211")
        XCTAssertEqual(items[0].title, "Food Inc 2009 1080p REMUX")
        XCTAssertEqual(items[0].pubDate, "Mon, 28 Sep 2026 10:00:00 +0800")
        // 无 guid 时退回 link
        XCTAssertEqual(items[1].guid, "https://hdsky.me/torrents.php?id=999")
        XCTAssertEqual(items[1].title, "NoGuid")
    }

    func testRssFeedURL() {
        let luck = SiteRegistry.prioritySites.first { $0.id == "luckpt" }!
        XCTAssertEqual(RssPoller.feedURL(site: luck, passkey: "abc123"),
                       "https://pt.luckpt.de/passkey.php?rss=abc123")
        // url 无结尾 / 也能拼对
        var s2 = luck
        s2.url = "https://hdsky.me"
        XCTAssertEqual(RssPoller.feedURL(site: s2, passkey: "k"), "https://hdsky.me/passkey.php?rss=k")
    }

    func testRssDetailURLNormalization() {
        XCTAssertEqual(RssPoller.detailURL(from: "https://hdsky.me/torrents.php?id=12345"),
                       "https://hdsky.me/details.php?id=12345")
        XCTAssertEqual(RssPoller.detailURL(from: "https://pt.luckpt.de/details.php?id=1&hit=1"),
                       "https://pt.luckpt.de/details.php?id=1&hit=1")
    }

    func testStateRssSeen() throws {
        let dir = NSTemporaryDirectory() + "rssseen-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let st = StateStore(dataDir: dir)
        XCTAssertFalse(st.isRssSeen(site: "luckpt", guid: "g1"))
        st.markRssSeen(site: "luckpt", guid: "g1")
        XCTAssertTrue(st.isRssSeen(site: "luckpt", guid: "g1"))
        // 不同站点互不影响
        XCTAssertFalse(st.isRssSeen(site: "hdsky", guid: "g1"))
        // 重启后仍在（持久化）
        let st2 = StateStore(dataDir: dir)
        XCTAssertTrue(st2.isRssSeen(site: "luckpt", guid: "g1"))
        // 上限 500：灌 520 条后仍能找到较新的
        for i in 0..<520 { st2.markRssSeen(site: "hdsky", guid: "k\(i)") }
        XCTAssertTrue(st2.isRssSeen(site: "hdsky", guid: "k519"))
    }
}
