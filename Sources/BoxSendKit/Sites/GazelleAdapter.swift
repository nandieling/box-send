import Foundation

/// Gazelle 家族适配器（经典 Gazelle / xbtit 皮肤：HDSpace、OpenCD、IPTorrents 等）。
/// 详情 index.php?page=torrent-details&id=<32hex>；上传 POST index.php?page=upload（BBCode 简介）。
final class GazelleAdapter: SiteAdapter {
    let site: SiteConfig
    let client: HTTPClient
    let override: SiteOverride?
    let debugDir: String?

    init(site: SiteConfig, client: HTTPClient, debugDir: String? = nil) {
        self.site = site
        self.client = client
        self.override = site.overrides
        self.debugDir = debugDir
    }

    var uploadPath: String { override?.uploadPath ?? "index.php?page=upload" }
    var uploadAction: String {
        let a = override?.uploadActionPath ?? uploadPath
        return a.hasPrefix("/") ? String(a.dropFirst()) : a
    }
    var fileField: String { override?.fileField ?? "torrent" }

    // MARK: - 列表

    func fetchTorrentList() throws -> [ReleaseInfo] {
        let listURL = site.url + "index.php?page=torrents"
        let html = try client.fetchHTML(listURL, referer: site.url)
        let pattern = override?.detailLinkPattern ?? Self.detailHrefPattern
        var seen = Set<String>()
        var out: [ReleaseInfo] = []
        for a in HTMLUtil.anchorText(html, hrefPattern: pattern) {
            let url = HTMLUtil.resolveURL(a.href, against: URL(string: listURL)!)
            guard !seen.contains(url), !a.text.isEmpty else { continue }
            seen.insert(url)
            // 下载链当详情链用时换算为详情页
            let detail = url.replacingOccurrences(of: "download.php?id=", with: "index.php?page=torrent-details&id=")
            out.append(ReleaseInfo(siteID: site.id, detailURL: detail, name: a.text,
                                   kind: ReleaseKind.infer(from: a.text)))
        }
        return out
    }

    // MARK: - 详情解析

    func fetchDetail(detailURL: String) throws -> ReleaseInfo {
        let html = try client.fetchHTML(detailURL, referer: site.url)
        return try parseDetail(html: html, detailURL: detailURL)
    }

    /// 纯解析（供测试）
    func parseDetail(html: String, detailURL: String) throws -> ReleaseInfo {
        let base = URL(string: detailURL) ?? URL(string: site.url)!

        // 标题: <title> "NAME at SITE - Slogan"（取最后一个 " at " 之前的部分）
        var name: String?
        if let raw = HTMLUtil.group(html, "<title>([\\s\\S]*?)</title>", group: 1) {
            var t = HTMLUtil.stripTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = t.range(of: " at ", options: .backwards)?.lowerBound {
                t = String(t[t.startIndex..<i])
            }
            if !t.isEmpty { name = t }
        }
        // 兜底: 名称锚点（xbtit torrent-name / 详情链接文本）
        if name == nil, let a = HTMLUtil.anchorText(html, hrefPattern: Self.detailHrefPattern).first, !a.text.isEmpty {
            name = a.text
        }

        // 简介: 1) xbtit "Description" 表头单元格 2) <div id="descr"> 3) "Description" 标签后的 div
        var descr = ""
        if let cell = Self.descriptionCell(html) {
            descr = cell
        } else if let d = HTMLUtil.divContent(html, id: "descr") {
            descr = d
        }
        descr = Self.unrenderBBCode(descr)

        // mediainfo: <pre> 块（经典 Gazelle 的 MediaInfo 在简介 BBCode 内，留空即可）
        var mediainfo = ""
        for pre in HTMLUtil.allMatches(html, "<pre[^>]*>([\\s\\S]*?)</pre>", options: .caseInsensitive) {
            let t = HTMLUtil.stripTags(pre).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.contains("Unique ID") || t.contains("DISC TITLE") {
                mediainfo = t.replacingOccurrences(of: "\r\n", with: "\n", options: [])
                    .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                break
            }
        }

        let imdb = HTMLUtil.group(html, "imdb\\.com/title/(tt\\d{5,13})")
        let douban = HTMLUtil.group(html, "douban\\.com/subject/(\\d+)")

        var size: Int64? = nil
        if let n = name,
           let numStr = HTMLUtil.group(n, "(\\d+(?:\\.\\d+)?)\\s*(GiB|GB|MiB|MB|TB)", group: 1),
           let unitRaw = HTMLUtil.group(n, "(GiB|GB|MiB|MB|TB)") {
            let num = Double(numStr) ?? 0
            let factor: Double = unitRaw.uppercased() == "TB" ? 1024.0 * 1024 * 1024 * 1024
                : (unitRaw.uppercased() == "GIB" || unitRaw.uppercased() == "GB" ? 1024.0 * 1024 * 1024 : 1024.0 * 1024)
            size = Int64(num * factor)
        }

        // .torrent 直链: download.php?id=<hash>&f=NAME.torrent（HDSpace）/ index.php?page=download&hash=
        var torrentURL: String? = nil
        var torrentName = ""
        if let m = HTMLUtil.group(html, "href=[\"']([^\"']*download\\.php\\?id=[0-9a-f]{32}[^\"']*)[\"']", options: .caseInsensitive) {
            let url = HTMLUtil.resolveURL(HTMLUtil.decodeEntities(m), against: base)
            torrentURL = url
            if let f = HTMLUtil.group(url, "[&?]f=([^&\"']+)") {
                var t = f.replacingOccurrences(of: "+", with: " ")
                if let d = t.removingPercentEncoding { t = d }
                torrentName = t
            }
        }
        if torrentURL == nil, let m = HTMLUtil.group(html, "href=[\"']([^\"']*page=download&hash=[0-9a-f]{24,64}[^\"']*)[\"']", options: .caseInsensitive) {
            torrentURL = HTMLUtil.resolveURL(HTMLUtil.decodeEntities(m), against: base)
        }

        let markers = override?.forbidReseedMarkers ?? ["禁转", "Excl.", "excl", "No seed"]
        let plain = HTMLUtil.stripTags(descr)
        let isForbid = markers.contains { m in plain.contains(m) || html.lowercased().contains(m.lowercased()) }

        guard let finalName = name, !finalName.isEmpty else {
            throw BoxSendError.badInput("无法解析标题: \(detailURL)")
        }
        guard let finalTorrentURL = torrentURL else {
            throw BoxSendError.badInput("未找到 .torrent 下载链接: \(detailURL)")
        }
        if torrentName.isEmpty {
            torrentName = finalName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "release.torrent"
        }

        return ReleaseInfo(
            siteID: site.id,
            detailURL: detailURL,
            name: finalName,
            descr: descr,
            imdb: imdb,
            douban: douban,
            size: size,
            kind: ReleaseKind.infer(from: finalName, genre: ""),
            torrentName: torrentName.hasSuffix(".torrent") ? torrentName : torrentName + ".torrent",
            torrentURL: finalTorrentURL,
            isForbidReseed: isForbid,
            subtitle: "",
            genre: "",
            mediainfo: mediainfo,
            region: ""
        )
    }

