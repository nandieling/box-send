import Foundation

/// 下载器里的一条种子（辅种的输入）。字段取自 qBittorrent `/torrents/info`、
/// Transmission `torrent-get`，两端命名不同，这里统一成一套。
public struct LocalTorrent: Codable, Equatable {
    /// v1 info hash（小写 40 位）
    public var hash: String
    /// v2 种子的 v2 hash（qB 的 infohash_v2）：站点那份多半只有 v1，比对时两个都要带上
    public var hashV2: String?
    public var name: String
    /// 种子内容所在目录（qB 的 save_path）：辅种必须沿用这个路径，否则下载器找不到文件会重下
    public var savePath: String
    public var category: String?
    public var tags: [String]
    public var totalSize: Int64
    /// 已完成比例（0…1）；没下完的种子文件不全，不该去辅
    public var progress: Double
    /// 该种子现有的 tracker host（小写）：判断「这份文件已经在哪些站做种」，能省掉绝大多数检索
    public var trackerHosts: [String]

    public init(hash: String, hashV2: String? = nil, name: String, savePath: String,
                category: String? = nil, tags: [String] = [], totalSize: Int64 = 0,
                progress: Double = 1, trackerHosts: [String] = []) {
        self.hash = hash.lowercased()
        self.hashV2 = hashV2?.lowercased()
        self.name = name
        self.savePath = savePath
        self.category = category
        self.tags = tags
        self.totalSize = totalSize
        self.progress = progress
        self.trackerHosts = trackerHosts
    }

    /// 比对可用的全部 hash
    public var allHashes: [String] {
        [hash] + (hashV2.map { [$0] } ?? [])
    }
}

/// 一条种子的文件指纹：逐文件的相对路径 + 字节数。辅种判「是不是同一段文件」靠它。
public struct TorrentFingerprint: Equatable {
    /// 内容根目录名（.torrent 的 info.name）：决定下载器去哪儿找文件
    public var root: String
    /// 逐文件清单，按路径排序后比较
    public var files: [(path: String, size: Int64)]
    public var totalSize: Int64

    public init(root: String, files: [(path: String, size: Int64)]) {
        self.root = root
        self.files = files
        self.totalSize = files.reduce(Int64(0)) { $0 + $1.size }
    }

    public var fileCount: Int { files.count }
    /// 一组文件路径共有的最外层目录（下载器只报文件路径时用它反推根目录名）；
    /// 路径都在同一层时没有共同根，返回空串
    public static func commonRoot(_ files: [(path: String, size: Int64)]) -> String {
        guard let head = files.first?.path.split(separator: "/").first else { return "" }
        let pre = String(head) + "/"
        return files.allSatisfy { $0.path.hasPrefix(pre) } ? String(head) : ""
    }
}

// 带元组数组，编译器合成不了 Equatable，手写一份（比较时按路径排序，站点条目顺序不可信）
public func == (a: TorrentFingerprint, b: TorrentFingerprint) -> Bool {
    guard a.root == b.root, a.totalSize == b.totalSize, a.files.count == b.files.count else { return false }
    let x = a.files.sorted { $0.path < $1.path }
    let y = b.files.sorted { $0.path < $1.path }
    return zip(x, y).allSatisfy { $0.path == $1.path && $0.size == $1.size }
}

/// 判定级别：站点那条种子与本地这条是什么关系
public enum AssistLevel: Equatable {
    /// 站点 .torrent 的 info hash 与本地一致：同一种子，直接辅
    case sameHash
    /// hash 不同但逐文件清单完全一致：站点重新打包（改了 source/private 标记），可以辅
    case sameFiles
    /// 只有名字像，清单对不上：不动下载器，交人工
    case nameOnly(String)
    /// 站内没检索到，或这个站/这条根本没法辅（原因给人看）
    case skip(String)
}

/// 一次辅种的结果（界面逐条显示）
public struct AssistOutcome: Equatable {
    public var siteID: String
    public var torrentName: String
    public var level: AssistLevel
    /// 站点那条种子的详情页
    public var detailURL: String?
    /// 已推送 / 已跳过 / 待人工确认 / 失败
    public var done: Bool
    public var message: String

    public init(siteID: String, torrentName: String, level: AssistLevel,
                detailURL: String? = nil, done: Bool = false, message: String = "") {
        self.siteID = siteID
        self.torrentName = torrentName
        self.level = level
        self.detailURL = detailURL
        self.done = done
        self.message = message
    }
}
