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

        // 六个区块在代码里装配（界面要读模型，XAML 里没法带构造参数）
        TabRun.Content = new RunView(model);
        TabSites.Content = new SitesView(model);
        TabCookies.Content = new CookiesView(model);
        TabDownloader.Content = new DownloaderView(model);
        TabLogs.Content = new LogsView(model);
        TabSettings.Content = new SettingsView(model);

        _model.FullRefreshed += (_, _) => ReapplyTheme();
        Closing += OnClosing;
        Closed += (_, _) => { _tray?.Dispose(); Application.Current.Shutdown(); };
    }

    protected override void OnContentRendered(EventArgs e)
    {
        base.OnContentRendered(e);
        _tray ??= new TrayIcon(this, $"BoxSend {_model.CoreVersion}", AppIcon.Hicon);
        _tray.ActivateRequested += ShowFromTray;
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
