using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace BoxSend.Windows.Views;

/// <summary>批量转种页：源站链接、可选项、按分组的勾选目标站、逐站转种与推送结果。
/// 目标站按分组成块（与 mac 版一致），「开始运行」旁给出本批概览，避免勾错分组就跑。</summary>
public partial class RunView : UserControl
{
    private readonly AppModel _model;
    private HashSet<string> _targets = new();
    private bool _seeded;
    /// 页面上现有的站点勾选框（重建时一起换掉；读勾选状态直接问它们，不爬视觉树）
    private readonly List<CheckBox> _boxes = new();

    /// 源站下拉里的第一项：不点名，按链接域名自动识别。文字会跟着链接变
    /// （识别出是哪一站就写成「源站：自动（某站）」），所以每次都要现造一个
    private const string AutoId = "";
    private string _autoLabel = "源站：自动识别";
    private string _lastProbeUrl = "";

    private SiteRow AutoSource => new() { Id = AutoId, Name = _autoLabel };

    public RunView(AppModel model)
    {
        _model = model;
        InitializeComponent();
        SiteEvents.ItemsSource = model.RunSites;
        PushEvents.ItemsSource = model.RunPushes;
        _model.FullRefreshed += (_, _) => Dispatcher.Invoke(Rebuild);
        DetailUrl.TextChanged += (_, _) => RefreshSourceLabel();
        LoadQuote();
        Rebuild();
    }

    // MARK: 重建（刷新时要保住用户勾选）

    private void Rebuild()
    {
        if (_boxes.Count > 0) _targets = CheckedTargets();
        var pickedSource = (SourceSitePick.SelectedItem as SiteRow)?.Id;

        LoadQuote();
        ProbeSourceLabel();

        SourceSitePick.Items.Clear();
        SourceSitePick.Items.Add(AutoSource);
        foreach (var s in _model.Sites.Where(s => s.Managed)) SourceSitePick.Items.Add(s);
        SourceSitePick.SelectedItem =
            SourceSitePick.Items.Cast<SiteRow>().FirstOrDefault(s => s.Id == pickedSource) ?? AutoSource;
        ShowSourceChip();

        if (!_seeded)
        {
            // 第一次进页面：默认勾上已开启的站点（与 mac 版一致）
            _targets = _model.Sites.Where(s => s.Enabled).Select(s => s.Id).ToHashSet();
            _seeded = true;
        }

        RebuildTargetBlocks();
        UpdateSummary();
        BtnRun.IsEnabled = !_model.Running;
        BtnRun.Content = _model.Running ? "运行中…" : "开始运行";
        RunStep.Text = _model.Running ? _model.RunningStep : "";
    }

    // MARK: 源站（下拉点名 + 按域名自动识别）

    /// 链接一改就去核心库问一次「这条链接像哪个站」，只换下拉第一项的文字，
    /// 不动用户已经点名的那个选择
    private void RefreshSourceLabel()
    {
        ProbeSourceLabel();
        if (SourceSitePick.Items.Count == 0) return;
        SourceSitePick.Items[0] = AutoSource;
        if (SourceSitePick.SelectedItem is SiteRow cur && cur.Id == AutoId)
            SourceSitePick.SelectedItem = AutoSource;
    }

    private void ProbeSourceLabel()
    {
        var url = DetailUrl.Text.Trim();
        if (url == _lastProbeUrl) return;
        _lastProbeUrl = url;
        var name = "";
        if (url.StartsWith("http"))
        {
            var hit = _model.Api.TryInvoke("sites.matchURL", out _, new { url })?["name"];
            name = hit is JsonValue v && v.TryGetValue<string>(out var n) ? n : "";
        }
        _autoLabel = name.Length > 0 ? $"源站：自动（{name}）" : "源站：自动识别";
    }

    /// 源站种子的获取状态（「源站种子获取中… / 已获取 / 获取失败」），与 mac 版那颗胶囊对应
    private void ShowSourceChip()
    {
        var e = _model.SourcePush;
        if (e == null || e.Text.Length == 0)
        {
            SourceChip.Visibility = Visibility.Collapsed;
            return;
        }
        SourceChipText.Text = e.Text;
        SourceChipText.Foreground = (Brush)FindResource(e.Phase switch
        {
            "done" => "Success",
            "failed" => "Warning",
            _ => "TextMuted",
        });
        SourceChip.ToolTip = string.IsNullOrEmpty(e.Detail) ? e.Text : e.Detail;
        SourceChip.Visibility = Visibility.Visible;
    }

