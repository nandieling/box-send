import Foundation

/// 软件版本号（1.0 起为正式版，1.1 为当前版本）。
/// 唯一来源：GUI 打包脚本 scripts/make-app.sh 从这里读取并写入 Info.plist，
/// CLI 的 `box-send version` 与应用窗口标题也用它，避免多处版本号互相漂移。
public enum BoxSendVersion {
    public static let version = "1.1"
}
