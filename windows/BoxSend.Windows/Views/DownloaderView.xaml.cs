using System.Text.Json.Nodes;
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
    /// 表单当前编辑哪台（"main" = 主下载器）
    private string _editingID = "main";

    /// 快照回来就整页重填：列表、用途、表单都以核心库那份为准
    private void Load()
    {
        _loading = true;
        Result.Text = _model.DownloaderMessage;

        var list = _model.Downloaders;
        var picked = list.FirstOrDefault(d => d.Id == _editingID) ?? list.LastOrDefault();
        if (picked == null)
        {
            _loading = false;
            return;
        }
        _editingID = picked.Id;
        DlPick.ItemsSource = list;
        DlPick.SelectedValue = picked.Id;
        DlName.Text = picked.Name;
        BtnDelDl.IsEnabled = !picked.IsMain;
        ConnCard.Header = $"连接（{picked.Label}）";
        RoleReseed.ItemsSource = list;
        RoleReseed.SelectedValue = _model.ReseedDownloaderID;
        RoleAssist.ItemsSource = list;
        RoleAssist.SelectedValue = _model.AssistDownloaderID;

        Select(Type, picked.Type);
        Url.Text = picked.Url;
        User.Text = picked.Username;
        Pass.Password = picked.Password;
        SavePath.Text = picked.SavePath;
        Category.Text = picked.Category;
        SkipCheck.IsChecked = picked.SkipChecking;
        DefaultLimit.Text = (picked.DefaultUpLimit / 1048576).ToString();
        Select(PushPolicy, picked.PushPolicy);
        Select(GuardMode, picked.SizeGuardMode);
        GuardMargin.Text = picked.SizeGuardMarginGB.ToString();
        VpsFree.Text = picked.VpsFreeGB > 0 ? picked.VpsFreeGB.ToString() : "";
        LoadSSH();
        _loading = false;
    }

    // MARK: 多台下载器

    private void OnDownloaderPicked(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || DlPick.SelectedValue is not string id || id == _editingID) return;
        _editingID = id;
        Load();
    }

    private void OnRoleChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if (sender == RoleReseed && RoleReseed.SelectedValue is string r)
            _model.AssignDownloader("reseed", r);
        if (sender == RoleAssist && RoleAssist.SelectedValue is string a)
            _model.AssignDownloader("assist", a);
    }

    private void OnAddDownloader(object sender, RoutedEventArgs e) => _model.AddDownloader();

    private void OnRemoveDownloader(object sender, RoutedEventArgs e)
    {
        var err = _model.RemoveDownloader(_editingID);
        if (err != null)
        {
            Result.Text = err;
            return;
        }
        _editingID = "main";
        Result.Text = "已删除，用途自动指回主下载器";
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

    /// 保存正在编辑的那台（按 id upsert；逐站限速由核心库原样保留）
    private void Save()
    {
        if (_loading) return;
        var s = new JsonObject
        {
            ["id"] = _editingID,
            ["name"] = string.IsNullOrWhiteSpace(DlName.Text) ? "主下载器" : DlName.Text.Trim(),
        };
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
        else s["vpsFreeGB"] = null;
        _model.SaveDownloader(s);
    }

    private async void OnTest(object sender, RoutedEventArgs e)
    {
        Save();
        Result.Text = "测试中…";
        // 连下载器要走网络：放在界面线程上，窗口会先「未响应」一下
        var error = await _model.TestDownloaderAsync(_editingID);
        Result.Text = error ?? (_model.DownloaderMessage.Length > 0 ? _model.DownloaderMessage : "测试中…");
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
