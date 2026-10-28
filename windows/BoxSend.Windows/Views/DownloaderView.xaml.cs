using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace BoxSend.Windows.Views;

/// <summary>下载器页：每台一张卡片，添加后直接列出、直接改（与 mac 版一致，
/// 不再需要先选「正在编辑哪一台」）；用途指派与 SSH 测速在顶部与底部。</summary>
public partial class DownloaderView : UserControl
{
    private readonly AppModel _model;

    public DownloaderView(AppModel model)
    {
        _model = model;
        InitializeComponent();
        _model.FullRefreshed += (_, _) => Dispatcher.Invoke(Load);
        if (!model.AssistEnabled)
        {
            // 多下载器是为辅种而存在的：辅种收起时就只剩一台，加机器和挑用途都没地方用
            AddRow.Visibility = Visibility.Collapsed;
            RoleRow.Visibility = Visibility.Collapsed;
            DlBox.Header = "下载器";
            DlCaption.Text = "转种成功的种子都推到这一台，逐站限速照站点分组里设的走；"
                             + "换地址或换账号改完就生效，点卡片里的「测试连接」验一下。";
        }
        Load();
    }

    private bool _loading;

    /// 快照回来就整页重填：用途指派与每台一张卡片都以核心库那份为准
    private void Load()
    {
        _loading = true;
        Result.Text = _model.DownloaderMessage;

        var list = _model.Downloaders;
        RoleReseed.ItemsSource = list;
        RoleReseed.SelectedValue = _model.ReseedDownloaderID;
        RoleAssist.ItemsSource = list;
        RoleAssist.SelectedValue = _model.AssistDownloaderID;

        BuildCards(_model.VisibleDownloaders);
        LoadSSH();
        _loading = false;
    }

    /// 一台一张卡片；重建会把正在输入的内容换掉，所以只在整份刷新时跑（与 mac 同一时机）
    private void BuildCards(IReadOnlyList<DownloaderRow> list)
    {
        DlCards.Children.Clear();
        foreach (var d in list) DlCards.Children.Add(CardFor(d));
    }

