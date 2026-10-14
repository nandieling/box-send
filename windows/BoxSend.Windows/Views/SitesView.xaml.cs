using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace BoxSend.Windows.Views;

/// <summary>站点分组页：分组卡片 + 组内站点卡片（cookie 状态、限速、免费一天、上下移、移除）。
/// 规则与 mac 版一致：移除分组 / 移除站点都要两次确认；没归组的站点才显示「未分组」这一块。</summary>
public partial class SitesView : UserControl
{
    private readonly AppModel _model;
    /// 组内拖拽排序：拖把手的那张卡片（半透明）+ 现有卡片与序号框，供拖放与序号排序回查
    private string? _dragging;
    private readonly Dictionary<string, Border> _cards = new();
    private readonly Dictionary<string, TextBox> _nums = new();

    public SitesView(AppModel model)
    {
        _model = model;
        InitializeComponent();
        _model.FullRefreshed += (_, _) => Dispatcher.Invoke(Reload);
        Reload();
    }

    private void Reload()
    {
        Blocks.Children.Clear();
        _cards.Clear();
        _nums.Clear();
        foreach (var g in _model.Groups) Blocks.Children.Add(BlockFor(g));
        var unassigned = _model.Sites.Where(s => s.Managed && s.Group < 0).ToList();
        // 只有真有没归组的站点才出现这一块，否则页面上会有一个去不掉的空「未分组」
        if (unassigned.Count > 0) Blocks.Children.Add(BlockFor(null, unassigned));
        if (!_model.Sites.Any(s => s.Managed))
            Blocks.Children.Add(new TextBlock
            {
                Text = "还没有添加站点：点「批量添加站点」挑一批，或点分组上的「添加站点」。",
                FontSize = 12,
                Margin = new Thickness(0, 4, 0, 0),
                Foreground = (Brush)FindResource("TextMuted"),
            });
        Hint.Text = $"共 {_model.Sites.Count(s => s.Managed)} 个已纳管站点"
            + $"（本地 cookie 记录 {_model.CookieTotal} 条）";
        BtnStopCheck.Visibility = _model.BusyCookieCheck ? Visibility.Visible : Visibility.Collapsed;
        BtnCheckAll.Content = _model.BusyCookieCheck ? "检测中…" : "检测全部 cookie";
        BtnCheckAll.IsEnabled = !_model.BusyCookieCheck;
        BtnSync.IsEnabled = !_model.BusyCookieSync;
        BtnSync.Content = _model.BusyCookieSync ? "同步中…" : "同步 Cookie";
    }

