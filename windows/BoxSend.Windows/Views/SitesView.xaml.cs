using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace BoxSend.Windows.Views;

/// <summary>站点分组页：分组卡片 + 组内站点卡片（cookie 状态、限速、免费一天、上下移、移除）。
/// 规则与 mac 版一致：移除分组 / 移除站点都要两次确认；没归组的站点才显示「未分组」这一块。</summary>
public partial class SitesView : UserControl
{
    private readonly AppModel _model;

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
        Hint.Text = $"共 {_model.Sites.Count(s => s.Managed)} 个已纳管站点，{_model.CookieTotal} 条 cookie";
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

        // ---- 标题行：分组名 + 重命名 / 添加站点 / 排序 / 移除 + 组默认限速 ----
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
                Width = 46,
                Text = group.UpLimitMB.ToString(),
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
            header.Children.Add(SmallButton("重命名", () => Rename(group)));
            header.Children.Add(SmallButton("上移", () => MoveGroup(group, -1), group.Index > 0));
            header.Children.Add(SmallButton("下移", () => MoveGroup(group, 1),
                group.Index < _model.Groups.Count - 1));
            header.Children.Add(SmallButton("移除分组", () => RemoveGroup(group), danger: true));
        }
        header.Children.Add(SmallButton("添加站点", () => AddSitesTo(group?.Index ?? -1)));
        panel.Children.Add(header);

        // ---- 工具行：N 站 / 全选 / 手动 cookie / 移除站点 / 检测本组 ----
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
        toolbar.Children.Add(TinyButton("检测本组",
            () => _model.Call("cookies.check",
                new { ids = sites.Select(s => s.Id).ToArray(), force = true }), sites.Count > 0));
        if (group == null)
            toolbar.Children.Add(TinyButton("全部移出纳管", () => RemoveSites(null, sites),
                sites.Count > 0, danger: true));
        panel.Children.Add(toolbar);

        var cards = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        foreach (var s in sites) cards.Children.Add(CardFor(s));
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
    /// 免得卡片窄时被压成竖排）；点名称区开启或停用该站。</summary>
    private UIElement CardFor(SiteRow s)
    {
        var head = new DockPanel { Cursor = System.Windows.Input.Cursors.Hand, Background = Brushes.Transparent };
        var title = new StackPanel();
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
        DockPanel.SetDock(title, Dock.Left);
        head.Children.Add(title);
        head.MouseLeftButtonUp += (_, _) =>
            _model.Call("sites.setEnabled", new { ids = new[] { s.Id }, enabled = !s.Enabled });
        head.ToolTip = s.Enabled ? "已开启，点击停用" : "未开启，点击开启";

        var body = new StackPanel();
        body.Children.Add(head);
        body.Children.Add(new TextBlock
        {
            Text = $"{(s.UsesApiKey ? (s.HasApiKey ? "已填 Key" : "缺 Key") : s.CookieCount + " 条 cookie")} · {s.CheckText}",
            FontSize = 11,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = (Brush)FindResource(s.CheckOk == true ? "Accent" : "TextMuted"),
        });
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
            Width = 40,
            Text = s.UpLimitMB.ToString(),
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
        row.Children.Add(TinyButton("↑", () => _model.Call("sites.move", new { id = s.Id, delta = -1 }),
            s.CanMoveUp));
        row.Children.Add(TinyButton("↓", () => _model.Call("sites.move", new { id = s.Id, delta = 1 }),
            s.CanMoveDown));
        row.Children.Add(TinyButton("移组", () => MoveToGroup(s)));
        row.Children.Add(TinyButton("移除", () => _model.Call("sites.remove", new { ids = new[] { s.Id } }),
            danger: true));
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

        return new Border
        {
            BorderBrush = (Brush)FindResource(s.Enabled ? "Accent" : "Line"),
            BorderThickness = new Thickness(s.Enabled ? 1.5 : 1),
            Background = (Brush)FindResource("BlockSurface"),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(8),
            Margin = new Thickness(0, 0, 8, 8),
            Width = 208,
            Child = body,
        };
    }

    // MARK: 动作

    /// 分组上下移：核心库按「把 dragged 放到 before 之前」挪，往下挪就是让后一个分组挪到自己前面
    private void MoveGroup(GroupRow g, int delta)
    {
        if (delta < 0)
        {
            var prev = _model.Groups.FirstOrDefault(x => x.Index == g.Index - 1);
            if (prev != null) _model.Call("groups.move", new { dragged = g.Name, before = prev.Name });
            return;
        }
        var next = _model.Groups.FirstOrDefault(x => x.Index == g.Index + 1);
        if (next != null) _model.Call("groups.move", new { dragged = next.Name, before = g.Name });
    }

    private void MoveToGroup(SiteRow s)
    {
        var menu = new ContextMenu();
        foreach (var g in _model.Groups)
        {
            var item = new MenuItem { Header = g.Name };
            var gi = g.Index;
            item.Click += (_, _) => _model.Call("sites.setGroup", new { id = s.Id, index = gi });
            menu.Items.Add(item);
        }
        if (_model.Groups.Count > 0) menu.Items.Add(new Separator());
        var outItem = new MenuItem { Header = "移出分组（未分组）" };
        outItem.Click += (_, _) => _model.Call("sites.setGroup", new { id = s.Id, index = -1 });
        menu.Items.Add(outItem);
        menu.PlacementTarget = this;
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint;
        menu.IsOpen = true;
    }

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

    private void OnAddSites(object sender, RoutedEventArgs e) => AddSitesTo(-1);

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