    private UIElement CardFor(DownloaderRow d)
    {
        var name = new TextBox { Text = d.Name };
        var type = new ComboBox { MinHeight = 30 };
        type.Items.Add(new ComboBoxItem { Content = "qBittorrent", Tag = "qbittorrent" });
        type.Items.Add(new ComboBoxItem { Content = "Transmission", Tag = "transmission" });
        Select(type, d.Type);
        var url = new TextBox { Text = d.Url };
        var user = new TextBox { Text = d.Username };
        var pass = new TextBox { Text = d.Password };
        var savePath = new TextBox { Text = d.SavePath };
        var category = new TextBox { Text = d.Category };
        var limit = new TextBox { Text = (d.DefaultUpLimit / 1048576).ToString(), Width = 60 };
        var push = new ComboBox { MinHeight = 30, Width = 150 };
        push.Items.Add(new ComboBoxItem { Content = "转种成功就推", Tag = "onSuccess" });
        push.Items.Add(new ComboBoxItem { Content = "总是推", Tag = "always" });
        Select(push, d.PushPolicy);
        var skip = new CheckBox { Content = "跳过校验", IsChecked = d.SkipChecking, VerticalAlignment = VerticalAlignment.Center };
        var vpsFree = new TextBox { Text = d.VpsFreeGB > 0 ? d.VpsFreeGB.ToString() : "", Width = 60 };
        var guard = new ComboBox { MinHeight = 30, Width = 110 };
        guard.Items.Add(new ComboBoxItem { Content = "只提示", Tag = "warn" });
        guard.Items.Add(new ComboBoxItem { Content = "跳过推送", Tag = "skip" });
        Select(guard, d.SizeGuardMode);
        var margin = new TextBox { Text = d.SizeGuardMarginGB.ToString(), Width = 50 };
        var status = new TextBlock
        {
            FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(10, 0, 0, 0),
            TextWrapping = TextWrapping.Wrap,
            Foreground = (Brush)FindResource("TextMuted"),
        };

        JsonObject Collect()
        {
            var o = new JsonObject
            {
                ["id"] = d.Id,
                ["name"] = string.IsNullOrWhiteSpace(name.Text) ? d.Label : name.Text.Trim(),
                ["type"] = SelectedTag(type),
                ["url"] = url.Text.Trim(),
                ["username"] = user.Text,
                ["password"] = pass.Text,
                ["savePath"] = string.IsNullOrWhiteSpace(savePath.Text) ? null : savePath.Text.Trim(),
                ["category"] = string.IsNullOrWhiteSpace(category.Text) ? null : category.Text.Trim(),
                ["skipChecking"] = skip.IsChecked == true,
                ["defaultUpLimit"] = Mb(limit, 10485760),
                ["pushPolicy"] = SelectedTag(push),
                ["sizeGuardMode"] = SelectedTag(guard),
                ["sizeGuardMarginGB"] = int.TryParse(margin.Text.Trim(), out var g) ? g : 20,
                ["vpsFreeGB"] = int.TryParse(vpsFree.Text.Trim(), out var free) ? free : (int?)null,
            };
            return o;
        }

        void Save()
        {
            if (_loading) return;
            _model.SaveDownloader(Collect());
            status.Text = "已保存";
        }

        async void Test()
        {
            Save();
            status.Text = "测试中…";
            // 连下载器要走网络：放在界面线程上，窗口会先「未响应」一下
            var error = await _model.TestDownloaderAsync(d.Id);
            status.Text = error ?? (_model.DownloaderMessage.Length > 0 ? _model.DownloaderMessage : "测试中…");
        }

        var grid = new Grid { Margin = new Thickness(0, 0, 0, 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var i = 0; i < 3; i++) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Put(grid, 0, 0, Labeled(_model.AssistEnabled ? "名字（列表与用途下拉里显示）" : "名字（卡片标题显示）", name));
        Put(grid, 0, 1, Labeled("类型", type));
        Put(grid, 1, 0, Labeled("地址（VPS 隧道地址，如 http://127.0.0.1:8080）", url));
        Put(grid, 1, 1, Two(
            Labeled("用户名", user),
            Labeled("密码", pass)));
        Put(grid, 2, 0, Two(
            Labeled("保存路径（留空用下载器默认）", savePath),
            Labeled("qBittorrent 分类", category)));
        Put(grid, 2, 1, Two(
            Labeled("默认上传限速 MB/s", limit),
            Two(Labeled("推送时机", push), skip)));

        var guardRow = new WrapPanel { Margin = new Thickness(0, 2, 0, 0), };
        guardRow.Children.Add(Labeled("VPS 剩余空间（GB，留空不检查）", vpsFree));
        guardRow.Children.Add(Labeled("不足时", guard));
        guardRow.Children.Add(Labeled("余量 GB", margin));

        var buttons = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        var save = new Button
        {
            Content = "保存",
            Style = (Style)FindResource("Primary"),
        };
        save.Click += (_, _) => Save();
        buttons.Children.Add(save);
        var test = new Button { Content = "测试连接", Margin = new Thickness(10, 0, 0, 0) };
        test.Click += (_, _) => Test();
        buttons.Children.Add(test);
        // 只剩一台时不给删除：删了整条推送链路就没落脚的地方
        if (_model.AssistEnabled)
        {
            var del = new Button
            {
                Content = "删除这台",
                Margin = new Thickness(10, 0, 0, 0),
                IsEnabled = !d.IsMain,
                ToolTip = d.IsMain ? "主下载器不能删" : "删除这台下载器",
            };
            del.Click += (_, _) =>
            {
                var err = _model.RemoveDownloader(d.Id);
                status.Text = err ?? "已删除，用途自动指回主下载器";
            };
            buttons.Children.Add(del);
        }
        buttons.Children.Add(status);

        var body = new StackPanel();
        body.Children.Add(grid);
        body.Children.Add(guardRow);
        body.Children.Add(buttons);
        return new GroupBox
        {
            // 标题只报名字（地址就在下面的输入框里，标题再重复一遍只是噪声）
            Header = string.IsNullOrWhiteSpace(d.Name) ? "下载器" : d.Name,
            Margin = new Thickness(0, 0, 0, 10),
            Content = body,
        };
    }

    /// 两列里再并排两个小字段
    private static UIElement Two(UIElement a, UIElement b)
    {
        var p = new WrapPanel();
        p.Children.Add(a);
        p.Children.Add(b);
        return p;
    }

    private static UIElement Labeled(string text, FrameworkElement input)
    {
        var p = new StackPanel { Margin = new Thickness(0, 0, 8, 6) };
        p.Children.Add(new Label { Content = text, Padding = new Thickness(0, 0, 0, 2) });
        input.MinHeight = 30;
        input.VerticalAlignment = VerticalAlignment.Center;
        p.Children.Add(input);
        return p;
    }

    private static void Put(Grid grid, int row, int col, UIElement child)
    {
        Grid.SetRow(child, row);
        Grid.SetColumn(child, col);
        grid.Children.Add(child);
    }

    // MARK: 多台下载器

    private void OnRoleChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if (sender == RoleReseed && RoleReseed.SelectedValue is string r)
            _model.AssignDownloader("reseed", r);
        if (sender == RoleAssist && RoleAssist.SelectedValue is string a)
            _model.AssignDownloader("assist", a);
    }

    private void OnAddDownloader(object sender, RoutedEventArgs e) => _model.AddDownloader();

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
}
