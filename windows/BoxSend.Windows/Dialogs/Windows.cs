using System.Text.Json.Nodes;
using System.Windows.Input;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

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
        };
        win.Content = Backdrop(win, Stack(new object[]
        {
            box,
            Row(new object[] { ok, Space(8), cancel }),
        }, 10));
        ok.Click += (_, _) => { result = box.Text; win.DialogResult = true; };
        box.SelectAll();
        box.Focus();
        return win.ShowDialog() == true ? result : null;
    }

    /// <summary>弹窗背景：主题渐变 + 背景图片（用设置里的透明度）+ 内容。
    /// Window.Background 只放得下一个纯色刷子，渐变与壁纸会整个丢掉，
    /// 所以这里像主窗口那样铺三层；底色留着当「没设壁纸」时的兜底。</summary>
    internal static FrameworkElement Backdrop(Window win, UIElement content)
    {
        win.Background = Themed("DialogBackground", "#1F2530");
        var grid = new Grid();
        grid.Children.Add(new Rectangle { Fill = Themed("GradientBackground", "#1F2530") });
        if (Application.Current.Resources["BackgroundImage"] is ImageSource img)
            grid.Children.Add(new Image
            {
                Source = img,
                Stretch = Stretch.UniformToFill,
                Opacity = Application.Current.Resources["BackgroundImageOpacity"] is double d
                    ? Math.Clamp(d, 0, 1)
                    : 0,
            });
        grid.Children.Add(content);
        return grid;
    }

    /// <summary>取主题色（没定义时退回深色底）：弹窗底色必须跟着主题走，
    /// 否则「云端白」上会浮一块近黑的板子。</summary>
    internal static Brush Themed(string key, string fallbackHex) =>
        Application.Current.Resources[key] is Brush b
            ? b
            : new SolidColorBrush((Color)ColorConverter.ConvertFromString(fallbackHex));

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

/// <summary>
/// 批量添加站点：卡片式多选（点卡片 = 选中，加深色边框 = 已选），支持搜索、全选、
/// 整卡拖拽排序、输入序号回车排到第 N 位（序号重复会提示）。
/// 候选顺序与排序规则都由核心给（sites.candidates / unmanagedSiteOrder），与 mac 版一致。
/// </summary>
public sealed class AddSitesWindow : Window
{
    private readonly AppModel _model;
    private readonly int _group;
    private readonly bool _assist;
    private readonly List<(string Id, string Name, string Url)> _all = new();
    private List<string> _order = new();                   // 当前完整排序（含未显示的）
    private readonly HashSet<string> _selected = new();
    private readonly Dictionary<string, CardRefs> _cards = new();
    private readonly TextBox _search = new() { Width = 220 };
    private readonly TextBlock _searchHint = new()
    {
        Text = "搜索站名 / id / 地址",
        Foreground = (Brush)Application.Current.Resources["TextMuted"],
        Margin = new Thickness(9, 0, 0, 0),
        VerticalAlignment = VerticalAlignment.Center,
        IsHitTestVisible = false,
        FontSize = 12,
    };
    private readonly TextBlock _picked = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _addAll = new() { Content = "全选", FontSize = 12 };
    private readonly Button _add = new()
    {
        Content = "添加",
        Style = (Style)Application.Current.Resources["Primary"],
        Padding = new Thickness(14, 5, 14, 5),
        IsDefault = true,
    };
    private readonly WrapPanel _grid = new();

