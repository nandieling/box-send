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
    /// 宽松查重：站点已回答「已存在」、只需找回站内链接时用（结果页常截断标题）
    func searchExists(_ info: ReleaseInfo, relaxed: Bool) throws -> String?
    /// 未配置 searchURL 时能否仍主动做站内查重（该框架有通用检索端点）
    var canPrecheckDuplicate: Bool { get }
    /// 上一次查重在站内认出的那条已有种子的标题：UI 用它说清「重复的是哪一条」
    var duplicateHitTitle: String? { get }
    /// 站内这条种子归谁（读详情页判定；认不出返回 unknown）。
    /// uploadedAt 是本地记下「本站转种成功」的时间：站内那条比它还早很多，就不可能是我们发的。
    func torrentOwnership(detailURL: String, uploadedAt: Date?) -> TorrentOwnership
    /// 上传（转种）
    func upload(_ info: ReleaseInfo, torrentData: Data, filename: String) throws -> UploadOutcome
    /// 上传字段预览（调试用，CLI info --preview）
    func previewUploadFields(_ info: ReleaseInfo) throws -> [(String, String)]
    /// 注入 TMDB 反查回调（NexusPHP 家族支持：源站没给 TMDB 链接时按豆瓣/IMDb 反查）
    func setTMDBLookup(_ lookup: ((ReleaseInfo) -> String?)?)
}

extension SiteAdapter {
    func previewUploadFields(_ info: ReleaseInfo) throws -> [(String, String)] {
        throw BoxSendError.badInput("\(site.id) 适配器不支持上传字段预览")
    }
    var canPrecheckDuplicate: Bool { false }
    var duplicateHitTitle: String? { nil }
    func torrentOwnership(detailURL: String, uploadedAt: Date?) -> TorrentOwnership { .unknown }
    /// 默认不支持宽松判定，退回严格查重
    func searchExists(_ info: ReleaseInfo, relaxed: Bool) throws -> String? { try searchExists(info) }
    /// 框架暂无反查需求（源站直接给出 TMDB 链接的站够用）
    func setTMDBLookup(_ lookup: ((ReleaseInfo) -> String?)?) {}
}

/// 站内这条种子是不是本账号发的：重跑时用来分清「此前我发的」与「别人早就发过」
public enum TorrentOwnership { case ours, theirs, unknown }

public struct UploadOutcome {
    public var success: Bool
    public var message: String
    public var detailURL: String?
    /// 站点提示该种子已存在（查重兜底命中）：算成功，但 UI 应显示「已存在」而非「转种成功」
    public var alreadyExists: Bool
    public init(success: Bool, message: String, detailURL: String?, alreadyExists: Bool = false) {
        self.success = success
        self.message = message
        self.detailURL = detailURL
        self.alreadyExists = alreadyExists
    }
}