    /// xbtit 皮肤：提取 "Description" 表头行的内容单元格（按 <td>/</td> 深度配对）
    static func descriptionCell(_ html: String) -> String? {
        let labelRe = try! NSRegularExpression(pattern: "<td[^>]*>\\s*Description\\s*</td>", options: [.caseInsensitive])
        guard let m = labelRe.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)) else { return nil }
        let after = Range(m.range, in: html)!.upperBound
        let tdOpen = html.range(of: "<td", range: after..<html.endIndex)
        guard let tdRange = tdOpen else { return nil }
        let start = tdRange.lowerBound
        let startOffset = NSRange(start..<html.endIndex, in: html).location
        let tdRe = try! NSRegularExpression(pattern: "<td\\b|</td>", options: [.caseInsensitive])
        let matches = tdRe.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
        var depth = 0
        for dm in matches where dm.range.location >= startOffset {
            if html[Range(dm.range, in: html)!].hasPrefix("</td") {
                depth -= 1
                if depth == 0 { return String(html[start..<Range(dm.range, in: html)!.lowerBound]) }
            } else {
                depth += 1
            }
        }
        return nil
    }

    /// xbtit 渲染的 BBCode 还原为原始 BBCode 片段（[quote]/[code]），去掉 NFO 滑块块
    static func unrenderBBCode(_ html: String) -> String {
        var s = html
        // NFO 滑块（Show|Hide NFO 链接 + 隐藏块）
        s = s.replacingOccurrences(of: "<div[^>]*>\\s*<a href=[\"']#nfo[\"'][^>]*>[^<]*</a>\\s*</div>",
                                   with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<div[^>]*slidenfo[^>]*>[\\s\\S]*?</div>\\s*</div>",
                                   with: "", options: .regularExpression)
        // [code]（先处理，code 表不含嵌套表）
        s = HTMLUtil.replaceMatches(s, "<b>\\s*Code:?</b>(?:\\s*<br\\s*/?>)*\\s*<table[^>]*class=\"code\"[^>]*>([\\s\\S]*?)</table>") { m in
            // 捕获组 range 是相对原串 s 的绝对坐标
            guard let r = Range(m.range(at: 1), in: s) else { return String(s[Range(m.range, in: s)!]) }
            var inner = String(s[r])
            inner = inner.replacingOccurrences(of: "</?tr>|</?td[^>]*>|</?font[^>]*>", with: "", options: .regularExpression)
            return "[code]" + inner + "[/code]"
        }
        // [quote]
        s = HTMLUtil.replaceMatches(s, "<b>\\s*Quote:?</b>(?:\\s*<br\\s*/?>)*\\s*<table[^>]*class=\"quote\"[^>]*>([\\s\\S]*?)</table>") { m in
            guard let r = Range(m.range(at: 1), in: s) else { return String(s[Range(m.range, in: s)!]) }
            var inner = String(s[r])
            inner = inner.replacingOccurrences(of: "</?tr>|</?td[^>]*>|</?font[^>]*>", with: "", options: .regularExpression)
            return "[quote]" + inner + "[/quote]"
        }
        return s
    }

    // MARK: - 下载 / 查重

    func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
        let resp = try client.get(info.torrentURL, referer: info.detailURL)
        if resp.status == 404 || resp.status == 403 {
            throw BoxSendError.cookieExpired(site.url)
        }
        if resp.status >= 400 {
            throw BoxSendError.http(status: resp.status, url: info.torrentURL,
                                    body: String(data: resp.data.prefix(200), encoding: .utf8) ?? "")
        }
        guard Bencode.infoHash(resp.data) != nil else {
            let head = String(data: resp.data.prefix(80), encoding: .utf8) ?? ""
            throw BoxSendError.badInput(".torrent 不是有效 bencode（\(resp.data.count) bytes，开头: \(head)），可能 cookie 失效或下载链接错误: \(info.torrentURL)")
        }
        return (resp.data, info.torrentName)
    }

    /// xbtit 结果行：详情链接是 <a href="index.php?page=torrent-details&amp;id=<sha1>">名称</a>
    /// （& 转义成 &amp;，id 是 40 位 sha1，不是 32 位）
    static let detailHrefPattern = "torrent-details&(?:amp;)?id=[0-9a-f]{24,64}|download\\.php\\?id=[0-9a-f]{24,64}|/torrent/\\d+"

    /// 查重：配置 searchURL 后按名称匹配（候选词逐级放宽，同 NexusPHP）
    func searchExists(_ info: ReleaseInfo) throws -> String? {
        guard let tmpl = override?.searchURL, !tmpl.isEmpty else { return nil }
        let names: [String] = [info.name]
            + (info.name.count > 32 ? [String(info.name.prefix(32))] : [])
            + (info.subtitle.count >= 6 && info.subtitle != info.name ? [info.subtitle] : [])
        var seen = Set<String>()
        for name in names where !seen.contains(name) {
            seen.insert(name)
            var q = tmpl
            q = q.replacingOccurrences(of: "{imdb}", with: info.imdb ?? "")
            q = q.replacingOccurrences(of: "{name}", with: name.urlEncoded)
            let url = (q.hasPrefix("http") ? q : site.url + q)
            let html = try client.fetchHTML(url, referer: site.url)
            let noResultMarkers = ["No torrents found", "没有种子", "no results", "No torrents", "No results"]
            if noResultMarkers.contains(where: { html.lowercased().contains($0.lowercased()) }) { continue }
            if let hit = NexusPHPAdapter.searchNameInResults(html: html, releaseName: name,
                                                            base: URL(string: url)!,
                                                            hrefPattern: Self.detailHrefPattern) {
                return hit.href
            }
        }
        return nil
    }

    // MARK: - 上传

    func buildUploadFields(_ info: ReleaseInfo, page: String) -> [HTTPClient.MultipartField] {
        var fields: [HTTPClient.MultipartField] = []
        let hiddenRe = try! NSRegularExpression(
            pattern: "<input[^>]*type=[\"']hidden[\"'][^>]*>",
            options: [.caseInsensitive])
        let range = NSRange(page.startIndex..., in: page)
        for m in hiddenRe.matches(in: page, options: [], range: range) {
            let tag = String(page[Range(m.range, in: page)!])
            guard tag.contains("type=\"hidden\"") || tag.contains("type='hidden'") else { continue }
            guard let name = HTMLUtil.group(tag, "name=[\"']([^\"']+)[\"']", group: 1) else { continue }
            let value = HTMLUtil.group(tag, "value=[\"']([^\"']*)[\"']", group: 1) ?? ""
            fields.append(.init(name, value))
        }
        func setField(_ name: String, _ value: String) {
            fields.removeAll { $0.name == name }
            fields.append(.init(name, value))
        }

        // 经典 Gazelle 字段：filename=标题, info=BBCode 简介, category=分类 ID
        setField("filename", info.name)
        setField("genre", "")
        if let imdb = info.imdb { setField("imdb", imdb) }
        if let category = resolveCategory(info) { setField("category", String(category)) }
        var bb = BBCode.fromHTML(info.descr, base: URL(string: site.url))
        bb = BBCode.insertMediainfo(bb, mediainfo: info.mediainfo)
        setField("info", info.extraQuoteBBCode + bb)
        setField("anonymous", "false")
        setField("t3d", "0")
        setField("req", "0")
        setField("nuk", "0")
        setField("submit", "Send")
        return fields
    }

    /// 分类：静态表（kind/profile 键）；未命中 -> other
    private func resolveCategory(_ info: ReleaseInfo) -> Int? {
        guard let map = override?.categoryMap else { return nil }
        let kind = info.kind?.rawValue ?? "other"
        if let profile = QualityTokens.catProfile(from: info.name, kind: info.kind),
           let v = map["\(kind)/\(profile)"] { return v }
        return map[kind] ?? map["other"]
    }

    func previewUploadFields(_ info: ReleaseInfo) throws -> [(String, String)] {
        let page = try client.fetchHTML(site.url + uploadPath, referer: site.url)
        return buildUploadFields(info, page: page).map { ($0.name, $0.value) }
    }

    private func dumpDebugHTML(_ body: String) -> String? {
        guard let root = debugDir else { return nil }
        let dir = (root as NSString).appendingPathComponent("debug")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("upload-\(site.id)-\(Int(Date().timeIntervalSince1970)).html")
        if let data = body.data(using: .utf8), (try? data.write(to: URL(fileURLWithPath: path))) != nil {
            return path
        }
        return nil
    }

    /// xbtit（HD-Space 等）用 info_hash 的 40 位 hex 当种子 id：
    /// 响应里不给详情链接时也能自己拼出详情页，「已存在」时同理（同一 info hash 才算重复）
    func infoHashDetailURL(_ torrentData: Data) -> String? {
        guard (override?.detailLinkPattern ?? "torrent-details").contains("torrent-details"),
              let hash = Bencode.infoHash(torrentData) else { return nil }
        return site.url + "index.php?page=torrent-details&id=" + hash
    }

    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
        let uploadURL = site.url + uploadAction
        let page = try client.fetchHTML(uploadURL, referer: site.url)
        let fields = buildUploadFields(info, page: page)

        let resp = try client.postMultipart(
            uploadURL,
            fields: fields,
            files: [(name: fileField, filename: filename, data: torrentData, mime: "application/x-bittorrent")],
            referer: uploadURL
        )

        let finalURL = resp.finalURL.lowercased()
        let body = String(data: resp.data, encoding: .utf8) ?? ""
        let hashURL = infoHashDetailURL(torrentData)
        // 响应正文里的详情链接（有些皮肤用 meta refresh / JS 跳转）
        let bodyLink: String? = HTMLUtil.group(
            body, "href=[\"']([^\"']*torrent-details&(?:amp;)?id=[0-9a-f]{24,64}[^\"']*)[\"']")
            .map { HTMLUtil.resolveURL(HTMLUtil.decodeEntities($0), against: URL(string: uploadURL)!) }
        // 成功: 跳转到 torrent-details
        if let m = HTMLUtil.firstMatch(finalURL, "(?:torrent-details&(?:amp;)?id=[0-9a-f]{24,64}|/torrent/\\d+|/torrents/\\d+)") {
            let u = URL(string: uploadURL)!
            return UploadOutcome(success: true, message: "发布成功",
                                 detailURL: HTMLUtil.resolveURL(m, against: u))
        }
        // HD-Space（xbtit 皮肤）的成功页文案是 "Upload successful! The torrent has been added."
        let okMarkers = ["Your torrent was added", "Torrent was added", "Upload successful",
                         "torrent has been added", "上传成功", "发布成功"]
        if resp.status == 200, okMarkers.contains(where: { body.contains($0) }) {
            return UploadOutcome(success: true, message: "发布成功", detailURL: bodyLink ?? hashURL)
        }
        var errMsg = "HTTP \(resp.status) 未识别的返回"
        if let e = HTMLUtil.group(body, "<span[^>]*class=\"[^\"]*error[^\"]*\"[^>]*>([\\s\\S]*?)</span>", group: 1) {
            let t = HTMLUtil.stripTags(e).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { errMsg = t }
        }
        if let m = HTMLUtil.firstMatch(body, "(?:already exist(?:s|ed)?|已存在)[^<]{0,60}") { errMsg = m }
        if let p = dumpDebugHTML(body) { errMsg += "（页面已存 \(p)）" }
        let msg = HTMLUtil.stripTags(errMsg)
        if msg.contains("已存在") || msg.lowercased().contains("already exist") {
            return UploadOutcome(success: true, message: "站点已存在该种子（查重兜底命中）",
                                 detailURL: bodyLink ?? hashURL, alreadyExists: true)
        }
        return UploadOutcome(success: false, message: msg, detailURL: nil)
    }
}
