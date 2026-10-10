using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace BoxSend.Windows.Dialogs;

/// <summary>要一行文本输入的场合（分组名、重命名）用这个，省掉一套 XAML。</summary>
public static class PromptWindow
{
    public static string? Ask(Window owner, string title, string initial = "")
    {
        var box = new TextBox { Text = initial, MinWidth = 260, Padding = new Thickness(6, 4, 6, 4) };
        string? result = null;
        var ok = new Button { Content = "确定", IsDefault = true, Padding = new Thickness(14, 5, 14, 5) };
        var cancel = new Button { Content = "取消", IsCancel = true, Padding = new Thickness(14, 5, 14, 5) };
        var win = new Window
        {
            Title = title,
            Owner = owner,
            SizeToContent = SizeToContent.WidthAndHeight,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ResizeMode = ResizeMode.NoResize,
            Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#1F2530")),
            Content = Stack(new object[]
            {
                box,
                Row(new object[] { ok, Space(8), cancel }),
            }, 10),
        };
        ok.Click += (_, _) => { result = box.Text; win.DialogResult = true; };
        box.SelectAll();
        box.Focus();
        return win.ShowDialog() == true ? result : null;
    }

    internal static StackPanel Stack(IEnumerable<object> items, double spacing)
    {
        var p = new StackPanel { Margin = new Thickness(16) };
        foreach (var i in items)
        {
            if (i is UIElement e) p.Children.Add(e);
            if (Math.Abs(spacing) > 0.001 && i is not double) p.Children.Add(new FrameworkElement { Height = spacing });
        }
        return p;
    }

    internal static WrapPanel Row(IEnumerable<object> items)
    {
        var p = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right };
        foreach (var i in items) if (i is UIElement e) p.Children.Add(e);
        return p;
    }

    internal static FrameworkElement Space(double width) => new() { Width = width };
}

/// <summary>批量添加站点：从未纳管列表里勾选，选目标分组，可带序号（序号 = 排在第几位）。</summary>
public sealed class AddSitesWindow : Window
{
    private readonly AppModel _model;
    private readonly int _fixedGroup;
    private readonly TextBox _search = new() { MinWidth = 200 };
    private readonly ItemsControl _list = new();
    private readonly ComboBox _group = new() { Width = 180 };

