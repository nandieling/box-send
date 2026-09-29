import Foundation

/// HAIDAN（海胆之家）：NexusPHP 后端 + 自定义详情布局（movie-content）。
/// 上传为经典表单（takeupload.php + type/medium_sel/tag_list[]），复用 NexusPHPAdapter；
/// 仅重写详情页解析（标题/副标题/kdescr/MediaInfo/下载链接）。
final class HaidanAdapter: NexusPHPAdapter {

    override func fetchDetail(detailURL: String) throws -> ReleaseInfo {
        let html = try client.fetchHTML(detailURL, referer: site.url)
        return try parseDetail(html: html, detailURL: detailURL)
    }

    /// 纯解析（供测试）
    override func parseDetail(html: String, detailURL: String) throws -> ReleaseInfo {
        // 标题块：'detail-info-item-name'>标题</span> ... <b><span>NAME</span></b>
        guard let nameRaw = HTMLUtil.group(html,
                "detail-info-item-name'>\\s*标题\\s*</span>[\\s\\S]{0,400}?<b><span>([^<]+)</span>",
                group: 1) else {
            throw BoxSendError.badInput("无法解析 HAIDAN 标题: \(detailURL)")
        }
        let name = HTMLUtil.stripTags(nameRaw).replacingOccurrences(of: "&nbsp;", with: " ", options: .literal)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 副标题：标题后的第二个 <span>（"中文名 / 别名 | 类型：… | 演员：…" -> 取 "类型" 前）
        var subtitle = ""
        if let subRaw = HTMLUtil.group(html,
                "detail-info-item-name'>\\s*标题\\s*</span>[\\s\\S]{0,400}?<b><span>[^<]+</span></br><span>([^<]*)</span>",
                group: 1) {
            var t = HTMLUtil.stripTags(subRaw).trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = t.range(of: " | 类型") { t = String(t[..<i.lowerBound]) }
            t = t.trimmingCharacters(in: .whitespaces)
            t = t.replacingOccurrences(of: "/\\s*$", with: "", options: .regularExpression)
            subtitle = t.trimmingCharacters(in: .whitespaces)
        }

        // 简介 + MediaInfo：#kdescr 容器
        let descr = HTMLUtil.divByOpenTag(html, "<div id=['\"]kdescr['\"][^>]*>") ?? ""
        var mediainfo = ""
        for fs in HTMLUtil.allMatches(descr, "<fieldset>([\\s\\S]*?)</fieldset>", options: .caseInsensitive) {
            let t = HTMLUtil.stripTags(fs)
                .replacingOccurrences(of: "&nbsp;", with: " ", options: .literal)
            if t.contains("Unique ID") || t.contains("DISC TITLE") || t.contains("Disc Label") {
                mediainfo = t.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        let imdb = HTMLUtil.group(descr, "imdb\\.com/title/(tt\\d{5,13})")
        let douban = HTMLUtil.group(descr, "douban\\.com/subject/(\\d+)")

        // 下载直链
        guard let dl = HTMLUtil.group(html, "(download\\.php\\?id=\\d+&passkey=[a-f0-9]{16,64})") else {
            throw BoxSendError.badInput("未找到 .torrent 下载链接: \(detailURL)")
        }
        let base = URL(string: detailURL) ?? URL(string: site.url)!
        let torrentURL = HTMLUtil.resolveURL(dl, against: base)

        // 类别（genre 行）
        let genre = HTMLUtil.group(descr, "◎类\\s*别\\s*[:：]\\s*([^<\\n]+)") ?? ""
        // 禁转标记
        let markers = override?.forbidReseedMarkers ?? ["禁转", "Excl.", "excl"]
        let plain = HTMLUtil.stripTags(descr)
        let isForbid = markers.contains { m in plain.contains(m) }

        let torrentName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "release"
        return ReleaseInfo(
            siteID: site.id,
            detailURL: detailURL,
            name: name,
            descr: descr,
            imdb: imdb,
            douban: douban,
            size: nil,
            kind: ReleaseKind.infer(from: name, genre: genre),
            torrentName: torrentName.hasSuffix(".torrent") ? torrentName : torrentName + ".torrent",
            torrentURL: torrentURL,
            isForbidReseed: isForbid,
            subtitle: subtitle,
            genre: genre.trimmingCharacters(in: .whitespaces),
            mediainfo: mediainfo,
            region: ""
        )
    }
}
