import Foundation

/// 站点适配器：一个框架家族一个实现，站点差异通过 SiteOverride 收敛。
public protocol SiteAdapter: AnyObject {
    var site: SiteConfig { get }
    var client: HTTPClient { get }
    var override: SiteOverride? { get }

    /// 拉取种子列表（M1: 尽力而为，主流程用 fetchDetail 指定详情页）
    func fetchTorrentList() throws -> [ReleaseInfo]
    /// 解析详情页 -> 完整 ReleaseInfo
    func fetchDetail(detailURL: String) throws -> ReleaseInfo
    /// 下载 .torrent 文件（带 passkey 直链）
    func downloadTorrentFile(_ info: ReleaseInfo) throws -> (data: Data, filename: String)
    /// 查重：返回已存在种子的详情页 URL，不存在返回 nil。未配置 searchURL 时返回 nil。
    func searchExists(_ info: ReleaseInfo) throws -> String?
    /// 上传（转种）
    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome
    /// 上传字段预览（调试用，CLI info --preview）
    func previewUploadFields(_ info: ReleaseInfo) throws -> [(String, String)]
}

extension SiteAdapter {
    func previewUploadFields(_ info: ReleaseInfo) throws -> [(String, String)] {
        throw BoxSendError.badInput("\(site.id) 适配器不支持上传字段预览")
    }
}

public struct UploadOutcome {
    public var success: Bool
    public var message: String
    public var detailURL: String?
    public init(success: Bool, message: String, detailURL: String?) {
        self.success = success
        self.message = message
        self.detailURL = detailURL
    }
}
