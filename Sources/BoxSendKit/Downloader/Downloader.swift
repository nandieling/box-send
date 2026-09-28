import Foundation

public protocol Downloader: AnyObject {
    func addTorrent(data: Data, filename: String,
                    savePath: String?, category: String?,
                    skipChecking: Bool,
                    upLimit: Int64) throws -> String   // 返回下载器侧标识

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
