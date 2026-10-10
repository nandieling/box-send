using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace BoxSend.Windows;

/// <summary>托盘图标（直接用 Shell_NotifyIcon，不引第三方库）。
/// 关窗后转种继续跑，靠托盘回到界面——与 macOS 版行为一致。</summary>
public sealed class TrayIcon : IDisposable
{
    private const int WM_USER = 0x0400;
    private const int NIM_ADD = 0x00;
    private const int NIM_DELETE = 0x02;
    private const int WM_LBUTTONDBLCLK = 0x0203;
    private const int WM_RBUTTONUP = 0x0205;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NOTIFYICONDATA
    {
        public int cbSize;
        public IntPtr hWnd;
        public int uID;
        public int uFlags;
        public int uMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public int dwState;
        public int dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public int uTimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public int dwInfoFlags;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int Shell_NotifyIcon(int dwMessage, ref NOTIFYICONDATA data);

    // 没有 boxsend.ico 时用系统默认应用图标兜底
    [DllImport("user32.dll")]
    private static extern IntPtr LoadIcon(IntPtr hInstance, IntPtr lpIconName);

    private static readonly IntPtr IDI_APPLICATION = new(32512);

    private NOTIFYICONDATA _data;
    private readonly HwndSource _source;

    public event Action? ActivateRequested;

    public TrayIcon(Window window, string tip, IntPtr hicon = default)
    {
        _data = new NOTIFYICONDATA
        {
            cbSize = Marshal.SizeOf<NOTIFYICONDATA>(),
            hWnd = new WindowInteropHelper(window).Handle,
            uID = 1,
            uFlags = 0x1 | 0x2 | 0x4,       // NIF_MESSAGE | NIF_ICON | NIF_TIP
            uMessage = WM_USER + 1,
            hIcon = hicon != IntPtr.Zero ? hicon : LoadIcon(IntPtr.Zero, IDI_APPLICATION),
            szTip = tip,
        };
        _source = HwndSource.FromHwnd(_data.hWnd)!;
        _source.AddHook(WndProc);
        Shell_NotifyIcon(NIM_ADD, ref _data);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_USER + 1 && (lParam.ToInt32() == WM_LBUTTONDBLCLK || lParam.ToInt32() == WM_RBUTTONUP))
        {
            ActivateRequested?.Invoke();
            handled = true;
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        Shell_NotifyIcon(NIM_DELETE, ref _data);
        _source.RemoveHook(WndProc);
    }
}
