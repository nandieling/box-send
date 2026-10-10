using System.Windows;
using System.Windows.Controls;

namespace BoxSend.Windows.Views;

/// <summary>Cookie 页：Gist / CookieCloud 两路同步、PT-depiler 备份目录监控、本地 cookie 管理。</summary>
public partial class CookiesView : UserControl
{
    private readonly AppModel _model;
    private bool _loading;

    public CookiesView(AppModel model)
    {
        _model = model;
        InitializeComponent();
        Hosts.ItemsSource = model.CookieHosts;
        // 「显示」按钮旁边放一个明文框，按下时才亮出来（PasswordBox 不支持绑定，只能两个控件切）
        GistPeeker.Visibility = Visibility.Collapsed;
        GistTokenDock.Children.Insert(0, GistPeeker);
        _model.FullRefreshed += (_, _) => Dispatcher.Invoke(Load);
        Load();
    }

    private void Load()
    {
        _loading = true;
        GistState.Text = $"上次同步：{_model.LastGistSync}";
        CookieMessage.Text = _model.CookieMessage;
        CookieTotal.Text = $"本地 {_model.CookieHosts.Count} 个站点、{_model.CookieTotal} 条 cookie";

        GistId.Text = _model.SectionText("gistSync", "gistID");
        GistToken.Password = _model.SectionText("gistSync", "token");
        GistKey.Password = _model.SectionText("gistSync", "encryptionKey");
        GistPoll.Text = _model.SectionInt("gistSync", "pollMinutes", 30).ToString();

        CcHost.Text = _model.SectionText("cookieCloud", "host");
        CcKey.Text = _model.SectionText("cookieCloud", "key");
        CcPassword.Password = _model.SectionText("cookieCloud", "password");
        CcPoll.Text = _model.SectionInt("cookieCloud", "pollMinutes", 30).ToString();

        ZipDir.Text = _model.SectionText("zipWatch", "dir", "~/Downloads");
        ZipPassword.Text = _model.SectionText("zipWatch", "password");
        ZipPoll.Text = _model.SectionInt("zipWatch", "pollMinutes", 5).ToString();
        GistAuto.IsChecked = _model.GistAuto;
        CcAuto.IsChecked = _model.CookieCloudAuto;
        ZipAuto.IsChecked = _model.SectionFlag("zipWatch", "enabled");
        _loading = false;
    }

    private static int Num(TextBox box, int fallback) =>
        int.TryParse(box.Text.Trim(), out var v) ? v : fallback;

    private void OnSaveGist(object sender, RoutedEventArgs e) =>
        _model.PatchSection("gistSync", s =>
        {
            s["gistID"] = GistId.Text.Trim();
            s["token"] = GistToken.Password;
            s["encryptionKey"] = GistKey.Password;
            s["pollMinutes"] = Num(GistPoll, 30);
        });

    private void OnSaveCookieCloud(object sender, RoutedEventArgs e) =>
        _model.PatchSection("cookieCloud", s =>
        {
            s["host"] = CcHost.Text.Trim();
            s["key"] = CcKey.Text.Trim();
            s["password"] = CcPassword.Password;
            s["pollMinutes"] = Num(CcPoll, 30);
        });

    private void OnSaveZip(object sender, RoutedEventArgs e) =>
        _model.PatchSection("zipWatch", s =>
        {
            s["dir"] = ZipDir.Text.Trim();
            s["password"] = ZipPassword.Text;
            s["pollMinutes"] = Num(ZipPoll, 5);
            s["enabled"] = ZipAuto.IsChecked == true;
        });

    private void OnSyncGist(object sender, RoutedEventArgs e) => Sync("gist");
    private void OnSyncCookieCloud(object sender, RoutedEventArgs e) => Sync("cookieCloud");

    private void Sync(string source)
    {
        SaveCurrentSection(source);
        var error = _model.Try("cookies.sync", new { source });
        CookieMessage.Text = error ?? "同步已提交，正在拉取…";
        _ = _model.RefreshAsync();
    }

    private void SaveCurrentSection(string source)
    {
        switch (source)
        {
            case "gist": OnSaveGist(this, new RoutedEventArgs()); break;
            case "cookieCloud": OnSaveCookieCloud(this, new RoutedEventArgs()); break;
        }
    }

    private void OnPickZipDir(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = "选择 PT-depiler 备份目录" };
        if (dialog.ShowDialog(Window.GetWindow(this)) == true) ZipDir.Text = dialog.FolderName;
    }

    // 三个自动开关：Gist / CookieCloud 只在界面里生效，zip 监控要落进配置好让下次开机继续
    private void OnGistAuto(object sender, RoutedEventArgs e) => _model.SetGistAuto(GistAuto.IsChecked == true);

    private void OnCookieCloudAuto(object sender, RoutedEventArgs e) =>
        _model.SetCookieCloudAuto(CcAuto.IsChecked == true);

    private void OnZipAuto(object sender, RoutedEventArgs e) => OnSaveZip(this, new RoutedEventArgs());

    private void OnZipScan(object sender, RoutedEventArgs e)
    {
        // 手动扫描也走服务：扫目录里新增的 PTD_backup*.zip，跳过已导入过的
        OnSaveZip(this, new RoutedEventArgs());
        var error = _model.Try("zip.scan");
        CookieMessage.Text = error ?? "扫描已提交…";
        _ = _model.RefreshAsync();
    }

    private void OnTrim(object sender, RoutedEventArgs e) => _model.Call("cookies.trim");

    private void OnClear(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(Window.GetWindow(this)!, "确定清空本地全部 cookie？同步后可重新拉取。", "BoxSend",
                            MessageBoxButton.OKCancel) != MessageBoxResult.OK) return;
        _model.Call("cookies.clear");
    }

    private void OnCheckAll(object sender, RoutedEventArgs e) =>
        _model.Call("cookies.check", new { ids = Array.Empty<string>(), force = true });

    private void OnManualCookie(object sender, RoutedEventArgs e)
    {
        var sites = _model.Sites.Where(s => s.Enabled).ToList();
        if (sites.Count == 0)
        {
            MessageBox.Show(Window.GetWindow(this)!, "还没有启用的站点。", "BoxSend");
            return;
        }
        new Dialogs.ManualCookieWindow(_model, sites) { Owner = Window.GetWindow(this) }.ShowDialog();
    }

    /// 口令显示切换：PasswordBox 没有 Text 绑定，换成同位置的 TextBox 太啰嗦，直接切可见性
    private void OnReveal(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        var reveal = GistReveal.IsChecked == true;
        GistToken.Visibility = reveal ? Visibility.Collapsed : Visibility.Visible;
        GistPeeker.Visibility = reveal ? Visibility.Visible : Visibility.Collapsed;
        if (reveal) GistPeeker.Text = GistToken.Password;
    }

    private readonly TextBox GistPeeker = new() { Margin = new Thickness(0) };
}
