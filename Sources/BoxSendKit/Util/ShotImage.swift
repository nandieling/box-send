import Foundation
import CoreGraphics
import ImageIO

/// 发种截图转码：源站截图常是几 MB 的 PNG，图床慢、站点的单文件大小也有限，
/// 统一缩到 1920 以内并转 JPEG 后再上传。用 ImageIO，不依赖 AppKit。
enum ShotImage {
    /// 小于这个体积的原图不折腾（已经是压缩过的截图，重编码只会掉画质）
    static let keepUnderBytes = 1_200_000

    /// 需要时把图片缩边转 JPEG；不需要转或转不动时返回 nil（调用方用原图）
    static func jpeg(_ data: Data, maxPixel: Int = 1920, quality: Float = 0.85) -> Data? {
        guard data.count > keepUnderBytes else { return nil }
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg,
                                  [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), out.length > 0, out.length < data.count else { return nil }
        return out as Data
    }
}
