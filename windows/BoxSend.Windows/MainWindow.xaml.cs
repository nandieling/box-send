using System.ComponentModel;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using BoxSend.Windows.Views;

namespace BoxSend.Windows;

public partial class MainWindow : Window
{
    private readonly AppModel _model;
    private TrayIcon? _tray;
    private bool _exiting;

    public MainWindow(AppModel model)
    {
        _model = model;
        InitializeComponent();
        Title = $"BoxSend {model.CoreVersion}";
        Icon = AppIcon.Source ?? Icon;

        // 顶部页签：矢量图标 + 标题，配色跟随主题（样式在 App.xaml）
        TabRun.Header = TabIcons.Header(TabIcons.Run, "批量转种");
        TabAssist.Header = TabIcons.Header(TabIcons.Assist, "辅种");
        // 辅种收起时连页签都不摆（开关在核心库 AssistFeature，两端同一份）
        TabAssist.Visibility = model.AssistEnabled ? Visibility.Visible : Visibility.Collapsed;
        TabSites.Header = TabIcons.Header(TabIcons.Sites, "站点分组");
        TabSettings.Header = TabIcons.Header(TabIcons.Settings, "设置");

        // 六个区块在代码里装配（界面要读模型，XAML 里没法带构造参数）
        TabRun.Content = new RunView(model);
        TabAssist.Content = new AssistView(model);
        TabSites.Content = new SitesView(model);
        TabSettings.Content = new SettingsView(model);

        _model.FullRefreshed += (_, _) => ReapplyTheme();
        // 底部提示条：cookie 同步信息之类不再长期占着底部，几分钟自己收，也能手动关
        _model.Refreshed += (_, _) => Dispatcher.Invoke(UpdateStatusBar);
        _model.FullRefreshed += (_, _) => Dispatcher.Invoke(UpdateStatusBar);
        UpdateStatusBar();
        Closing += OnClosing;
        Closed += (_, _) => { _tray?.Dispose(); Application.Current.Shutdown(); };
    }

    protected override void OnContentRendered(EventArgs e)
    {
        base.OnContentRendered(e);
        _tray ??= new TrayIcon($"BoxSend {_model.CoreVersion}");
        _tray.ActivateRequested += ShowFromTray;
        _tray.ExitRequested += ExitApplication;
        // 到这里窗口是真的画出来了。没这一行而进程还活着，就说明卡在绘制之前
        StartupLog.Write(_tray != null ? "内容已绘制，托盘已挂" : "内容已绘制，但托盘没挂上");
    }

    /// <summary>底部提示条只画模型给的那句话（配置报错优先，其次 cookie 提示）；
    /// 两边都空就整条收起来，不留一条空带。</summary>
    private void UpdateStatusBar()
    {
        var text = _model.StatusText;
        StatusText.Text = text;
        // 配置报错是「有事要看」，cookie 同步只是「告知一声」，图标上区分开
        StatusGlyph.Text = string.IsNullOrEmpty(_model.ConfigError) ? "\uE946" : "\uE7BA";
        StatusBar.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnDismissStatus(object sender, RoutedEventArgs e)
    {
        _model.DismissBottomMessage();
        UpdateStatusBar();
    }

    /// <summary>全屏（最大化）时窗口大、离得远：页签与图标整体放大一档。</summary>
    protected override void OnStateChanged(EventArgs e)
    {
        base.OnStateChanged(e);
        if (Application.Current is App app)
            ThemeManager.ApplyMetrics(app, WindowState == WindowState.Maximized);
    }

    public void ShowFromTray()
    {
        Show();
        WindowState = WindowState.Normal;
        Activate();
    }

    /// 换主题 / 换背景图后重画（色值来自核心库主题表）
    public static void ReapplyTheme()
    {
        if (Application.Current is App app && app.MainWindow is MainWindow w)
            ThemeManager.Apply(app, w._model.CurrentTheme, App.BackgroundImage(),
                w._model.Config?["appearance"]?["bgOpacity"]?.GetValue<double>() ?? 0.45);
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_exiting) return;
        // 关窗收进托盘：转种是长任务，窗口关掉也要让它跑完
        if (_model.Running || _tray != null)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        _exiting = true;
    }

    public void ExitApplication()
    {
        _exiting = true;
        _tray?.Dispose();
        Application.Current.Shutdown();
    }
}
