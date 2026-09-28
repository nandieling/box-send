import Foundation

/// NexusPHP 家族适配器（覆盖 9 个优先站 + 大多数中文站）。
/// 通用逻辑 + SiteOverride 站点差异。
final class NexusPHPAdapter: SiteAdapter {
    let site: SiteConfig
    let client: HTTPClient
    let override: SiteOverride?

    init(site: SiteConfig, client: HTTPClient) {
        self.site = site
        self.client = client
        self.override = site.overrides
    }

    private var uploadPath: String { override?.uploadPath ?? "upload.php" }
    private var titleField: String { override?.titleField ?? "title" }
    private var descrField: String { override?.descrField ?? "descr" }
    private var imdbField: String { override?.imdbField ?? "imdbid" }
    private var fileField: String { "file" }
    private var listPath: String { "torrents.php" }

    // MARK: - 详情解析

    func fetchDetail(detailURL: String) throws -> ReleaseInfo {
        let html = try client.fetchHTML(detailURL, referer: site.url)
        let base = URL(string: detailURL) ?? URL(string: site.url)!

        // 标题: #hdarea 内第一个链接文本（NexusPHP 标准），回退 <title>
        var name = HTMLUtil.group(html, "<div[^>]*id=[\"']hdarea[\"'][^>]*>.*?<a[^>]*>(.*?)</a>", group: 1, options: [.dotMatchesLineSeparators, .caseInsensitive])
            ?? HTMLUtil.group(html, "<title>(.*?)</title>", group: 1, options: [.dotMatchesLineSeparators])
        name = name.map { HTMLUtil.stripTags($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        name = name?.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        // 简介: #kdescr 或 #largedescribe
        let descr = HTMLUtil.group(html, "<div[^>]*id=[\"'](kdescr|largedescribe|descr)[\"'][^>]*>(.*?)</div>", group: 2, options: [.dotMatchesLineSeparators, .caseInsensitive])
            ?? HTMLUtil.group(html, "<div[^>]*class=[\"'][^\"']*descr[^\"']*[\"'][^>]*>(.*?)</div>", group: 1, options: [.dotMatchesLineSeparators, .caseInsensitive])
            ?? ""

        // 外链信息
        let imdb = HTMLUtil.firstMatch(descr, "tt\\d{5,13}")
        let douban = HTMLUtil.group(descr, "douban\\.com/subject/(\\d+)")

        // 大小: 名称中的 GiB/MiB/GB/MB 标记
        var size: Int64? = nil
        if let m = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*(GiB|GB|MiB|MB|TB)", options: .caseInsensitive),
           let mt = m.firstMatch(in: name ?? "", range: NSRange((name ?? "").startIndex..., in: name ?? "")) {
            let num = Double(HTMLUtil.group(name!, "(\\d+(?:\\.\\d+)?)\\s*(GiB|GB|MiB|MB|TB)", group: 1) ?? "0") ?? 0
            let unit = (HTMLUtil.group(name!, "(GiB|GB|MiB|MB|TB)", group: 1) ?? "").uppercased()
            let factor: Double
            switch unit {
            case "TB": factor = 1024 * 1024 * 1024 * 1024
            case "GIB", "GB": factor = 1024 * 1024 * 1024
            default: factor = 1024 * 1024
            }
            size = Int64(num * factor)
            _ = mt
        }

        // .torrent 下载直链: download.php 链接
        var torrentURL: String? = nil
        var torrentName = ""
        for a in HTMLUtil.anchorText(html, hrefPattern: "download.php") {
            let t = a.text.lowercased()
            if t.contains("torrent") || t.contains("种子") || t.contains("下载") {
                torrentName = a.text
                torrentURL = HTMLUtil.resolveURL(a.href, against: base)
                break
            }
        }
        if torrentURL == nil {
            torrentURL = HTMLUtil.firstMatch(html, "href=[\"']([^\"']*download\\.php[^\"']*)[\"']").map {
                HTMLUtil.resolveURL($0, against: base)
            }
            if torrentURL != nil { torrentName = "\(site.id).torrent" }
        }

        // 禁转标记
        let markers = override?.forbidReseedMarkers ?? ["禁转", "Excl.", "excl"]
        let plainDescr = HTMLUtil.stripTags(descr)
        let pageHead = String(html.prefix(3000))
        let isForbid = markers.contains { m in plainDescr.contains(m) || pageHead.lowercased().contains(m.lowercased()) }

        guard let finalName = name, !finalName.isEmpty else {
            throw BoxSendError.badInput("无法解析标题: \(detailURL)")
        }
        guard let finalTorrentURL = torrentURL else {
            throw BoxSendError.badInput("未找到 .torrent 下载链接: \(detailURL)")
        }
        if torrentName.isEmpty { torrentName = finalName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "release.torrent" }

        return ReleaseInfo(
            siteID: site.id,
            detailURL: detailURL,
            name: finalName,
            descr: cleanDescription(descr, sourceHost: site.url),
            imdb: imdb,
            douban: douban,
            size: size,
            kind: ReleaseKind.infer(from: finalName),
            torrentName: torrentName.hasSuffix(".torrent") ? torrentName : torrentName + ".torrent",
            torrentURL: finalTorrentURL,
            isForbidReseed: isForbid
        )
    }

    /// 简介清洗（M1 通用版）：
    /// 1. 源站域名链接 -> 纯文本；2. 保留 <img> 的 src 绝对化；3. 去掉脚本/样式/多余空行。
    func cleanDescription(_ html: String, sourceHost: String) -> String {
        var s = html
        s = HTMLUtil.replaceMatches(s, "<(script|style)[^>]*>.*?</\\1>",
                           options: [.dotMatchesLineSeparators, .caseInsensitive]) { _ in "" }
        // 源站内部链接转文本
        let host = (try? URL(string: sourceHost)?.host()) ?? sourceHost
        var re = try! NSRegularExpression(pattern: "<a\\s[^>]*href=[\"'](?:https?://)?(?:www\\.)?\(NSRegularExpression.escapedPattern(for: host.split(separator: ".").joined(separator: "\\.?")))(?:/[^\"']*)?[\"'][^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators, .caseInsensitive])
        s = HTMLUtil.replaceMatches(s, re.pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) { m in
            let raw = String(s[Range(m.range(at: 1), in: s)!])
            return HTMLUtil.stripTags(raw)
        }
        // img 绝对化
        let imgRe = try! NSRegularExpression(pattern: "<img\\s[^>]*src=[\"']([^\"']+)[\"']", options: .caseInsensitive)
        s = HTMLUtil.replaceMatches(s, imgRe.pattern, options: .caseInsensitive) { m in
            let orig = String(s[Range(m.range, in: s)!])
            let src = String(s[Range(m.range(at: 1), in: s)!])
            if src.hasPrefix("http") { return orig }
            if let u = URL(string: sourceHost) {
                let abs = u.absoluteString + (src.hasPrefix("/") ? src : "/" + src)
                return orig.replacingOccurrences(of: "src=\"\(src)\"", with: "src=\"\(abs)\"")
            }
            return orig
        }
        // 压缩连续空行
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 列表

    func fetchTorrentList() throws -> [ReleaseInfo] {
        let listURL = site.url + listPath
        let html = try client.fetchHTML(listURL, referer: site.url)
        let pattern = override?.detailLinkPattern ?? "(?:details\\.php\\?id=\\d+|/torrents\\.php\\?id=\\d+)"
        var seen = Set<String>()
        var out: [ReleaseInfo] = []
        // anchorText 提取
        let anchors = HTMLUtil.anchorText(html, hrefPattern: pattern)
        for a in anchors {
            let url = HTMLUtil.resolveURL(a.href, against: URL(string: listURL)!)
            guard !seen.contains(url), !a.text.isEmpty else { continue }
            seen.insert(url)
            out.append(ReleaseInfo(siteID: site.id, detailURL: url, name: a.text,
                                   kind: ReleaseKind.infer(from: a.text)))
        }
        return out
    }

    // MARK: - 下载与查重

    func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
        let resp = try client.get(info.torrentURL, referer: info.detailURL)
        if resp.status == 404 || resp.status == 403 {
            throw BoxSendError.cookieExpired(site.url)
        }
        if resp.status >= 400 {
            throw BoxSendError.http(status: resp.status, url: info.torrentURL,
                                    body: String(data: resp.data.prefix(200), encoding: .utf8) ?? "")
        }
        // .torrent 是 bencode，长度合理
        guard resp.data.count > 64 else {
            throw BoxSendError.badInput(".torrent 内容异常(\(resp.data.count) bytes)，可能 cookie 失效: \(info.torrentURL)")
        }
        return (resp.data, info.torrentName)
    }

    func searchExists(_ info: ReleaseInfo) throws -> String? {
        guard let tmpl = override?.searchURL, !tmpl.isEmpty else { return nil }
        var q = tmpl
        q = q.replacingOccurrences(of: "{imdb}", with: info.imdb ?? "")
        q = q.replacingOccurrences(of: "{name}", with: (info.name).urlEncoded)
        let url = (q.hasPrefix("http") ? q : site.url + q)
        let html = try client.fetchHTML(url, referer: site.url)
        // 无结果特征
        let noResultMarkers = ["No torrents found", "没有种子", "没有相关", "no results"]
        if noResultMarkers.contains(where: { html.contains($0) }) { return nil }
        // 有结果: 取第一个详情链接
        let anchors = HTMLUtil.anchorText(html, hrefPattern: "details\\.php\\?id=|/torrents\\.php\\?id=")
        guard let first = anchors.first else { return nil }
        return HTMLUtil.resolveURL(first.href, against: URL(string: url)!)
    }

    // MARK: - 上传（转种）

    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
        let uploadURL = site.url + uploadPath
        let page = try client.fetchHTML(uploadURL, referer: site.url)

        // 抓取所有隐藏字段（含 passkey/n_id 等站点 token）
        var fields: [String: String] = [:]
        let hiddenRe = try! NSRegularExpression(
            pattern: "<input[^>]*type=[\"']hidden[\"'][^>]*>|<input[^>]*type=[\"']file[\"'][^>]*>",
            options: [.caseInsensitive])
        let range = NSRange(page.startIndex..., in: page)
        for m in hiddenRe.matches(in: page, options: [], range: range) {
            let tag = String(page[Range(m.range, in: page)!])
            guard tag.contains("type=\"hidden\"") || tag.contains("type='hidden'") else { continue }
            guard let name = HTMLUtil.group(tag, "name=[\"']([^\"']+)[\"']", group: 1) else { continue }
            let value = HTMLUtil.group(tag, "value=[\"']([^\"']*)[\"']", group: 1) ?? ""
            fields[name] = value
        }

        // 业务字段
        fields[titleField] = info.name
        fields[descrField] = cleanDescription(info.descr, sourceHost: site.url)
        if let imdb = info.imdb { fields[imdbField] = imdb }
        // 分类
        let catMap = override?.categoryMap
        let kindKey = info.kind?.rawValue ?? "other"
        let category = catMap?[kindKey] ?? catMap?["other"]
        if let category { fields["category"] = String(category) }
        // 额外固定字段
        for (k, v) in (override?.extraUploadFields ?? [:]) {
            fields[k] = v
        }
        // 常见可选字段的默认值（不影响大多数站）
        fields["nfo"] = ""
        fields["anonymous"] = "1"
        fields["strikethrough"] = ""

        let resp = try client.postMultipart(
            uploadURL,
            fields: fields,
            files: [(name: fileField, filename: filename, data: torrentData, mime: "application/x-bittorrent")],
            referer: uploadURL
        )

        let finalURL = resp.finalURL.lowercased()
        let body = String(data: resp.data, encoding: .utf8) ?? ""
        // 成功特征: 跳到新种子详情页 / 发布成功提示
        if let m = HTMLUtil.firstMatch(finalURL, "(?:details\\.php\\?id=\\d+|/torrents\\.php\\?id=\\d+)"), !m.isEmpty {
            let u = URL(string: uploadURL)!
            return UploadOutcome(success: true, message: "发布成功",
                                 detailURL: HTMLUtil.resolveURL(m, against: u))
        }
        if resp.status == 200, body.contains("new torrent") || body.contains("发布成功") || body.contains("Torrent added") {
            return UploadOutcome(success: true, message: "发布成功", detailURL: nil)
        }
        // 失败: 提取错误信息
        let errMsg = HTMLUtil.group(body, "<div[^>]*id=[\"']errorbox[\"'][^>]*>(.*?)</div>", group: 1, options: [.dotMatchesLineSeparators])
            ?? HTMLUtil.firstMatch(body, "(?:This torrent already exists|already exists|已存在|标题.*错误|不能为空|分类.*错误)[^<]{0,80}")
            ?? "HTTP \(resp.status) 未识别的返回"
        return UploadOutcome(success: false, message: HTMLUtil.stripTags(errMsg), detailURL: nil)
    }
}
