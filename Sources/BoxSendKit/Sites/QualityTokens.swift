import Foundation

/// 从发布名称解析质量标记。
/// 用途：1) 质量型分类（HDHome/TTG 按分辨率分区）；2) 各站 medium/codec/audiocodec/standard 下拉自动填充。
enum QualityTokens {
    /// 媒介/源介质 token
    static func medium(from name: String, kind: ReleaseKind?) -> String? {
        let n = name.lowercased()
        if n.contains("remux") { return "remux" }
        if kind == .music || n.contains("flac") || n.contains("ape") || n.contains("m4a") { return "track" }
        if n.contains("hdtv") { return "hdtv" }
        let isDisc = n.contains("bluray") || n.contains("blu-ray") || n.contains("bdrip") || n.contains("brrip") || n.contains("bdiso")
        let isWeb = n.contains("web-dl") || n.contains("webdl") || n.contains("web rip") || n.contains("webrip")
        let is8K = n.contains("8k") || n.contains("4320")
        let is4K = n.contains("2160p") || n.contains("4k") || n.contains("uhd")
        if is8K { return isDisc ? "uhdbd8k" : "uhd8k" }
        if is4K {
            if isDisc { return "uhdbd" }
            if isWeb { return "webdl" }
            return "uhd"
        }
        if n.contains("1080p") || n.contains("1080i") || n.contains("720p") || n.contains("1440p") || n.contains("2k") {
            if isDisc { return "bluray" }
            if isWeb { return "webdl" }
            return "encode"
        }
        if n.contains("dvd") { return "dvd" }
        return nil
    }

    /// 分辨率型分类 token（HDHome/TTG 的分类按分辨率划分）
    static func catProfile(from name: String, kind: ReleaseKind?) -> String? {
        let n = name.lowercased()
        if kind == .music { return nil }
        if n.contains("remux") { return "remux" }
        let isDisc = n.contains("bluray") || n.contains("blu-ray") || n.contains("bdrip") || n.contains("brrip") || n.contains("bdiso")
        let is8K = n.contains("8k") || n.contains("4320")
        let is4K = n.contains("2160p") || n.contains("4k") || n.contains("uhd")
        if is8K { return isDisc ? "8k-bd" : "8k" }
        if is4K { return isDisc ? "uhd-bd" : "2160p" }
        if n.contains("1440p") || n.contains("2k") { return "1440p" }
        if n.contains("1080p") { return "1080p" }
        if n.contains("1080i") { return "1080i" }
        if n.contains("720p") { return "720p" }
        if n.contains("dvd") { return "dvd" }
        if n.contains("480") || n.contains("sd") { return "sd" }
        return nil
    }

    static func codec(from name: String) -> String? {
        let n = name.lowercased()
        if n.contains("x265") || n.contains("hevc") || n.contains("h265") || n.contains("h.265") { return "hevc" }
        if n.contains("x264") || n.contains("avc") || n.contains("h264") || n.contains("h.264") { return "avc" }
        if n.contains("xvid") { return "xvid" }
        if n.contains("vc-1") || n.contains("vc1") { return "vc1" }
        if n.contains("av1") { return "av1" }
        if n.contains("mpeg-2") || n.contains("mpeg2") { return "mpeg2" }
        return nil
    }

    static func audio(from name: String) -> String? {
        let n = name.lowercased()
        if n.contains("dts:x") || n.contains("dts x") { return "dtsc" }
        if n.contains("dts-hd") || n.contains("dts hd") || n.contains("dts.hd") || n.contains("dts-hdma") {
            if n.contains(".ma") || n.contains("-ma") || n.contains(" ma") || n.contains("dma") { return "dtsma" }
            return "dtsbr"
        }
        if n.contains("truehd") { return n.contains("atmos") ? "truehd atmos" : "truehd" }
        if n.contains("e-ac3") || n.contains("eac3") || n.contains("ddp") { return n.contains("atmos") ? "eac3 atmos" : "eac3" }
        if n.contains("dd5") || n.contains("ac3") { return "ac3" }
        if n.contains("dts") { return "dts" }
        if n.contains("flac") { return "flac" }
        if n.contains("ape") { return "ape" }
        if n.contains("opus") { return "opus" }
        if n.contains("m4a") || n.contains("alac") { return "m4a" }
        if n.contains("aac") { return "aac" }
        if n.contains("mp3") { return "mp3" }
        if n.contains("ogg") { return "ogg" }
        if n.contains("wav") { return "wav" }
        if n.contains("lpcm") || n.contains("pcm") { return "pcm" }
        return nil
    }

    /// 发布名中的年份（第一个 19xx/20xx 四位数字）
    static func year(from name: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: "(?<![0-9])(?:19|20)[0-9]{2}(?![0-9])") else { return nil }
        let ns = NSRange(name.startIndex..., in: name)
        for m in re.matches(in: name, options: [], range: ns) {
            guard let r = Range(m.range, in: name), let v = Int(String(name[r])), (1900...2100).contains(v) else { continue }
            return v
        }
        return nil
    }

    static func standard(from name: String) -> String? {
        let n = name.lowercased()
        if n.contains("8k") || n.contains("4320") { return "8k" }
        if n.contains("2160p") || n.contains("4k") || n.contains("uhd") { return "2160p" }
        if n.contains("1080p") { return "1080p" }
        if n.contains("1080i") { return "1080i" }
        if n.contains("720p") { return "720p" }
        if n.contains("480") || n.contains("sd") || n.contains("dvd") { return "sd" }
        return nil
    }
}