    public AddSitesWindow(AppModel model, int fixedGroup, bool assist = false)
    {
        _model = model;
        _group = fixedGroup;
        _assist = assist;
        Title = assist ? "批量添加站点（辅种站点）"
            : fixedGroup >= 0 && fixedGroup < model.Groups.Count
            ? $"批量添加站点（加入分组：{model.Groups[fixedGroup].Name}）"
            : "批量添加站点";
        Owner = Window.GetWindow(Application.Current.MainWindow);
        Width = 760;
        Height = 600;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        LoadCandidates();

        var head = new DockPanel();
        DockPanel.SetDock(_picked, Dock.Right);
        head.Children.Add(_picked);
        head.Children.Add(new TextBlock
        {
            Text = Title,
            FontWeight = FontWeights.SemiBold,
            FontSize = 14,
            VerticalAlignment = VerticalAlignment.Center,
        });

        var search = new Grid();
        search.Children.Add(_search);
        search.Children.Add(_searchHint);
        _search.TextChanged += (_, _) =>
        {
            _searchHint.Visibility = _search.Text.Length > 0 ? Visibility.Collapsed : Visibility.Visible;
            Rebuild();
        };
        _addAll.Click += (_, _) =>
        {
            var shown = Visible();
            if (shown.All(_selected.Contains)) foreach (var id in shown) _selected.Remove(id);
            else foreach (var id in shown) _selected.Add(id);
            RefreshVisuals();
        };

        var toolbar = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        toolbar.Children.Add(search);
        toolbar.Children.Add(new FrameworkElement { Width = 8 });
        toolbar.Children.Add(_addAll);
        toolbar.Children.Add(new TextBlock
        {
            Text = "拖右侧把手排序，或在把手左边输入序号回车排到第 N 位",
            FontSize = 12,
            Margin = new Thickness(12, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = (Brush)Application.Current.Resources["TextMuted"],
        });

        var scroll = new ScrollViewer
        {
            Content = _grid,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Margin = new Thickness(0, 10, 0, 10),
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        Grid.SetRow(scroll, 1);

        var hint = new TextBlock
        {
            Text = "添加后默认开启；限速默认取分组上传限速，未设 = 10 MB/s。",
            FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 380,
            HorizontalAlignment = HorizontalAlignment.Left,
            Foreground = (Brush)Application.Current.Resources["TextMuted"],
        };
        var cancel = new Button { Content = "取消", IsCancel = true, Padding = new Thickness(14, 5, 14, 5) };
        var buttons = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(hint, Dock.Left);
        buttons.Children.Add(cancel);
        buttons.Children.Add(new FrameworkElement { Width = 8 });
        buttons.Children.Add(_add);
        var footer = new DockPanel();
        footer.Children.Add(hint);
        footer.Children.Add(buttons);
        Grid.SetRow(footer, 2);
        cancel.Click += (_, _) => Close();
        _add.Click += OnAdd;
        _add.IsEnabled = false;

        // 三行：标题 + 工具条 / 卡片列表 / 底部按钮
        var top = new StackPanel();
        top.Children.Add(head);
        top.Children.Add(toolbar);
        Grid.SetRow(top, 0);
        var layout = new Grid { Margin = new Thickness(16) };
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.Children.Add(top);
        layout.Children.Add(scroll);
        layout.Children.Add(footer);
        Content = PromptWindow.Backdrop(this, layout);

        Rebuild();
    }

    private void LoadCandidates()
    {
        // 辅种那份不受转种分组影响：列全部站点，只排掉已经在辅种名单里的（规则在核心）
        var rows = (_model.Api.Invoke("sites.candidates", new { assist = _assist })["sites"]?.AsArray()
                    ?? new JsonArray());
        foreach (var n in rows)
        {
            _all.Add((n!["id"]?.GetValue<string>() ?? "",
                      n["name"]?.GetValue<string>() ?? "",
                      n["url"]?.GetValue<string>() ?? ""));
            _order.Add(n!["id"]?.GetValue<string>() ?? "");
        }
    }

    private (string Id, string Name, string Url) Row(string id)
    {
        foreach (var r in _all) if (r.Id == id) return r;
        return (id, id, "");
    }

    /// 当前搜索词下要显示的站点（按 _order 的顺序）
    private List<string> Visible()
    {
        var q = _search.Text.Trim();
        return _order.Where(id =>
        {
            if (q.Length == 0) return true;
            var r = Row(id);
            return r.Name.Contains(q, StringComparison.OrdinalIgnoreCase)
                   || r.Id.Contains(q, StringComparison.OrdinalIgnoreCase)
                   || r.Url.Contains(q, StringComparison.OrdinalIgnoreCase);
        }).ToList();
    }

    private void Rebuild()
    {
        _grid.Children.Clear();
        _cards.Clear();
        var shown = Visible();
        if (shown.Count == 0)
        {
            _grid.Children.Add(new TextBlock
            {
                Text = _order.Count == 0 ? "内置站点都已经添加过了。" : "没有匹配的站点",
                Margin = new Thickness(0, 6, 0, 0),
                Foreground = (Brush)Application.Current.Resources["TextMuted"],
            });
        }
        foreach (var id in shown) _grid.Children.Add(CardFor(id));
        RefreshVisuals();
    }

    /// 一张卡片：站名 + 地址 + 序号框 + 拖拽把手；点卡片文字区选中 / 取消
    private UIElement CardFor(string id)
    {
        var r = Row(id);
        var title = new TextBlock
        {
            Text = r.Name,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var url = new TextBlock
        {
            Text = r.Url,
            FontSize = 11,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = (Brush)Application.Current.Resources["TextMuted"],
        };
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(title);
        texts.Children.Add(url);
        texts.MouseLeftButtonUp += (_, _) =>
        {
            if (CardDrag.JustDragged) return;   // 刚从这张卡上拖起来，不算「点击选中」
            Toggle(id);
        };

        // 序号框：占位显示当前位置，输入数字回车即排到该位置
        var num = new TextBox
        {
            Width = 34,
            MinHeight = 24,
            FontSize = 12,
            Padding = new Thickness(3, 2, 3, 2),
            TextAlignment = TextAlignment.Center,
            Tag = id,
            ToolTip = $"当前第 {_order.IndexOf(id) + 1} 位；输入新序号回车排到该位置",
        };
        num.PreviewTextInput += (_, e) =>
        {
            if (!e.Text.All(char.IsDigit)) e.Handled = true;
        };
        num.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            e.Handled = true;      // 「添加」是默认按钮，不截下来会在排序前先关窗
            ApplySortNumbers();
        };
        // 只填了数字没敲回车（点到别处）也照样排，别让人以为没生效
        num.LostFocus += (_, _) =>
        {
            if (num.Text.Trim().Length > 0) ApplySortNumbers();
        };

        var grip = new TextBlock
        {
            Text = "≡",
            FontSize = 15,
            Width = 12,
            TextAlignment = TextAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Cursor = System.Windows.Input.Cursors.SizeNS,
            ToolTip = "按住卡片拖到另一张卡上，排到它前面",
            Foreground = (Brush)Application.Current.Resources["TextMuted"],
            // 把手只当视觉提示：接拖拽的是整张卡片
            IsHitTestVisible = false,
        };

        var row = new DockPanel();
        DockPanel.SetDock(grip, Dock.Right);
        DockPanel.SetDock(num, Dock.Right);
        row.Children.Add(grip);
        row.Children.Add(num);
        row.Children.Add(texts);

        var card = new Border
        {
            Width = 190,
            Margin = new Thickness(0, 0, 8, 8),
            Padding = new Thickness(9),
            CornerRadius = new CornerRadius(8),
            Background = PromptWindow.Themed("BlockSurface", "#61000000"),
            BorderThickness = new Thickness(1),
            BorderBrush = (Brush)Application.Current.Resources["Line"],
            Child = row,
            ToolTip = $"{r.Name}\n{r.Url}",
        };
        card.MouseEnter += (_, _) => { if (CardDrag.DraggingId == null) card.BorderBrush = AccentBrush(); };
        card.MouseLeave += (_, _) => RefreshCard(id);
        CardDrag.MakeSortable(card, id, MoveBefore, _ => RefreshVisuals());

        _cards[id] = new CardRefs(card, title, num);
        return card;
    }

    private void Toggle(string id)
    {
        if (!_selected.Remove(id)) _selected.Add(id);
        RefreshVisuals();
    }

    private static Brush AccentBrush() =>
        Application.Current.Resources["Accent"] is SolidColorBrush a
            ? a
            : (Brush)Application.Current.Resources["Line"];

    /// 选中态：强调色描边 + 一层淡淡的强调色底（与 mac 版「加深色 = 已选中」一致）
    private void RefreshCard(string id)
    {
        if (!_cards.TryGetValue(id, out var refs)) return;
        var on = _selected.Contains(id);
        refs.Card.BorderBrush = on || CardDrag.DraggingId == id ? AccentBrush()
            : (Brush)Application.Current.Resources["Line"];
        refs.Card.BorderThickness = new Thickness(on ? 1.5 : 1);
        refs.Card.Background = on ? TintedAccent() : PromptWindow.Themed("BlockSurface", "#61000000");
        refs.Title.FontWeight = on ? FontWeights.SemiBold : FontWeights.Normal;
        refs.Num.ToolTip = $"当前第 {_order.IndexOf(id) + 1} 位；输入新序号回车排到该位置";
    }

    private static Brush TintedAccent()
    {
        if (Application.Current.Resources["Accent"] is SolidColorBrush a)
        {
            var b = new SolidColorBrush(a.Color) { Opacity = 0.28 };
            b.Freeze();
            return b;
        }
        return (Brush)Application.Current.Resources["BlockSurface"];
    }

    private void RefreshVisuals()
    {
        foreach (var id in _cards.Keys.ToList()) RefreshCard(id);
        _picked.Text = $"已选 {_selected.Count}";
        _picked.Foreground = (Brush)Application.Current.Resources["TextMuted"];
        var shown = Visible();
        _addAll.Content = shown.Count > 0 && shown.All(_selected.Contains) ? "全不选" : "全选";
        _add.Content = $"添加 {_selected.Count} 个站点";
        _add.IsEnabled = _selected.Count > 0;
    }

    /// 拖拽：把 from 放到 to 之前，并把手排序回写配置（下次打开还是这个顺序）
    private void MoveBefore(string from, string to)
    {
        var i = _order.IndexOf(from);
        if (i < 0) return;
        _order.RemoveAt(i);
        _order.Insert(Math.Min(_order.IndexOf(to), _order.Count), from);
        ReorderDone();
    }

    /// 序号 = 目标位置：填 N 的排到第 N 位，位置被占就往后挪；没填的按原相对顺序填剩下的坑
    private void ApplySortNumbers()
    {
        var nums = new Dictionary<string, int>();
        foreach (var refs in _cards.Values)
            if (int.TryParse(refs.Num.Text.Trim(), out var n) && n > 0)
                nums[refs.Id] = n;
        if (nums.Count == 0) return;

        var dups = nums.GroupBy(kv => kv.Value)
                       .Where(g => g.Count() > 1)
                       .OrderBy(g => g.Key)
                       .Select(g => $"「{string.Join("、", g.Select(kv => Row(kv.Key).Name))}」都填了序号 {g.Key}")
                       .ToList();
        if (dups.Count > 0)
        {
            MessageBox.Show(this,
                "序号重复：" + string.Join("；", dups) + "。请改重复的序号后再回车排序。",
                "序号重复", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var count = _order.Count;
        var old = _order.Select((id, i) => (id, i)).ToDictionary(x => x.id, x => x.i);
        var slots = new string?[count];
        foreach (var id in _order.Where(nums.ContainsKey)
                     .OrderBy(a => nums[a])
                     .ThenBy(a => old[a]))
        {
            var target = Math.Min(Math.Max(nums[id] - 1, 0), count - 1);
            var t = target;
            while (t < count && slots[t] != null) t++;
            if (t == count)
            {
                t = target;
                while (t > 0 && slots[t] != null) t--;
            }
            slots[t] = id;
        }
        var rest = _order.Where(id => !nums.ContainsKey(id)).GetEnumerator();
        for (var i = 0; i < count; i++) if (slots[i] == null && rest.MoveNext()) slots[i] = rest.Current;
        _order = slots.Select(x => x ?? "").Where(x => x.Length > 0).ToList();

        foreach (var refs in _cards.Values) refs.Num.Clear();
        ReorderDone();
    }

    private void ReorderDone()
    {
        // 手动排序存进配置（unmanagedSiteOrder），关窗重开也保留
        var arr = new JsonArray();
        foreach (var id in _order) arr.Add(id);
        _model.Patch(new JsonObject { ["unmanagedSiteOrder"] = arr });
        Rebuild();
    }

    private void OnAdd(object sender, RoutedEventArgs e)
    {
        // 按当前显示顺序提交，分组内的先后就跟卡片顺序一致
        var ids = _order.Where(_selected.Contains).ToArray();
        if (ids.Length == 0) return;
        // 辅种模式：入站点池但不进分组（核心里那一份实现与 mac 共用）
        _model.Call(_assist ? "assist.addSites" : "sites.add", new { ids, group = _group });
        Close();
    }

    private sealed record CardRefs(Border Card, TextBlock Title, TextBox Num)
    {
        public string Id => (string)Num.Tag!;
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
    private readonly TextBlock _kind = new() { Margin = new Thickness(0, 8, 0, 2) };
    private readonly TextBlock _status = new() { Margin = new Thickness(0, 6, 0, 0) };
    private readonly Button _clear = new() { Content = "清空本站 cookie", Padding = new Thickness(14, 5, 14, 5) };

    public ManualCookieWindow(AppModel model, IReadOnlyList<SiteRow> sites)
    {
        _model = model;
        Title = "手动添加 cookie 或 api key";
        Width = 620;
        Height = 400;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        foreach (var s in sites) _site.Items.Add(s);
        _site.SelectedIndex = 0;
        _site.SelectionChanged += (_, _) => Load();

        var save = new Button { Content = "保存", Style = (Style)Application.Current.Resources["Primary"], Padding = new Thickness(14, 5, 14, 5) };
        save.Click += OnSave;
        var close = new Button { Content = "关闭", IsCancel = true, Padding = new Thickness(14, 5, 14, 5) };
        _clear.Click += (_, _) => { _raw.Clear(); OnSave(save, new RoutedEventArgs()); };

        Content = PromptWindow.Backdrop(this, PromptWindow.Stack(new object[]
        {
            new TextBlock { Text = "站点" },
            _site,
            _kind,
            _raw,
            _status,
            PromptWindow.Row(new object[] { save, PromptWindow.Space(8), _clear, PromptWindow.Space(8), close }),
        }, 0));
        Load();
    }

    private void Load()
    {
        if (_site.SelectedItem is not SiteRow s) return;
        // API 站（馒头、肉丝）不走 cookie 同步，输入框里那串是 API Key
        _kind.Text = s.UsesApiKey
            ? "站点 API Key（站点页「个人主页 → 设置 → API」里获取，整段粘贴）"
            : "cookie 原文（浏览器 Cookie 头，形如 name1=value1; name2=value2，整段粘贴）";
        _clear.Content = s.UsesApiKey ? "清空本站 API Key" : "清空本站 cookie";
        _status.Text = $"当前{s.CookieText}；保存即覆盖该站原有"
                       + (s.UsesApiKey ? " API Key" : " cookie") + "，并自动开启该站";
        var result = _model.Api.Invoke("cookies.getRaw", new { id = s.Id });
        _raw.Text = result["raw"] is JsonValue rv && rv.TryGetValue<string>(out var t) ? t : "";
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        if (_site.SelectedItem is not SiteRow s) return;
        var result = _model.Api.TryInvoke("cookies.setRaw", out var error,
                                          new { id = s.Id, raw = _raw.Text });
        _status.Text = error ?? (result?["message"] is JsonValue mv && mv.TryGetValue<string>(out var msg)
            ? msg + "，正在检测…" : "已保存，正在检测…");
        _ = _model.RefreshAsync();
    }
}
