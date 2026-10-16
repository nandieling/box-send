import Foundation

/// 「站点这条和本地这条是不是同一段文件」的判定。名字会因站点改写、组标签、结果页截断而失真，
/// 所以名字只用来挑候选，定性一律靠下载来的 .torrent：先比 info hash，再比逐文件清单。
public enum AssistMatcher {

    /// 可比对的清单键：每条 `"归一化路径|字节数"`。集合比较，站点条目顺序不可信。
    public struct Manifest: Equatable {
        public var root: String
        public var totalSize: Int64
        public var keys: Set<String>
        public var count: Int { keys.count }

        public init(root: String, totalSize: Int64, keys: Set<String>) {
            self.root = root; self.totalSize = totalSize; self.keys = keys
        }
    }

    /// 本地 hash（v1/v2 都算）命中 → sameHash；否则逐文件清单全等 → sameFiles；
    /// 都不成立 → nameOnly（附一句差异说明，界面「待人工确认」里显示）。
    public static func judge(localHashes: [String], local: TorrentFingerprint,
                             siteTorrentData: Data, siteName: String) -> (AssistLevel, String) {
        let hashes = Set(localHashes.map { $0.lowercased() })
        if let h = Bencode.infoHash(siteTorrentData)?.lowercased(), hashes.contains(h) {
            return (.sameHash, "info hash 一致（\(h.prefix(12))…）")
        }
        guard let site = manifest(ofTorrent: siteTorrentData) else {
            return (.nameOnly(siteName), "站点种子解析不出文件清单，只能靠名字")
        }
        let a = comparableKey(local), b = site
        if a.keys == b.keys {
            return (.sameFiles, "逐文件清单全等（\(b.count) 个文件、\(sizeText(b.totalSize))），"
                              + "站点重新打包过所以 hash 不同")
        }
        let onlyLocal = a.keys.subtracting(b.keys)
        let onlySite = b.keys.subtracting(a.keys)
        // 同一路径两边都有、大小不同 —— 这是「不是一段文件」最直接的证据
        var pathsLocal: [String: Int64] = [:]
        var pathsSite: [String: Int64] = [:]
        for k in a.keys { pathsLocal[k.pathPart] = k.sizePart ?? -1 }
        for k in b.keys { pathsSite[k.pathPart] = k.sizePart ?? -1 }
        var reasons: [String] = []
        if a.count != b.count { reasons.append("文件数 \(a.count) vs \(b.count)") }
        let mismatched = Set(pathsLocal.keys).intersection(Set(pathsSite.keys))
            .filter { pathsLocal[$0] != pathsSite[$0] }
        if !mismatched.isEmpty { reasons.append("\(mismatched.count) 个同路径文件大小不同") }
        if !onlyLocal.isEmpty || !onlySite.isEmpty {
            reasons.append("只有本地有 \(onlyLocal.count) 个、只有站点有 \(onlySite.count) 个")
        }
        return (.nameOnly(siteName), reasons.isEmpty ? "清单对不上" : reasons.joined(separator: "；"))
    }

    /// .torrent -> 指纹（根目录名 + 逐文件路径与大小）
    public static func fingerprint(ofTorrent data: Data) -> TorrentFingerprint? {
        guard let root = Bencode.infoName(data), let files = Bencode.fileList(data), !files.isEmpty
        else { return nil }
        return TorrentFingerprint(root: root, files: files)
    }

    public static func manifest(ofTorrent data: Data) -> Manifest? {
        guard let fp = fingerprint(ofTorrent: data) else { return nil }
        return comparableKey(fp)
    }

    /// 本地/站点的指纹都过这道归一化：去根目录名（站点常写成另一个名字，那是路径问题不是内容问题）、
    /// 反斜杠换斜杠、丢 `.` 段、小写
    public static func comparableKey(_ fp: TorrentFingerprint) -> Manifest {
        let keys = Set(fp.files.map { normalizedPath($0.path, root: fp.root) + "|" + String($0.size) })
        return Manifest(root: fp.root, totalSize: fp.totalSize, keys: keys)
    }

    /// 单条路径归一化：去根目录名、去 `.` 段、`\` 换 `/`、小写
    public static func normalizedPath(_ path: String, root: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        if parts.isEmpty { parts = [path] }
        if parts.count > 1, parts.first == root { parts.removeFirst() }
        parts.removeAll { $0 == "." }
        return parts.map { $0.replacingOccurrences(of: "\\", with: "/") }
            .joined(separator: "/").lowercased()
    }

    /// 路径布局对得上吗。内容相同但布局对不上时，下载器找不到文件会去重下一整份，
    /// 所以这一判必须和「是不是同一段文件」分开做，界面上也分开说。
    /// localPaths 取下载器自己报的文件路径（它说去哪儿找，就去哪儿找），
    /// sitePaths 取站点 .torrent 里写的路径。
    public static func layout(localPaths: Set<String>, sitePaths: Set<String>) -> Layout {
        let a = normalizeSet(localPaths), b = normalizeSet(sitePaths)
        if a == b { return .same }
        // 只差最外面一层目录名：内容没问题，把站点种子期望的路径改一下就能成
        if stripRoot(a) == stripRoot(b) { return .rootDiffers }
        return .differs
    }

    public enum Layout: Equatable {
        case same          // 完全一致，直接加
        case rootDiffers   // 只有根目录名不同
        case differs       // 结构不同，别加
    }

    private static func normalizeSet(_ paths: Set<String>) -> Set<String> {
        Set(paths.map { $0.lowercased().replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").filter { $0 != "." }.joined(separator: "/") })
    }

    private static func stripRoot(_ paths: Set<String>) -> Set<String> {
        // 只有一层的路径（单文件种子）没有根目录可剥，原样留着
        Set(paths.map { p in
            let parts = p.split(separator: "/")
            return parts.count > 1 ? parts.dropFirst().joined(separator: "/") : p
        })
    }

    static func sizeText(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

private extension String {
    /// `"path|123"` -> ("path", 123)；拆不动时整串当路径
    var pathPart: String {
        guard let i = lastIndex(of: "|") else { return self }
        return String(self[..<i])
    }
    var sizePart: Int64? {
        guard let i = lastIndex(of: "|") else { return nil }
        return Int64(self[self.index(after: i)...])
    }
}
