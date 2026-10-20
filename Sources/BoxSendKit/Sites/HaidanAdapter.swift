import Foundation

/// HAIDAN（海胆之家）：NexusPHP 后端 + 自定义详情布局（movie-content）。
/// 上传为经典表单（takeupload.php + type/medium_sel/tag_list[]），复用 NexusPHPAdapter；
/// 仅重写详情页解析（标题/副标题/kdescr/MediaInfo/下载链接）。
final class HaidanAdapter: NexusPHPAdapter {

    override func fetchDetail(detailURL: String) throws -> ReleaseInfo {
        let html = try client.fetchHTML(detailURL, referer: site.url)
        return try parseDetail(html: html, detailURL: detailURL)
    }

    /// 归属判定与解析只看本条种子那一段（见 `torrentBlock(forID:in:)`）
    override func scopedPage(_ html: String, torrentID: String?) -> String {
        guard let id = torrentID, let block = Self.torrentBlock(forID: id, in: html) else { return html }
        return block
    }

    /// 海胆的详情页把同一部影片的每个版本并列在一页里，每个 `<div class="torrent-wrap">` 一块，
    /// 各自有自己的 download.php?id=N、标题和发布时间。整页去读会读到排在最前面那个版本：
    /// 实测黑礁新种（80033）排在 2020 年的 BDrip 后面，标题与发布时间都成了别人的，
    /// 刚发的新种因此被判成「不是本次发布的」，推给下载器的是同页另一条种子。
    /// 页面上找不到这个 id 时返回 nil，调用方退回整页（改版、只有一块等情况）
    static func torrentBlock(forID id: String, in html: String) -> String? {
        torrentBlocks(in: html).first {
            $0.contains("download.php?id=" + id) || $0.contains("edit.php?id=" + id)
        }
    }

    /// 按版本块切页（详情页用 torrent-wrap、检索页用 torrent_wrap，都算一块）
    static func torrentBlocks(in html: String) -> [String] {
        let ns = html as NSString
        guard let re = try? NSRegularExpression(pattern: "class=['\"]torrent[-_]wrap", options: [])
        else { return [] }
        let marks = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { $0.range.location }
        return marks.enumerated().map { i, start in
            let end = i + 1 < marks.count ? marks[i + 1] : ns.length
            return ns.substring(with: NSRange(location: start, length: end - start))
        }
    }

    /// 同一页并列几个版本时，每块各自写着本块的发布名：逐块读出 id -> 发布名，
    /// 「已存在」响应页给的链接指向别的版本时靠它找回本次这条（见 verifiedDuplicate）
    override func torrentTitles(on page: String) -> [String: String] {
        var out: [String: String] = [:]
        for block in Self.torrentBlocks(in: page) {
            guard let id = HTMLUtil.group(block, #"download\.php\?id=(\d+)"#, group: 1),
                  let raw = HTMLUtil.group(block,
                          "detail-info-item-name'>\\s*标题\\s*</span>[\\s\\S]{0,400}?<b><span>([^<]+)</span>",
                          group: 1) else { continue }
            let name = HTMLUtil.stripTags(raw)
                .replacingOccurrences(of: "&nbsp;", with: " ", options: .literal)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if name.count >= 8 { out[id] = name }
        }
        return out
    }

    /// 纯解析（供测试）
    override func parseDetail(html: String, detailURL: String) throws -> ReleaseInfo {
        // 整页可能并列同一部影片的多个版本，先裁到本条种子那一段
        let html = scopedPage(html, torrentID: Self.torrentIDFromDetail(detailURL))
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
            kind: ReleaseKind.infer(from: name, genre: genre, imdb: imdb, douban: douban),
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