    private UIElement BlockFor(GroupRow? group, List<SiteRow>? overrideSites = null)
    {
        var sites = overrideSites ?? _model.Sites.Where(s => s.Group == group!.Index).ToList();
        var panel = new StackPanel();

        // ---- 标题行：分组名 + 组默认限速 + 重命名 / 移除分组 / 添加站点 ----
        var header = new WrapPanel();
        header.Children.Add(new TextBlock
        {
            Text = group == null ? $"未分组站点（{sites.Count}）" : $"分组：{group.Name}",
            FontWeight = FontWeights.SemiBold,
            FontSize = 14,
            Margin = new Thickness(0, 0, 10, 0),
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (group != null)
        {
            var limit = new TextBox
            {
                Width = 116,
                Text = group.UpLimitMB.ToString(),
                TextAlignment = TextAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                ToolTip = "组内新增站点的默认限速 MB/s，0 = 用 10",
            };
            header.Children.Add(new TextBlock
            {
                Text = "限速 MB/s",
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 4, 0),
            });
            header.Children.Add(limit);
            var saved = group.UpLimitMB;
            limit.LostFocus += (_, _) =>
            {
                if (int.TryParse(limit.Text, out var mb) && mb != saved)
                    _model.Call("groups.setLimit", new { index = group.Index, upLimitMB = mb });
            };
            // 顺序与 mac 一致：先加站点，再改名，最后才是那个要两次确认的移除
            header.Children.Add(SmallButton("添加站点", () => AddSitesTo(group.Index)));
            header.Children.Add(SmallButton("重命名", () => Rename(group)));
            header.Children.Add(SmallButton("移除分组", () => RemoveGroup(group), danger: true));
        }
        else
        {
            header.Children.Add(SmallButton("添加站点", () => AddSitesTo(-1)));
        }
        panel.Children.Add(header);

        // ---- 工具行：N 站 / 全选 / 手动 cookie / 移除站点（cookie 检测只在顶部做全量）----
        var toolbar = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
        toolbar.Children.Add(new TextBlock
        {
            Text = $"{sites.Count} 站",
            FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = (Brush)FindResource("TextMuted"),
        });
        var on = sites.Where(s => s.Enabled).ToList();
        var allOn = sites.Count > 0 && on.Count == sites.Count;
        toolbar.Children.Add(TinyButton(allOn ? "全不选" : "全选",
            () => _model.Call("sites.setEnabled",
                new { ids = sites.Select(s => s.Id).ToArray(), enabled = !allOn }), sites.Count > 0));
        toolbar.Children.Add(TinyButton("手动填 cookie / Key",
            () => new Dialogs.ManualCookieWindow(_model, on) { Owner = Window.GetWindow(this) }.ShowDialog(),
            on.Count > 0));
        toolbar.Children.Add(TinyButton("移除站点", () => RemoveSites(group, on), on.Count > 0, danger: true));
        if (group == null)
            toolbar.Children.Add(TinyButton("全部移出纳管", () => RemoveSites(null, sites),
                sites.Count > 0, danger: true));
        panel.Children.Add(toolbar);

        var cards = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        var block = group?.Index ?? -1;
        foreach (var s in sites) cards.Children.Add(CardFor(s, block));
        panel.Children.Add(cards);
        if (sites.Count == 0)
            panel.Children.Add(new TextBlock
            {
                Text = "该分组还没有站点：点上面的「添加站点」批量添加。",
                FontSize = 12,
                Margin = new Thickness(0, 4, 0, 0),
                Foreground = (Brush)FindResource("TextMuted"),
            });

        return new Border
        {
            Background = (Brush)FindResource("TextSurface"),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10),
            Margin = new Thickness(0, 0, 0, 14),
            Child = panel,
        };
    }

    /// <summary>站点卡片：名称 / 地址 / cookie 状态 / 上传限速（+「发种后免费一天」单独一行，
    /// 免得卡片窄时被压成竖排）。点名称区开启或停用该站；组内排序靠拖右侧把手或在把手左边
    /// 输入序号回车（与 mac 版同一套），所以卡上不再放上下移与移组 / 移除按钮。</summary>
    private UIElement CardFor(SiteRow s, int block)
    {
        var title = new StackPanel { Cursor = Cursors.Hand, Background = Brushes.Transparent };
        title.Children.Add(new TextBlock
        {
            Text = s.Name,
            FontWeight = s.Enabled ? FontWeights.SemiBold : FontWeights.Normal,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = (Brush)FindResource(s.Enabled ? "TextPrimary" : "TextMuted"),
        });
        title.Children.Add(new TextBlock
        {
            Text = s.Url,
            FontSize = 11,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = (Brush)FindResource("TextMuted"),
        });
        title.MouseLeftButtonUp += (_, _) =>
            _model.Call("sites.setEnabled", new { ids = new[] { s.Id }, enabled = !s.Enabled });
        title.ToolTip = s.Enabled ? "已开启，点击停用" : "未开启，点击开启";

        // 序号框：占位显示组内当前位置，输入数字回车即排到该位置
        var num = new TextBox
        {
            Width = 34,
            MinHeight = 24,
            FontSize = 12,
            Padding = new Thickness(3, 2, 3, 2),
            TextAlignment = TextAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Tag = s.Id,
            ToolTip = $"组内第 {s.IndexInBlock + 1} 位；输入新序号回车排到该位置",
        };
        num.PreviewTextInput += (_, e) =>
        {
            if (!e.Text.All(char.IsDigit)) e.Handled = true;
        };
        num.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            e.Handled = true;
            ApplySiteSort(block);
        };
        _nums[s.Id] = num;

