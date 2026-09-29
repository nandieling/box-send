import Foundation

/// Blu 家族适配器（Blutopia / MonikaDesign，Laravel + Layuout UI）。
/// 详情页 /torrents/{id}；上传 = GET 创建页取 _token -> POST 表单（torrents / upload）。
final class BluAdapter: SiteAdapter {
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

    /// 创建页（取 _token）；blutopia=torrents/create, monika=upload/1
    var uploadPath: String { override?.uploadPath ?? "torrents/create" }
    /// POST 动作；blutopia=torrents, monika=upload
    var uploadAction: String {
        let a = override?.uploadActionPath ?? "torrents"
        return a.hasPrefix("/") ? String(a.dropFirst()) : a
    }
    var fileField: String { override?.fileField ?? "torrent" }

    // MARK: - 列表

    func fetchTorrentList() throws -> [ReleaseInfo] {
        let listURL = site.url + "torrents"
        let html = try client.fetchHTML(listURL, referer: site.url)
        var seen = Set<String>()
        var out: [ReleaseInfo] = []
        for a in HTMLUtil.anchorText(html, hrefPattern: "/torrents/\\d+") {
            let url = HTMLUtil.resolveURL(a.href, against: URL(string: listURL)!)
            guard !seen.contains(url), !a.text.isEmpty else { continue }
            seen.insert(url)
            out.append(ReleaseInfo(siteID: site.id, detailURL: url, name: a.text,
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

        // 标题: 页面最后一个 <h1>（第一个是片名/剧集名）
        var name: String?
        for raw in HTMLUtil.allMatches(html, "<h1[^>]*>([\\s\\S]*?)</h1>", options: .caseInsensitive).reversed() {
            let t = HTMLUtil.stripTags(raw).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { name = t; break }
        }
        // 兜底 <title> "NAME - 资源 - SITE"
        if name == nil, let raw = HTMLUtil.group(html, "<title>([\\s\\S]*?)</title>", group: 1) {
            var t = HTMLUtil.stripTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            t = t.replacingOccurrences(of: " - [^ -].*$", with: "", options: .regularExpression)
            if !t.isEmpty { name = t }
        }

        // 简介: blutopia 的 panel__body bbcode-rendered / monika 的 torrent-description 面板
        let descr = HTMLUtil.divByOpenTag(html, "<div[^>]*class=\"[^\"]*panel__body[^\"]*bbcode-rendered[^\"]*\"[^>]*>")
            ?? HTMLUtil.divByOpenTag(html, "<div[^>]*class=\"[^\"]*torrent-description[^\"]*\"[^>]*>")
            ?? ""

        // mediainfo: 含 Unique ID / DISC TITLE 的 <pre> 块
        var mediainfo = ""
        for pre in HTMLUtil.allMatches(html, "<pre[^>]*>([\\s\\S]*?)</pre>", options: .caseInsensitive) {
            let t = HTMLUtil.stripTags(pre).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.contains("Unique ID") || t.contains("DISC TITLE") || (t.contains("Format") && t.contains("Duration")) {
                mediainfo = t.replacingOccurrences(of: "\r\n", with: "\n", options: [])
                    .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                break
            }
        }

        // 外链
        let imdb = HTMLUtil.group(html, "imdb\\.com/title/(tt\\d{5,13})", group: 1)
        let douban = HTMLUtil.group(html, "douban\\.com/subject/(\\d+)")

        // 大小: 名称中的 GiB/GB 标记（下载 .torrent 后由流水线用 bencode 校正）
        var size: Int64? = nil
        if let n = name,
           let numStr = HTMLUtil.group(n, "(\\d+(?:\\.\\d+)?)\\s*(GiB|GB|MiB|MB|TB)", group: 1),
           let unitRaw = HTMLUtil.group(n, "(GiB|GB|MiB|MB|TB)") {
            let num = Double(numStr) ?? 0
            let unit = unitRaw.uppercased()
            let factor: Double
            switch unit {
            case "TB": factor = 1024 * 1024 * 1024 * 1024
            case "GIB", "GB": factor = 1024 * 1024 * 1024
            default: factor = 1024 * 1024
            }
            size = Int64(num * factor)
        }

        // .torrent 直链: torrents/download/{id}[.{hash}]
        var torrentURL: String? = nil
        var torrentName = ""
        for a in HTMLUtil.anchorText(html, hrefPattern: "torrents?/download/\\d+") {
            torrentURL = HTMLUtil.resolveURL(HTMLUtil.decodeEntities(a.href), against: base)
            if a.text.hasSuffix(".torrent") { torrentName = a.text }
            break
        }
        if torrentURL == nil,
           let m = HTMLUtil.firstMatch(html, "href=[\"']([^\"']*torrents?/download/\\d+[^\"']*)[\"']", options: .caseInsensitive) {
            torrentURL = HTMLUtil.resolveURL(HTMLUtil.decodeEntities(m), against: base)
        }

        // 禁转标记
        let markers = override?.forbidReseedMarkers ?? ["禁转", "Excl.", "excl"]
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
            kind: Self.refineKind(infer: ReleaseKind.infer(from: finalName, genre: ""), page: html),
            torrentName: torrentName.hasSuffix(".torrent") ? torrentName : torrentName + ".torrent",
            torrentURL: finalTorrentURL,
            isForbidReseed: isForbid,
            subtitle: "",
            genre: "",
            mediainfo: mediainfo,
            region: ""
        )
    }

    /// 页面分类标签（blu: torrent__category 链接文本 / monika: class="tags"）校正 kind
    static func refineKind(infer: ReleaseKind, page: String) -> ReleaseKind {
        guard let raw = HTMLUtil.group(page, "<li[^>]*class=\"[^\"]*torrent__category[^\"]*\"[^>]*>[\\s\\S]*?</li>", group: 0)
            ?? HTMLUtil.group(page, "<div[^>]*class=\"[^\"]*tags[^\"]*\"[^>]*>([\\s\\S]*?)</div>", group: 1) else {
            return infer
        }
        let label = HTMLUtil.stripTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return kindFromLabel(label) ?? infer
    }

    static func kindFromLabel(_ label: String) -> ReleaseKind? {
        let l = label.lowercased()
        if l.contains("anime") { return .anime }
        if l.contains("music") { return .music }
        if l.contains("tv") { return .series }
        if l.contains("movie") || l.contains("film") { return .movie }
        return nil
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

    /// Blu 家族无独立搜索端点；查重依赖上传时的已存在提示
    func searchExists(_ info: ReleaseInfo) throws -> String? { nil }

    // MARK: - 上传

    /// S01E01 / S1E2 等 -> (季, 集)
    static func seasonEpisode(from name: String) -> (season: Int, episode: Int)? {
        guard let m = try? NSRegularExpression(pattern: "S(\\d{1,2})[ ._-]*E(\\d{1,4})", options: .caseInsensitive),
              let hit = m.firstMatch(in: name, options: [], range: NSRange(name.startIndex..., in: name)) else { return nil }
        let s = name[Range(hit.range(at: 1), in: name)!]
        let e = name[Range(hit.range(at: 2), in: name)!]
        return (Int(s) ?? 0, Int(e) ?? 0)
    }

    /// 从站点值表取值：categoryMap(kind/profile) / qualityValueMaps(attr)[token] / "default" 兜底
    private func resolveValue(_ info: ReleaseInfo, _ attr: String) -> String? {
        let kind = info.kind?.rawValue ?? "other"
        if attr == "category" {
            guard let map = override?.categoryMap else { return nil }
            if let profile = QualityTokens.catProfile(from: info.name, kind: info.kind),
               let v = map["\(kind)/\(profile)"] { return String(v) }
            return (map[kind] ?? map["other"]).map(String.init)
        }
        guard let maps = override?.qualityValueMaps, let table = maps[attr] else { return nil }
        var token: String?
        switch attr {
        case "medium": token = QualityTokens.medium(from: info.name, kind: info.kind)
        case "standard":
            token = QualityTokens.standard(from: info.name)
            if token == nil && info.kind == .music { token = "music" }
        default: token = nil
        }
        if let token, let v = table[token] { return String(v) }
        if let v = table["default"] { return String(v) }
        return nil
    }

    /// 构建上传表单字段（hidden 含 _token；业务字段覆盖同名 hidden）
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

        // 标题（Blu 直接用解析出的发布名）
        setField("name", info.name)
        // 分类 / 媒介 / 分辨率（站点值表）
        if let v = resolveValue(info, "category") { setField("category_id", v) }
        if let v = resolveValue(info, "medium") { setField("type_id", v) }
        if let v = resolveValue(info, "standard") { setField("resolution_id", v) }
        // 季/集（剧集类）
        if info.kind == .series || info.kind == .anime || info.kind == .tvshow,
           let se = Self.seasonEpisode(from: info.name) {
            setField("season_number", String(se.season))
            setField("episode_number", String(se.episode))
        }
        // IMDb（仅当页面存在该字段：blutopia 有，monika 无）
        if let imdb = info.imdb, page.contains("name=\"imdb\"") || page.contains("name='imdb'") {
            setField("imdb", imdb)
            setField("title_exists_on_imdb", "1")
        }
        // 简介（BBCode）/ MediaInfo
        var bb = BBCode.fromHTML(info.descr, base: URL(string: site.url))
        bb = BBCode.insertMediainfo(bb, mediainfo: info.mediainfo)
        setField("description", bb)
        if !info.mediainfo.isEmpty { setField("mediainfo", info.mediainfo) }
        // 固定项
        setField("anon", "0")
        setField("personal_release", "0")
        return fields
    }

    func previewUploadFields(_ info: ReleaseInfo) throws -> [(String, String)] {
        let page = try client.fetchHTML(site.url + uploadPath, referer: site.url)
        return buildUploadFields(info, page: page).map { ($0.name, $0.value) }
    }

    private func extractUploadError(body: String, status: Int, finalURL: String) -> String {
        if let m = HTMLUtil.firstMatch(body, "(?:This torrent already exists|already exists|已存在)[^<]{0,60}") {
            return m
        }
        // Layuout 校验错误: <ul class="...error..."><li>msg</li>
        if let ul = HTMLUtil.group(body, "<ul[^>]*class=\"[^\"]*error[^\"]*\"[^>]*>([\\s\\S]*?)</ul>", group: 1),
           let li = HTMLUtil.group(ul, "<li[^>]*>([\\s\\S]*?)</li>", group: 1) {
            let t = HTMLUtil.stripTags(li).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if body.contains("<form") && (finalURL.contains("create") || finalURL.contains("upload")) {
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
        let createAction = site.url + uploadPath
        let uploadURL = site.url + uploadAction
        let page = try client.fetchHTML(createAction, referer: site.url)
        let fields = buildUploadFields(info, page: page)

        let resp = try client.postMultipart(
            uploadURL,
            fields: fields,
            files: [(name: fileField, filename: filename, data: torrentData, mime: "application/x-bittorrent")],
            referer: createAction
        )

        let finalURL = resp.finalURL.lowercased()
        let body = String(data: resp.data, encoding: .utf8) ?? ""
        // 成功: 跳转到新种子详情页 /torrents/{id}（monika 同构）
        if let m = HTMLUtil.firstMatch(finalURL, "(?:/torrents?/\\d+)") {
            let u = URL(string: uploadURL)!
            return UploadOutcome(success: true, message: "发布成功",
                                 detailURL: HTMLUtil.resolveURL(m, against: u))
        }
        if resp.status == 200, body.contains("Torrent was added") || body.contains("发布成功") {
            return UploadOutcome(success: true, message: "发布成功", detailURL: nil)
        }
        var errMsg = extractUploadError(body: body, status: resp.status, finalURL: finalURL)
        if let p = dumpDebugHTML(body) { errMsg += "（页面已存 \(p)）" }
        let msg = HTMLUtil.stripTags(errMsg)
        if msg.contains("已存在") || msg.lowercased().contains("already exists") {
            return UploadOutcome(success: true, message: "站点已存在该种子（查重兜底命中）", detailURL: nil)
        }
        return UploadOutcome(success: false, message: msg, detailURL: nil)
    }
}
