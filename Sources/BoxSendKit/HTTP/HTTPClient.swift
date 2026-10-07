import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 轻量 HTTP 客户端：手动管理 Cookie（不发 Set-Cookie 自动存储），支持 multipart 表单。
public final class HTTPClient {
    let cookies: CookieStore
    var userAgent: String
    var timeout: TimeInterval = 90
    /// 整个请求（含重试/跳转）的总时长上限；检测类短任务会压到与 timeout 相同
    var resourceTimeout: TimeInterval = 180
    /// 上传类站点返回 302/303 后是否跟随（跟随到发布成功页时用于二次校验）
    var followRedirects = true
    /// 调试时保留最后一段响应体
    var lastResponseBody = ""
    /// 单测/调试用：注入的响应（跳过真实网络）
    var performOverride: ((URLRequest) throws -> Response)?
    /// 自动把 Set-Cookie 存入 CookieStore（qBittorrent SID 等场景需要）
    var storeSetCookies = true

    private var sessionRef: URLSession?
    /// 连接池按当前 timeout 惰性创建；setRequestTimeout 会重建它
    var session: URLSession {
        if let s = sessionRef { return s }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = resourceTimeout
        cfg.httpAdditionalHeaders = ["Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"]
        cfg.httpShouldUsePipelining = false
        let made = URLSession(configuration: cfg)
        sessionRef = made
        return made
    }

    /// 缩短请求超时（cookie / API Key 检测等短任务用），已建连接池则重建
    public func setRequestTimeout(_ seconds: TimeInterval) {
        timeout = max(1, seconds)
        resourceTimeout = timeout
        sessionRef?.invalidateAndCancel()
        sessionRef = nil
    }

    /// 供外部手动构造请求时复用（如 Transmission RPC）
    var session0: URLSession { session }

    public struct Response {
        public var status: Int
        public var data: Data
        public var headers: [String: String]
        public var finalURL: String
    }

    public init(cookies: CookieStore, userAgent: String) {
        self.cookies = cookies
        self.userAgent = userAgent
    }

    // MARK: - 请求

    @discardableResult
    public func get(_ url: String, referer: String? = nil, extraHeaders: [String: String] = [:]) throws -> Response {
        var req = try makeRequest(url: url, method: "GET", referer: referer, extraHeaders: extraHeaders)
        req.httpMethod = "GET"
        return try perform(req)
    }

    /// 普通表单 POST（x-www-form-urlencoded）
    @discardableResult
    func postForm(_ url: String, fields: [String: String], referer: String? = nil) throws -> Response {
        var req = try makeRequest(url: url, method: "POST", referer: referer)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields
            .map { key, value in
                (key.urlEncoded) + "=" + (value.urlEncoded)
            }
            .joined(separator: "&")
            .data(using: .utf8)
        return try perform(req)
    }

    /// multipart 文本字段（有序，允许同名多次，如 option_sel[]）
    public struct MultipartField {
        public let name: String
        public let value: String
        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    /// multipart/form-data POST，可混入文本字段与文件
    @discardableResult
    public func postMultipart(_ url: String, fields: [MultipartField],
                       files: [(name: String, filename: String, data: Data, mime: String)],
                       referer: String? = nil, extraHeaders: [String: String] = [:]) throws -> Response {
        try perform(multipartRequest(url: url, fields: fields, files: files,
                                     referer: referer, extraHeaders: extraHeaders))
    }

