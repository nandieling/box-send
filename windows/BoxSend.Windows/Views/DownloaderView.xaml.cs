using System.Windows;
using System.Windows.Controls;

namespace BoxSend.Windows.Views;

/// <summary>下载器页：qBittorrent / Transmission 连接信息、限速与推送策略。</summary>
public partial class DownloaderView : UserControl
{
    private readonly AppModel _model;

    public DownloaderView(AppModel model)
    {
        _model = model;
        InitializeComponent();
        _model.FullRefreshed += (_, _) => Dispatcher.Invoke(Load);
        Load();
    }

    private bool _loading;

    private void Load()
    {
        _loading = true;
        Result.Text = _model.DownloaderMessage;
        var type = _model.SectionText("downloader", "type", "qbittorrent");
        Select(Type, type);
        Url.Text = _model.SectionText("downloader", "url", "http://127.0.0.1:8080");
        User.Text = _model.SectionText("downloader", "username");
        Pass.Password = _model.SectionText("downloader", "password");
        SavePath.Text = _model.SectionText("downloader", "savePath");
        Category.Text = _model.SectionText("downloader", "category");
        SkipCheck.IsChecked = _model.SectionFlag("downloader", "skipChecking");
        DefaultLimit.Text = (_model.SectionInt("downloader", "defaultUpLimit", 10485760) / 1048576).ToString();
        Select(PushPolicy, _model.SectionText("downloader", "pushPolicy", "onSuccess"));
        Select(GuardMode, _model.SectionText("downloader", "sizeGuardMode", "warn"));
        GuardMargin.Text = _model.SectionInt("downloader", "sizeGuardMarginGB", 20).ToString();
        VpsFree.Text = _model.Config?["downloader"]?["vpsFreeGB"] is { } v && v.GetValue<int>() > 0
            ? v.GetValue<int>().ToString() : "";
        LoadSSH();
        _loading = false;
    }

    /// SSH 测速卡片：配置里没这一段时用默认值显示（密钥登录、每轮 64 MB、Cloudflare 接收端）
    private void LoadSSH()
    {
        SshHost.Text = _model.SectionText("ssh", "host");
        Select(SshAuth, _model.SectionText("ssh", "auth", "key"));
        SshPass.Password = _model.SectionText("ssh", "password");
        SshPort.Text = _model.SectionInt("ssh", "port", 22).ToString();
        SshUser.Text = _model.SectionText("ssh", "user");
        SshKeyPath.Text = _model.SectionText("ssh", "keyPath", _model.SSHDefaults.KeyPath);
        SshTestMB.Text = _model.SectionInt("ssh", "testMB", _model.SSHDefaults.TestMB).ToString();
        SshProbe.Text = _model.SectionText("ssh", "probeURL", _model.SSHDefaults.ProbeURL);
        BtnSshTest.IsEnabled = !_model.BusySSH;
        BtnSshTest.Content = _model.BusySSH ? "测速中…" : "测试连接并测速";
    }

    private static void Select(ComboBox box, string tag)
    {
        foreach (var item in box.Items.OfType<ComboBoxItem>())
            if ((item.Tag as string) == tag) { box.SelectedItem = item; return; }
        box.SelectedIndex = 0;
    }

    private static string SelectedTag(ComboBox box) => (box.SelectedItem as ComboBoxItem)?.Tag as string ?? "";

    private static int Mb(TextBox box, int fallback) =>
        int.TryParse(box.Text.Trim(), out var mb) ? mb * 1048576 : fallback;

    private void OnSave(object sender, RoutedEventArgs e) => Save();

    private void Save() => _model.PatchSection("downloader", s =>
    {
        s["type"] = SelectedTag(Type);
        s["url"] = Url.Text.Trim();
        s["username"] = User.Text;
        s["password"] = Pass.Password;
        s["savePath"] = string.IsNullOrWhiteSpace(SavePath.Text) ? null : SavePath.Text.Trim();
        s["category"] = string.IsNullOrWhiteSpace(Category.Text) ? null : Category.Text.Trim();
        s["skipChecking"] = SkipCheck.IsChecked == true;
        s["defaultUpLimit"] = Mb(DefaultLimit, 10485760);
        s["pushPolicy"] = SelectedTag(PushPolicy);
        s["sizeGuardMode"] = SelectedTag(GuardMode);
        s["sizeGuardMarginGB"] = int.TryParse(GuardMargin.Text.Trim(), out var g) ? g : 20;
        if (int.TryParse(VpsFree.Text.Trim(), out var free)) s["vpsFreeGB"] = free;
        else s.Remove("vpsFreeGB");
    });

    private void OnTest(object sender, RoutedEventArgs e)
    {
        Save();
        var error = _model.Try("downloader.test");
        Result.Text = error ?? "测试中…";
        _ = _model.RefreshAsync(full: false);
    }

    private void OnTestSSH(object sender, RoutedEventArgs e) => _ = TestSSH();

    /// 测速走网络要几十秒：先存配置，丢给核心库后台跑，回来只报速度，不替用户下判断
    private async Task TestSSH()
    {
        SaveSSH();
        if (SshHost.Text.Trim().Length == 0 || SshUser.Text.Trim().Length == 0)
        {
            SshState.Text = "先填服务器地址与用户名";
            return;
        }
        if (SelectedTag(SshAuth) == "password" && SshPass.Password.Length == 0)
        {
            SshState.Text = "登录方式选了密码，还没填密码";
            return;
        }
        BtnSshTest.IsEnabled = false;
        BtnSshTest.Content = "测速中…";
        SshState.Text = "正在连接服务器并上传测试数据…";
        var r = await _model.TestSSHAsync();
        await _model.RefreshAsync(full: false);
        BtnSshTest.IsEnabled = true;
        BtnSshTest.Content = "测试连接并测速";
        SshState.Text = r.Ok
            ? "成功: " + r.Text + (r.Low ? "（接近被限速的量级）" : "")
            : "失败: " + r.Text;
    }

    private void SaveSSH()
    {
        if (_loading) return;
        // enabled 归「批量转种」页那个勾选项管，这里不碰（补丁只合并一层，没写的字段原样留着）
        _model.PatchSection("ssh", s =>
        {
            s["host"] = SshHost.Text.Trim();
            s["port"] = Num(SshPort, 22);
            s["user"] = SshUser.Text.Trim();
            s["auth"] = SelectedTag(SshAuth) == "password" ? "password" : "key";
            s["password"] = SshPass.Password;
            s["keyPath"] = Or(SshKeyPath.Text, _model.SSHDefaults.KeyPath);
            s["testMB"] = Num(SshTestMB, _model.SSHDefaults.TestMB);
            s["probeURL"] = Or(SshProbe.Text, _model.SSHDefaults.ProbeURL);
            s["timeoutSeconds"] = 15;
        });
    }

    private static int Num(TextBox box, int fallback) =>
        int.TryParse(box.Text.Trim(), out var v) ? v : fallback;

    private static string Or(string text, string fallback) =>
        string.IsNullOrWhiteSpace(text) ? fallback : text.Trim();

    private void OnReveal(object sender, RoutedEventArgs e)
    {
        PassPeek.Text = Pass.Password;
        Pass.Visibility = Reveal.IsChecked == true ? Visibility.Collapsed : Visibility.Visible;
        PassPeek.Visibility = Reveal.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }
}
