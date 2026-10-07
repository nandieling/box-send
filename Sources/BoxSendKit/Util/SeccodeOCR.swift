import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Discuz 防灌水图片验证码（4 位字母数字）识别。
/// 站点的验证码字体常用西里尔字形——图上看是 "K6KK"，Vision 读出来是 "К6КK"——
/// 所以先做形近字转写再按 [a-z0-9] 过滤；位数不对就当作没认出来，交给调用方重试。
enum SeccodeOCR {
    /// 西里尔 / 希腊字形 -> 拉丁对应字符（含被拿去当数字的 6）
    static let lookAlike: [Character: Character] = [
        "К": "k", "к": "k", "Е": "e", "е": "e", "М": "m", "Н": "h", "А": "a", "В": "b",
        "С": "c", "с": "c", "Т": "t", "О": "o", "Р": "p", "Х": "x", "У": "y", "Б": "6",
        "Л": "n", "Г": "r", "З": "3", "Ф": "o", "Ι": "i", "Β": "b", "Ε": "e", "Ζ": "z",
        "Ν": "n", "Υ": "y", "α": "a", "ο": "o", "ѕ": "s", "і": "i", "ԁ": "d", "р": "p",
        "у": "y", "х": "x", "а": "a", "є": "e",
    ]

    /// 识别验证码文本；认不出或位数不符返回 nil
    static func code(_ image: Data, length: Int = 4) -> String? {
        guard let img = enlarged(image) else { return nil }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.recognitionLanguages = ["en-US"]
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        for observation in req.results ?? [] {
            for candidate in observation.topCandidates(3) where candidate.confidence > 0.3 {
                if let c = normalize(candidate.string, length: length) { return c }
            }
        }
        return nil
    }

    /// 形近字转写 + 过滤，结果必须是 length 位字母数字
    static func normalize(_ raw: String, length: Int = 4) -> String? {
        let mapped = String(raw.map { lookAlike[$0] ?? $0 }).lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let kept = mapped.components(separatedBy: allowed.inverted).joined()
        return kept.count == length ? kept : nil
    }

    /// 白底 4 倍无损放大：100x30 的小图字身太细，Vision 容易整行读空
    static func enlarged(_ data: Data, scale: Int = 4) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let base = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: base.width * scale, height: base.height * scale,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .none
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: base.width * scale, height: base.height * scale))
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width * scale, height: base.height * scale))
        return ctx.makeImage()
    }
}
