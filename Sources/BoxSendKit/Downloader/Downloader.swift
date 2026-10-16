import Foundation

public struct AddTorrentResult {
    /// 下载器侧标识（qBittorrent 为 info hash；Transmission 为下载 id）
    public var id: String
    /// 附加说明：如"已存在于下载器" / "限速未生效"；无则为空
    public var note: String
    public init(id: String, note: String = "") {
        self.id = id
        self.note = note
    }
}

public protocol Downloader: AnyObject {
    func addTorrent(data: Data, filename: String,
                    savePath: String?, category: String?,
                    skipChecking: Bool,
                    upLimit: Int64) throws -> AddTorrentResult

    /// 连接/登录检测：成功返回描述（如版本信息），失败抛错
    func testConnection() throws -> String

    // MARK: 辅种要读下载器（转种只写不读，这些是辅种新长出来的口子）

    /// 列出下载器里的种子（辅种的输入）
    func listTorrents() throws -> [LocalTorrent]
    /// 某条种子的文件清单：qB 报的路径就是它期望的相对路径，与 .torrent 逐文件比对用
    func torrentFiles(hash: String) throws -> [(path: String, size: Int64)]
    /// 暂停/继续（辅种先暂停加进去，校验过了再启动，免得半路重下）
    func setPaused(hashes: [String], paused: Bool) throws
    /// 删掉一条种子；keepFiles = false 才会连文件一起删
    func removeTorrent(hash: String, keepFiles: Bool) throws
    /// 一条种子当前的完成度（0…1）与状态：辅种加进去之后要等它校验完才敢启动
    func torrentProgress(hash: String) throws -> (progress: Double, state: String)?
    /// 加种子时要求先暂停（辅种的保险丝）。写成协议要求而不是只放扩展里：
    /// 扩展方法静态派发，实现方的覆写会被无声吞掉。
    func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                    skipChecking: Bool, upLimit: Int64, paused: Bool) throws -> AddTorrentResult
}

extension Downloader {
    /// 默认不支持读：老实现只要能加种子就能跑转种，辅种在界面上标「该下载器暂不支持」
    public func listTorrents() throws -> [LocalTorrent] {
        throw BoxSendError.notImplemented("\(Self.self) 不支持列出种子，辅种暂不可用")
    }
    public func torrentFiles(hash: String) throws -> [(path: String, size: Int64)] {
        throw BoxSendError.notImplemented("\(Self.self) 不支持读取种子文件清单")
    }
    public func setPaused(hashes: [String], paused: Bool) throws {
        throw BoxSendError.notImplemented("\(Self.self) 不支持暂停/继续")
    }
    public func removeTorrent(hash: String, keepFiles: Bool) throws {
        throw BoxSendError.notImplemented("\(Self.self) 不支持删除种子")
    }
    public func torrentProgress(hash: String) throws -> (progress: Double, state: String)? {
        // 默认实现从整份清单里挑：实现方有单条查询端点时应当自己覆写，别每次拉全表
        try listTorrents().first { $0.hash == hash.lowercased() }
            .map { ($0.progress, "") }
    }

    /// 能列种子才谈得上辅种
    public var supportsAssist: Bool { true }

    /// 默认实现忽略「先暂停」的要求，退回不带暂停的老路径
    public func addTorrent(data: Data, filename: String, savePath: String?, category: String?,
                           skipChecking: Bool, upLimit: Int64, paused: Bool) throws -> AddTorrentResult {
        try addTorrent(data: data, filename: filename, savePath: savePath, category: category,
                       skipChecking: skipChecking, upLimit: upLimit)
    }
}

/// 下载器工厂（CLI 与 Web 共用）
public enum DownloaderFactory {
    public static func make(_ config: AppConfig, client: HTTPClient) -> Downloader {
        switch config.downloader.type {
        case .qbittorrent:
            return QBittorrent(client: client, baseURL: config.downloader.url,
                               username: config.downloader.username,
                               password: config.downloader.password)
        case .transmission:
            return Transmission(client: client, baseURL: config.downloader.url,
                                username: config.downloader.username,
                                password: config.downloader.password)
        }
    }
}
