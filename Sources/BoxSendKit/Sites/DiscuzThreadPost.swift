import Foundation

/// Discuz 插件发种的第二步（YZYY dz_seed 插件实测 2026-10-06）：
/// 发布表单 POST 只把种子与 ptgen 结果暂存到会话，页面用 JS 跳到
/// forum.php?mod=post&action=newthread；发帖页先弹「发帖须知」，同意后才渲染真正的
/// postform（subject / message + 分类信息 typeoption[...]）。这一步补完才算发出种子帖。
extension DiscuzAdapter {
    struct ThreadPostContext {
        var title: String
        var message: String
        var info: ReleaseInfo
    }

    /// 第二步页面存档（Discuz 拒绝时按提示补字段用）
    private func save(_ kind: String, _ text: String) {
        guard let root = debugDir else { return }
        let dir = (root as NSString).appendingPathComponent("debug")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = URL(fileURLWithPath: dir).appendingPathComponent("step2-\(kind)-\(site.id)-\(Int(Date().timeIntervalSince1970)).html")
        try? text.data(using: .utf8)?.write(to: f)
    }

    /// 返回 nil 表示这不是两步发帖的页面，调用方按一步提交的结果判定
    func completeThreadPost(_ publishBody: String, ctx: ThreadPostContext) throws -> UploadOutcome? {
        guard let target = DiscuzThreadPost.redirectTarget(publishBody),
              target.lowercased().contains("action=newthread") else { return nil }
        var page = try client.fetchHTML(target, referer: site.url)
        // 发帖须知：提交该表单的隐藏域（formhash）即可放行
        if let notice = DiscuzThreadPost.noticeForm(page) {
            let action = HTMLUtil.group(notice, "action=[\"']([^\"']*)[\"']")
                .map { HTMLUtil.resolveURL(HTMLUtil.decodeEntities($0), against: URL(string: site.url)!) } ?? target
            let fields = DiscuzThreadPost.hiddenFields(notice)
            _ = try? client.postMultipart(action, fields: fields, files: [], referer: target)
            page = try client.fetchHTML(target, referer: target)
        }
        guard let form = DiscuzThreadPost.postForm(page) else { return nil }
        save("form", page)
        var fields = DiscuzThreadPost.fields(form, ctx: ctx)
        // 防灌水图片验证码：先按浏览器同款流程识图作答，通过后随表单一起提交
        if let seccode = solveSeccode(page, referer: target) {
            for f in seccode where !fields.contains(where: { $0.name == f.0 }) {
                fields.append(HTTPClient.MultipartField(f.0, f.1))
            }
        }
        let action = HTMLUtil.group(form, "<form[^>]*action=[\"']([^\"']*)[\"']", options: [.caseInsensitive])
            .map { HTMLUtil.resolveURL(HTMLUtil.decodeEntities($0), against: URL(string: site.url)!) } ?? target
        let resp = try client.postMultipart(action, fields: fields, files: [], referer: target)
        let body = String(data: resp.data, encoding: .utf8) ?? ""
        save("post", body)
        // Discuz 的结果都写在 showmessage 里，取出来当错误原因（整页去标签会混进导航文字）
        let text = DiscuzThreadPost.messageText(body) ?? HTMLUtil.stripTags(body)
        // 帖子进了审核队列时站点不回跳 URL，tid 只写在提示块里的 JS 跳转中
        let review = text.contains("审核")
        if let tid = DiscuzThreadPost.threadID(body, finalURL: resp.finalURL) {
            return UploadOutcome(success: true, message: review ? "发帖成功（待版主审核）" : "发帖成功",
                                 detailURL: site.url + "thread-\(tid)-1-1.html")
        }
        if ["发布成功", "帖子发布成功", "发表成功", "需要审核"].contains(where: { text.contains($0) }) {
            return UploadOutcome(success: true, message: review ? "发帖成功（待版主审核）" : "发帖成功", detailURL: nil)
        }
        if text.contains("已存在") || text.contains("已经存在") {
            return UploadOutcome(success: true, message: "站点已存在该种子", detailURL: nil, alreadyExists: true)
        }
        if text.contains("验证码填写错误") || text.contains("请先填写验证码") || text.contains("验证方式") {
            // 图片验证码认不出来（YZYY 的字体形近字多）：种子已暂存，站内点「发布」补完即可
            return UploadOutcome(success: false,
                                 message: "种子已投递，发帖页的验证码没能自动识别，请在站内点「发布」补完发帖",
                                 detailURL: nil)
        }
        let brief = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return UploadOutcome(success: false, message: "发帖未完成：\(brief.prefix(120))", detailURL: nil)
    }
}