    public AddSitesWindow(AppModel model, int fixedGroup)
    {
        _model = model;
        _fixedGroup = fixedGroup;
        Title = "批量添加站点";
        Owner = Window.GetWindow(Application.Current.MainWindow);
        Width = 720;
        Height = 560;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#1F2530"));

        foreach (var g in model.Groups) _group.Items.Add(g);
        _group.Items.Add(new GroupRow { Index = -1, Name = "不分组" });
        _group.SelectedIndex = fixedGroup >= 0 && fixedGroup < model.Groups.Count ? fixedGroup : 0;
        if (fixedGroup >= 0) _group.IsEnabled = false;

        var buttons = PromptWindow.Row(new object[]
        {
            new TextBlock { Text = "序号（可选，N = 排到第 N 位）", VerticalAlignment = VerticalAlignment.Center, Foreground = (Brush)Application.Current.Resources["TextMuted"] },
            new Button { Content = "添加所选", Padding = new Thickness(14, 5, 14, 5) },
        });
        var add = (Button)((WrapPanel)buttons).Children.Cast<UIElement>().Last();
        add.Click += OnAdd;
        var close = new Button { Content = "关闭", IsCancel = true, Padding = new Thickness(14, 5, 14, 5) };
        buttons.Children.Add(PromptWindow.Space(8));
        buttons.Children.Add(close);

        var header = new WrapPanel();
        header.Children.Add(new TextBlock
        {
            Text = "勾选要纳管的站点（纳管后即可参与转种与 cookie 同步）",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 10, 0),
        });
        header.Children.Add(_search);
        _search.TextChanged += (_, _) => Refresh();
        header.Children.Add(new TextBlock { Text = "加入分组", Margin = new Thickness(14, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
        header.Children.Add(_group);

        _list.Margin = new Thickness(0, 10, 0, 10);
        Content = PromptWindow.Stack(new object[]
        {
            header,
            new ScrollViewer { Content = _list, MaxHeight = 400, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            buttons,
        }, 0);
        Refresh();
    }

    private void Refresh()
    {
        var filter = _search.Text.Trim();
        _list.Items.Clear();
        foreach (var s in _model.Sites)
        {
            if (s.Managed) continue;
            if (filter.Length > 0 && !s.Name.Contains(filter, StringComparison.OrdinalIgnoreCase)
                                 && !s.Id.Contains(filter, StringComparison.OrdinalIgnoreCase)) continue;
            var box = new CheckBox
            {
                Content = $"{s.Name}  {s.Id}",
                Tag = s.Id,
                Margin = new Thickness(0, 3, 14, 3),
                Foreground = (Brush)Application.Current.Resources["TextPrimary"],
            };
            _list.Items.Add(box);
        }
        if (_list.Items.Count == 0)
            _list.Items.Add(new TextBlock { Text = "没有可添加的站点", Margin = new Thickness(0, 6, 0, 0) });
    }

    private void OnAdd(object sender, RoutedEventArgs e)
    {
        var ids = _list.Items.OfType<CheckBox>().Where(c => c.IsChecked == true)
                      .Select(c => (string)c.Tag!).ToArray();
        if (ids.Length == 0) return;
        var gi = (_group.SelectedItem as GroupRow)?.Index ?? -1;
        _model.Call("sites.add", new { ids, group = gi });
        Close();
    }
}

/// <summary>手动填写单站 cookie / API Key（站点没走同步插件时的兜底）。</summary>
public sealed class ManualCookieWindow : Window
{
    private readonly AppModel _model;
    private readonly ComboBox _site = new() { Width = 220 };
    private readonly TextBox _raw = new()
    {
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        MinHeight = 160,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        FontFamily = new FontFamily("Consolas, Microsoft YaHei"),
    };
    private readonly TextBlock _status = new() { Margin = new Thickness(0, 6, 0, 0) };

    public ManualCookieWindow(AppModel model, IReadOnlyList<SiteRow> sites)
    {
        _model = model;
        Title = "手动添加 cookie 或 api key";
        Width = 620;
        Height = 400;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#1F2530"));

        foreach (var s in sites) _site.Items.Add(s);
        _site.SelectedIndex = 0;
        _site.SelectionChanged += (_, _) => Load();

        var save = new Button { Content = "保存", Style = (Style)Application.Current.Resources["Primary"], Padding = new Thickness(14, 5, 14, 5) };
        save.Click += OnSave;
        var close = new Button { Content = "关闭", IsCancel = true, Padding = new Thickness(14, 5, 14, 5) };
        var clear = new Button { Content = "清空本站 cookie", Padding = new Thickness(14, 5, 14, 5) };
        clear.Click += (_, _) => { _raw.Clear(); OnSave(save, new RoutedEventArgs()); };

        Content = PromptWindow.Stack(new object[]
        {
            new TextBlock { Text = "站点" },
            _site,
            new TextBlock { Text = "cookie 原文（浏览器请求头里那一串，或 API Key）", Margin = new Thickness(0, 8, 0, 2) },
            _raw,
            _status,
            PromptWindow.Row(new object[] { save, PromptWindow.Space(8), clear, PromptWindow.Space(8), close }),
        }, 0);
        Load();
    }

    private void Load()
    {
        if (_site.SelectedItem is not SiteRow s) return;
        _status.Text = s.UsesApiKey ? "该站走 API Key" : $"当前状态：{s.CookieText}";
        var result = _model.Api.Invoke("cookies.getRaw", new { id = s.Id });
        _raw.Text = result["raw"]?.GetValue<string>() ?? "";
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        if (_site.SelectedItem is not SiteRow s) return;
        var error = _model.Try("cookies.setRaw", new { id = s.Id, raw = _raw.Text });
        _status.Text = error ?? "已保存，正在检测…";
        _ = _model.RefreshAsync();
    }
}
