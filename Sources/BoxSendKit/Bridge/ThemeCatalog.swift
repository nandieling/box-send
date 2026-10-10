import Foundation

/// 主题表（id / 显示名 / 渐变色 / 强调色）。
///
/// 色值放核心库是为了让 mac 与 Windows 两端读到同一份主题定义：配置里只存 id，
/// 换肤时各自把同一组十六进制色画成渐变（SwiftUI 用 LinearGradient，WPF 用
/// LinearGradientBrush）。界面上的圆角、区块表面等仍归各自 UI 管。
public struct ThemeSpec: Codable, Equatable {
    public var id: String
    public var name: String
    public var colorsHex: [String]
    public var dark: Bool
    public var accentHex: String

    public init(id: String, name: String, colorsHex: [String], dark: Bool, accentHex: String) {
        self.id = id
        self.name = name
        self.colorsHex = colorsHex
        self.dark = dark
        self.accentHex = accentHex
    }
}

public enum ThemeCatalog {
    public static let all: [ThemeSpec] = [
        ThemeSpec(id: "deepBlue", name: "深空蓝", colorsHex: ["#0f2027", "#203a43", "#2c5364"], dark: true, accentHex: "#4fc3f7"),
        ThemeSpec(id: "aurora", name: "极光紫", colorsHex: ["#1a0b2e", "#43227a", "#7b2ff7"], dark: true, accentHex: "#b39ddb"),
        ThemeSpec(id: "jade", name: "翡翠绿", colorsHex: ["#07271c", "#0f5132", "#198754"], dark: true, accentHex: "#34d399"),
        ThemeSpec(id: "sunset", name: "落日橙", colorsHex: ["#2b1106", "#8a3a12", "#d97706"], dark: true, accentHex: "#fbbf24"),
        ThemeSpec(id: "rose", name: "玫瑰粉", colorsHex: ["#2d0b1c", "#7a1f3d", "#c2185b"], dark: true, accentHex: "#f48fb1"),
        ThemeSpec(id: "cloud", name: "云端白", colorsHex: ["#dceafa", "#eef6fd", "#ffffff"], dark: false, accentHex: "#0284c7"),
    ]

    public static var `default`: ThemeSpec { all[0] }

    public static func spec(_ id: String) -> ThemeSpec {
        all.first { $0.id == id } ?? `default`
    }

    public static var allJSON: [[String: Any]] {
        all.map {
            ["id": $0.id, "name": $0.name, "colors": $0.colorsHex,
             "dark": $0.dark, "accent": $0.accentHex]
        }
    }
}
