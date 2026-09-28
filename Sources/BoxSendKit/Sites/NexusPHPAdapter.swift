import Foundation

/// NexusPHP 家族适配器（覆盖 9 个优先站 + 大多数中文站）。
/// 通用逻辑 + SiteOverride 站点差异。
final class NexusPHPAdapter: SiteAdapter {
    let site: SiteConfig
    let client: HTTPClient
    let override: SiteOverride?
    /// 上传失败时把页面 HTML 存到这里排查（<dataDir>/debug/）
    let debugDir: String?

    init(site: SiteConfig, client: HTTPClient, debugDir: String? = nil) {
        self.site = site
        self.client = client
        self.override = site.overrides
        self.debugDir = debugDir
    }

    private var uploadPath: String { override?.uploadPath ?? "upload.php" }
    private var uploadAction: String {
        let a = override?.uploadActionPath ?? uploadPath
        return a.hasPrefix("/") ? String(a.dropFirst()) : a
    }
    private var titleField: String { override?.titleField ?? "title" }
    private var descrField: String { override?.descrField ?? "descr" }
    private var imdbField: String { override?.imdbField ?? "imdbid" }
    private var categoryField: String { override?.categoryField ?? "category" }
    private var fileField: String { override?.fileField ?? "file" }
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

    private func resolvedTitle(_ info: ReleaseInfo) -> String {
        let mode = override?.titleMode ?? "reseed"
        var t = info.name
        if mode == "torrentName" || mode == "torrentNameDotted" {
            t = info.torrentName
            if t.hasSuffix(".torrent") { t = String(t.dropLast(8)) }
        }
        if mode == "torrentNameDotted" {
            t = t.replacingOccurrences(of: "\\s+", with: ".", options: .regularExpression)
        }
        return t
    }

    private func resolveCategory(_ info: ReleaseInfo) -> Int? {
        guard let map = override?.categoryMap else { return nil }
        let kind = info.kind?.rawValue ?? "other"
        if let profile = QualityTokens.catProfile(from: info.name, kind: info.kind),
           let v = map["\(kind)/\(profile)"] {
            return v
        }
        return map[kind] ?? map["other"]
    }

    private func applyQualitySelects(_ info: ReleaseInfo, into fields: inout [String: String]) {
        guard let selects = override?.qualitySelects, let maps = override?.qualityValueMaps else { return }
        let tokens: [String: String?] = [
            "medium": QualityTokens.medium(from: info.name, kind: info.kind),
            "codec": QualityTokens.codec(from: info.name),
            "audiocodec": QualityTokens.audio(from: info.name),
            "standard": QualityTokens.standard(from: info.name),
        ]
        for (field, attr) in selects {
            guard let token = tokens[attr].flatMap({ $0 }), let v = maps[attr]?[token] else { continue }
            fields[field] = String(v)
        }
    }

    /// 上传未成功时提取错误：errorbox -> 常见错误特征 -> 静默重渲染提示
    private func extractUploadError(body: String, status: Int) -> String {
        if let e = HTMLUtil.group(body, "<div[^>]*id=[\"']errorbox[\"'][^>]*>(.*?)</div>", group: 1, options: [.dotMatchesLineSeparators]) {
            let t = HTMLUtil.stripTags(e).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if let m = HTMLUtil.firstMatch(body, "(?:This torrent already exists|already exists|已存在)[^<]{0,60}") {
            return m
        }
        if body.contains("<form") && (body.contains("takeupload.php") || body.contains("upload.php")) {
            return "服务器未跳转到详情页（必填字段缺失或校验失败），请核对该站 overrides 配置"
        }
        return "HTTP \(status) 未识别的返回"
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

    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
        let uploadURL = site.url + uploadAction
        let page = try client.fetchHTML(uploadURL, referer: site.url)

        // 抓取所有隐藏字段（含 passkey/n_id 等站点 token）
        var fields: [String: String] = [:]
        let hiddenRe = try! NSRegularExpression(
            pattern: "<input[^>]*type=[\"']hidden[\"'][^>]*>",
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
        fields[titleField] = resolvedTitle(info)
        fields[descrField] = cleanDescription(info.descr, sourceHost: site.url)
        if let imdb = info.imdb {
            let tmpl = override?.imdbValueTemplate ?? "{imdb}"
            fields[imdbField] = tmpl.replacingOccurrences(of: "{imdb}", with: imdb)
        }
        if let doubanField = override?.doubanField, let douban = info.douban {
            let tmpl = override?.doubanValueTemplate ?? "{douban}"
            fields[doubanField] = tmpl.replacingOccurrences(of: "{douban}", with: douban)
        }
        // 分类（支持质量型键 "<kind>/<profile>"）
        if let category = resolveCategory(info) { fields[categoryField] = String(category) }
        // 质量下拉（medium/codec/audiocodec/standard）
        applyQualitySelects(info, into: &fields)
        // 额外固定字段
        for (k, v) in (override?.extraUploadFields ?? [:]) {
            fields[k] = v
        }
        // 常见可选字段的默认值（不影响大多数站）
        fields["nfo"] = ""
        fields["anonymous"] = "1"

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
        // 失败: 提取错误信息 + 保存页面
        var errMsg = extractUploadError(body: body, status: resp.status)
        if let p = dumpDebugHTML(body) {
            errMsg += "（页面已存 \(p)）"
        }
        return UploadOutcome(success: false, message: HTMLUtil.stripTags(errMsg), detailURL: nil)
    }
}