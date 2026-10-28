import Foundation

/// 辅种整条线这一版先收起来：界面上不摆、定时不跑、`assist.*` 命令也不接。
///
/// 只是「不运行」，不是删掉：流水线、状态表、已辅记录、两端界面代码都原样留着，
/// 这个开关改回 true 就整套回来（含设置里的搜索节奏与逐站筛选）。
/// 测试里可以临时打开它，好让辅种那批用例照旧跑到真代码。
public enum AssistFeature {
    public static var enabled = false

    /// 关着的时候回给界面那句话
    public static let offMessage = "辅种这一版先收起来了：记录都还在，开关一开就回来"
}