extension DiscuzAdapter {
    /// Discuz X3.x 防灌水图片验证码（YZYY 发帖必过）：按前端同款流程走
    /// `misc.php?mod=seccode&action=update` 取部件 -> 下载验证码图 -> Vision 识字
    /// -> `action=check` 校验，认错的轮次重新取图重试（站点每次取图都换新码）。
    /// 校验通过后 Discuz 把该 idhash 标记为已验证，发帖表单必须带回
    /// seccodehash / seccodemodid / seccodeverify 三个字段。
    func solveSeccode(_ page: String, referer: String, attempts: Int = 6) -> [(String, String)]? {
        guard let idhash = HTMLUtil.group(page, "updateseccode\\(\\s*'([0-9A-Za-z_]+)'") else { return nil }
        let modid = HTMLUtil.group(page, #"updateseccode\([^)]*,\s*'([^']*)'\s*\)"#) ?? "forum::post"
        for _ in 0..<attempts {
            let upURL = site.url + "misc.php?mod=seccode&action=update&idhash=\(idhash)"
                + "&0.\(Int.random(in: 100...999))&modid=\(modid.urlEncoded)"
            guard let up = try? client.get(upURL, referer: referer),
                  let js = String(data: up.data, encoding: .utf8),
                  let imgPath = HTMLUtil.group(js, #"src=["']?(misc\.php\?mod=seccode&update=\d+&idhash=[0-9A-Za-z_]+)"#),
                  let img = try? client.get(HTMLUtil.resolveURL(imgPath, against: URL(string: site.url)!),
                                           referer: referer).data,
                  let code = SeccodeOCR.code(img) else { continue }
            let check = site.url + "misc.php?mod=seccode&action=check&inajax=1&modid=\(modid.urlEncoded)"
                + "&idhash=\(idhash)&secverify=\(code)"
            if let r = try? client.get(check, referer: referer),
               String(data: r.data, encoding: .utf8)?.contains("succeed") == true {
                return [("seccodehash", idhash), ("seccodemodid", modid), ("seccodeverify", code)]
            }
        }
        return nil
    }
}

enum DiscuzThreadPost {
    /// 页面里的 JS/meta 跳转目标（Discuz showmessage 用 location.href）
    static func redirectTarget(_ body: String) -> String? {
        if let u = HTMLUtil.group(body, "location\\.href\\s*=\\s*[\"']([^\"']+)[\"']") { return decode(u) }
        if let u = HTMLUtil.group(body, "URL=['\"]?redirect['\"]?[^\"]*\"([^\"]+)\"") { return decode(u) }
        if let u = HTMLUtil.group(body, "<meta[^>]*http-equiv=[\"']refresh[\"'][^>]*url=([^\"' >]+)",
                                  options: [.caseInsensitive]) { return decode(u) }
        if let u = HTMLUtil.group(body, "(forum\\.php\\?[^\"'<> ]*action=newthread[^\"'<> ]*)") { return decode(u) }
        return nil
    }

    static func decode(_ s: String) -> String { HTMLUtil.decodeEntities(s) }

    /// 「发帖须知」拦截表单
    static func noticeForm(_ page: String) -> String? {
        for f in forms(page) where (HTMLUtil.group(f, "action=[\"']([^\"']*)[\"']") ?? "").lowercased().contains("notice") {
            return f
        }
        return nil
    }

    /// 真正的发帖表单：action 里带 action=newthread
    static func postForm(_ page: String) -> String? {
        forms(page).first { f in
            let a = (HTMLUtil.group(f, "<form[^>]*action=[\"']([^\"']*)[\"']") ?? "").lowercased()
            return a.contains("newthread")
        }
    }

    static func forms(_ page: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "<form[\\s\\S]*?</form>", options: [.caseInsensitive])
        return re.matches(in: page, options: [], range: NSRange(page.startIndex..., in: page))
            .compactMap { Range($0.range, in: page) }.map { String(page[$0]) }
    }

    static func hiddenFields(_ form: String) -> [HTTPClient.MultipartField] {
        HTMLUtil.allMatches(form, "<input[^>]*>", options: [.caseInsensitive]).compactMap { tag in
            guard DiscuzAdapter.hasType(tag, "hidden"),
                  let n = HTMLUtil.group(tag, "name=[\"']([^\"']+)[\"']") else { return nil }
            return HTTPClient.MultipartField(n, HTMLUtil.group(tag, "value=[\"']([^\"']*)[\"']") ?? "")
        }
    }

    /// 发帖表单字段：隐藏域 + 表单默认下拉 + 标题/正文 + 分类信息（typeoption）
    static func fields(_ form: String, ctx: DiscuzAdapter.ThreadPostContext) -> [HTTPClient.MultipartField] {
        var out: [HTTPClient.MultipartField] = []
        var seen = Set<String>()
        func add(_ name: String, _ value: String) {
            guard !name.isEmpty, !seen.contains(name), !name.contains("[") else { return }
            seen.insert(name)
            out.append(.init(name, value))
        }
        for f in hiddenFields(form) { add(f.name, f.value) }
        // 其它下拉：按浏览器行为提交默认项（selected 优先，否则首项）
        for tag in HTMLUtil.allMatches(form, "<select[^>]*name=[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</select>",
                                       options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            guard let name = HTMLUtil.group(tag, "name=[\"']([^\"']+)[\"']"), !name.contains("[") else { continue }
            let selected = HTMLUtil.group(tag, "<option[^>]*selected[^>]*value=[\"']([^\"']*)[\"']")
                ?? HTMLUtil.group(tag, "<option[^>]*value=[\"']([^\"']*)[\"']")
            add(name, selected ?? "")
        }
        if form.lowercased().contains("name=\"subject\"") || form.lowercased().contains("name='subject'") {
            add("subject", ctx.title)
        }
        if form.lowercased().contains("name=\"message\"") || form.lowercased().contains("name='message'") {
            out.append(.init("message", ctx.message))     // 正文可重名，直接追加
        }
        for f in typeOptionFields(form, info: ctx.info) { out.append(f) }
        return out
    }

    /// 分类信息（typeoption[...]）：按行标签认领角色，再按选项文案挑值
    static func typeOptionFields(_ form: String, info: ReleaseInfo) -> [HTTPClient.MultipartField] {
        // 组名 -> (行标签, [(值, 选项文案)])
        var groups: [String: (label: String, opts: [(value: String, text: String)])] = [:]
        for (tag, at) in DiscuzAdapter.controlRanges(form) {
            guard DiscuzAdapter.hasType(tag, "radio") || DiscuzAdapter.hasType(tag, "checkbox") else { continue }
            guard let name = HTMLUtil.group(tag, "name=[\"']([^\"']+)[\"']") else { continue }
            let value = HTMLUtil.group(tag, "value=[\"']([^\"']*)[\"']") ?? ""
            let after = String(form[at...].prefix(400))
            let label = DiscuzAdapter.labelBefore(form, controlStart: at)
            let opt = (value: value, text: optionText(tag, after: after))
            if groups[name] == nil { groups[name] = (label, [opt]) } else { groups[name]!.opts.append(opt) }
        }
        var out: [HTTPClient.MultipartField] = []
        let profile = QualityTokens.catProfile(from: info.name, kind: info.kind)
        for (name, g) in groups.sorted(by: { $0.key < $1.key }) {
            let label = QualityMatcher.normalize(g.label)
            func pick(_ candidates: [String]) -> String? {
                for c in candidates {
                    if let o = g.opts.first(where: { QualityMatcher.normalize($0.text) == c }) { return o.value }
                }
                for c in candidates {
                    if let o = g.opts.first(where: { QualityMatcher.normalize($0.text).contains(c) }) { return o.value }
                }
                return nil
            }
            func other() -> String? {
                g.opts.first { let t = QualityMatcher.normalize($0.text)
                    return t == "其它" || t == "其他" || t == "other" }?.value
            }
            var value: String?
            if label.contains("地区") || label.contains("国家") {
                value = RegionMatch.option(forRegion: info.region,
                                           in: g.opts.map { (value: $0.value, label: $0.text) })
                    ?? other()
            } else if label.contains("分辨率") || label.contains("清晰度") {
                value = pick(QualityTokens.standard(from: info.name).map { [$0] } ?? []) ?? other()
            } else if label.contains("视频编码") || label.contains("编码格式") {
                value = pick(QualityTokens.codec(from: info.name, mediainfo: info.mediainfo).map { [$0] } ?? []) ?? other()
            } else if label.contains("音频编码") || label.contains("音轨") {
                value = pick(QualityTokens.audio(from: info.name).map { [$0] } ?? []) ?? other()
            } else if label.contains("字幕") {
                let tags = QualityTokens.canonicalTags(info)
                let keys = (tags.contains("cnsub") ? ["中字", "中文", "简中"] : []) + ["无字幕", "其它"]
                value = pick(keys) ?? other()
            } else if label.contains("语言") || label.contains("语系") {
                value = pick(info.region.contains("日本") ? ["日语", "日文"] : ["其它"]) ?? other()
            } else if label.contains("完结") || label.contains("全集") || label.contains("分集") || label.contains("连载") {
                value = QualityTokens.isCompletedRelease(info) ? pick(["完结", "全集", "完整"]) ?? other()
                    : pick(["未完结", "连载中", "分集", "其它"]) ?? other()
            } else if label.contains("媒介") || label.contains("介质") || label.contains("来源") {
                value = pick(PeerGoAdapter.sourceMediumTokens(profile)) ?? other()
            } else if label.contains("发布类型") {
                value = pick(PeerGoAdapter.releaseTypeTokens(profile)) ?? other()
            }
            if let v = value, !v.isEmpty { out.append(.init(name, v)) }
        }
        return out
    }

    /// 发帖结果里的帖子 ID：先看跳转参数，再看提示块内的 thread-<id>-1-1 链接。
    /// 只看提示块：Discuz 提示页的侧栏也满是 thread 链接，整页找会把失败页读成成功。
    static func threadID(_ body: String, finalURL: String = "") -> String? {
        HTMLUtil.group(finalURL, "[?&](?:pt|t)id=(\\d+)")
            ?? HTMLUtil.group(body, "[?&](?:pt|t)id=(\\d+)")
            ?? HTMLUtil.group(messageBlock(body) ?? "", "thread-(\\d+)-\\d+-\\d+\\.html")
    }

    /// Discuz showmessage 提示块的原始 HTML（成功跳转的 thread 链接常写在里面的 JS 中）
    static func messageBlock(_ body: String) -> String? {
        HTMLUtil.group(body, "id=[\"']messagetext[\"'][\\s\\S]*?</div>", group: 0,
                       options: [.dotMatchesLineSeparators])
    }

    /// Discuz showmessage 提示页的正文（<div id="messagetext" class="alert_..."><p>正文</p>）
    static func messageText(_ body: String) -> String? {
        guard let block = messageBlock(body) else { return nil }
        let t = HTMLUtil.stripTags(HTMLUtil.decodeEntities(block))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : String(t.prefix(200))
    }

    /// 选项文案：value 属性 + 控件后面紧跟的文本（Discuz 分类信息常把文案写在控件后）
    private static func optionText(_ tag: String, after: String) -> String {
        let v = HTMLUtil.group(tag, "value=[\"']([^\"']*)[\"']") ?? ""
        let head = String(after.dropFirst(tag.count).prefix(80))
        let t = HTMLUtil.stripTags(HTMLUtil.decodeEntities(head)).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? v : String(t.prefix(30))
    }
}
