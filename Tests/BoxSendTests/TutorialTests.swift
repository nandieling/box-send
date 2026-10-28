import XCTest
@testable import BoxSendKit

/// 使用说明正文的回归。两端（macOS SwiftUI / Windows WPF）现在渲染的是核心这一份，
/// 以前各自抄一份时抄出过「Windows 还在讲早已删掉的推送结果区块」这种事，所以把这些钉住。
final class TutorialTests: XCTestCase {

    private static let tokenKeys = ["manualCookie", "checkCookies", "sourceControl", "sshAuth",
                                    "skipCheck", "autoUpdate", "install", "pkg", "imageFormats"]

    /// 一节里所有会出现的字：标题、步骤、代码块逐行
    private func allText(_ os: TutorialText.OS) -> [String] {
        TutorialText.sections(for: os).flatMap { sec -> [String] in
            var lines = [sec.title] + sec.steps
            if let code = sec.code { lines += code.components(separatedBy: "\n") }
            return lines
        }
    }

    func testSectionShape() {
        let secs = TutorialText.sections(for: .macos)
        XCTAssertEqual(secs.count, 8, "八节说明：站点分组 / Cookie / 转种 / 下载器 / 测速 / TMDB / 更新 / 外观")
        for (i, s) in secs.enumerated() {
            XCTAssertEqual(s.title.hasPrefix("\(i + 1)."), true, "第 \(i + 1) 节标题要带编号：\(s.title)")
            XCTAssertGreaterThanOrEqual(s.steps.count, 3, "\(s.title) 步骤太少")
            for step in s.steps {
                XCTAssertFalse(step.isEmpty, "\(s.title) 有空步骤")
                XCTAssert(step.count > 10, "\(s.title) 有一步短得不像话")
            }
        }
        XCTAssertEqual(secs[5].code?.contains("api.themoviedb.org"), true, "Worker 脚本要随 TMDB 那一节给出")
    }

    func testBothPlatformsSayTheSameThings() {
        let m = TutorialText.sections(for: .macos)
        let w = TutorialText.sections(for: .windows)
        XCTAssertEqual(m.map(\.title), w.map(\.title), "两端小节标题必须一致")
        XCTAssertEqual(m.map(\.steps.count), w.map(\.steps.count), "两端每节步骤数必须一致")
    }

    func testPlaceholdersAreFullyReplaced() {
        for os in [TutorialText.OS.macos, .windows, .other] {
            for text in allText(os) {
                for key in Self.tokenKeys {
                    XCTAssertFalse(text.contains("{\(key)}"), "\(os.rawValue) 端还剩没替换的占位 {\(key)}：\(text)")
                }
            }
        }
        // CookieCloud 那一步里的 {服务器}/{KEY} 是正文本身要显示的，不该被吃掉
        let cc = TutorialText.sections(for: .macos)[1].steps.joined(separator: "\n")
        XCTAssert(cc.contains("GET {服务器}/get/{KEY}"), "CookieCloud 的接口形状要照原样写着")
    }

    func testContentMatchesCurrentUI() {
        let both = allText(.macos).joined(separator: "\n") + allText(.windows).joined(separator: "\n")
        for want in ["CookieCloud", "gist", "tmdb123", "Workers", "帖子免费1天",
                     "运行记录", "源站引用", "my.dnshe.com", "cloudflare"] {
            XCTAssert(both.lowercased().contains(want.lowercased()), "说明里要提到 \(want)")
        }
        // 已经不在界面上的东西别再写回教程里
        for gone in ["下载器推送结果", "与 mac 版一致", "每年续期"] {
            XCTAssertFalse(both.contains(gone), "「\(gone)」这套旧界面对应的说法已经作废")
        }
        // 免费域名不续期这件事要说清楚（用户踩过）
        XCTAssert(allText(.macos).joined().contains("不用每年续"))
    }

    func testBridgeServesTutorialToWindows() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boxsend-tutorial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let svc = try AppService(configPath: dir.appendingPathComponent("boxsend.json").path,
                                 dataDir: dir.path)
        let v = try svc.invoke("version")
        let tut = try XCTUnwrap(v["tutorial"] as? [String: Any])
        XCTAssertEqual(tut["title"] as? String, TutorialText.title)
        let secs = try XCTUnwrap(tut["sections"] as? [[String: Any]])
        XCTAssertEqual(secs.count, 8)
        let flat = secs.flatMap { ($0["steps"] as? [String]) ?? [] }
        XCTAssertEqual(flat.count, TutorialText.sections(for: .windows).flatMap(\.steps).count,
                       "桥给 Windows 的那份要按 Windows 的措辞")
        XCTAssert(flat.joined().contains("Setup.exe"), "Windows 那份要讲 Setup.exe，不是 dmg")
        XCTAssertNotNil(secs[5]["code"], "Worker 脚本要能过 JSON 边界")
    }
}