        var grip = new TextBlock
        {
            Text = "≡",
            FontSize = 15,
            Width = 14,
            TextAlignment = TextAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Cursor = Cursors.SizeNS,
            ToolTip = "按住拖拽调整组内位置",
            Foreground = (Brush)FindResource("TextMuted"),
        };
        var self = s.Id;
        grip.MouseLeftButtonDown += (_, _) =>
        {
            _dragging = self;
            if (_cards.TryGetValue(self, out var me)) me.Opacity = 0.45;
            DragDrop.DoDragDrop(grip, new DataObject(DataFormats.Text, self), DragDropEffects.Move);
            // DoDragDrop 到放手才返回，这里恢复透明度并清状态
            if (_cards.TryGetValue(self, out me)) me.Opacity = 1;
            _dragging = null;
        };

        var head = new DockPanel();
        DockPanel.SetDock(grip, Dock.Right);
        DockPanel.SetDock(num, Dock.Right);
        head.Children.Add(grip);
        head.Children.Add(num);
        head.Children.Add(title);

        var body = new StackPanel();
        body.Children.Add(head);
        // 状态只说结论，检测原因放鼠标提示（跟 mac 版一致）
        var status = new TextBlock
        {
            Text = s.Enabled ? s.CredentialText : "未开启",
            FontSize = 11,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = (Brush)FindResource(s.CheckOk == true ? "Accent" : "TextMuted"),
        };
        if (s.CheckMessage.Length > 0) status.ToolTip = s.CheckMessage;
        body.Children.Add(status);
        if (s.Warning.Length > 0)
            body.Children.Add(new TextBlock
            {
                Text = s.Warning,
                FontSize = 11,
                TextWrapping = TextWrapping.Wrap,
                Foreground = (Brush)FindResource("Warning"),
            });

