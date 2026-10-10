using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace BoxSend.Windows.Views;

/// <summary>站点分组页：分组卡片 + 组内站点卡片（cookie 状态、限速、上下移、移除）。</summary>
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
        if (unassigned.Count > 0) Blocks.Children.Add(BlockFor(null, unassigned));
        Hint.Text = $"共 {_model.Sites.Count(s => s.Managed)} 个已纳管站点，{_model.CookieTotal} 条 cookie";
    }

    private UIElement BlockFor(GroupRow? group, List<SiteRow>? overrideSites = null)
    {
        var sites = overrideSites ?? (_model.Sites.Where(s => s.Group == group!.Index).ToList());
        var panel = new StackPanel { Margin = new Thickness(0, 0, 0, 14) };

        var header = new WrapPanel();
        header.Children.Add(new TextBlock
        {
            Text = group?.Name ?? "未分组",
            FontWeight = FontWeights.SemiBold,
            FontSize = 14,
            Margin = new Thickness(0, 0, 10, 0),
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (group != null)
        {
            var limit = new TextBox { Width = 46, Text = group.UpLimitMB.ToString(), ToolTip = "组内新增站点的默认限速 MB/s" };
            header.Children.Add(new TextBlock { Text = "限速 MB/s", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 4, 0) });
            header.Children.Add(limit);
            var limitBox = limit;
            var saved = group.UpLimitMB;
            limitBox.LostFocus += (_, _) =>
            {
                if (int.TryParse(limitBox.Text, out var mb) && mb != saved)
                    _model.Call("groups.setLimit", new { index = group.Index, upLimitMB = mb });
            };
            header.Children.Add(SmallButton("重命名", () => Rename(group)));
            header.Children.Add(SmallButton("移除分组", () => _model.Call("groups.remove", new { index = group.Index })));
        }
        header.Children.Add(SmallButton("添加站点", () => AddSitesTo(group?.Index ?? -1)));
        header.Children.Add(SmallButton("检测本组", () => _model.Call("cookies.check",
            new { ids = sites.Select(s => s.Id).ToArray(), force = true })));
        panel.Children.Add(header);

        var cards = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
        foreach (var s in sites) cards.Children.Add(CardFor(s));
        panel.Children.Add(cards);

        var border = new Border
        {
            Background = (Brush)FindResource("TextSurface"),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10),
            Child = panel,
        };
        return border;
    }

    private UIElement CardFor(SiteRow s)
    {
        var body = new StackPanel();
        body.Children.Add(new TextBlock { Text = s.Name, FontWeight = FontWeights.SemiBold });
        body.Children.Add(new TextBlock
        {
            Text = s.CookieText,
            FontSize = 11,
            Foreground = (Brush)FindResource("TextMuted"),
        });
        var check = new TextBlock
        {
            Text = s.CheckText,
            FontSize = 11,
            Foreground = (Brush)FindResource(s.CheckOk == true ? "Accent" : "TextMuted"),
        };
        body.Children.Add(check);

        var row = new WrapPanel { Margin = new Thickness(0, 4, 0, 0) };
        var enabled = new CheckBox { Content = "启用", IsChecked = s.Enabled };
        var state = s.Enabled;
        enabled.Click += (_, _) =>
        {
            if (enabled.IsChecked != state)
                _model.Call("sites.setEnabled", new { ids = new[] { s.Id }, enabled = enabled.IsChecked == true });
        };
        row.Children.Add(enabled);

        var limit = new TextBox { Width = 40, Text = s.UpLimitMB.ToString(), Margin = new Thickness(8, 0, 0, 0), ToolTip = "上传限速 MB/s" };
        var savedLimit = s.UpLimitMB;
        limit.LostFocus += (_, _) =>
        {
            if (int.TryParse(limit.Text, out var mb) && mb != savedLimit)
                _model.Call("sites.setUpLimit", new { id = s.Id, upLimitMB = mb });
        };
        row.Children.Add(limit);

        row.Children.Add(SmallButton("↑", () => _model.Call("sites.move", new { id = s.Id, delta = -1 }), s.CanMoveUp));
        row.Children.Add(SmallButton("↓", () => _model.Call("sites.move", new { id = s.Id, delta = 1 }), s.CanMoveDown));
        row.Children.Add(SmallButton("移除", () => _model.Call("sites.remove", new { ids = new[] { s.Id } })));

        return new Border
        {
            BorderBrush = (Brush)FindResource("Line"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(8),
            Margin = new Thickness(0, 0, 8, 8),
            Width = 190,
            Child = body,
        };
    }

    private static Button SmallButton(string text, Action onClick, bool enabled = true)
    {
        var b = new Button
        {
            Content = text,
            Margin = new Thickness(6, 0, 0, 0),
            Padding = new Thickness(8, 2, 8, 2),
            IsEnabled = enabled,
        };
        b.Click += (_, _) => onClick();
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
        _model.Call("groups.add", new { name, upLimitMB = 0 });
        NewGroupName.Text = "";
    }

    private void OnAddSites(object sender, RoutedEventArgs e) => AddSitesTo(-1);

    private void AddSitesTo(int groupIndex)
    {
        new Dialogs.AddSitesWindow(_model, groupIndex) { Owner = Window.GetWindow(this) }.ShowDialog();
    }

    private void OnCheckAll(object sender, RoutedEventArgs e) =>
        _model.Call("cookies.check", new { ids = Array.Empty<string>(), force = true });
}