    /// 每个分组一块：组名 + 整组全选 + 组内站点勾选框（只列已开启的站点）
    private void RebuildTargetBlocks()
    {
        TargetBlocks.Children.Clear();
        _boxes.Clear();
        foreach (var g in _model.Groups)
            TargetBlocks.Children.Add(GroupBlock(g.Name, Members(g.Index)));
        var unassigned = _model.Sites.Where(s => s.Enabled && s.Managed && s.Group < 0).ToList();
        if (unassigned.Count > 0) TargetBlocks.Children.Add(GroupBlock("未分组", unassigned));
        if (TargetBlocks.Children.Count == 0)
            TargetBlocks.Children.Add(new TextBlock
            {
                Text = "还没有开启的站点：到「站点分组」页添加并开启。",
                FontSize = 12,
                Foreground = (Brush)FindResource("TextMuted"),
            });
    }

    private List<SiteRow> Members(int groupIndex) =>
        _model.Sites.Where(s => s.Enabled && s.Managed && s.Group == groupIndex).ToList();

    private UIElement GroupBlock(string name, List<SiteRow> sites)
    {
        var panel = new StackPanel { Margin = new Thickness(0, 0, 0, 8) };
        var header = new WrapPanel();
        var allOn = sites.Count > 0 && sites.All(s => _targets.Contains(s.Id));   // 整组是否都已选中
        var groupAll = new CheckBox
        {
            Content = allOn ? "全不选" : "全选",
            IsChecked = allOn,
            FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center,
            ToolTip = allOn ? "取消该分组全部站点" : "选中该分组全部站点作为转种目标",
        };
        groupAll.Click += (_, _) =>
        {
            foreach (var s in sites)
            {
                if (groupAll.IsChecked == true) _targets.Add(s.Id);
                else _targets.Remove(s.Id);
            }
            _targets = CheckedTargets();
            RebuildTargetBlocks();
            UpdateSummary();
        };
        header.Children.Add(groupAll);
        header.Children.Add(new TextBlock
        {
            Text = name,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(10, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
        });
        header.Children.Add(new TextBlock
        {
            Text = $"{sites.Count} 站",
            FontSize = 12,
            Margin = new Thickness(8, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = (Brush)FindResource("TextMuted"),
        });
        panel.Children.Add(header);

        var cards = new WrapPanel { Margin = new Thickness(0, 4, 0, 0) };
        foreach (var s in sites)
        {
            var box = new CheckBox
            {
                Content = s.Name,
                Tag = s.Id,
                IsChecked = _targets.Contains(s.Id),
                Margin = new Thickness(0, 2, 14, 2),
                ToolTip = $"{s.Url}\n上传限速 {s.UpLimitMB} MB/s",
            };
            box.Click += (_, _) =>
            {
                if (box.IsChecked == true) _targets.Add(s.Id);
                else _targets.Remove(s.Id);
                UpdateSummary();
            };
            cards.Children.Add(box);
            _boxes.Add(box);
        }
        panel.Children.Add(cards);

        return new Border
        {
            BorderBrush = (Brush)FindResource("Line"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(8),
            Child = panel,
        };
    }

    private HashSet<string> CheckedTargets()
    {
        var set = new HashSet<string>();
        foreach (var box in _boxes)
            if (box.IsChecked == true && box.Tag is string id) set.Add(id);
        return set;
    }

    // MARK: 批次概览

    /// 本批实际会转的站点：勾了且已开启（与「开始运行」取目标的口径一致）
    private List<SiteRow> RunTargets() =>
        _model.Sites.Where(s => s.Enabled && _targets.Contains(s.Id)).ToList();

    private List<string> SelectedGroupNames()
    {
        var picked = RunTargets().Select(s => s.Id).ToHashSet();
        var names = new List<string>();
        foreach (var g in _model.Groups)
            if (_model.Sites.Any(s => s.Enabled && s.Group == g.Index && picked.Contains(s.Id)))
                names.Add(g.Name);
        if (_model.Sites.Any(s => s.Enabled && s.Managed && s.Group < 0 && picked.Contains(s.Id)))
            names.Add("未分组");
        return names;
    }

    private void UpdateSummary()
    {
        var sites = RunTargets();
        var groups = SelectedGroupNames();
        BatchSummary.Text = sites.Count == 0
            ? "未选择站点"
            : groups.Count > 0 ? $"已选 {groups.Count} 个分组 · {sites.Count} 个站点"
                               : $"已选 {sites.Count} 个站点";
        BatchSummary.Foreground = (Brush)FindResource(sites.Count == 0 ? "Warning" : "TextMuted");
        BatchSummary.ToolTip = "勾选的转种分组：" + (groups.Count > 0 ? string.Join("、", groups) : "无")
            + "\n勾选的站点：" + string.Join("、", sites.Select(s => s.Name));
        UpdateQuoteHint(sites);
    }

    /// cmct、劳改所的「附加信息」只用源站引用：两处都没有内容时该区块留空，可能被站方打回
    private void UpdateQuoteHint(List<SiteRow> sites)
    {
        var filled = UseQuote.IsChecked == true && QuoteText.Text.Trim().Length > 0;
        var names = filled
            ? sites.Where(s => s.NeedsSourceQuote).Select(s => s.Name).ToList()
            : new List<string>();
        if (names.Count == 0)
        {
            QuoteHint.Visibility = Visibility.Collapsed;
            return;
        }
        QuoteHint.Text = string.Join("、", names)
            + " 的「附加信息」= 源站引用 + 源简介自带引用块：两处都没有内容时该区块留空，可能被站方打回。";
        QuoteHint.Visibility = Visibility.Visible;
    }

    private void OnQuoteToggled(object sender, RoutedEventArgs e) => SaveQuote();

    /// 源站引用是配置里的一对顶层字段（sourceQuoteEnabled / sourceQuoteText），
    /// 正在输入的时候不要被刷新打断
    private void LoadQuote()
    {
        var on = _model.Config?["sourceQuoteEnabled"] is JsonValue v && v.TryGetValue<bool>(out var b) && b;
        var text = _model.Config?["sourceQuoteText"] is JsonValue t && t.TryGetValue<string>(out var s2) ? s2 : "";
        if (!UseQuote.IsKeyboardFocusWithin) UseQuote.IsChecked = on;
        if (!QuoteText.IsKeyboardFocusWithin) QuoteText.Text = text;
    }

    private void SaveQuote() =>
        _model.Call("sourceQuote.set", new { enabled = UseQuote.IsChecked == true, text = QuoteText.Text });

    // MARK: 运行

    private async void OnRun(object sender, RoutedEventArgs e)
    {
        var url = DetailUrl.Text.Trim();
        if (url.Length == 0)
        {
            MessageBox.Show(Window.GetWindow(this)!, "请先填写源站种子链接。", "BoxSend");
            return;
        }
        _targets = CheckedTargets();
        var targets = RunTargets().Select(s => s.Id).ToArray();
        if (targets.Length == 0)
        {
            MessageBox.Show(Window.GetWindow(this)!, "没有勾选目标站。", "BoxSend");
            return;
        }
        SaveQuote();

        // 服务器可能被限速：先测一次，把速度报出来，由人决定这一批转不转
        if (!_model.SectionFlag("ssh", "enabled")
            || _model.SectionText("ssh", "host").Trim().Length == 0
            || _model.SectionText("ssh", "user").Trim().Length == 0
            || await SpeedGateAsync())
            Start(url, targets);
    }

    /// 返回 false = 用户看了测速结果后决定先不转
    private async Task<bool> SpeedGateAsync()
    {
        BtnRun.IsEnabled = false;
        RunStep.Text = "正在测试服务器上传速度…";
        var r = await _model.TestSSHAsync();
        RunStep.Text = "";
        BtnRun.IsEnabled = true;
        // 文案由核心给（一句测速信息），这里只决定按钮：继续转种 / 先不转种
        var win = Window.GetWindow(this)!;
        if (!r.Ok)
            return MessageBox.Show(win, r.Text, "服务器测速没做成",
                                   MessageBoxButton.OKCancel, MessageBoxImage.Warning)
                   == MessageBoxResult.OK;
        return MessageBox.Show(win, r.Text, $"服务器上传实测 {r.MBps:0.#} MB/s",
                               MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK;
    }

    private void Start(string url, string[] targets)
    {
        _model.StartRun(url, targets,
                        skipReseed: DoReseed.IsChecked != true,
                        skipPush: DoPush.IsChecked != true,
                        sourceQuote: UseQuote.IsChecked == true ? QuoteText.Text : "",
                        sourceSiteId: string.IsNullOrEmpty((SourceSitePick.SelectedItem as SiteRow)?.Id)
                            ? null : (SourceSitePick.SelectedItem as SiteRow)!.Id);
        UpdateSummary();
    }
}
