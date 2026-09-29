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

    var uploadPath: String { override?.uploadPath ?? "upload.php" }
    var uploadAction: String {
        let a = override?.uploadActionPath ?? uploadPath
        return a.hasPrefix("/") ? String(a.dropFirst()) : a
    }
    var titleField: String { override?.titleField ?? "title" }
    var descrField: String { override?.descrField ?? "descr" }
    var imdbField: String { override?.imdbField ?? "imdbid" }
    var categoryField: String { override?.categoryField ?? "category" }
    var fileField: String { override?.fileField ?? "file" }
    var listPath: String { "torrents.php" }

    // MARK: - 详情解析

    func fetchDetail(detailURL: String) throws -> ReleaseInfo {
        let html = try client.fetchHTML(detailURL, referer: site.url)
        return try parseDetail(html: html, detailURL: detailURL)
    }

    /// 纯解析（供测试与复用）
    func parseDetail(html: String, detailURL: String) throws -> ReleaseInfo {
        let base = URL(string: detailURL) ?? URL(string: site.url)!

        // 标题: 1) <h1 id="top">（LuckPT 等改版 NexusPHP）
        //       2) #hdarea 内第一个链接（经典 NexusPHP）
        //       3) <title> 清洗（"站名 :: 种子详情 \"X\" - Powered by NexusPHP" -> X）
        var name: String?
        if let h1 = HTMLUtil.group(html, "<h1[^>]*id=[\"']top[\"'][^>]*>(.*?)</h1>",
                                   group: 1, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            var t = h1.replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
            if let cut = t.firstIndex(of: "<") { t = String(t[t.startIndex..<cut]) }
            t = HTMLUtil.stripTags(t).trimmingCharacters(in: .whitespacesAndNewlines)
            t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if !t.isEmpty { name = t }
        }
        if name == nil {
            name = HTMLUtil.group(html, "<div[^>]*id=[\"']hdarea[\"'][^>]*>.*?<a[^>]*>(.*?)</a>",
                                  group: 1, options: [.dotMatchesLineSeparators, .caseInsensitive])
                .map { HTMLUtil.stripTags($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if name == nil, let raw = HTMLUtil.group(html, "<title>(.*?)</title>", group: 1, options: [.dotMatchesLineSeparators]) {
            var t = HTMLUtil.stripTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if let m = try? NSRegularExpression(pattern: "种子详情\\s*[\"“]\\s*(.+?)\\s*[\"”]"),
               let hit = m.firstMatch(in: t, options: [], range: NSRange(t.startIndex..., in: t)) {
                t = String(t[Range(hit.range(at: 1), in: t)!])
            } else {
                t = t.replacingOccurrences(of: "^.*?种子详情\\s*", with: "", options: .regularExpression)
                t = t.replacingOccurrences(of: "\\s*-\\s*Powered by NexusPHP.*$", with: "", options: .regularExpression)
            }
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”' ")).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { name = t }
        }

        // 简介: #kdescr / #largedescribe（配对 div，支持嵌套）
        let descr = HTMLUtil.divContent(html, id: "kdescr")
            ?? HTMLUtil.divContent(html, id: "largedescribe")
            ?? HTMLUtil.group(html, "<div[^>]*id=[\"'](descr|description)[\"'][^>]*>(.*?)</div>", group: 2, options: [.dotMatchesLineSeparators, .caseInsensitive])
            ?? ""

        // 副标题（译名）与类别：从简介纯文本的 "❁ 译　　名:　X" / "❁ 类　　别:　X" 行提取
        let plain = HTMLUtil.stripTags(descr)
        // 副标题：优先详情页"副标题"行（完整内容），回退简介"译名"行
        var subtitle = Self.detailRowValue(html, label: "副标题") ?? ""
        if subtitle.isEmpty { subtitle = Self.lineValue(plain, prefix: "译", suffix: "名") ?? "" }
        let genre = Self.lineValue(plain, prefix: "类", suffix: "别") ?? ""
        let region = Self.lineValue(plain, prefix: "产", suffix: "地") ?? ""

        // MediaInfo / BDInfo：源页 <pre> 块（含 Unique ID / DISC TITLE 特征）
        var mediainfo = ""
        for pre in HTMLUtil.allMatches(html, "<pre[^>]*>(.*?)</pre>", options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            var t = HTMLUtil.stripTags(pre).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.contains("Unique ID") || t.contains("DISC TITLE") || (t.contains("Format") && t.contains("Duration")) {
                // 源页 CRLF：统一换行并压缩多空行（与简介 BBCode 一致，最多 1 个空行）
                t = t.replacingOccurrences(of: "\r\n", with: "\n", options: [])
                t = t.replacingOccurrences(of: "\r", with: "\n", options: [])
                t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                mediainfo = t
                break
            }
        }

        // 外链信息
        let imdb = HTMLUtil.firstMatch(descr, "tt\\d{5,13}")
        let douban = HTMLUtil.group(descr, "douban\\.com/subject/(\\d+)")

        // 大小: 名称中的 GiB/MiB/GB/MB 标记（下载 .torrent 后由流水线用 bencode 校正）
        var size: Int64? = nil
        if let n = name, let m = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*(GiB|GB|MiB|MB|TB)", options: .caseInsensitive),
           m.firstMatch(in: n, options: [], range: NSRange(n.startIndex..., in: n)) != nil {
            let num = Double(HTMLUtil.group(n, "(\\d+(?:\\.\\d+)?)\\s*(GiB|GB|MiB|MB|TB)", group: 1) ?? "0") ?? 0
            let unit = (HTMLUtil.group(n, "(GiB|GB|MiB|MB|TB)", group: 1) ?? "").uppercased()
            let factor: Double
            switch unit {
            case "TB": factor = 1024 * 1024 * 1024 * 1024
            case "GIB", "GB": factor = 1024 * 1024 * 1024
            default: factor = 1024 * 1024
            }
            size = Int64(num * factor)
        }

        // .torrent 下载直链：1) 文本含关键词的 download.php 锚点；2) 下载表单（HDSky：form action + submit value=文件名）；兜底：任意含 download.php 的 href
        var torrentURL: String? = nil
        var torrentName = ""
        func cleanURL(_ r: String) -> String {
            HTMLUtil.resolveURL(HTMLUtil.decodeEntities(r), against: base)
        }
        for a in HTMLUtil.anchorText(html, hrefPattern: "download.php") {
            let t = a.text.lowercased()
            if t.contains("torrent") || t.contains("种子") || t.contains("下载") {
                torrentName = a.text
                torrentURL = cleanURL(a.href)
                break
            }
        }
        if torrentURL == nil {
            let formRe = try? NSRegularExpression(pattern: "<form[^>]*action=[\"']([^\"']*download\\.php[^\"']*)[\"'][^>]*>(.*?)</form>", options: [.caseInsensitive, .dotMatchesLineSeparators])
            if let m = formRe?.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)) {
                torrentURL = cleanURL(String(html[Range(m.range(at: 1), in: html)!]))
                let body = String(html[Range(m.range(at: 2), in: html)!])
                if let v = HTMLUtil.group(body, "<input[^>]*value=[\"']([^\"']*)[\"']") {
                    torrentName = HTMLUtil.decodeEntities(v)
                }
            }
        }
        if torrentURL == nil {
            // 逐属性取 href 值再匹配（避免跨属性误匹配拼出坏 URL）
            for v in HTMLUtil.allMatches(html, "href=[\"']([^\']+)[\"']", options: .caseInsensitive) where v.contains("download.php") {
                torrentURL = cleanURL(v)
                break
            }
            if torrentURL != nil { torrentName = "\(site.id).torrent" }
        }

        // 禁转标记
        let markers = override?.forbidReseedMarkers ?? ["禁转", "Excl.", "excl"]
        let pageHead = String(html.prefix(3000))
        let isForbid = markers.contains { m in plain.contains(m) || pageHead.lowercased().contains(m.lowercased()) }

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
            descr: descr,
            imdb: imdb,
            douban: douban,
            size: size,
            kind: ReleaseKind.infer(from: finalName, genre: genre),
            torrentName: torrentName.hasSuffix(".torrent") ? torrentName : torrentName + ".torrent",
            torrentURL: finalTorrentURL,
            isForbidReseed: isForbid,
            subtitle: subtitle,
            genre: genre,
            mediainfo: mediainfo,
            region: region
        )
    }

    /// 提取 "❁ 译　　名:　X" 风格的行值（prefix/suffix 之间容忍全角空格，如 ("译","名") / ("类","别")）
    static func lineValue(_ text: String, prefix: String, suffix: String) -> String? {
        let pfx = NSRegularExpression.escapedPattern(for: prefix)
        let sfx = NSRegularExpression.escapedPattern(for: suffix)
        let pattern = "(?:^|\\n)[^\\n]*\(pfx)[\\s　]{0,8}\(sfx)[\\s　]{0,4}[:：][\\s　]{0,4}([^\\n]+)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range), m.numberOfRanges > 1 else { return nil }
        let v = text[Range(m.range(at: 1), in: text)!]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \u{3000}：:"))
        return v.isEmpty ? nil : String(v)
    }

    /// 详情页表格行取值：<tr><td>标签</td><td>值</td></tr>（如 副标题 行，值可能含 | 分隔的完整副标题）
    static func detailRowValue(_ html: String, label: String) -> String? {
        let pattern = "<tr[^>]*>\\s*<td[^>]*>\\s*\(NSRegularExpression.escapedPattern(for: label))\\s*</td>\\s*<td[^>]*>(.*?)</td>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)) else { return nil }
        let raw = String(html[Range(m.range(at: 1), in: html)!])
        let t = HTMLUtil.stripTags(HTMLUtil.decodeEntities(raw))
            .replacingOccurrences(of: "[ \\t　 ]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 简介清洗（HTML 格式目标站用）：
    /// 1. 源站域名链接 -> 纯文本；2. 保留 <img> 的 src 绝对化；3. 去掉脚本/样式/多余空行。
    func cleanDescription(_ html: String, sourceHost: String) -> String {
        var s = html
        s = HTMLUtil.replaceMatches(s, "<(script|style)[^>]*>.*?</\\1>",
                           options: [.dotMatchesLineSeparators, .caseInsensitive]) { _ in "" }
        // 源站内部链接转文本
        let host = (try? URL(string: sourceHost)?.host()) ?? sourceHost
        let hostPat = NSRegularExpression.escapedPattern(for: host.split(separator: ".").joined(separator: "\\.?"))
        let re = try! NSRegularExpression(pattern: "<a\\s[^>]*href=[\"'](?:https?://)?(?:www\\.)?\(hostPat)(?:/[^\"']*)?[\"'][^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators, .caseInsensitive])
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
        // 校验是有效 bencode 且含 info（防止误抓 HTML 页面，如下载链接过期/失效时）
        guard Bencode.infoHash(resp.data) != nil else {
            let head = String(data: resp.data.prefix(80), encoding: .utf8) ?? ""
            throw BoxSendError.badInput(".torrent 不是有效 bencode（\(resp.data.count) bytes，开头: \(head)），可能 cookie 失效或下载链接错误: \(info.torrentURL)")
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
        // 无结果特征（早退；最终判定以名称匹配为准）
        let noResultMarkers = ["No torrents found", "没有种子", "没有相关", "no results", "No torrents"]
        if noResultMarkers.contains(where: { html.contains($0) }) { return nil }
        // 结果行 = 详情链接的锚文本（各站搜索结果名称在 <a href="details.php?id=..">名称</a> 内）
        guard let hit = Self.searchNameInResults(html: html, releaseName: info.name, base: URL(string: url)!) else {
            return nil
        }
        return hit.href
    }

    /// 搜索结果页里按名称匹配已存在种子：任一结果行的归一化名称与发布名互含即命中
    static func searchNameInResults(html: String, releaseName: String, base: URL) -> (href: String, text: String)? {
        let anchors = HTMLUtil.anchorText(html, hrefPattern: "details\\.php\\?id=|/torrents\\.php\\?id=")
        guard !anchors.isEmpty else { return nil }
        let target = normalizeSearchName(releaseName)
        guard target.count >= 8 else { return nil }
        for a in anchors {
            let cand = normalizeSearchName(a.text)
            guard cand.count >= 8 else { continue }
            if cand.contains(target) || (target.count >= 15 && target.contains(cand)) {
                return (HTMLUtil.decodeEntities(a.href), a.text)
            }
        }
        return nil
    }

    /// 搜索名称归一化：去标签/实体、小写、只留字母数字（CJK 按字母保留）
    static func normalizeSearchName(_ s: String) -> String {
        let t = HTMLUtil.decodeEntities(HTMLUtil.stripTags(s)).lowercased()
        return String(t.filter { $0.isLetter || $0.isNumber })
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

    /// 分类命中结果：提交值 + 所属下拉的 data-mode（新版 NexusPHP 质量下拉按 mode 索引）
    struct CategoryHit { let value: String; let mode: String? }

    /// 分类值解析：1) 静态 Int 表 2) 静态字符串表（影 站）3) 动态解析上传页 <select>（新站免配置）
    /// 4) ajax 动态分类（xingtan：type 下拉由 JS 异步生成）
    private func resolveCategory(_ info: ReleaseInfo, page: String) -> CategoryHit? {
        let kind = info.kind?.rawValue ?? "other"
        let profile = QualityTokens.catProfile(from: info.name, kind: info.kind)
        let groups = HTMLUtil.selectGroups(page, name: categoryField)
        // 静态表：值需落在某个下拉选项里（多个 type 下拉时定位所属组）
        var staticValue: String?
        if let map = override?.categoryMap {
            if let profile, let v = map["\(kind)/\(profile)"] { staticValue = String(v) }
            if staticValue == nil, let v = map[kind] ?? map["other"] { staticValue = String(v) }
        }
        if staticValue == nil, let map = override?.categoryStringMap {
            if let profile, let v = map["\(kind)/\(profile)"] { staticValue = v }
            if staticValue == nil, let v = map[kind] ?? map["other"] { staticValue = v }
        }
        if let v = staticValue {
            if let g = groups.first(where: { $0.options.contains(where: { $0.value == v }) }) {
                return CategoryHit(value: v, mode: g.mode)
            }
            return CategoryHit(value: v, mode: groups.first?.mode)
        }
        // 动态关键词（跨全部 type 下拉）
        for g in groups {
            for (k, keywords) in Self.kindKeywords {
                guard k == kind || (k == "other" && kind == "other") else { continue }
                for kw in keywords {
                    if let hit = g.options.first(where: { $0.label.lowercased().contains(kw) }) {
                        return CategoryHit(value: hit.value, mode: g.mode)
                    }
                }
            }
        }
        // ajax 动态分类（页面无 type 下拉时）
        if groups.isEmpty, let modes = override?.ajaxCategoryModes {
            guard let topMode = modes[kind] ?? modes["other"] else { return nil }
            if let direct = override?.ajaxCategorySubMap?[kind] ?? override?.ajaxCategorySubMap?["other"] {
                return CategoryHit(value: String(direct), mode: String(topMode))
            }
            let path = override?.ajaxCategoryPath ?? "ajax.php"
            if let list = fetchAjaxCategories(path: path, mode: topMode) {
                if let kw = override?.ajaxCategoryKeywords?[kind] ?? override?.ajaxCategoryKeywords?["other"],
                   let hit = list.first(where: { $0.name.lowercased().contains(kw.lowercased()) }) {
                    return CategoryHit(value: hit.id, mode: String(topMode))
                }
                if let kws = Self.kindKeywords.first(where: { $0.0 == kind })?.1,
                   let hit = list.first(where: { n in kws.contains { n.name.lowercased().contains($0.lowercased()) } }) {
                    return CategoryHit(value: hit.id, mode: String(topMode))
                }
                if let first = list.first { return CategoryHit(value: first.id, mode: String(topMode)) }
            }
        }
        return nil
    }

    /// 拉取 ajax 动态分类（xingtan: POST action=getCategories&params[mode]=N&params[keyword]=）
    private func fetchAjaxCategories(path: String, mode: Int) -> [(id: String, name: String)]? {
        let url = site.url + path
        guard let res = try? client.postForm(url, fields: ["action": "getCategories", "params[mode]": String(mode), "params[keyword]": ""], referer: site.url) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: res.data) as? [String: Any],
              (obj["ret"] as? Int) == 0,
              let arr = obj["data"] as? [[String: Any]] else { return nil }
        return arr.compactMap { x in
            guard let id = x["id"] as? String, let name = x["name"] as? String else { return nil }
            return (id, name)
        }
    }

    /// 源介质下拉（tr_source 型：值依赖 medium+standard 组合，如 BD Remux 1080 vs UHD Remux 2160）
    private func applySourceSelect(_ info: ReleaseInfo, _ set: (String, String) -> Void) {
        guard let field = override?.sourceSelectField, let map = override?.sourceMap else { return }
        let medium = QualityTokens.medium(from: info.name, kind: info.kind)
        let standard = QualityTokens.standard(from: info.name)
        if let medium, let standard, let v = map["\(medium)/\(standard)"] { set(field, v); return }
        if let medium, let v = map[medium] { set(field, v) }
    }

    /// 类型 -> 分类选项关键词（顺序 = 优先级；命中任一即返回）
    static let kindKeywords: [(String, [String])] = [
        ("anime", ["动漫", "动画", "anime", "animation"]),
        ("documentary", ["纪录片", "documentary", "doc "]),
        ("music", ["音乐", "music", "hq audio"]),
        ("series", ["剧集", "series", "tv"]),
        ("tvshow", ["综艺", "tv show", "show"]),
        ("movie", ["电影", "movie", "film"]),
        ("other", ["其他", "other"]),
    ]

    private func applyQualitySelects(_ info: ReleaseInfo, page: String, mode: String?, _ set: (String, String) -> Void) {
        let tokens: [String: String?] = [
            "medium": QualityTokens.medium(from: info.name, kind: info.kind),
            "codec": QualityTokens.codec(from: info.name),
            "audiocodec": QualityTokens.audio(from: info.name),
            "standard": QualityTokens.standard(from: info.name),
        ]
        // 显式表优先（个别站字段名/值特殊）
        if let selects = override?.qualitySelects {
            for (field, attr) in selects {
                guard let token = tokens[attr].flatMap({ $0 }) else { continue }
                if let v = override?.qualityValueMaps?[attr]?[token] { set(field, String(v)); continue }
                if let v = override?.qualityStringMaps?[attr]?[token] { set(field, v); continue }
            }
        }
        // 动态填充：标准字段名（新版 NexusPHP 为 xxx_sel[mode] 数组式，旧版为裸 xxx_sel）
        func tok(_ k: String) -> String? { tokens[k].flatMap { $0 } }
        let dyn: [(base: String, attr: String, token: String?)] = [
            ("medium_sel", "medium", tok("medium")),
            ("codec_sel", "codec", tok("codec")),
            ("standard_sel", "standard", tok("standard")),
            ("audiocodec_sel", "audiocodec", tok("audiocodec")),
            ("source_sel", "medium", tok("medium")),
        ]
        let explicitFields = Set(override?.qualitySelects?.keys.sorted() ?? [])
        for d in dyn {
            var candidates: [String] = []
            if let mode { candidates.append("\(d.base)[\(mode)]") }
            candidates.append(d.base)
            candidates = candidates.filter { !explicitFields.contains($0) }
            for name in candidates {
                let groups = HTMLUtil.selectGroups(page, name: name)
                guard !groups.isEmpty else { continue }
                var done = false
                if let token = d.token,
                   let v = QualityMatcher.match(token: token, attr: d.attr, options: groups[0].options) {
                    set(name, v)
                    done = true
                }
                // 个别站 codec 下拉实为年份（ggpt）：按发布名年份匹配
                if !done, d.attr == "codec",
                   let year = QualityTokens.year(from: info.name),
                   let v = QualityMatcher.matchYear(year, options: groups[0].options) {
                    set(name, v)
                    done = true
                }
                if done { break }
            }
        }
    }

    /// 简介按目标站格式生成：bbcode（中文站默认）或 html
    private func buildDescription(_ info: ReleaseInfo) -> String {
        let format = override?.descrFormat ?? "bbcode"
        guard format == "bbcode" else {
            return cleanDescription(info.descr, sourceHost: site.url)
        }
        let base = URL(string: site.url)
        var out = BBCode.fromHTML(info.descr, base: base)
        out = BBCode.insertMediainfo(out, mediainfo: info.mediainfo)
        return out
    }

    /// 规范标签判定（源名 + 简介 + mediainfo 文本证据）
    private func canonicalTags(_ info: ReleaseInfo) -> [String] {
        var tags: [String] = []
        let n = info.name.uppercased()
        let evidence = HTMLUtil.stripTags(info.descr) + "\n" + info.mediainfo + "\n" + info.subtitle
        if n.contains("DTS:X") || n.contains("DTS X") { tags.append("dtsx") }
        if n.contains("ATMOS") { tags.append("atmos") }
        if n.contains("HDR10+") { tags.append("hdr10plus") }
        else if n.contains("HDR10") { tags.append("hdr10") }
        if n.contains("DOVI") || n.contains("DOLBY VISION") { tags.append("dovi") }
        if evidence.contains("中文字幕") || evidence.contains("简体") || evidence.contains("繁体") || evidence.contains("中文") || info.name.contains("中字") {
            tags.append("chinese_sub")
        }
        if n.contains("DIY") && (n.hasPrefix("DIY") || n.contains(" DIY") || n.contains("DIY ") || n.contains("DIY-")) {
            tags.append("diy")
        }
        if ["bluray", "uhdbd", "uhdbd8k"].contains(QualityTokens.medium(from: info.name, kind: info.kind)) {
            tags.append("disc")
        }
        if info.isForbidReseed { tags.append("forbid") }
        if evidence.contains("限转") { tags.append("limited") }
        return tags
    }

    /// 动态标签：解析页面 tags 类复选框，按文案匹配规范标签后提交（新站免逐站配置）
    private func dynamicTagValues(_ info: ReleaseInfo, page: String) -> [(name: String, value: String)] {
        let boxes = HTMLUtil.checkboxes(page)
        func allowed(_ n: String) -> Bool {
            let base = n.replacingOccurrences(of: #"[\d]+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            return base.contains("tag") || base == "chinese" || base == "exclusive"
        }
        let cbs = boxes.filter { allowed($0.name) }
        // 规范标签 -> 标签文案关键词（顺序 = 优先级；atmos 先于 dovi 避免"杜比全景声"误判）
        let table: [(tag: String, keywords: [String])] = [
            ("atmos", ["atmos", "全景声"]),
            ("dovi", ["dovi", "杜比视界", "杜比视频", "杜比"]),
            ("hdr10plus", ["hdr10+", "hdrm"]),
            ("hdr10", ["hdr10", "hdr"]),
            ("dtsx", ["dtsx", "dts:x"]),
            ("chinese_sub", ["中字", "中文字幕", "zz", "简中"]),
            ("forbid", ["禁转", "禁止转载", "jz"]),
            ("limited", ["限转", "xz"]),
            ("diy", ["diy", "自压"]),
            ("first", ["首发"]),
            ("disc", ["原盘"]),
        ]
        let tags = canonicalTags(info)
        var out: [(String, String)] = []
        for (tag, keywords) in table {
            guard tags.contains(tag) else { continue }
            guard let hit = cbs.first(where: { box in
                let label = box.label.lowercased()
                return keywords.contains { label.contains($0) }
            }) else { continue }
            out.append((hit.name, hit.value))
        }
        return out
    }

    /// 制作组：种子名最后一个 "-" 后的发布组名匹配 teamPatterns（长名优先）；未知 -> teamOtherValue
    private func resolveTeam(_ info: ReleaseInfo) -> Int? {
        guard let ov = override, ov.teamField != nil else { return nil }
        var group = info.name
        if let i = group.lastIndex(of: "-") {
            group = String(group[group.index(after: i)...])
        }
        group = group.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let pats = ov.teamPatterns {
            for (k, v) in pats.sorted(by: { $0.key.count > $1.key.count }) {
                if group.contains(k.uppercased()) { return v }
            }
        }
        return ov.teamOtherValue
    }

    /// 构建上传表单字段（业务字段覆盖同名 hidden；标签字段同名多次追加在末尾）
    func buildUploadFields(_ info: ReleaseInfo, page: String) -> [HTTPClient.MultipartField] {
        // 抓取所有 hidden 字段（含 passkey/n_id 等站点 token）
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

        // 业务字段
        setField(titleField, resolvedTitle(info))
        if let f = override?.subtitleField, !info.subtitle.isEmpty {
            setField(f, info.subtitle)
        }
        // 新版 NexusPHP 有独立 MediaInfo 文本域时不内嵌进简介（详情页分开渲染）
        let taNames = Set(HTMLUtil.textareaNames(page))
        if taNames.contains("technical_info"), !info.mediainfo.isEmpty {
            setField("technical_info", info.mediainfo)
            setField(descrField, cleanDescription(info.descr, sourceHost: site.url))
        } else if taNames.contains("media_info"), !info.mediainfo.isEmpty {
            setField("media_info", info.mediainfo)
            setField(descrField, cleanDescription(info.descr, sourceHost: site.url))
        } else {
            setField(descrField, buildDescription(info))
        }
        if let imdb = info.imdb {
            let tmpl = override?.imdbValueTemplate ?? "{imdb}"
            setField(imdbField, tmpl.replacingOccurrences(of: "{imdb}", with: imdb))
        }
        if let doubanField = override?.doubanField, let douban = info.douban {
            let tmpl = override?.doubanValueTemplate ?? "{douban}"
            setField(doubanField, tmpl.replacingOccurrences(of: "{douban}", with: douban))
        }
        // 分类（支持质量型键 "<kind>/<profile>"，字符串表与动态解析；多下拉时定位 mode）
        var catMode: String?
        if let hit = resolveCategory(info, page: page) {
            setField(categoryField, hit.value)
            catMode = hit.mode
        }
        // 质量下拉（medium/codec/audiocodec/standard）+ 源介质组合下拉
        applyQualitySelects(info, page: page, mode: catMode, setField)
        applySourceSelect(info, setField)
        // 额外固定字段
        for (k, v) in (override?.extraUploadFields ?? [:]) {
            setField(k, v)
        }
        // 常见可选字段的默认值（不影响大多数站）
        setField("nfo", "")
        setField("anonymous", "1")
        // 标签（同名多次）
        if let tagField = override?.tagField, let map = override?.tagMap {
            for tag in canonicalTags(info) {
                if let v = map[tag] { fields.append(.init(tagField, v)) }
            }
        }
        // 独立复选框标签（chdbits 等：cnsub=yes）
        if let box = override?.tagCheckboxes {
            for tag in canonicalTags(info) {
                if let f = box[tag] { setField(f, "yes") }
            }
        }
        // 动态标签：无显式标签配置时按页面 tags 复选框文案匹配（新站免逐站配置）
        if override?.tagField == nil && override?.tagCheckboxes == nil {
            for (tag, value) in dynamicTagValues(info, page: page) {
                fields.append(.init(tag, value))
            }
        }
        // 制作组
        if let teamField = override?.teamField, let v = resolveTeam(info) {
            setField(teamField, String(v))
        }
        // 地区（个别站该下拉实为产地）
        if let rf = override?.regionField, !info.region.isEmpty,
           let patterns = override?.regionPatterns {
            var val = override?.regionOtherValue
            for (k, v) in patterns.sorted(by: { $0.key.count > $1.key.count }) where info.region.contains(k) {
                val = v
                break
            }
            if let val { setField(rf, String(val)) }
        }
        return fields
    }

    /// 上传字段预览（CLI info --preview 用）
    func previewUploadFields(_ info: ReleaseInfo) throws -> [(String, String)] {
        let page = try client.fetchHTML(site.url + uploadPath, referer: site.url)
        return buildUploadFields(info, page: page).map { ($0.name, $0.value) }
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
        let fields = buildUploadFields(info, page: page)

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
        let msg = HTMLUtil.stripTags(errMsg)
        // 站点提示同名/同 hash 种子已存在（如手动转过）：视为成功，不再重复发种
        if msg.contains("已存在") || msg.lowercased().contains("already exists") {
            return UploadOutcome(success: true, message: "站点已存在该种子（查重兜底命中）", detailURL: nil)
        }
        return UploadOutcome(success: false, message: msg, detailURL: nil)
    }
}
