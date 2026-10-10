using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace BoxSend.Windows;

/// <summary>
/// 应用图标：读同目录下的 boxsend.ico（与 macOS 的 AppIcon.icns 同源，由 windows/make_icon.py 生成）。
/// 任务栏/标题栏给 WPF 用 ImageSource，托盘要 HICON，就从同一帧现做——
/// 只用 PresentationCore + user32/gdi32，不为此引 WinForms 或 System.Drawing.Common。
/// </summary>
public static class AppIcon
{
    private static readonly object Gate = new();
    private static BitmapSource? _frames;
    private static ImageSource? _source;
    private static IntPtr _hicon;
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
                // 标题栏和托盘都按 32px 取，缺则就近
                var best = PickFrame(decoder.Frames, 32) ?? decoder.Frames[0];
                _frames = best;
                _source = best;
                _hicon = CreateHicon(best);
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

    /// 托盘用的 HICON；读不到时返回 IntPtr.Zero，由调用方兜底
    public static IntPtr Hicon
    {
        get { Ensure(); return _hicon; }
    }

    // ---- BitmapSource -> HICON（32 位带 alpha）----

    [StructLayout(LayoutKind.Sequential)]
    private struct ICONINFO
    {
        public int fIcon;
        public int fMask;
        public IntPtr hbmMask;
        public IntPtr hbmColor;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr CreateIconIndirect(ref ICONINFO iconinfo);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateBitmap(int width, int height, uint planes, uint bpp, IntPtr bits);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr obj);

    private static IntPtr CreateHicon(BitmapSource src)
    {
        int w = src.PixelWidth, h = src.PixelHeight;
        var bgra = new FormatConvertedBitmap(src, PixelFormats.Bgra32, null, 0);
        var stride = w * 4;

        // 图标位图要求自下而上，BitmapSource 是自上而下，得倒一遍行
        var top = new byte[h * stride];
        bgra.CopyPixels(top, stride, 0);
        var bottom = new byte[top.Length];
        for (var y = 0; y < h; y++)
            Buffer.BlockCopy(top, (h - 1 - y) * stride, bottom, y * stride, stride);

        // 1 位 AND 遮罩全 0：透明度完全交给 alpha 通道，Vista 起外壳认这个规则
        var maskStride = ((w + 31) / 32) * 4;
        var mask = new byte[h * maskStride];

        var colorHandle = GCHandle.Alloc(bottom, GCHandleType.Pinned);
        var maskHandle = GCHandle.Alloc(mask, GCHandleType.Pinned);
        try
        {
            var hbmColor = CreateBitmap(w, h, 1, 32, colorHandle.AddrOfPinnedObject());
            var hbmMask = CreateBitmap(w, h, 1, 1, maskHandle.AddrOfPinnedObject());
            try
            {
                var info = new ICONINFO { fIcon = 1, fMask = 0, hbmColor = hbmColor, hbmMask = hbmMask };
                return CreateIconIndirect(ref info);
            }
            finally
            {
                DeleteObject(hbmColor);
                DeleteObject(hbmMask);
            }
        }
        finally
        {
            colorHandle.Free();
            maskHandle.Free();
        }
    }
}
