import Foundation

/// 软件更新：更新地址就是项目的 GitHub Releases（https://github.com/nandieling/box-send）。
/// 只读公开接口、无需 token；直连 GitHub 不通时给一行明确原因，并让用户自己打开发布页。
public enum SoftwareUpdate {
    public static let repo = "nandieling/box-send"
    public static let repoURL = "https://github.com/\(repo)"
    public static let releasesURL = "\(repoURL)/releases"
    public static let latestAPIURL = "https://api.github.com/repos/\(repo)/releases/latest"

    public struct Release: Equatable {
        public var version: String        // tag 里的版本号（去掉前缀与非数字）
        public var title: String          // 发布标题（如 "BoxSend 1.1"）
        public var url: String            // 该版本的发布页
        public var downloadURL: String?   // 安装包资产（dmg 优先）
    }

    /// GitHub `releases/latest` 的 JSON -> 版本信息；读不出版本号返回 nil
    public static func parse(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        let version = normalizeVersion(tag)
        guard !version.isEmpty else { return nil }
        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        var download: String?
        for ext in ["dmg", "zip"] where download == nil {
            if let hit = assets.first(where: { (($0["name"] as? String) ?? "").lowercased().hasSuffix(ext) }),
               let u = hit["browser_download_url"] as? String { download = u }
        }
        if download == nil, let first = assets.first, let u = first["browser_download_url"] as? String {
            download = u
        }
        return Release(version: version,
                       title: (obj["name"] as? String) ?? "BoxSend \(version)",
                       url: (obj["html_url"] as? String) ?? releasesURL,
                       downloadURL: download)
    }

    /// "v1.1" / "BoxSend 1.1" / "release-1.10.2" -> "1.1" / "1.1" / "1.10.2"
    public static func normalizeVersion(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "[0-9]+(?:\\.[0-9]+)*") else { return "" }
        let ns = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, options: [], range: ns),
              let r = Range(m.range, in: s) else { return "" }
        return String(s[r])
    }

    /// 版本比较：按 . 分段比数字，缺的段当 0（所以 1.10 比 1.9 新，1.1 不比 1.1.0 新）
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            normalizeVersion(s).split(separator: ".").compactMap { Int($0) }
        }
        let a = parts(candidate), b = parts(current)
        guard !a.isEmpty, !b.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 检查结果：拿到版本信息，或一行能看懂的失败原因
    public enum Check: Equatable {
        case found(Release)
        case failed(String)
    }

    /// 取最新版本
    public static func latest(client: HTTPClient) -> Check {
        do {
            let resp = try client.get(latestAPIURL,
                                      extraHeaders: ["Accept": "application/vnd.github+json"],
                                      timeout: 20)
            switch resp.status {
            case 200: break
            case 403: return .failed("GitHub 接口限流（HTTP 403），稍后再试或直接打开发布页")
            case 404: return .failed("仓库还没有发布版本（HTTP 404）")
            default: return .failed("GitHub 返回 HTTP \(resp.status)")
            }
            guard let rel = parse(resp.data) else { return .failed("没读懂 GitHub 的返回内容") }
            return .found(rel)
        } catch {
            return .failed("连不上 GitHub：\(error.localizedDescription)（可直接打开发布页看新版本）")
        }
    }
}
