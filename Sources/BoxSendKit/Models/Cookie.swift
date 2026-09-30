import Foundation

/// 与 chrome.cookies.Cookie / PT-depiler 备份格式对齐的 cookie 结构。
public struct Cookie: Codable, Hashable {
    public var name: String
    public var value: String
    public var domain: String?
    public var path: String?
    public var secure: Bool?
    public var httpOnly: Bool?
    public var expirationDate: Double?
}

/// 按站点 host 维护的 cookie 集合。
/// 请求 host 为 H 时，jar 中 key == H 或 key 是 H 的父域名的条目都会带上。
public final class CookieStore {
    private var byHost: [String: [Cookie]] = [:]

    public init() {}
    private let lock = NSLock()

    public func importCookies(host: String, cookies: [Cookie]) {
        lock.lock(); defer { lock.unlock() }
        byHost[host] = cookies
    }

    /// 解析一条 Set-Cookie 头并合并入 jar
    public func importSetCookie(_ header: String, host: String) {
        var cookie = Cookie(name: "", value: "", domain: host, path: "/")
        let parts = header.split(separator: ";")
        for (idx, part) in parts.enumerated() {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else {
                if idx == 0 { cookie.name = trimmed }
                continue
            }
            let k = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let v = kv[1].trimmingCharacters(in: .whitespaces)
            switch k {
            case "name": cookie.name = v
            case "value": cookie.value = v
            case "domain": cookie.domain = v
            case "path": cookie.path = v
            case "expires":
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.timeZone = TimeZone(identifier: "GMT")
                fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                cookie.expirationDate = fmt.date(from: v)?.timeIntervalSince1970
            case "max-age":
                if let s = Double(v) { cookie.expirationDate = Date().timeIntervalSince1970 + s }
            case "secure": cookie.secure = true
            case "httponly": cookie.httpOnly = true
            default:
                // 首段无标准属性名时视为 name=value（如 "SID=xxx"），保留 name 大小写
                if idx == 0 && cookie.name.isEmpty {
                    cookie.name = kv[0].trimmingCharacters(in: .whitespaces)
                    cookie.value = v
                }
            }
        }
        guard !cookie.name.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if var existing = byHost[host] {
            if let i = existing.firstIndex(where: { $0.name == cookie.name }) {
                existing[i] = cookie
            } else {
                existing.append(cookie)
            }
            byHost[host] = existing
        } else {
            byHost[host] = [cookie]
        }
    }

    /// 生成请求 host 应携带的 `Cookie` 头；无 cookie 时返回 nil。
    public func cookieHeader(forHost host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let host = normalized(host)
        var pairs: [String] = []
        for (key, cookies) in byHost {
            let key = normalized(key)
            guard host == key || host.hasSuffix("." + key) else { continue }
            for c in cookies where !c.value.isEmpty || c.expirationDate == nil {
                pairs.append("\(c.name)=\(c.value)")
            }
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    public func hosts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return byHost.keys.sorted()
    }

    public func snapshot() -> [String: [Cookie]] {
        lock.lock(); defer { lock.unlock() }
        return byHost
    }

    public var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return byHost.values.allSatisfy { $0.isEmpty }
    }

    /// 从 PT-depiler 备份的 cookies 结构导入：`{ "host": [Cookie] }`。
    /// 也兼容 `{ "cookies": { "host": [Cookie] } }` 外层包裹。
    @discardableResult
    public func importBackupJSON(_ data: Data) throws -> Int {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            throw BoxSendError.badInput("cookie JSON 顶层应为对象")
        }
        let source: [String: Any]
        if let inner = dict["cookies"] as? [String: Any] {
            source = inner
        } else {
            source = dict
        }
        var count = 0
        for (host, value) in source {
            guard host.lowercased().hasPrefix("http") == false else { continue }
            let rawCookies = (value as? [[String: Any]]) ?? []
            let data = try JSONSerialization.data(withJSONObject: rawCookies)
            let cookies = try JSONDecoder().decode([Cookie].self, from: data)
            importCookies(host: host, cookies: cookies)
            count += cookies.count
        }
        return count
    }

    /// 从 "k1=v1; k2=v2" 形式的裸 cookie 字符串导入。
    public func importRawString(host: String, _ raw: String) {
        var cookies: [Cookie] = []
        for part in raw.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            cookies.append(Cookie(name: kv[0], value: kv[1], domain: host, path: "/"))
        }
        importCookies(host: host, cookies: cookies)
    }

    private func normalized(_ host: String) -> String {
        var h = host.lowercased().trimmingCharacters(in: .whitespaces)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let r = h.range(of: "/") { h = String(h[..<r.lowerBound]) }
        return h
    }

    /// 移除某个 host 的全部 cookie（按归一化 host 匹配）
    @discardableResult
    public func removeHost(_ host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let h = normalized(host)
        guard let key = byHost.keys.first(where: { normalized($0) == h }) else { return false }
        byHost.removeValue(forKey: key)
        return true
    }

    /// 清空全部 cookie
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        byHost.removeAll()
    }

    /// 用备份 JSON 整体替换现有内容（web 控制台热加载本地 cookies.json 用）
    @discardableResult
    public func replace(from data: Data) throws -> Int {
        clear()
        return try importBackupJSON(data)
    }

    /// 导出为与 importBackupJSON 兼容的备份结构：{"cookies": {host: [...]}}
    public func exportBackupJSON() -> Data? {
        var dict: [String: Any] = [:]
        for (host, arr) in snapshot() {
            guard let d = try? JSONEncoder().encode(arr),
                  let j = try? JSONSerialization.jsonObject(with: d) else { continue }
            dict[host] = j
        }
        return try? JSONSerialization.data(withJSONObject: ["cookies": dict], options: [.prettyPrinted])
    }
}

public enum BoxSendError: LocalizedError {
    case badInput(String)
    case http(status: Int, url: String, body: String)
    case cookieExpired(String)
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .badInput(let m): return "输入错误: \(m)"
        case .http(let s, let u, let b): return "HTTP \(s) \(u): \(String(b.prefix(300)))"
        case .cookieExpired(let h): return "站点 \(h) 的 cookie 可能已失效，请在 PT-depiler 中重新登录并触发备份"
        case .notImplemented(let m): return "尚未实现: \(m)"
        }
    }
}
