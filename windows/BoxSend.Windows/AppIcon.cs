using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace BoxSend.Windows;

/// <summary>
/// 应用图标：读同目录下的 boxsend.ico（与 macOS 的 AppIcon.icns 同源，由 windows/make_icon.py 生成）。
/// 窗口/任务栏用这份位图；托盘自己按系统小图标尺寸读同一个文件（见 TrayIcon）。
/// 任务栏/标题栏给 WPF 用 ImageSource，托盘要 HICON，就从同一帧现做——
/// 只用 PresentationCore + user32/gdi32，不为此引 WinForms 或 System.Drawing.Common。
/// </summary>
public static class AppIcon
{
    private static readonly object Gate = new();
    private static BitmapSource? _frames;
    private static ImageSource? _source;
    private static bool _tried;

    private static string Path => System.IO.Path.Combine(AppContext.BaseDirectory, "boxsend.ico");

    private static void Ensure()
    {
        lock (Gate)
        {
            if (_tried) return;
            _tried = true;
            try
            {
                if (!File.Exists(Path)) return;
                var decoder = new IconBitmapDecoder(new Uri(Path), BitmapCreateOptions.PreservePixelFormat,
                                                   BitmapCacheOption.OnLoad);
                // 标题栏/任务栏按 32px 取，缺则就近
                var best = PickFrame(decoder.Frames, 32) ?? decoder.Frames[0];
                _frames = best;
                _source = best;
            }
            catch
            {
                // 图标读不出来不影响功能，退回系统默认应用图标
            }
        }
    }

    private static BitmapFrame? PickFrame(System.Collections.Generic.IReadOnlyList<BitmapFrame> frames, int px)
    {
        BitmapFrame? pick = null;
        var bestGap = int.MaxValue;
        foreach (var f in frames)
        {
            var gap = Math.Abs(f.PixelWidth - px);
            if (gap < bestGap) { bestGap = gap; pick = f; }
        }
        return pick;
    }

    /// 标题栏、任务栏用的图标；没有 boxsend.ico 时为 null
    public static ImageSource? Source
    {
        get { Ensure(); return _source; }
    }

}