    /// 构造 multipart 请求（要自行控制跳转时配合 performWithoutRedirect 用）
    func multipartRequest(url: String, fields: [MultipartField],
                          files: [(name: String, filename: String, data: Data, mime: String)],
                          referer: String? = nil, extraHeaders: [String: String] = [:]) throws -> URLRequest {
        let boundary = "----BoxSend" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var body = Data()
        func addHeader(name: String, filename: String? = nil, mime: String? = nil) {
            if let filename {
                body.append(("--\(boundary)\r\n" +
                             "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n" +
                             "Content-Type: \(mime ?? "application/octet-stream")\r\n\r\n").data(using: .utf8)!)
            } else {
                body.append(("--\(boundary)\r\n" +
                             "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n").data(using: .utf8)!)
            }
        }
        for f in fields {
            addHeader(name: f.name)
            body.append(f.value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        for f in files {
            addHeader(name: f.name, filename: f.filename, mime: f.mime)
            body.append(f.data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = try makeRequest(url: url, method: "POST", referer: referer, extraHeaders: extraHeaders)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    /// 只发一次请求、绝不跟随 302（城市 HDCity 第一步：种子 POST 到独立上传域名，
    /// 跳转目标属于站点自己的域，必须换成本站链接后重新带 cookie 请求）
    func performWithoutRedirect(_ req: URLRequest) throws -> Response {
        if let override = performOverride { return try override(req) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.httpAdditionalHeaders = ["Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"]
        let stopper = NoRedirectDelegate()
        let session = URLSession(configuration: cfg, delegate: stopper, delegateQueue: nil)
        let task = session.dataTask(with: req)
        task.resume()
        _ = stopper.sem.wait(timeout: .now() + timeout + 30)
        session.invalidateAndCancel()
        guard let http = stopper.response else {
            throw BoxSendError.badInput("无响应: \(req.url?.absoluteString ?? "")")
        }
        var headers = [String: String]()
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String { headers[ks.lowercased()] = "\(v)" }
        }
        if storeSetCookies, let setCookie = headers["set-cookie"], let host = (http.url ?? req.url)?.host {
            for part in Self.splitSetCookieHeader(setCookie) {
                cookies.importSetCookie(part, host: host)
            }
        }
        lastResponseBody = String(data: stopper.data.prefix(4000), encoding: .utf8) ?? ""
        return Response(status: http.statusCode, data: stopper.data, headers: headers,
                        finalURL: (http.url ?? req.url!).absoluteString)
    }

    /// 拦下 302：把重定向响应本身交回调用方
    private final class NoRedirectDelegate: NSObject, URLSessionDataDelegate {
        let sem = DispatchSemaphore(value: 0)
        var response: HTTPURLResponse?
        var data = Data()
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            self.response = response
            completionHandler(nil)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if self.response == nil { self.response = response as? HTTPURLResponse }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            self.data.append(data)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            sem.signal()
        }
    }

    // MARK: - 内部

    private func makeRequest(url: String, method: String, referer: String? = nil, extraHeaders: [String: String] = [:]) throws -> URLRequest {
        guard let u = URL(string: url) else {
            throw BoxSendError.badInput("非法 URL: \(url)")
        }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let header = cookies.cookieHeader(forHost: u.host ?? "") {
            req.setValue(header, forHTTPHeaderField: "Cookie")
        }
        req.setValue(referer ?? url, forHTTPHeaderField: "Referer")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    /// application/json POST（TNode 搜索等）
    @discardableResult
    func postJSON(_ url: String, object: Any, referer: String? = nil, extraHeaders: [String: String] = [:]) throws -> Response {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else {
            throw BoxSendError.badInput("JSON 序列化失败")
        }
        var req = try makeRequest(url: url, method: "POST", referer: referer, extraHeaders: extraHeaders)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try perform(req)
    }

    /// 瞬时网络错误（连接中断 / TLS 握手失败 / DNS 抖动等）自动重试：
    /// 部分站 CDN 不稳定（如 ttg/okpt/luckpt），单次失败不应判为 cookie 失效或上传失败
    static let transientURLErrors: Set<Int> = [
        NSURLErrorNetworkConnectionLost,    // -1005
        NSURLErrorCannotConnectToHost,      // -1004
        NSURLErrorSecureConnectionFailed,   // -1200
        NSURLErrorCannotFindHost,           // -1003
        NSURLErrorTimedOut,                 // -1001
        NSURLErrorResourceUnavailable,      // -1011
    ]

    private func perform(_ req: URLRequest) throws -> Response {
        if let override = performOverride { return try override(req) }
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try performOnce(req)
            } catch let e as NSError where Self.transientURLErrors.contains(e.code) {
                guard attempt < 3 else { throw e }
                Thread.sleep(forTimeInterval: attempt == 1 ? 1.5 : 3)
            }
        }
    }

    /// URLSession 会把多个 Set-Cookie 头合并成一个逗号分隔串；逗号同样出现在 Expires 日期里，
    /// 所以只在"逗号后紧跟 name="处切分（日期里逗号后是 "09 Jun 2026…"，不会误切）
    static func splitSetCookieHeader(_ merged: String) -> [String] {
        guard merged.contains(", ") else { return [merged] }
        let re = try! NSRegularExpression(pattern: ",\\s*(?=[A-Za-z0-9_.\\-]+=)")
        let ns = merged as NSString
        var out: [String] = []
        var start = 0
        for m in re.matches(in: merged, options: [], range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + 1
        }
        out.append(ns.substring(from: start))
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func performOnce(_ req: URLRequest) throws -> Response {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Response, Error> = .failure(BoxSendError.badInput("no response"))
        let task = session.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                result = .failure(BoxSendError.badInput("非 HTTP 响应: \(req.url?.absoluteString ?? "")"))
                return
            }
            var headers = [String: String]()
            for (k, v) in http.allHeaderFields {
                if let ks = k as? String { headers[ks.lowercased()] = "\(v)" }
            }
            let resp = Response(status: http.statusCode, data: data ?? Data(),
                                 headers: headers, finalURL: (http.url ?? req.url!).absoluteString)
            self.lastResponseBody = String(data: (data ?? Data()).prefix(4000), encoding: .utf8) ?? ""
            if self.storeSetCookies, let setCookie = headers["set-cookie"], let finalHost = http.url?.host {
                // 一次下发多个 cookie（NexusPHP 会轮换 c_secure_*）时必须逐条入库，
                // 否则整串被当成一条 cookie 存下，下次请求就是失效凭证
                for part in Self.splitSetCookieHeader(setCookie) {
                    self.cookies.importSetCookie(part, host: finalHost)
                }
            }
            result = .success(resp)
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 30)
        return try result.get()
    }

    /// 便捷方法：GET 并返回 HTML 文本；登录失效（302 到登录页 / 403）时抛 cookieExpired。
    public func fetchHTML(_ url: String, referer: String? = nil) throws -> String {
        let resp = try get(url, referer: referer)
        if resp.status == 403 || resp.status == 401 {
            let host = (URL(string: url)?.host ?? url)
            throw BoxSendError.cookieExpired(host)
        }
        if resp.status >= 300, followRedirects {
            let final = resp.finalURL
            let loginHints = ["login", "enter.php", "signin", "auth/login"]
            if loginHints.contains(where: { final.lowercased().contains($0) }) {
                throw BoxSendError.cookieExpired((URL(string: url)?.host ?? url))
            }
        }
        guard let html = String(data: resp.data, encoding: .utf8)
            ?? String(data: resp.data, encoding: .isoLatin1) else {
            throw BoxSendError.badInput("无法解码页面: \(url)")
        }
        return html
    }
}

extension String {
    /// 表单编码（空格 -> +，与 PHP 一致）
    var urlEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = addingPercentEncoding(withAllowedCharacters: allowed) ?? self
        return encoded.replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: " ", with: "+")
    }
}
