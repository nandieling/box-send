import Foundation

/// NexusPHP 家族适配器（覆盖 9 个优先站 + 大多数中文站）。
/// 通用逻辑 + SiteOverride 站点差异。
class NexusPHPAdapter: SiteAdapter {
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
        var html = try client.fetchHTML(detailURL, referer: site.url)
        // 新版 NexusPHP 主题（LuckPT 等）：details.php 默认返回列表页，
        // 需追加 ajax=1 才返回经典详情页（含 kdescr/副标题/mediainfo）
        if !Self.looksLikeDetailPage(html), let alt = Self.detailURLWithAjax(detailURL),
           let again = try? client.fetchHTML(alt, referer: site.url),
           Self.looksLikeDetailPage(again) {
            html = again
        }
        return try parseDetail(html: html, detailURL: detailURL)
    }

    /// 页面是否为详情页（含任一详情容器）。用于识别新主题站点“返回列表页”的行为。
    static func looksLikeDetailPage(_ html: String) -> Bool {
        for id in ["kdescr", "largedescribe", "hdarea", "top"] {
            if html.contains("id=\"\(id)\"") || html.contains("id='\(id)'") {
                return true
            }
        }
        return false
    }

    /// 为详情 URL 追加 ajax=1（details.php / torrents.php 且尚无 ajax 参数）
    static func detailURLWithAjax(_ url: String) -> String? {
        guard url.contains("details.php") || url.contains("torrents.php") else { return nil }
        guard !url.contains("ajax=") else { return nil }
        return url + (url.contains("?") ? "&" : "?") + "ajax=1"
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
        if name == nil {
            // 新版式（LuckPT 等）：页面无 h1/#hdarea，标题在 id 匹配的详情锚点内
            // <a title="名称" href="details.php?id=N"><b>名称</b></a>
            if let idStr = HTMLUtil.group(detailURL, "id=(\\d+)", group: 1), let id = Int(idStr), id > 100 {
                for a in HTMLUtil.anchorText(html, hrefPattern: "details\\.php\\?id=\(id)(?![0-9])|/torrents\\.php\\?id=\(id)(?![0-9])") {
                    let t = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.count > 2 { name = t; break }
                }
            }
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

        // 部分站点（城市）标题只在 <title> 里，且带品牌后缀
        if name != nil, let strip = override?.titleStrip {
            let cleaned = name!.replacingOccurrences(of: strip, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { name = cleaned }
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
        var genre = Self.lineValue(plain, prefix: "类", suffix: "别")
            ?? Self.lineValue(plain, prefix: "类", suffix: "型") ?? ""
        if genre.isEmpty,
           let v = HTMLUtil.group(html, "<b[^>]*>\\s*类型\\s*[:：]\\s*</b>([^<]{1,40})", group: 1, options: [.caseInsensitive]) {
            let t = HTMLUtil.stripTags(HTMLUtil.decodeEntities(v))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { genre = t }
        }
        let region = Self.lineValue(plain, prefix: "产", suffix: "地") ?? ""
        let sourceTags = Self.sourceTags(fromHTML: html)

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
        var tmdb: String? = nil
        if let re = try? NSRegularExpression(pattern: "themoviedb\\.org/(movie|tv)/(\\d+)", options: .caseInsensitive),
           let m = re.firstMatch(in: descr, options: [], range: NSRange(descr.startIndex..., in: descr)),
           m.numberOfRanges >= 3 {
            let kind = String(descr[Range(m.range(at: 1), in: descr)!])
            let id = String(descr[Range(m.range(at: 2), in: descr)!])
            tmdb = "https://www.themoviedb.org/\(kind)/\(id)"
        }

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

        // .torrent 下载直链：
        // 1) href 同时含 download 与当前详情页 id 的锚点（最可靠，不受版式改版影响）
        // 2) 文本含关键词的 download.php 锚点；3) 纯图标的 download.php 锚点（新版式锚内只有 <img>）
        // 4) 下载表单（HDSky）；5) torrentLinkPattern；兜底：任意含 download.php 的 href
        var torrentURL: String? = nil
        var torrentName = ""
        func cleanURL(_ r: String) -> String {
            HTMLUtil.resolveURL(HTMLUtil.decodeEntities(r), against: base)
        }
        if let idStr = HTMLUtil.group(detailURL, "id=(\\d+)", group: 1), let id = Int(idStr), id > 100 {
            for a in HTMLUtil.anchorText(html, hrefPattern: "download") where a.href.contains("id=\(id)") {
                let t = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.lowercased().hasPrefix("http") { continue }   // 文本是 URL 本身（直链展示锚），不是下载入口
                torrentName = t
                torrentURL = cleanURL(a.href)
                break
            }
        }
        if torrentURL == nil {
            for a in HTMLUtil.anchorText(html, hrefPattern: "download\\.php") {
                let t = a.text.lowercased()
                if a.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http") { continue }
                if t.contains("torrent") || t.contains("种子") || t.contains("下载") {
                    torrentName = a.text
                    torrentURL = cleanURL(a.href)
                    break
                }
            }
        }
        if torrentURL == nil {
            for a in HTMLUtil.anchorText(html, hrefPattern: "download\\.php") where a.text.isEmpty {
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
        if torrentURL == nil, let pat = override?.torrentLinkPattern,
           let hrefRe = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
            // 站点自定义 .torrent 链接形态（如 Unit3D /torrents/download/123）
            for v in HTMLUtil.allMatches(html, "href=[\"']([^\"']+)[\"']", options: .caseInsensitive) {
                let url = String(v.dropFirst(6).dropLast(1))   // 去掉 href=" 外壳，取真实 URL
                let r = NSRange(url.startIndex..., in: url)
                if hrefRe.firstMatch(in: url, options: [], range: r) != nil {
                    torrentURL = cleanURL(url)
                    break
                }
            }
        }
        if torrentURL == nil {
            // 逐属性取 href 值再匹配（避免跨属性误匹配拼出坏 URL；双引号属性值内出现单引号时不能跨属性吞 HTML）
            for v in HTMLUtil.allMatches(html, "href=[\"']([^\"']+)[\"']", options: .caseInsensitive) where v.contains("download.php") {
                torrentURL = cleanURL(String(v.dropFirst(6).dropLast(1)))
                break
            }
            if torrentURL != nil { torrentName = "\(site.id).torrent" }
        }

        // 禁转标记
        let markers = override?.forbidReseedMarkers ?? ["禁转", "Excl.", "excl"]
        let pageHead = String(html.prefix(3000))
        let isForbid = markers.contains { m in plain.contains(m) || pageHead.lowercased().contains(m.lowercased()) }

        // cookie 失效时详情页会被弹回登录页，报错要说清楚（否则只看到「解析不到标题」）
        if name == nil && NexusPHPAdapter.isLoginPage(html) {
            throw BoxSendError.badInput("会话失效（站点返回登录页），请重新同步 \(site.name) 的 cookie")
        }
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
            tmdb: tmdb,
            size: size,
            kind: ReleaseKind.infer(from: finalName, genre: genre),
            torrentName: torrentName.hasSuffix(".torrent") ? torrentName : torrentName + ".torrent",
            torrentURL: finalTorrentURL,
            isForbidReseed: isForbid,
            subtitle: subtitle,
            genre: genre,
            mediainfo: mediainfo,
            region: region,
            sourceName: override?.sourceLabel ?? site.name,
            sourceTags: sourceTags
        )
    }

    /// 提取 "❁ 译　　名:　X" 风格的行值（prefix/suffix 之间容忍全角空格，如 ("译","名") / ("类","别")；
    /// 冒号可选——"◎类　　别　　X"（无冒号）与 "❁ 类　　别: X" 均支持，无冒号时值前需至少一个空格）
    static func lineValue(_ text: String, prefix: String, suffix: String) -> String? {
        let pfx = NSRegularExpression.escapedPattern(for: prefix)
        let sfx = NSRegularExpression.escapedPattern(for: suffix)
        let pattern = "(?:^|\\n)[^\\n]*\(pfx)[\\s　]{0,8}\(sfx)(?::[\\s　]{0,4}|[\\s　]{1,4})([^\\n]+)"
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

    /// 详情页"标签"行的标签列表（NexusPHP 用彩色 <span> 逐个展示，去标签后会连成一片，必须逐节点取）
    static func sourceTags(fromHTML html: String) -> [String] {
        let pattern = "<tr[^>]*>\\s*<td[^>]*>\\s*标签\\s*</td>\\s*<td[^>]*>(.*?)</td>"
        guard let cell = HTMLUtil.group(html, pattern, group: 1,
                                        options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        var out: [String] = []
        func add(_ fragment: String) {
            let t = HTMLUtil.stripTags(HTMLUtil.decodeEntities(fragment))
                .replacingOccurrences(of: "[\\s　]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.count <= 20 else { return }
            for piece in t.components(separatedBy: CharacterSet(charactersIn: " |、,，;；·")) where !piece.isEmpty {
                if !out.contains(piece) { out.append(piece) }
            }
        }
        var matched = false
        for pat in ["<span[^>]*>(.*?)</span>", "<a[^>]*>(.*?)</a>"] {
            for node in HTMLUtil.allMatches(cell, pat, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
                add(node)
                matched = true
            }
        }
        if !matched { add(cell) }
        return out
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

    /// 下载 .torrent 却拿回 HTML 提示页时，提取页面正文里最像原因的一句话（待审核/未通过/请登录…）
    static func downloadNotice(_ html: String) -> String {
        guard html.contains("<") else { return "" }
        let text = HTMLUtil.stripTags(html)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        for kw in ["审核", "未通过", "驳回", "尚未", "已被屏蔽", "请登录", "无权", "不存在", "已到期", "失败"] {
            guard let r = text.range(of: kw) else { continue }
            // 只取关键词所在的一句，别把整页正文倒进错误提示
            let anchor = text[..<r.lowerBound].lastIndex(where: { "。！？；;.\n".contains($0) })
            let start = anchor == nil ? text.startIndex : text.index(after: anchor!)
            let stop = text[r.upperBound...].firstIndex(where: { "。！？；;.\n".contains($0) }) ?? text.endIndex
            let snippet = String(text[start..<stop]).trimmingCharacters(in: .whitespaces)
            if !snippet.isEmpty { return String(snippet.prefix(80)) }
        }
        return ""
    }

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
            let notice = Self.downloadNotice(String(data: resp.data, encoding: .utf8) ?? "")
            let head = String(data: resp.data.prefix(80), encoding: .utf8) ?? ""
            throw BoxSendError.badInput("\(notice.isEmpty ? "下载链接返回的不是种子文件（\(resp.data.count) bytes，开头: \(head)），可能 cookie 失效或下载链接错误" : "站点提示：\(notice)")：\(info.torrentURL)")
        }
        return (resp.data, info.torrentName)
    }

    func searchExists(_ info: ReleaseInfo) throws -> String? {
        guard let tmpl = override?.searchURL, !tmpl.isEmpty else { return nil }
        // 候选 (查询词, 匹配基准)：全名 -> 去组标签名 -> 前缀截短 -> 副标题（中文名）。
        // 已有种子的组标签/细节/语言可能不同，逐级放宽
        var pairs: [(String, String)] = [(info.name, info.name)]
        if let dash = info.name.lastIndex(of: "-"), dash > info.name.index(info.name.startIndex, offsetBy: 10) {
            pairs.append((String(info.name[..<dash]), info.name))
        }
        if info.name.count > 32 {
            pairs.append((String(info.name.prefix(32)), info.name))
        }
        var subtitle = info.subtitle
        for pat in ["[", "【", "（", "("] {
            if let i = subtitle.firstIndex(of: Character(pat)) { subtitle = String(subtitle[..<i]) }
        }
        subtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if subtitle.count >= 6, subtitle != info.name {
            pairs.append((subtitle, subtitle))
        }
        var seen = Set<String>()
        for (name, target) in pairs where !seen.contains(name) {
            seen.insert(name)
            var q = tmpl
            q = q.replacingOccurrences(of: "{imdb}", with: info.imdb ?? "")
            q = q.replacingOccurrences(of: "{name}", with: name.urlEncoded)
            let url = (q.hasPrefix("http") ? q : site.url + q)
            let html = try client.fetchHTML(url, referer: site.url)
            // 搜索页存档（排查查重未命中）
            if let data = html.data(using: .utf8), let dir = debugDir {
                let root = (dir as NSString).appendingPathComponent("debug")
                try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
                let fpath = (root as NSString).appendingPathComponent("search-\(site.id)-\(Int(Date().timeIntervalSince1970)).html")
                try? data.write(to: URL(fileURLWithPath: fpath))
            }
            // 无结果特征（早退；最终判定以名称匹配为准）
            let noResultMarkers = ["No torrents found", "没有种子", "没有相关", "no results", "No torrents"]
            if noResultMarkers.contains(where: { html.contains($0) }) { continue }
            // 结果行 = 详情链接的锚文本（各站搜索结果名称在 <a href="details.php?id=..">名称</a> 内）
            if let hit = Self.searchNameInResults(html: html, releaseName: target, base: URL(string: url)!) {
                return hit.href
            }
        }
        return nil
    }

    /// 搜索结果页里按名称匹配已存在种子：任一结果行的归一化名称与发布名互含即命中
    static func searchNameInResults(html: String, releaseName: String, base: URL,
                                       hrefPattern: String = "details\\.php\\?id=|/torrents\\.php\\?id=") -> (href: String, text: String)? {
        let anchors = HTMLUtil.anchorText(html, hrefPattern: hrefPattern)
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
        switch mode {
        case "torrentName":
            break   // .torrent 文件名原样（U2 等）
        case "torrentNameDotted":
            // 去 [源站] 前缀与中文标题段，空格换点（cmct 等 dot 风格站）
            t = Self.asciiReleaseName(t)
            t = t.replacingOccurrences(of: "\\s+", with: ".", options: .regularExpression)
        default:
            // 默认：ASCII 发布名，点换空格（保留 2015.1080p / 5.1 等版本号中的点）
            t = Self.prettyReleaseName(Self.asciiReleaseName(t))
        }
        return t
    }

    /// 提取发布名中的 ASCII 段：去开头 [组名] 前缀，再从首个 ASCII 字母/数字起截取。
    /// "[LuckPT].摇曳百合.第三季.Yuru.Yuri.S03.2015.1080p..-LuckAni" -> "Yuru.Yuri.S03.2015.1080p..-LuckAni"
    static func asciiReleaseName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let bracketRe = try! NSRegularExpression(pattern: "^\\[[^\\]]{1,60}\\][.\\s]*")
        var guardCount = 0
        while guardCount < 3,
              let m = bracketRe.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) {
            s = String(s[Range(m.range, in: s)!.upperBound...])
            guardCount += 1
        }
        if let i = s.firstIndex(where: { $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            s = String(s[i...])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 点号换空格；版本号中的点保留：年份.分辨率（2015.1080p）与短版本号（2.0 / 5.1）
    /// "Yuru.Yuri.S03.2015.1080p.BluRay.Remux.AVC.LPCM.2.0-LuckAni" -> "Yuru Yuri S03 2015.1080p BluRay Remux AVC LPCM 2.0-LuckAni"
    static func prettyReleaseName(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?<!\\d)(\\d{4})\\.(\\d{3,4}p)", with: "$1\u{0}$2", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?<![A-Za-z])([A-Za-z]{1,3})\\.(\\d{3})(?!\\d)", with: "$1\u{0}$2", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?<!\\w)(\\d{1,2})\\.(\\d)(?!\\d)", with: "$1\u{0}$2", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\.", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\u{0}", with: ".", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    let cands = g.options.filter { $0.label.lowercased().contains(kw) }
                    if let hit = Self.bestCategoryOption(cands, keyword: kw) {
                        return CategoryHit(value: hit, mode: g.mode)
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

    /// 分类选项打分：关键词越靠前、选项越短，越像"就是这个分类"；
    /// 关键词前有否定词（"电影…(不含动漫)"）直接判负。PTtime 的 Movies 选项曾因此抢走动漫。
    static func bestCategoryOption(_ options: [(value: String, label: String)], keyword: String) -> String? {
        var best: (score: Int, value: String)?
        for (i, o) in options.enumerated() {
            let l = o.label.lowercased()
            guard let r = l.range(of: keyword) else { continue }
            var score = 10 - min(i, 9)
            let pos = l.distance(from: l.startIndex, to: r.lowerBound)
            score += max(0, 8 - pos)
            let before = String(l[..<r.lowerBound])
            if before.contains("不含") || before.contains("除") || before.contains("非") || before.contains("无") {
                score -= 12
            }
            score -= min(l.count / 4, 6)
            if l == keyword.lowercased() { score += 6 }
            if best == nil || score > best!.score { best = (score, o.value) }
        }
        return best?.value
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
        let standardToken = tok("standard")
        let ctx = QualityMatcher.Context(
            isUHD: ["2160p", "8k"].contains(standardToken ?? ""),
            kindKeywords: Self.kindKeywords.first { $0.0 == (info.kind?.rawValue ?? "other") }?.1 ?? [],
            completed: QualityTokens.isCompletedRelease(info))
        let dyn: [(base: String, attr: String, token: String?)] = [
            ("medium_sel", "medium", tok("medium")),
            ("codec_sel", "codec", tok("codec")),
            ("standard_sel", "standard", tok("standard")),
            ("audiocodec_sel", "audiocodec", tok("audiocodec")),
            ("source_sel", "medium", tok("medium")),
            // 处理下拉：烧包=处理方式(Remux/原盘/重编码)，麒麟=年份，蟹黄堡=地区
            ("processing_sel", "processing", tok("medium")),
            // 有些站有独立的「地区」下拉（HDVideo 新版主题 region_sel[4]）
            ("region_sel", "region", nil),
        ]
        let explicitFields = Set(override?.qualitySelects?.keys.sorted() ?? [])
        // 子下拉的数组后缀由上传页模板决定（HDVideo 新版主题写作 medium_sel[4]），不一定等于分类 ID：
        // 以页面里实际存在的名字为准，配置里的 mode 只用来决定优先级
        let presentNames = HTMLUtil.allGroups(page, "<select[^>]*name=[\"']([^\"']+)[\"']")
        func names(for base: String) -> [String] {
            var out: [String] = []
            if let m = mode, presentNames.contains("\(base)[\(m)]") { out.append("\(base)[\(m)]") }
            if presentNames.contains(base) { out.append(base) }
            out += presentNames.filter { $0.hasPrefix("\(base)[") && !out.contains($0) }.sorted()
            return out.filter { !explicitFields.contains($0) }
        }
        // Scene / P2P 二选一的来源下拉（吐鲁番）：转种来的都是 P2P 发布，别按 medium 兜底选到 Scene
        for name in names(for: "source_sel") {
            guard let g = HTMLUtil.selectGroups(page, name: name).first else { continue }
            var hasScene = false, p2pValue: String?
            for o in g.options where o.value != "0" {
                let n = QualityMatcher.normalize(o.label)
                if n.contains("scene") || n.contains("0day") { hasScene = true }
                if p2pValue == nil, n.contains("p2p") || n.contains("non-scene") { p2pValue = o.value }
            }
            if hasScene, let v = p2pValue { set(name, v) }
        }
        for d in dyn {
            for name in names(for: d.base) {
                var groups = HTMLUtil.selectGroups(page, name: name)
                guard !groups.isEmpty else { continue }
                var done = false
                // 不少站的来源/处理/地区下拉其实是地区表（熊猫/优堡/麒麟/咖啡/蟹黄堡/HDVideo）：先按产地取
                if ["source_sel", "processing_sel", "region_sel"].contains(d.base), !info.region.isEmpty,
                   let v = RegionMatch.option(forRegion: info.region, in: groups[0].options) {
                    set(name, v)
                    done = true
                }
                // 组合式来源（烧包"动漫-完结"/"电影-Remux"）：先限定到本分类的子集
                if !done, d.base == "source_sel", !ctx.kindKeywords.isEmpty {
                    let subset = groups[0].options.filter { o in
                        let n = QualityMatcher.normalize(o.label)
                        return ctx.kindKeywords.contains { n.contains($0) }
                    }
                    if !subset.isEmpty { groups[0].options = subset }
                }
                if !done, let token = d.token,
                   let v = QualityMatcher.match(token: token, attr: d.attr, options: groups[0].options, ctx: ctx) {
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
        // 制作组/团队下拉：转种带来的发布组不是本站制作组，留在"请选择一项"会被服务端拒，选「其他」
        if override?.teamOtherFallback != false && override?.teamField == nil {
            for base in ["team_sel", "team"] {
                for name in names(for: base) {
                    guard let g = HTMLUtil.selectGroups(page, name: name).first else { continue }
                    let hit = g.options.first { o in
                        guard o.value != "0" else { return false }
                        let n = QualityMatcher.normalize(o.label)
                        return n == "其他" || n == "其它" || n == "other" || n == "self" || n.contains("个人原创")
                    }
                    if let hit { set(name, hit.value); break }
                }
            }
        }
    }

    /// 季数/集数文本框（海胆等站对分集资源必填）：从发布名 SxxExx 取。
    /// 站点约定：季数 0 = 不区分季，集数 0 = 全季；多季/合集勾 collages。
    static func seasonEpisodeValues(_ info: ReleaseInfo, page: String) -> [(String, String)] {
        var out: [(String, String)] = []
        func has(_ name: String) -> Bool {
            page.contains("name=\"\(name)\"") || page.contains("name='\(name)'")
        }
        let n = info.name.lowercased()
        var season: Int?
        if has("season"), let g = HTMLUtil.group(n, #"s(\d{1,2})"#), let v = Int(g), v > 0 {
            season = v
            out.append(("season", String(v)))
        }
        if has("episode") {
            if let g = HTMLUtil.group(n, #"[^a-z]e\d{1,3}\s*-\s*e?(\d{1,3})"#) {
                out.append(("episode", g))
            } else if let g = HTMLUtil.group(n, #"[^a-z]e(\d{1,3})(?![a-z])"#), let v = Int(g), v > 0 {
                out.append(("episode", String(v)))
            } else if season != nil {
                out.append(("episode", "0"))   // 整季
            }
        }
        if has("collages"), season != nil,
           HTMLUtil.firstMatch(n, #"s\d{1,2}\s*-\s*s\d{1,2}"#) != nil {
            out.append(("collages", "1"))      // 多季合集
        }
        return out
    }

    /// 简介中全部图片 URL（文档顺序、去重）：锚包图取 href 原图，其余取 img src
    static func allImageURLs(from descrHTML: String, base: URL) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let re = try! NSRegularExpression(
            pattern: "<a[^>]*href=[\"']([^\"']+)[\"'][^>]*>\\s*<img[^>]*>|<img[^>]*src=[\"']([^\"']+)[\"']",
            options: [.caseInsensitive])
        for m in re.matches(in: descrHTML, options: [], range: NSRange(descrHTML.startIndex..., in: descrHTML)) {
            let u: String
            if m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound,
               let r = Range(m.range(at: 1), in: descrHTML) {
                u = HTMLUtil.resolveURL(HTMLUtil.decodeEntities(String(descrHTML[r])), against: base)
            } else if m.numberOfRanges > 2, m.range(at: 2).location != NSNotFound,
               let r = Range(m.range(at: 2), in: descrHTML) {
                u = HTMLUtil.resolveURL(HTMLUtil.decodeEntities(String(descrHTML[r])), against: base)
            } else { continue }
            if Self.isImageURL(u), seen.insert(u).inserted { out.append(u) }
        }
        return out
    }

    /// 海报图：优先取专用海报 div（新版主题 torrent-detail-poster）内 img，其次简介首图
    /// 页面是否是登录页（NexusPHP 会话失效后详情页会 302 到 login 表单）
    static func isLoginPage(_ html: String) -> Bool {
        let head = String(html.prefix(6000)).lowercased()
        if HTMLUtil.group(html, "<title>[^<]*(?:登录|login)") != nil { return true }
        return head.contains("action=[\"']takelogin.php") || head.contains("action='takelogin.php")
    }

    static func posterURL(from descrHTML: String, base: String) -> String? {
        guard let baseU = URL(string: base) else { return nil }
        let divRe = try! NSRegularExpression(
            pattern: "<div[^>]*class=[\"'][^\"']*poster[^\"']*[\"'][^>]*>(.*?)</div>",
            options: [.caseInsensitive, .dotMatchesLineSeparators])
        if let m = divRe.firstMatch(in: descrHTML, options: [], range: NSRange(descrHTML.startIndex..., in: descrHTML)),
           m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: descrHTML) {
            let inner = String(descrHTML[r])
            if let src = HTMLUtil.group(inner, "<img[^>]*src=[\"']([^\"']+)[\"']", group: 1, options: [.caseInsensitive]) {
                let u = HTMLUtil.resolveURL(HTMLUtil.decodeEntities(src), against: baseU)
                if Self.isImageURL(u) { return u }
            }
        }
        return allImageURLs(from: descrHTML, base: baseU).first
    }

    /// 截图直链 = 简介全部图片去掉海报（每行一个提交给截图字段）
    static func screenshotURLs(from descrHTML: String, base: String) -> [String] {
        guard let baseU = URL(string: base) else { return [] }
        let all = allImageURLs(from: descrHTML, base: baseU)
        guard let poster = posterURL(from: descrHTML, base: base) else { return all }
        return all.filter { $0 != poster }
    }

    /// 源简介引用框（<fieldset><legend>引用</legend>）内部原始 HTML（去 legend、首尾 <br>/空白），
    /// 用于 cmct 等站"附加信息=转种来源"
    static func quoteHTML(from descrHTML: String) -> String? {
        let re = try! NSRegularExpression(pattern: "<fieldset[^>]*>(.*?)</fieldset>",
                                          options: [.caseInsensitive, .dotMatchesLineSeparators])
        guard let m = re.firstMatch(in: descrHTML, options: [], range: NSRange(descrHTML.startIndex..., in: descrHTML)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: descrHTML) else { return nil }
        var inner = String(descrHTML[r])
        inner = inner.replacingOccurrences(of: "\r\n", with: "\n", options: [])
        inner = inner.replacingOccurrences(of: "\r", with: "\n", options: [])
        inner = inner.replacingOccurrences(of: "<legend>.*?</legend>", with: "",
                                           options: [.regularExpression, .caseInsensitive])
        inner = inner.replacingOccurrences(of: "^(?:\\s|<br\\s*/?>)+", with: "", options: .regularExpression)
        inner = inner.replacingOccurrences(of: "(?:\\s*<br\\s*/?>)*\\s*$", with: "", options: .regularExpression)
        inner = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// bbcode 目标站简介 HTML 预清洗：
    /// 1) fieldset 引用框内部首尾的 <br>/空白（源页排版用）去掉；
    /// 2) 海报 div：存在同图独立 <img> 时整块去掉，否则保留 div 内 img；
    /// 3) 有独立截图字段时去掉截图 <img>（海报图保留在简介里）；
    /// 4) 同一海报图只保留第一处
    static func preprocessDescription(_ html: String, base: String, dropScreenshots: Bool) -> String {
        guard let baseU = URL(string: base) else { return html }
        var s = html
        s = HTMLUtil.replaceMatches(s, "<fieldset[^>]*>(.*?)</fieldset>",
                                    options: [.caseInsensitive, .dotMatchesLineSeparators]) { m in
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else {
                return String(s[Range(m.range, in: s)!])
            }
            var inner = String(s[r])
            inner = inner.replacingOccurrences(of: "<legend>.*?</legend>", with: "",
                                               options: [.regularExpression, .caseInsensitive])
            inner = inner.replacingOccurrences(of: "^(?:\\s|<br\\s*/?>)+", with: "", options: .regularExpression)
            inner = inner.replacingOccurrences(of: "(?:\\s*<br\\s*/?>)*\\s*$", with: "", options: .regularExpression)
            return "<fieldset>" + inner + "</fieldset>"
        }
        if let poster = posterURL(from: html, base: base) {
            let divRe = try! NSRegularExpression(
                pattern: "<div[^>]*class=[\"'][^\"']*poster[^\"']*[\"'][^>]*>(.*?)</div>",
                options: [.caseInsensitive, .dotMatchesLineSeparators])
            let standaloneRe = try! NSRegularExpression(
                pattern: "<img[^>]*src=[\"']" + NSRegularExpression.escapedPattern(for: poster) + "[\"']",
                options: [.caseInsensitive])
            if let divM = divRe.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)),
               let range = Range(divM.range, in: s) {
                let before = String(s[..<range.lowerBound])
                let after = String(s[range.upperBound...])
                let beforeR = NSRange(before.startIndex..., in: before)
                let afterR = NSRange(after.startIndex..., in: after)
                if standaloneRe.firstMatch(in: before, options: [], range: beforeR) != nil
                    || standaloneRe.firstMatch(in: after, options: [], range: afterR) != nil {
                    s.removeSubrange(range)   // 独立海报图存在：整块去掉海报 div
                } else if divM.numberOfRanges > 1, let innerR = Range(divM.range(at: 1), in: s) {
                    s.replaceSubrange(range, with: String(s[innerR]))   // 无独立图：保留 div 内 img
                }
            }
            if dropScreenshots {
                for u in screenshotURLs(from: html, base: base) {
                    let pat = "<img[^>]*src=[\"']" + NSRegularExpression.escapedPattern(for: u) + "[\"'][^>]*/?>"
                    s = s.replacingOccurrences(of: pat, with: "", options: .regularExpression)
                }
            }
            // 海报图去重：只保留第一处
            let posterRe = try! NSRegularExpression(
                pattern: "<img[^>]*src=[\"']" + NSRegularExpression.escapedPattern(for: poster) + "[\"'][^>]*/?>",
                options: [.caseInsensitive])
            let ranges = posterRe.matches(in: s, options: [], range: NSRange(s.startIndex..., in: s))
                .compactMap { Range($0.range, in: s) }
            for r in ranges.dropFirst().reversed() { s.removeSubrange(r) }
        }
        return s
    }

    /// cmct 等站"附加信息"：转种来源（源站引用框内容 + 致谢前缀）
    func reseedSourceText(_ info: ReleaseInfo) -> String {
        var t = "转载自\(sourceLabel(info))，感谢发布者。"
        if let q = Self.quoteHTML(from: info.descr) { t += q }
        return t
    }

    static func isImageURL(_ s: String) -> Bool {
        let path = (s as NSString).deletingPathExtension.lowercased()
        return [".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif"].contains { path.hasSuffix($0) }
            || s.lowercased().contains("pic/") || s.lowercased().contains("image")
    }

    /// 简介按目标站格式生成：bbcode（中文站默认）或 html。
    /// embedMediainfo = false 时 MediaInfo 已单独提交（独立文本域），简介不再内嵌
    private func buildDescription(_ info: ReleaseInfo, embedMediainfo: Bool = true) -> String {
        let format = override?.descrFormat ?? "bbcode"
        guard format == "bbcode" else {
            return cleanDescription(info.descr, sourceHost: site.url)
        }
        let html = Self.preprocessDescription(info.descr, base: site.url,
                                              dropScreenshots: override?.screenshotField != nil)
        var out = BBCode.fromHTML(html, base: URL(string: site.url))
        if embedMediainfo {
            out = BBCode.insertMediainfo(out, mediainfo: info.mediainfo)
        }
        return out
    }

    private func canonicalTags(_ info: ReleaseInfo) -> [String] { QualityTokens.canonicalTags(info) }

    /// 简介最前面的转种来源：配置要求的站点（如织梦）加一行纯文本；源站是官种的用独立引用块注明出处
    /// （不并入源简介自带引用块，那里可能是 MediaInfo 或剧集信息）
    private func withSourcePrefix(_ text: String, _ info: ReleaseInfo) -> String {
        let line = "转载自\(sourceLabel(info))，感谢发布者。"
        if info.isOfficialSource { return "[quote]\n\(line)\n[/quote]\n" + text }
        guard override?.descrSourcePrefix == true else { return text }
        return line + "\n" + text
    }

    /// 转种来源里的源站名（解析时已按源站 overrides.sourceLabel 归一，如 LuckPT）
    private func sourceLabel(_ info: ReleaseInfo) -> String {
        info.sourceName.isEmpty ? info.siteID : info.sourceName
    }

    /// 上传表单的 action（城市把种子文件 POST 到独立上传域名，必须按页面 action 提交）
    static func formActionURL(_ page: String) -> String? {
        guard let form = HTMLUtil.group(page, "<form[^>]*enctype=[\"']multipart/form-data[\"'][^>]*>",
                                       group: 0, options: [.caseInsensitive]),
              let action = HTMLUtil.group(form, "action=[\"']([^\"']*)[\"']"),
              action.lowercased().hasPrefix("http") else { return nil }
        return action
    }

    /// 豆瓣字段自动识别：行标签含"豆瓣"的文本框；没有则退回 pt_gen（PT-Gen 框按惯例填豆瓣链接）
    static func autoDoubanField(_ page: String) -> String? {
        let pattern = "<tr[^>]*>\\s*<td[^>]*>[^<]*豆瓣[^<]*</td>\\s*<td[^>]*>(.*?)</td>"
        if let cell = HTMLUtil.group(page, pattern, group: 1,
                                     options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let name = HTMLUtil.group(cell, "<input[^>]*name=[\"']([^\"']+)[\"']") {
            return name
        }
        if HTMLUtil.group(page, "<input[^>]*name=[\"'](pt_gen)[\"']") != nil { return "pt_gen" }
        return nil
    }

    /// 自动识别出的豆瓣字段：名字像 ID 的填裸 ID，其余（含 pt_gen）填完整链接
    static func defaultDoubanTemplate(_ field: String) -> String {
        let f = field.lowercased()
        if f == "douban_id" || f == "doubanid" || f.hasSuffix("_id") { return "{douban}" }
        return "https://movie.douban.com/subject/{douban}/"
    }

    /// 动态标签：解析页面复选框，按文案匹配规范标签后提交（新站免逐站配置）。
    /// 字段名含 tag/chinese/exclusive 的按"文案包含关键词"匹配；其余字段名（如 pterclub 的
    /// zhongzi/jinzhuan 拼音命名）只接受文案与关键词完全一致，避免误勾表单里其它复选框。
    private func dynamicTagValues(_ info: ReleaseInfo, page: String) -> [(name: String, value: String)] {
        func nameGated(_ n: String) -> Bool {
            let base = n.replacingOccurrences(of: #"[\d]+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            return base.contains("tag") || base == "chinese" || base == "exclusive"
        }
        func norm(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "[\\s　]+", with: "", options: .regularExpression)
        }
        let boxes = HTMLUtil.checkboxes(page).filter { !$0.label.isEmpty }
        let tags = canonicalTags(info)
        var out: [(name: String, value: String)] = []
        var claimed: Set<String> = []
        for (tag, keywords) in QualityTokens.tagTextMap {
            guard tags.contains(tag) else { continue }
            let keys = keywords.map(norm)
            func claimedBox(_ b: (name: String, value: String, label: String)) -> Bool {
                claimed.contains("\(b.name)\u{1}\(b.value)")
            }
            let hit = boxes.first { !claimedBox($0) && keys.contains(norm($0.label)) }
                ?? boxes.first { box in
                    if claimedBox(box) || !nameGated(box.name) { return false }
                    // 并列文案（"原盘或ISO"）语义不唯一，只有完全一致才算命中
                    if box.label.contains("或") { return false }
                    return keys.contains(where: { norm(box.label).contains($0) })
                }
            guard let h = hit else { continue }
            claimed.insert("\(h.name)\u{1}\(h.value)")
            if !out.contains(where: { $0.name == h.name && $0.value == h.value }) {
                out.append((h.name, h.value))
            }
        }
        return out
    }

    /// 种子名末尾的发布组名（最后一个 "-" 之后），取不到给 Unknown
    static func releaseGroup(_ name: String) -> String {
        guard let dash = name.lastIndex(of: "-") else { return "Unknown" }
        let g = String(name[name.index(after: dash)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return g.isEmpty || g.count > 40 ? "Unknown" : g
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
        // 表单内所有 <select> 的默认值（selected 项，无则首项）一并提交，模拟浏览器；
        // 部分站（TTG 等）把 anonymity/nodistr 等下拉设为必填，缺省会直接拒收
        let selectRe = try! NSRegularExpression(
            pattern: "<select[^>]*name=[\"']([^\"']+)[\"'][^>]*>(.*?)</select>",
            options: [.caseInsensitive, .dotMatchesLineSeparators])
        for m in selectRe.matches(in: page, options: [], range: range) {
            let name = String(page[Range(m.range(at: 1), in: page)!])
            if fields.contains(where: { $0.name == name }) { continue }   // hidden/业务字段已设置的优先
            if name.contains("[") { continue }   // mode 型字段（medium_sel[4] 等）由质量下拉逻辑按分类模式处理
            let body = String(page[Range(m.range(at: 2), in: page)!])
            let optRe = try! NSRegularExpression(pattern: "<option[^>]*>", options: [.caseInsensitive])
            var first: String?
            var selected: String?
            for om in optRe.matches(in: body, options: [], range: NSRange(body.startIndex..., in: body)) {
                let tag = String(body[Range(om.range, in: body)!])
                let v = HTMLUtil.group(tag, "value=[\"']([^\"']*)[\"']", group: 1) ?? ""
                if first == nil { first = v }
                if tag.contains("selected") { selected = v; break }
            }
            fields.append(.init(name, selected ?? first ?? ""))
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
        // technical_info / media_info / media_bdinfo（cmct 的 "Media_BDInfo"）
        let taNames = Set(HTMLUtil.textareaNames(page))
        // 字段名大小写不敏感（cmct 为 "Media_BDInfo"）
        let mediaField = ["technical_info", "media_info", "media_bdinfo"].lazy
            .compactMap { want in taNames.first { $0.lowercased() == want } }
            .first
        var mediaHandled = false
        if let mf = mediaField, !info.mediainfo.isEmpty {
            setField(mf, info.mediainfo)
            mediaHandled = true
        }
        // 简介：bbcode 目标站即使 MediaInfo 独立提交也走 bbcode 转换（hddolby 等曾误用 HTML）
        if override?.descrStyle == "reseedSource" {
            setField(descrField, reseedSourceText(info))   // cmct：descr 实为"附加信息"
        } else if mediaHandled {
            setField(descrField, withSourcePrefix(buildDescription(info, embedMediainfo: false), info))
        } else {
            setField(descrField, withSourcePrefix(buildDescription(info), info))
        }
        // 海报 URL（cmct url_poster 等）
        if let pf = override?.posterField, let poster = Self.posterURL(from: info.descr, base: site.url) {
            setField(pf, poster)
        }
        // 截图 URL 文本域（hddolby 等必填，每行一个，不含海报）
        if let sf = override?.screenshotField {
            let urls = Self.screenshotURLs(from: info.descr, base: site.url)
            if !urls.isEmpty { setField(sf, urls.joined(separator: "\n")) }
        }
        if let imdb = info.imdb {
            let tmpl = override?.imdbValueTemplate ?? "{imdb}"
            setField(imdbField, tmpl.replacingOccurrences(of: "{imdb}", with: imdb))
        }
        if let douban = info.douban {
            let field = override?.doubanField ?? Self.autoDoubanField(page)
            if let field {
                let tmpl = override?.doubanValueTemplate ?? Self.defaultDoubanTemplate(field)
                setField(field, tmpl.replacingOccurrences(of: "{douban}", with: douban))
            }
        }
        // PT-Gen 链接框（hdvideo 等：豆瓣已填 douban_url，pt_gen 仍是独立必填项）
        if !fields.contains(where: { $0.name == "pt_gen" }),
           HTMLUtil.group(page, "<input[^>]*name=[\"'](pt_gen)[\"']") != nil {
            if let douban = info.douban {
                setField("pt_gen", "https://movie.douban.com/subject/\(douban)/")
            } else if let imdb = info.imdb {
                setField("pt_gen", "https://www.imdb.com/title/\(imdb)/")
            }
        }
        if let tmdbField = override?.tmdbField, let tmdb = info.tmdb {
            setField(tmdbField, tmdb)
        }
        // 分类（支持质量型键 "<kind>/<profile>"，字符串表与动态解析；多下拉时定位 mode）
        var catMode: String?
        if let hit = resolveCategory(info, page: page) {
            setField(categoryField, hit.value)
            catMode = hit.mode
        }
        // 质量下拉（medium/codec/audiocodec/standard）+ 源介质组合下拉
        applyQualitySelects(info, page: page, mode: catMode, setField)
        for (k, v) in Self.seasonEpisodeValues(info, page: page) { setField(k, v) }
        applySourceSelect(info, setField)
        // 额外固定字段
        for (k, v) in (override?.extraUploadFields ?? [:]) {
            setField(k, v)
        }
        // 部分站（TTG 等）把匿名发布设为必填：表单存在 anonymity 下拉而提交的值仍是占位 -1（或未提交）时，默认 "no"
        if HTMLUtil.group(page, "<select[^>]*name=[\"']anonymity[\"'][^>]*>", options: [.caseInsensitive]) != nil {
            let cur = fields.first { $0.name == "anonymity" }?.value
            if cur == nil || cur == "-1" { setField("anonymity", "no") }
        }
        // 常见可选字段的默认值（只提交表单里真实存在的字段；部分站对未知/空字段校验更严）
        if page.contains("name=\"nfo\"") || page.contains("name='nfo'") { setField("nfo", "") }
        if page.contains("name=\"anonymous\"") || page.contains("name='anonymous'") { setField("anonymous", "1") }
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
        // 标签型下拉（城市 HDCity tag1ing/tag2ing：选项值就是文案，按规范标签文案填）
        var usedTagOptions: Set<String> = []
        var usedTags: Set<String> = []
        for field in override?.tagSelectFields ?? [] {
            guard let options = HTMLUtil.selectGroups(page, name: field).first?.options, !options.isEmpty else { continue }
            for tag in canonicalTags(info) where !usedTags.contains(tag) {
                guard let keys = QualityTokens.tagTextMap.first(where: { $0.tag == tag })?.keywords else { continue }
                // 选项形如"喜剧/Comedy"：按分隔段整段比对，避免"Jazz/爵士乐"被关键词 zz 误命中
                if let hit = options.first(where: { o in
                    guard !usedTagOptions.contains(o.value) else { return false }
                    let segs = o.label.split(whereSeparator: { "/、,|，； ".contains($0) })
                        .map { QualityMatcher.normalize(String($0)) }
                    return segs.contains(where: { keys.contains($0) })
                }) {
                    setField(field, hit.value)
                    usedTagOptions.insert(hit.value)
                    usedTags.insert(tag)
                    break
                }
            }
        }
        // 动态标签：无显式标签配置时按页面 tags 复选框文案匹配（新站免逐站配置）
        if override?.tagField == nil && override?.tagCheckboxes == nil {
            for (tag, value) in dynamicTagValues(info, page: page) {
                fields.append(.init(tag, value))
            }
        }
        // 制作组后缀（海胆等：文本框，站点按种子名末尾的发布组校验，缺了直接拒收）
        if HTMLUtil.group(page, "<input[^>]*name=[\"'](team_suffix)[\"']") != nil {
            setField("team_suffix", Self.releaseGroup(info.name))
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
        if let m = HTMLUtil.firstMatch(body, "(?:This torrent already exists|already exists|已存在|已经上传|上传过了|被人上传)[^<]{0,60}") {
            return m
        }
        if let e = HTMLUtil.group(body, "<h2[^>]*>(?:上传失败|Publish Failed)[^<]*</h2>\\s*<p[^>]*>(.*?)</p>", group: 1, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            let t = HTMLUtil.stripTags(e).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if body.contains("<form") && (body.contains("takeupload.php") || body.contains("upload.php")) {
            return "服务器未跳转到详情页（必填字段缺失或校验失败），请核对该站 overrides 配置"
        }
        // 会话中途失效：POST 被弹回登录页（NexusPHP takelogin.php / 自研站 signinhandler）
        let lower = body.lowercased()
        if lower.contains("takelogin.php") || lower.contains("signinhandler")
            || HTMLUtil.group(body, "<form[^>]*action=[\"'][^\"']*login[\"']") != nil {
            return "HTTP \(status) 会话失效（返回登录页），请重新导入该站 cookie"
        }
        return "HTTP \(status) 未识别的返回"
    }

    /// 提交字段清单存 debug 目录（站点报「请填写必填项目」时用来核对缺哪一项）
    private func dumpUploadFields(_ fields: [HTTPClient.MultipartField],
                                  files: [(name: String, filename: String, data: Data, mime: String)]) {
        guard let root = debugDir else { return }
        let dir = (root as NSString).appendingPathComponent("debug")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var lines = files.map { "FILE \($0.name)=\($0.filename) (\($0.data.count) bytes)" }
        lines += fields.map { "FIELD \($0.name)=\($0.value.prefix(200))" }
        let path = (dir as NSString).appendingPathComponent("fields-\(site.id)-\(Int(Date().timeIntervalSince1970)).txt")
        try? lines.joined(separator: "\n").data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
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
        // 肉丝这类站只有 API 上传（上传页是 SPA），表单提交会被网关拒成 405，先给明确原因
        if override?.usesAPIKey == true {
            throw BoxSendError.badInput("\(site.name) 走 API Key 发种，表单上传未适配（当前仅支持 API Key 检测）")
        }
        var uploadURL = site.url + uploadAction
        // 表单页优先取 uploadPath（upload.php）；部分站（TTG 等）action 页纯处理不渲染表单，
        // 若表单页里没有 <form> 则回退抓 action 页
        let formPage = try client.fetchHTML(site.url + uploadPath, referer: site.url)
        var page: String
        if formPage.lowercased().contains("<form") {
            page = formPage
        } else {
            page = try client.fetchHTML(uploadURL, referer: site.url)
        }
        // 表单 action 可以是站外绝对地址（城市：种子文件 POST 到独立上传域名）
        var action = Self.formActionURL(page) ?? uploadURL
        var fields = buildUploadFields(info, page: page)
        var files: [(name: String, filename: String, data: Data, mime: String)] =
            [(name: fileField, filename: filename, data: torrentData, mime: "application/x-bittorrent")]

        // 两步上传（城市）：第一步只投递种子文件与页面 token，站点回跳到元信息表单页
        if override?.uploadTwoStep == true {
            // 不跟随跳转：302 目标是站点自己的域，直接跟过去会丢掉本站 cookie（城市把种子传到独立域名）
            let first = try client.performWithoutRedirect(client.multipartRequest(
                url: action, fields: fields, files: files, referer: site.url + uploadPath))
            let step2URL = HTMLUtil.resolveURL(first.headers["location"] ?? "",
                                               against: URL(string: action)!)
            let step2 = try client.fetchHTML(step2URL, referer: site.url + uploadPath)
            guard step2.lowercased().contains("<form") else {
                throw BoxSendError.badInput("\(site.id) 两步上传没拿到第二步表单（跳转 \(step2URL)）")
            }
            uploadURL = step2URL
            action = Self.formActionURL(step2) ?? step2URL
            page = step2
            fields = buildUploadFields(info, page: step2)
            files = []      // 第二步只提交元信息，种子已在第一步入库
        }

        dumpUploadFields(fields, files: files)
        let resp = try client.postMultipart(
            action,
            fields: fields,
            files: files,
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
        // 站点自定义成功跳转（城市：/t-<id>），按 overrides.successIDPattern 取 id 组详情链接
        if let pat = override?.successIDPattern,
           let id = HTMLUtil.group(resp.finalURL, pat, group: 1) {
            return UploadOutcome(success: true, message: "发布成功",
                                 detailURL: site.url + "details.php?id=" + id)
        }
        if resp.status == 200, body.contains("new torrent") || body.contains("发布成功") || body.contains("Torrent added") {
            return UploadOutcome(success: true, message: "发布成功", detailURL: nil)
        }
        // 失败: 提取错误信息 + 保存页面
        var errMsg = extractUploadError(body: body, status: resp.status)
        if resp.finalURL != action { errMsg += "（跳转 \(resp.finalURL)）" }
        if let p = dumpDebugHTML(body) {
            errMsg += "（页面已存 \(p)）"
        }
        // 表单页一并存档（失败时用于核对字段是否齐全）
        if let data = page.data(using: .utf8), let dir = debugDir {
            let root = (dir as NSString).appendingPathComponent("debug")
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            let fpath = (root as NSString).appendingPathComponent("form-\(site.id)-\(Int(Date().timeIntervalSince1970)).html")
            try? data.write(to: URL(fileURLWithPath: fpath))
        }
        let msg = HTMLUtil.stripTags(errMsg)
        // 站点提示同名/同 hash 种子已存在（如手动转过）：视为成功，不再重复发种
        // TTG 的重复提示是「种子已经上传！」，其他站多为「该种子已存在！」/ already exists
        // 同时检查原始 body，防止错误提取失败时漏判
        func hasExistMarker(_ t: String) -> Bool {
            t.contains("已存在") || t.contains("已经上传") || t.contains("上传过了") || t.contains("被人上传")
                || t.lowercased().contains("already exists") || t.lowercased().contains("already uploaded")
        }
        if hasExistMarker(msg) || hasExistMarker(body) {
            // 尽力从重复提示页提取已存在种子的详情链接（部分站会带上），供后续推送
            var existingURL: String?
            if let m = HTMLUtil.group(body, "href=[\"']([^\"']*?(?:details|torrents)\\.php\\?id=\\d+[^\"']*)[\"']", group: 1),
               !m.contains("userdetails") {
                let u = URL(string: uploadURL)!
                existingURL = HTMLUtil.resolveURL(HTMLUtil.decodeEntities(m), against: u)
            }
            if existingURL == nil,
               let m = HTMLUtil.group(body, "(https?://[^\\s<>\"]+?(?:details|torrents)\\.php\\?id=\\d+[^\\s<>\"]*)", group: 1),
               !m.contains("userdetails") {
                existingURL = m
            }
            if existingURL == nil,
               let m = HTMLUtil.group(body, "(?<![>\"\'=\\w])(?:details|torrents)\\.php\\?id=\\d+(?:&[^\\s<>\"]*)?", group: 1),
               !m.contains("userdetails") {
                let u = URL(string: uploadURL)!
                existingURL = HTMLUtil.resolveURL(m, against: u)
            }
            return UploadOutcome(success: true, message: "已存在（查重兜底命中）", detailURL: existingURL, alreadyExists: true)
        }
        return UploadOutcome(success: false, message: msg, detailURL: nil)
    }
}
