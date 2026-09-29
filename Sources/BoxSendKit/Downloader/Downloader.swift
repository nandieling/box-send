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