        var row = new WrapPanel { Margin = new Thickness(0, 4, 0, 0) };
        var limit = new TextBox
        {
            Width = 52,
            Text = s.UpLimitMB.ToString(),
            TextAlignment = TextAlignment.Center,
            FontSize = 12,
            Padding = new Thickness(4, 2, 4, 2),
            MinHeight = 24,
            ToolTip = "上传限速 MB/s，0 = 不限速",
        };
        var savedLimit = s.UpLimitMB;
        limit.LostFocus += (_, _) =>
        {
            if (int.TryParse(limit.Text, out var mb) && mb != savedLimit)
                _model.Call("sites.setUpLimit", new { id = s.Id, upLimitMB = mb });
        };
        row.Children.Add(new TextBlock
        {
            Text = "限速",
            FontSize = 11,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 4, 0),
            Foreground = (Brush)FindResource("TextMuted"),
        });
        row.Children.Add(limit);
        row.Children.Add(new TextBlock
        {
            Text = "MB/s",
            FontSize = 11,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(3, 0, 0, 0),
            Foreground = (Brush)FindResource("TextMuted"),
        });
        body.Children.Add(row);

        // 只有站内真有「帖子免费1天」按钮的站点才出现这一行
        if (s.SupportsAutoFree)
        {
            var free = new CheckBox
            {
                Content = "发种后免费一天",
                IsChecked = s.AutoFree,
                FontSize = 11,
                Margin = new Thickness(0, 6, 0, 0),
                ToolTip = "发种成功后自动点一次站内「帖子免费1天」（要扣站内积分）；"
                          + "已在免费满一天就不重复扣",
            };
            var state = s.AutoFree;
            free.Click += (_, _) =>
            {
                if (free.IsChecked != state)
                    _model.Call("sites.setAutoFree", new { id = s.Id, on = free.IsChecked == true });
            };
            body.Children.Add(free);
        }

        var card = new Border
        {
            BorderBrush = (Brush)FindResource(s.Enabled ? "Accent" : "Line"),
            BorderThickness = new Thickness(s.Enabled ? 1.5 : 1),
            Background = (Brush)FindResource("BlockSurface"),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(8),
            Margin = new Thickness(0, 0, 8, 8),
            Width = 208,
            AllowDrop = true,
            Child = body,
        };
        card.PreviewDrop += (_, e) =>
        {
            e.Handled = true;   // 卡里有输入框，不截下来会被输入框当成「拖入文本」
            var from = e.Data.GetData(DataFormats.Text) as string;
            if (from != null && from != s.Id)
                _model.Call("sites.moveBefore", new { id = from, before = s.Id });
        };
        card.DragOver += (_, e) =>
        {
            e.Effects = _dragging != null && _dragging != s.Id
                ? DragDropEffects.Move : DragDropEffects.None;
            e.Handled = true;
        };
        _cards[s.Id] = card;
        return card;
    }

    /// 序号 = 组内目标位置：填 N 的排到第 N 位，序号相同的按原顺序，没填的留在后面（同 mac 版）
    private void ApplySiteSort(int block)
    {
        var order = new Dictionary<string, int>();
        foreach (var kv in _nums)
            if (int.TryParse(kv.Value.Text.Trim(), out var n) && n > 0) order[kv.Key] = n;
        if (order.Count == 0) return;
        _model.Call("groups.sortSites", new { group = block, order });
    }

    // MARK: 动作

    /// 移除分组：与 mac 版一样要两次确认，第一次说清后果，第二次才真删
    private void RemoveGroup(GroupRow g)
    {
        var win = Window.GetWindow(this)!;
        var first = MessageBox.Show(win,
            $"移除分组「{g.Name}」？\n分组会删掉，组内 {g.SiteIds.Length} 个站点同时退出纳管"
            + "（回到「批量添加站点」列表，cookie 与限速设置都保留，随时可以再加回来）。",
            "移除分组", MessageBoxButton.OKCancel, MessageBoxImage.Question);
        if (first != MessageBoxResult.OK) return;
        var second = MessageBox.Show(win, $"再次确认：真的要移除分组「{g.Name}」吗？",
            "移除分组", MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (second == MessageBoxResult.OK) _model.Call("groups.remove", new { index = g.Index });
    }

    private void RemoveSites(GroupRow? group, List<SiteRow> sites)
    {
        if (sites.Count == 0) return;
        var win = Window.GetWindow(this)!;
        var where = group == null ? "未分组里的" : $"分组「{group.Name}」里已开启的";
        var first = MessageBox.Show(win,
            $"移除{where}的 {sites.Count} 个站点？\n站点会退回「批量添加站点」列表，cookie 与设置保留，之后可以再加回来。",
            "移除站点", MessageBoxButton.OKCancel, MessageBoxImage.Question);
        if (first != MessageBoxResult.OK) return;
        var second = MessageBox.Show(win, $"再次确认：移除这 {sites.Count} 个站点？",
            "移除站点", MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (second == MessageBoxResult.OK)
            _model.Call("sites.remove", new { ids = sites.Select(s => s.Id).ToArray() });
    }

    private static Button SmallButton(string text, Action onClick, bool enabled = true,
                                      bool danger = false)
    {
        var b = new Button
        {
            Content = text,
            Margin = new Thickness(6, 0, 0, 0),
            Padding = new Thickness(8, 2, 8, 2),
            IsEnabled = enabled,
        };
        if (danger) b.Style = (Style)System.Windows.Application.Current.Resources["Danger"];
        b.Click += (_, _) => onClick();
        return b;
    }

    private static Button TinyButton(string text, Action onClick, bool enabled = true,
                                     bool danger = false)
    {
        var b = SmallButton(text, onClick, enabled, danger);
        b.FontSize = 12;
        b.Margin = new Thickness(6, 0, 0, 0);
        b.Padding = new Thickness(7, 1, 7, 1);
        return b;
    }

    private void Rename(GroupRow g)
    {
        var name = Dialogs.PromptWindow.Ask(Window.GetWindow(this)!, "重命名分组", g.Name);
        if (!string.IsNullOrWhiteSpace(name))
            _model.Call("groups.rename", new { index = g.Index, name });
    }

    private void OnAddGroup(object sender, RoutedEventArgs e)
    {
        var name = NewGroupName.Text.Trim();
        if (name.Length == 0) return;
        var mb = int.TryParse(NewGroupMB.Text.Trim(), out var v) ? v : 10;
        _model.Call("groups.add", new { name, upLimitMB = mb });
        NewGroupName.Text = "";
    }

    private void AddSitesTo(int groupIndex)
    {
        new Dialogs.AddSitesWindow(_model, groupIndex) { Owner = Window.GetWindow(this) }.ShowDialog();
    }

    private void OnSyncCookies(object sender, RoutedEventArgs e) =>
        _model.Call("cookies.sync", new { source = "both" });

    private void OnCheckAll(object sender, RoutedEventArgs e) =>
        _model.Call("cookies.check", new { ids = Array.Empty<string>(), force = true });

    private void OnStopCheck(object sender, RoutedEventArgs e) => _model.Call("cookies.stopCheck");
}
