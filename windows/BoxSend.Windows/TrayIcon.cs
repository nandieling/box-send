namespace BoxSend.Windows;

/// <summary>托盘图标（WinForms 的 NotifyIcon）。关窗后转种继续跑，靠托盘回到界面——
/// 与 macOS 版行为一致。右键给「打开 / 退出」菜单：以前右键只是叫窗口，想退出只能回窗口里关，
/// 而关窗又是收托盘，等于没有退出口。</summary>
public sealed class TrayIcon : IDisposable
{
    private readonly System.Windows.Forms.NotifyIcon _icon;

    public event Action? ActivateRequested;
    public event Action? ExitRequested;

    public TrayIcon(string tip)
    {
        _icon = new System.Windows.Forms.NotifyIcon
        {
            Text = tip.Length > 127 ? tip[..127] : tip,
            Icon = LoadTrayIcon(),
            Visible = true,
            ContextMenuStrip = BuildMenu(),
        };
        // 左键单击与双击都叫窗口：托盘图标小，没人记得「要双击」
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == System.Windows.Forms.MouseButtons.Left) ActivateRequested?.Invoke();
        };
        _icon.DoubleClick += (_, _) => ActivateRequested?.Invoke();
    }

    private System.Windows.Forms.ContextMenuStrip BuildMenu()
    {
        var menu = new System.Windows.Forms.ContextMenuStrip();
        var open = new System.Windows.Forms.ToolStripMenuItem("打开 BoxSend");
        open.Click += (_, _) => ActivateRequested?.Invoke();
        var quit = new System.Windows.Forms.ToolStripMenuItem("退出 BoxSend");
        quit.Click += (_, _) => ExitRequested?.Invoke();
        menu.Items.AddRange(new System.Windows.Forms.ToolStripItem[]
        {
            open, new System.Windows.Forms.ToolStripSeparator(), quit,
        });
        return menu;
    }

    /// <summary>图标优先用随包那份 boxsend.ico（GDI+ 自己按系统小图标尺寸挑一帧，
    /// 折叠区里也是真图标）；退化顺序：exe 里嵌的那份 -> 系统应用图标。</summary>
    private static System.Drawing.Icon LoadTrayIcon()
    {
        var ico = System.IO.Path.Combine(AppContext.BaseDirectory, "boxsend.ico");
        try
        {
            if (System.IO.File.Exists(ico)) return new System.Drawing.Icon(ico);
        }
        catch { /* 图标读不出来不影响功能，往下退 */ }
        try
        {
            var exe = Environment.ProcessPath;
            if (exe != null && System.IO.File.Exists(exe))
                return System.Drawing.Icon.ExtractAssociatedIcon(exe);
        }
        catch { }
        return System.Drawing.SystemIcons.Application;
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
