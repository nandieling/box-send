using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.IO;

namespace BoxSend.Windows;

/// <summary>把核心库主题表（ThemeCatalog）画到窗口上：渐变背景 + 强调色 + 区块半透明表面。
/// 与 macOS 版同一组色值，两端只是渲染方式不同。</summary>
public static class ThemeManager
{
    public static void Apply(Application app, ThemeRow theme, string? backgroundImageFile, double bgOpacity)
    {
        var res = app.Resources;
        res["Accent"] = Brush(theme.Accent);
        res["GradientBackground"] = Gradient(theme.Colors);
        res["BlockSurface"] = Brush(theme.Dark ? "#61000000" : "#9EFFFFFF");
        res["TextSurface"] = Brush(theme.Dark ? "#73000000" : "#BFFFFFFF");
        res["TextPrimary"] = Brush(theme.Dark ? "#F2F5F8" : "#161A1F");
        res["TextMuted"] = Brush(theme.Dark ? "#9AA6B2" : "#5C6673");
        res["Line"] = Brush(theme.Dark ? "#33FFFFFF" : "#1F000000");
        res["IsDark"] = theme.Dark;
        // 悬停态、页签条底板、弹窗底色：不跟着主题走的话，深色主题上「云端白」以外全都看不清
        res["Hover"] = Brush(theme.Dark ? "#2EFFFFFF" : "#14000000");
        res["Chrome"] = Brush(theme.Dark ? "#4A000000" : "#8FFFFFFF");
        res["DialogBackground"] = Brush(theme.Dark ? "#1E252E" : "#F3F7FC");
        res["Warning"] = Brush(theme.Dark ? "#FFC46B" : "#B45309");
        res["Success"] = Brush(theme.Dark ? "#7BD88F" : "#15803D");
        ApplyMetrics(app, _maximized);

        if (backgroundImageFile != null && File.Exists(backgroundImageFile))
        {
            var img = new BitmapImage();
            img.BeginInit();
            img.CacheOption = BitmapCacheOption.OnLoad;
            img.UriSource = new Uri(backgroundImageFile);
            img.EndInit();
            img.Freeze();
            res["BackgroundImage"] = img;
            res["BackgroundImageOpacity"] = Math.Clamp(bgOpacity, 0, 1);
        }
        else
        {
            res["BackgroundImage"] = null;
            res["BackgroundImageOpacity"] = 0.0;
        }
    }

    private static bool _maximized;

    /// <summary>页签尺寸：全屏（最大化）时窗口大、离得远，页签整体放大一档。
    /// 界面上的字号/图标尺寸都走 DynamicResource，改这里就能立刻生效。</summary>
    public static void ApplyMetrics(Application app, bool maximized)
    {
        _maximized = maximized;
        var res = app.Resources;
        res["TabFontSize"] = maximized ? 16.0 : 14.0;
        res["TabIconSize"] = maximized ? 24.0 : 19.0;
        res["TabPadding"] = maximized
            ? new Thickness(20, 10, 20, 10)
            : new Thickness(14, 7, 14, 7);
    }

    private static SolidColorBrush Brush(string hex)
    {
        var b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        b.Freeze();
        return b;
    }

    private static LinearGradientBrush Gradient(string[] hexes)
    {
        var brush = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
        for (var i = 0; i < hexes.Length; i++)
            brush.GradientStops.Add(new GradientStop(
                (Color)ColorConverter.ConvertFromString(hexes[i]),
                hexes.Length == 1 ? 0 : (double)i / (hexes.Length - 1)));
        brush.Freeze();
        return brush;
    }
}
