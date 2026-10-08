import XCTest
import CoreGraphics
import ImageIO
@testable import BoxSendKit

/// 站点跳回详情页 ≠ 发了新种：归属判定（本次上传 vs 站内已有）与上传页缺失表单的报错
final class SeedOwnershipTests: XCTestCase {
    private func fixture(_ name: String) -> String {
        let p = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name).path
        return (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
    }

    /// 本次上传种子的 hash（LuckPT 43659），站点重算后与站内显示值不同
    let mine = "684776eab527d7ac690532a1bb9165f56f78e902"

    /// 高清视界：站方重算 hash（页面显示 ca1ba7c3…），但发布者就是自己，必须算本次发种成功
    func testOwnSeedWithRewrittenHashIsOurs() throws {
        let html = fixture("detail-hdclone-mine.html")
        let hash = try XCTUnwrap(NexusPHPAdapter.pageInfoHash(html))
        XCTAssertNotEqual(hash, mine, "fixture 里的 hash 应与上传文件不同")
        XCTAssertEqual(NexusPHPAdapter.pageOwnership(html, torrentID: "100674", ourHash: mine), .ours)
    }

    /// 蟹黄堡：hash 不同且发布者是别人（id 11812 / 我们 16213）
    func testOtherUploadersSeedIsTheirs() {
        let html = fixture("detail-crabpt-theirs.html")
        XCTAssertEqual(NexusPHPAdapter.pageOwnership(html, torrentID: "215283", ourHash: mine), .theirs)
    }

    /// 优堡 / 麒麟：认不出发布者，但种子是半年前发布的，不可能是刚才那次上传建的
    func testAncientSeedIsTheirsEvenWithoutUploaderRow() {
        for f in ["detail-ubits-theirs.html", "detail-qilin-theirs.html"] {
            XCTAssertEqual(NexusPHPAdapter.pageOwnership(fixture(f), torrentID: "1", ourHash: mine),
                           .theirs, f)
        }
    }

    /// 什么都判不了时按发布成功报（宁可漏报「已存在」，别把发出去的说成没发）
    func testNoOwnershipSignalIsUnknown() {
        XCTAssertEqual(NexusPHPAdapter.pageOwnership("<p>详情页</p>", torrentID: "9", ourHash: mine), .unknown)
    }

    func testPageOwnershipSignals() {
        XCTAssertEqual(NexusPHPAdapter.currentUserID(fixture("detail-hdclone-mine.html")), "10663")
        XCTAssertEqual(NexusPHPAdapter.uploaderID(fixture("detail-hdclone-mine.html")), "10663")
        XCTAssertEqual(NexusPHPAdapter.uploaderID(fixture("detail-crabpt-theirs.html")), "11812")
        XCTAssertNotNil(NexusPHPAdapter.pageCreatedAt(fixture("detail-hdclone-mine.html")))
        XCTAssertEqual(NexusPHPAdapter.torrentIDFromDetail("https://pt.hdclone.top/details.php?id=100674"),
                       "100674")
        XCTAssertEqual(NexusPHPAdapter.torrentIDFromDetail("https://kp.m-team.cc/detail/1144407"),
                       "1144407")
    }

    /// hash 与上传文件一致时不用再看别的信号
    func testHashMatchWins() {
        let html = "<b>Hash码:</b> \(mine)"
            + "<span>由</span><a href=\"https://x/userdetails.php?id=11812\">other</a>"
        XCTAssertEqual(NexusPHPAdapter.pageOwnership(html, torrentID: "1", ourHash: mine), .ours)
    }

    // MARK: - 上传页没有发种表单

    /// 龙：审核被驳回的种子数达上限，页面只有页头捐赠小表单，要给出站点写明的原因
    func testBlockedUploadPage() {
        let html = fixture("upload-longpt-blocked.html")
        XCTAssertFalse(NexusPHPAdapter.hasUploadForm(html))
        let notice = NexusPHPAdapter.uploadBlockedNotice(html) ?? ""
        XCTAssertTrue(notice.contains("不允许发布"), "实际提示：\(notice)")
    }

    func testUploadFormDetection() {
        XCTAssertTrue(NexusPHPAdapter.hasUploadForm(fixture("cmct-upload.html")))
    }
}

/// 发种截图：URL 粗筛与转码
final class ScreenshotFetchTests: XCTestCase {
    func testDecorativeImagesAreNotScreenshots() {
        XCTAssertTrue(PeerGoAdapter.isScreenshotCandidate(
            "https://img2.pixhost.to/images/5527/692066108_1.png"))
        for bad in ["pic/trans.gif", "https://pt.luckpt.de/pic/smilies/10.gif",
                    "https://x/useravatars/avatar_1.gif", "data:image/png;base64,AAAA",
                    "https://x/logo.png"] {
            XCTAssertFalse(PeerGoAdapter.isScreenshotCandidate(bad), bad)
        }
    }

    func testSmallImageIsKeptAsIs() {
        XCTAssertNil(ShotImage.jpeg(Data(repeating: 0, count: 4096)), "小图不重编码")
        XCTAssertNil(ShotImage.jpeg(Data("not an image".utf8)), "解不动就交回原图")
    }

    /// 大图（源站截图常是几 MB）压到 1920 以内并重编码
    func testLargeImageIsRescaled() throws {
        let w = 2600, h = 1700
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt64 = 0x2545F4914F6CDD1D
        // 4x4 随机色块：接近真实截图的可压缩度（纯噪声 PNG 本身压不动）
        for y in 0..<h {
            for x in 0..<w {
                if x % 4 == 0 && y % 4 == 0 {
                    seed ^= seed << 13
                    seed ^= seed >> 7
                    seed ^= seed << 17
                }
                let i = (y * w + x) * 4
                bytes[i] = UInt8(truncatingIfNeeded: seed >> 24)
                bytes[i + 1] = UInt8(truncatingIfNeeded: seed >> 16)
                bytes[i + 2] = UInt8(truncatingIfNeeded: seed >> 8)
                bytes[i + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cg = try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                       bytesPerRow: w * 4,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                       provider: provider, decode: nil,
                                       shouldInterpolate: false, intent: .defaultIntent))
        // 源图用高质量大图（站点截图常见：几 MB 的 PNG/JPG）
        let raw = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(raw, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg,
                                   [kCGImageDestinationLossyCompressionQuality: Float(0.95)] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let data = raw as Data
        XCTAssertGreaterThan(data.count, ShotImage.keepUnderBytes, "fixture 图要够大才走转码")

        let jpeg = try XCTUnwrap(ShotImage.jpeg(data))
        XCTAssertLessThan(jpeg.count, data.count / 2)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual(try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int), 1920,
                                "长边要压到 1920 以内")
    }
}
