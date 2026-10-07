import Foundation

/// 备份来源（CookieCloud / PT-depiler Gist）的 cookie 条目 → {host: "k=v; k=v"}。
///
/// 同一站点的 cookie 常分散在 `.example.com` 与 `example.com` 两个分组键里
/// （CookieCloud 按 cookie 域分组，带点的域 cookie 和不带点的 host-only cookie 各成一组），
/// 直接按 host 建字典会整组互相覆盖，cf_clearance 这类关键 cookie 就整条丢了。
/// 这里按「站点 + cookie 名」合并，同名保留过期时间更晚的那份。
public struct CookieRawMerge {
    struct Entry { let value: String; let exp: Double? }
    /// host -> (按出现顺序的名称列表, 名称 -> 值)；列表是为了让导出的 Cookie 头顺序稳定
    typealias Acc = [String: (order: [String], values: [String: Entry])]

    /// host 归一化：去前导点、去协议/路径/端口
    public static func norm(_ host: String) -> String {
        var h = host.lowercased().trimmingCharacters(in: .whitespaces)
        if h.hasPrefix(".") { h.removeFirst() }
        if h.contains("://"), let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let i = h.firstIndex(of: "/") { h = String(h[..<i]) }
        if let i = h.firstIndex(of: ":") { h = String(h[..<i]) }
        return h
    }

    public mutating func add(host: String, name: String, value: String, exp: Double?) {
        let h = Self.norm(host)
        guard !h.isEmpty, !name.isEmpty else { return }
        var entry = acc[h] ?? ([], [:])
        if let old = entry.values[name], (old.exp ?? -1) > (exp ?? -1) { return }   // 已有更新（过期更晚）的一份
        if !entry.order.contains(name) { entry.order.append(name) }
        entry.values[name] = Entry(value: value, exp: exp)
        acc[h] = entry
    }

    public func serialized() -> [String: String] {
        var out: [String: String] = [:]
        for (h, e) in acc {
            let raw = e.order.compactMap { name -> String? in
                guard let v = e.values[name] else { return nil }
                return "\(name)=\(v.value)"
            }.joined(separator: "; ")
            if !raw.isEmpty { out[h] = raw }
        }
        return out
    }

    private var acc: Acc = [:]
    public init() {}
}

extension CookieRawMerge {
    /// 从备份里的一条 cookie 记录取字段（CookieCloud 与 PT-depiler 都用 chrome.cookies 风格字段）
    public static func expiration(of entry: [String: Any]) -> Double? {
        if let d = entry["expirationDate"] as? Double { return d }
        if let i = entry["expirationDate"] as? Int { return Double(i) }
        if let d = entry["expires"] as? Double { return d }
        return nil
    }
}

extension CookieRawMerge {
    /// 备份里的 {host: [cookie 条目]} → {归一化 host: "k=v; k=v"}（CookieCloud 与 PT-depiler Gist 通用）
    public static func rawStrings(map: [String: Any]) -> [String: String] {
        var merge = CookieRawMerge()
        for (host, value) in map {
            guard let arr = value as? [[String: Any]] else { continue }
            for c in arr {
                guard let n = c["name"] as? String, let v = c["value"] as? String else { continue }
                merge.add(host: host, name: n, value: v, exp: expiration(of: c))
            }
        }
        return merge.serialized()
    }
}
