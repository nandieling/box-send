import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 轻量 HTTP 客户端：手动管理 Cookie（不发 Set-Cookie 自动存储），支持 multipart 表单。
public final class HTTPClient {
    let cookies: CookieStore
    var userAgent: String
    var timeout: TimeInterval = 90
    /// 上传类站点返回 302/303 后是否跟随（跟随到发布成功页时用于二次校验）
    var followRedirects = true
    /// 调试时保留最后一段响应体
    var lastResponseBody = ""
    /// 自动把 Set-Cookie 存入 CookieStore（qBittorrent SID 等场景需要）
    var storeSetCookies = true

    lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.httpAdditionalHeaders = ["Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"]
        cfg.httpShouldUsePipelining = false
        return URLSession(configuration: cfg)
    }()
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
        return try perform(req)
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

    private func perform(_ req: URLRequest) throws -> Response {
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
                self.cookies.importSetCookie(setCookie, host: finalHost)
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
