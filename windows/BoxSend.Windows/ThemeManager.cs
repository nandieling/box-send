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
