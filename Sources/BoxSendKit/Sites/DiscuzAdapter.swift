import Foundation

/// Discuz! 论坛型 PT 站（YZYY 等）：发种页是 Discuz 插件渲染的表单
/// （如 plugin.php?id=dz_seed:publish），字段名各站自定，所以按「行标签 + 控件类型」推断，
/// 不硬编码字段名。详情页解析/种子下载/查重复用 NexusPHP 的通用逻辑。
/// 上传结果判定要按 Discuz 的 showmessage 提示页，与 NexusPHP 的跳转判定不同。
final class DiscuzAdapter: SiteAdapter {
    let site: SiteConfig
    let client: HTTPClient
    var override: SiteOverride? { site.overrides }
    private let base: NexusPHPAdapter
    let debugDir: String?

    init(site: SiteConfig, client: HTTPClient, debugDir: String? = nil) {
        self.site = site
        self.client = client
        self.debugDir = debugDir
        self.base = NexusPHPAdapter(site: site, client: client, debugDir: debugDir)
    }

    private var uploadPath: String { override?.uploadPath ?? "plugin.php?id=dz_seed:publish" }

    func fetchTorrentList() throws -> [ReleaseInfo] { try base.fetchTorrentList() }
    func fetchDetail(detailURL: String) throws -> ReleaseInfo { try base.fetchDetail(detailURL: detailURL) }
    func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String) {
        try base.downloadTorrentFile(info)
    }
    func searchExists(_ info: ReleaseInfo) throws -> String? { try base.searchExists(info) }

    func previewUploadFields(_ info: ReleaseInfo) throws -> [(String, String)] {
        let page = try client.fetchHTML(site.url + uploadPath, referer: site.url)
        return buildFields(info, page: page).0.map { ($0.name, $0.value) }
    }

    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome {
        let page = try client.fetchHTML(site.url + uploadPath, referer: site.url)
        save("form", page)
        var (fields, fileField) = buildFields(info, page: page)
        guard !fields.isEmpty else {
            throw BoxSendError.badInput("\(site.id) 发种页没解析出可提交字段（页面已存 debug）")
        }
        fields = withPTGenResult(fields, page: page, info: info)
        let action = formActionURL(page) ?? (site.url + uploadPath)
        var files: [(name: String, filename: String, data: Data, mime: String)] = []
        if let ff = fileField {
            files = [(ff, filename, torrentData, "application/x-bittorrent")]
        }
        let resp = try client.postMultipart(action, fields: fields, files: files, referer: site.url + uploadPath)
        let body = String(data: resp.data, encoding: .utf8) ?? ""
        save("upload", body)
        let text = HTMLUtil.stripTags(body)
        if resp.status >= 400 {
            return UploadOutcome(success: false, message: "HTTP \(resp.status) \(text.prefix(80))", detailURL: nil)
        }
        // 已存在（站点查重兜底）
        if ["已经存在", "已存在", "重复", "duplicate"].contains(where: { text.lowercased().contains($0.lowercased()) }) {
            return UploadOutcome(success: true, message: "站点已存在该种子（查重兜底命中）",
                                 detailURL: nil, alreadyExists: true)
        }
        // 两步发种（YZYY 插件）：发布表单只是暂存种子，还要在 Discuz 发帖页提交一次
        if let step2 = try? completeThreadPost(body, ctx: ThreadPostContext(
            title: uploadTitle(info), message: description(info), info: info)) {
            save("upload", body)
            return step2
        }
        let okMarkers = ["发布成功", "上传成功", "发表成功", "新增成功", "发布完成"]
        if okMarkers.contains(where: { text.contains($0) }) {
            let link = HTMLUtil.firstMatch(body, "href=[\"']([^\"']*(?:tid|aid|do=view)[^\"']*)[\"']")
                .flatMap { HTMLUtil.resolveURL($0, against: URL(string: site.url)!) }
            return UploadOutcome(success: true, message: "发布成功", detailURL: link)
        }
        if text.contains("您尚未登录") || text.contains("请先登录") {
            return UploadOutcome(success: false, message: "cookie 失效（站点要求登录）", detailURL: nil)
        }
        let err = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return UploadOutcome(success: false, message: "未识别的返回：\(err.prefix(120))", detailURL: nil)
    }

    // MARK: - 表单推断

    /// 行标签关键词 -> 规范角色（先命中的优先）
    static let labelMap: [(keys: [String], role: String)] = [
        (["mediainfo", "bdinfo", "抓轨日志", "软件介绍"], "mediainfo"),
        (["截图链接", "截图"], "screenshot"),
        (["种子名称", "发布标题", "资源标题", "标题", "名称"], "title"),
        (["种子说明", "内容简介", "内容介绍", "简介", "描述", "详细介绍"], "descr"),
        (["分类", "类型", "类别", "所属分类"], "category"),
        (["豆瓣"], "douban"),
        (["imdb", "IMDB"], "imdb"),
        (["产地", "地区", "国家/地区", "来源地"], "region"),
        (["制作组", "发布组", "团队"], "team"),
    ]

    /// 控件是否声明了某个 type（属性引号可选）
    static func hasType(_ tag: String, _ type: String) -> Bool {
        let t = tag.lowercased()
        let dq = String("\"")
        let sq = String("'")
        return t.contains("type=" + dq + type + dq)
            || t.contains("type=" + sq + type + sq)
            || t.contains("type=" + type)
    }

    /// 页面里的上传表单：优先 enctype=multipart/form-data，其次第一个含 file 输入的表单
    static func uploadForm(_ page: String) -> String? {
        let re = try! NSRegularExpression(pattern: "<form[\\s\\S]*?</form>", options: [.caseInsensitive])
        let forms = re.matches(in: page, options: [], range: NSRange(page.startIndex..., in: page))
            .compactMap { Range($0.range, in: page) }
            .map { String(page[$0]) }
        return forms.first { $0.lowercased().contains("multipart/form-data") && hasType($0, "file") }
            ?? forms.first { hasType($0, "file") }
            ?? forms.first { $0.lowercased().contains("multipart/form-data") }
    }

    /// 表单内控件的「行标签」：Discuz 模板多为 `<td>标签</td><td>控件</td>`，
    /// 所以取控件前的去标签文本尾部（选项文案在控件之后，不会混进来）
    static func labelBefore(_ page: String, controlStart: String.Index) -> String {
        let head = String(page[page.startIndex..<controlStart].suffix(400))
        let text = HTMLUtil.stripTags(HTMLUtil.decodeEntities(head))
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        return String(text.suffix(24)).trimmingCharacters(in: CharacterSet(charactersIn: "：:*|/、,"))
    }

    /// 组装提交字段：隐藏域 + 站点自己的提交标记 + 按标签推断的字段；返回字段与文件域名
    func buildFields(_ info: ReleaseInfo, page: String) -> ([HTTPClient.MultipartField], String?) {
        guard let form = Self.uploadForm(page) else { return ([], nil) }
        var out: [HTTPClient.MultipartField] = []
        var used = Set<String>()
        func add(_ name: String, _ value: String) {
            guard !name.isEmpty, !used.contains(name) else { return }
            used.insert(name)
            out.append(HTTPClient.MultipartField(name, value))
        }
        // 隐藏域（formhash / 插件动作参数等，Discuz 缺 formhash 会直接拒）
        for tag in HTMLUtil.allMatches(form, "<input[^>]*>", options: [.caseInsensitive]) {
            guard Self.hasType(tag, "hidden") else { continue }
            guard let n = HTMLUtil.group(tag, "name=[\"']([^\"']+)[\"']") else { continue }
            let v = HTMLUtil.group(tag, "value=[\"']([^\"']*)[\"']") ?? ""
            add(n, v)
        }
        // 提交按钮的标记字段（Discuz 常见 topicsubmit=yes / submit=yes）
        for tag in HTMLUtil.allMatches(form, "<input[^>]*>", options: [.caseInsensitive]) {
            guard Self.hasType(tag, "submit") else { continue }
            guard let n = HTMLUtil.group(tag, "name=[\"']([^\"']+)[\"']") else { continue }
            add(n, HTMLUtil.group(tag, "value=[\"']([^\"']*)[\"']") ?? "yes")
        }
        let fileField = HTMLUtil.allGroups(form, "<input[^>]*type=[\"']file[\"'][^>]*name=[\"']([^\"']+)[\"']", group: 1).first
            ?? HTMLUtil.allGroups(form, "<input[^>]*name=[\"']([^\"']+)[\"'][^>]*type=[\"']file[\"']", group: 1).first

        let ctxKind = info.kind?.rawValue ?? "other"
        let kindKeys = NexusPHPAdapter.kindKeywords.first { $0.0 == ctxKind }?.1 ?? []
        // 逐个控件按标签认领角色
        var claimed: [String: (name: String, tag: String)] = [:]
        for m in Self.controlRanges(form) {
            let tag = m.tag
            let label = Self.labelBefore(form, controlStart: m.at)
            guard !label.isEmpty else { continue }
            let norm = QualityMatcher.normalize(label)
            for entry in Self.labelMap {
                let role = entry.role
                guard claimed[role] == nil else { continue }
                if entry.keys.contains(where: { norm.contains(QualityMatcher.normalize($0)) }) {
                    if role == "title" || role == "descr" {
                        // 标题/简介必须落在文本控件上，别被同名单选框抢走
                        guard Self.hasType(tag, "text") || Self.hasType(tag, "email") || Self.hasType(tag, "number") || tag.lowercased().contains("<textarea") else { continue }
                    }
                    if role == "category" || role == "region" || role == "team" {
                        guard tag.lowercased().contains("<select") else { continue }
                    }
                    if let n = HTMLUtil.group(tag, "name=[\"']([^\"']+)[\"']") {
                        claimed[role] = (n, tag)
                    }
                    break
                }
            }
        }
        if let (n, tag) = claimed["mediainfo"], tag.lowercased().contains("<textarea") || Self.hasType(tag, "text"),
           !info.mediainfo.isEmpty { add(n, info.mediainfo) }
        if let (n, _) = claimed["screenshot"] {
            let urls = NexusPHPAdapter.screenshotURLs(from: info.descr, base: site.url)
            if !urls.isEmpty { add(n, urls.map { "[img]\($0)[/img]" }.joined(separator: "\n")) }
        }
        if let (n, _) = claimed["title"] { add(n, uploadTitle(info)) }
        if let (n, _) = claimed["descr"] { add(n, description(info)) }
        if let (n, tag) = claimed["category"],
           let g = HTMLUtil.selectGroups(form, name: n).first {
            _ = tag
            for kw in kindKeys {
                if let o = g.options.first(where: { QualityMatcher.normalize($0.label).contains(QualityMatcher.normalize(kw)) && $0.value != "0" }) {
                    add(n, o.value)
                    break
                }
            }
            if !used.contains(n), let v = Self.categoryFallback(g.options, info: info) { add(n, v) }
        }
        if let (n, _) = claimed["region"], !info.region.isEmpty,
           let g = HTMLUtil.selectGroups(form, name: n).first,
           let v = RegionMatch.option(forRegion: info.region, in: g.options) {
            add(n, v)
        }
        if let (n, _) = claimed["team"], let g = HTMLUtil.selectGroups(form, name: n).first {
            if let o = g.options.first(where: { o in
                guard o.value != "0" else { return false }
                let t = QualityMatcher.normalize(o.label)
                return t == "其他" || t == "其它" || t == "other" || t.contains("个人原创")
            }) {
                add(n, o.value)
            }
        }
        if let d = info.douban, let (n, _) = claimed["douban"] {
            add(n, override?.doubanValueTemplate?.replacingOccurrences(of: "{douban}", with: d)
                ?? "https://movie.douban.com/subject/\(d)/")
        }
        if let imdb = info.imdb, let (n, _) = claimed["imdb"] {
            add(n, override?.imdbValueTemplate?.replacingOccurrences(of: "{imdb}", with: imdb) ?? imdb)
        }
        return (out, fileField)
    }

    /// 站点没有同类目时（YZYY 只有华语剧/外语剧/华语电影…）按「体裁 + 产地」兜底选版块
    static func categoryFallback(_ options: [(value: String, label: String)], info: ReleaseInfo) -> String? {
        let groups: [[String]]
        switch info.kind {
        case .movie: groups = [["电影", "影片"], ["剧"]]
        case .music: groups = [["音乐", "音频"], ["其它", "其他"]]
        case .tvshow: groups = [["综艺"], ["剧"]]
        case .documentary: groups = [["纪录"], ["剧"]]
        default: groups = [["剧", "番"], ["其它", "其他"]]
        }
        let cn = info.region.isEmpty || info.region.contains("中") || info.region.contains("港")
            || info.region.contains("台")
        let lang = cn ? ["华语", "中文", "国产"] : ["外语", "欧美", "海外", "日语"]
        for group in groups {
            let hits = options.filter { o in
                o.value != "0" && group.contains { QualityMatcher.normalize(o.label).contains(QualityMatcher.normalize($0)) }
            }
            if let hit = hits.first(where: { o in lang.contains { QualityMatcher.normalize(o.label).contains(QualityMatcher.normalize($0)) } }) {
                return hit.value
            }
            if let hit = hits.first { return hit.value }
        }
        return nil
    }

    /// 表单里的控件（input / select / textarea）及其位置
    static func controlRanges(_ form: String) -> [(tag: String, at: String.Index)] {
        let re = try! NSRegularExpression(pattern: "<(input|select|textarea)[^>]*>", options: [.caseInsensitive])
        return re.matches(in: form, options: [], range: NSRange(form.startIndex..., in: form)).compactMap { m in
            guard let r = Range(m.range, in: form) else { return nil }
            return (String(form[r]), r.lowerBound)
        }
    }

    private func uploadTitle(_ info: ReleaseInfo) -> String {
        let mode = override?.titleMode ?? ""
        if mode == "torrentName" { return (info.torrentName as NSString).deletingPathExtension }
        return info.name
    }

    private func description(_ info: ReleaseInfo) -> String {
        let html = NexusPHPAdapter.preprocessDescription(info.descr, base: site.url, dropScreenshots: false)
        var out = BBCode.fromHTML(html, base: URL(string: site.url))
        out = BBCode.insertMediainfo(out, mediainfo: info.mediainfo)
        if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out = NexusPHPAdapter.fallbackDescr(info) }
        // 来源引用只认「批量转种」页手填的源站引用（可选项），官种不再自动加致谢
        return info.extraQuoteBBCode + out
    }

    /// Discuz 表单 action（可能是相对路径或带查询串的插件 URL）
    private func formActionURL(_ page: String) -> String? {
        guard let form = Self.uploadForm(page),
              let action = HTMLUtil.group(form, "<form[^>]*action=[\"']([^\"']*)[\"']", options: [.caseInsensitive]),
              !action.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return HTMLUtil.resolveURL(HTMLUtil.decodeEntities(action), against: URL(string: site.url)!)
    }

    /// 插件自带 ptgen 接口时（YZYY：source/plugin/dz_seed/ptgen_local.php），
    /// 像浏览器一样先取豆瓣数据再提交，站点就不会重复解析或解析失败
    private func withPTGenResult(_ fields: [HTTPClient.MultipartField], page: String,
                                info: ReleaseInfo) -> [HTTPClient.MultipartField] {
        let name = "ptgen_result"
        guard fields.contains(where: { $0.name == name }),
              let helper = HTMLUtil.group(page, "([a-zA-Z0-9./?=&:_-]*ptgen_local\\.php)"),
              let douban = info.douban else { return fields }
        let link = HTMLUtil.resolveURL(helper, against: URL(string: site.url + uploadPath)!)
            + "?url=" + ("https://movie.douban.com/subject/\(douban)/".urlEncoded)
        guard let resp = try? client.get(link, referer: site.url + uploadPath),
              resp.status < 400, resp.data.count > 16 else { return fields }
        let json = String(data: resp.data, encoding: .utf8) ?? ""
        return fields.map { $0.name == name ? HTTPClient.MultipartField(name, json) : $0 }
    }

    private func save(_ kind: String, _ text: String) {
        guard let dir = debugDir else { return }
        let f = URL(fileURLWithPath: dir).appendingPathComponent("\(kind)-\(site.id)-\(Int(Date().timeIntervalSince1970)).html")
        try? text.data(using: .utf8)?.write(to: f)
    }
}
