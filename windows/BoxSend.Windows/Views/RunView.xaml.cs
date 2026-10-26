using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace BoxSend.Windows.Views;

/// <summary>批量转种页：源站链接、可选项、按分组的站点卡片（点卡片选为转种目标）。
/// 卡片上直接给出上传限速与转种 / 推送的实时状态，不再另开「转种结果」「下载器推送」两块；
/// 整批汇总收在可展开的「运行记录」里。布局与 mac 版一一对应。</summary>
public partial class RunView : UserControl
{
    private readonly AppModel _model;
    private HashSet<string> _targets = new();
    private bool _seeded;

    /// <summary>卡片上会随运行状态变的几处（结构只在整份刷新时重建，平时只改文字与底色）</summary>
    private sealed class CardRefs
    {
        public required TextBlock Name { get; init; }
        public required Border Reseed { get; init; }
        public required TextBlock ReseedText { get; init; }
        public required Border Push { get; init; }
        public required TextBlock PushText { get; init; }
        public required Button Seed { get; init; }
        public required TextBlock Detail { get; init; }
    }

    private readonly Dictionary<string, CardRefs> _cards = new();

    /// 源站下拉里的第一项：不点名，按链接域名自动识别。文字会跟着链接变
    /// （识别出是哪一站就写成「源站：自动（某站）」），所以每次都要现造一个
    private const string AutoId = "";
    private string _autoLabel = "源站：自动识别";
    private string _lastProbeUrl = "";
    /// 下拉里点名的源站（AutoId = 不点名，按链接域名自动识别）。
    /// 记在字段里而不是问 ComboBox：换项时 Items 会整体重置，选中项会被清空
    private string _pickedSourceId = AutoId;

    private SiteRow AutoSource => new() { Id = AutoId, Name = _autoLabel };

    public RunView(AppModel model)
    {
        _model = model;
        InitializeComponent();
        _model.FullRefreshed += (_, _) => Dispatcher.Invoke(Rebuild);
        _model.Refreshed += (_, _) => Dispatcher.Invoke(UpdateRunStatus);
        DetailUrl.TextChanged += (_, _) => RefreshSourceLabel();
        SourceSitePick.SelectionChanged += (_, _) =>
        {
            if (SourceSitePick.SelectedItem is SiteRow r) _pickedSourceId = r.Id;
        };
        LoadQuote();
        Rebuild();
        // 日志页合并进「运行记录」：这一页直接跟着核心日志走
        LogLines.ItemsSource = _model.Logs;
    }

    // MARK: 重建（刷新时要保住用户勾选）

    private void Rebuild()
    {
        LoadQuote();
        ProbeSourceLabel();
        LoadSpeedButton();
        RebuildSourcePick();

        if (!_seeded)
        {
            // 默认只勾配置里存着的转种目标（与 mac 版同一份 targetSites）：第一次用就是全不选。
            // 以前是「把所有已开启的站点都勾上」，连没纳管的源站也算进去，数字比卡片多一个
            _targets = SavedTargets();
            _seeded = true;
        }

        RebuildTargetBlocks();
        UpdateRunStatus();
    }

    // MARK: 源站（下拉点名 + 按域名自动识别）

    /// 链接一改就去核心库问一次「这条链接像哪个站」，把识别结果写进下拉第一项的文案
    /// （不动用户点名的那一项）。整组重建：只换 Items[0] 会让 ComboBox 丢掉选中项，
    /// 结果就是链接已经识别出站点、框里却还是「自动识别」
    private void RefreshSourceLabel()
    {
        ProbeSourceLabel();
        RebuildSourcePick();
    }

    /// 重建源站下拉：第一项永远是「源站：自动（某站）」，其余是已添加的站点
    private void RebuildSourcePick()
    {
        if (_pickedSourceId != AutoId && _model.Sites.All(s => s.Id != _pickedSourceId))
            _pickedSourceId = AutoId;
        SourceSitePick.Items.Clear();
        SourceSitePick.Items.Add(AutoSource);
        foreach (var s in _model.Sites.Where(s => s.Managed)) SourceSitePick.Items.Add(s);
        SourceSitePick.SelectedItem =
            SourceSitePick.Items.Cast<SiteRow>().First(s => s.Id == _pickedSourceId);
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
        // 源站种子取到之后，下拉里要看得见这次用的到底是哪一站（与 mac 版同一显示）
        if (_autoLabel == "源站：自动识别" && DetailUrl.Text.Trim().StartsWith("http"))
            RefreshSourceLabel();
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

    // MARK: 分组卡片

    /// 每个分组一块：组名 + 整组全选 / 全不选 + 站点卡片（只列已开启的站点）
    private void RebuildTargetBlocks()
    {
        TargetBlocks.Children.Clear();
        _cards.Clear();
        foreach (var g in _model.Groups)
            TargetBlocks.Children.Add(GroupCard(g.Name, Members(g.Index)));
        var unassigned = _model.Sites.Where(s => s.Enabled && s.Managed && s.Group < 0).ToList();
        if (unassigned.Count > 0) TargetBlocks.Children.Add(GroupCard("未分组", unassigned));
        if (TargetBlocks.Children.Count == 0)
            TargetBlocks.Children.Add(new TextBlock
            {
                Text = "还没有开启的站点：到「站点分组」页添加并开启。",
                FontSize = 12,
                Foreground = (Brush)FindResource("TextMuted"),
            });
    }

    /// 组内已开启的站点，按 group.sites 的顺序（扁平站点列表是站点表顺序，不能拿来显示）
    private List<SiteRow> Members(int groupIndex)
    {
        var g = _model.Groups.FirstOrDefault(x => x.Index == groupIndex);
        var live = _model.Sites.Where(x => x.Enabled && x.Managed && x.Group == groupIndex)
            .ToDictionary(x => x.Id, x => x);
        var outList = new List<SiteRow>();
        if (g != null)
            foreach (var id in g.SiteIds)
                if (live.TryGetValue(id, out var row)) outList.Add(row);
        outList.AddRange(live.Values.Where(x => !outList.Contains(x)));
        return outList;
    }

    private UIElement GroupCard(string name, List<SiteRow> sites)
    {
        var panel = new StackPanel();
        var header = new WrapPanel();
        var allOn = sites.Count > 0 && sites.All(s => _targets.Contains(s.Id));
        var groupAll = new Button
        {
            Content = allOn ? "全不选" : "全选",
            FontSize = 12,
            Padding = new Thickness(9, 3, 9, 3),
            VerticalAlignment = VerticalAlignment.Center,
            ToolTip = allOn ? "取消该分组全部站点" : "选中该分组全部站点作为转种目标",
        };
        groupAll.Click += (_, _) =>
        {
            foreach (var s in sites)
            {
                if (allOn) _targets.Remove(s.Id);
                else _targets.Add(s.Id);
            }
            SaveTargets();
            RebuildTargetBlocks();
            UpdateRunStatus();
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

        var cards = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        foreach (var s in sites) cards.Children.Add(SiteCard(s));
        panel.Children.Add(cards);
        if (sites.Count == 0)
            panel.Children.Add(new TextBlock
            {
                Text = "该分组里没有已开启的站点。",
                FontSize = 12,
                Margin = new Thickness(0, 2, 0, 0),
                Foreground = (Brush)FindResource("TextMuted"),
            });

        return new Border
        {
            Background = (Brush)FindResource("BlockSurface"),
            BorderBrush = (Brush)FindResource("Line"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(12),
            Margin = new Thickness(0, 0, 0, 10),
            Child = panel,
        };
    }

    /// 站点卡片：名称 + 上传限速 + 转种 / 推送状态 + 一行说明。点一下选为目标，再点取消
    private UIElement SiteCard(SiteRow s)
    {
        var selected = _targets.Contains(s.Id);
        var name = new TextBlock
        {
            Text = s.Name,
            FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = (Brush)FindResource("TextPrimary"),
        };
        var (reseed, reseedText) = Chip();
        var (push, pushText) = Chip();
        // 说明行不设 MaxHeight：转种失败原因这类文案本来就长，限高会把后半句裁掉。
        // 但空着的时候也要占住三行的位置：卡片高度随进度变来变去，一排里就显歪，
        // 长文案出现时还会把旁边的卡片挤得像是被盖住（与 mac 版同一套占位）
        var detail = new TextBlock
        {
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 4, 0, 0),
            MinHeight = DetailLines * 14,
            Opacity = 0,
        };
        var body = new StackPanel();
        body.Children.Add(name);
        body.Children.Add(new TextBlock
        {
            Text = s.UpLimitMB > 0 ? $"上传限速 {s.UpLimitMB} MB/s" : "上传限速 不限速",
            FontSize = 11,
            Foreground = (Brush)FindResource("TextMuted"),
        });
        body.Children.Add(reseed);
        body.Children.Add(push);
        // 站内那条种子的详情页：已推送 / 站内已有时给一个跳转，省得回站内搜
        var seed = new Button
        {
            Content = "种子页 ↗",
            FontSize = 11,
            Padding = new Thickness(8, 2, 8, 2),
            Margin = new Thickness(0, 4, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Left,
            // 卡片底本身就是 TextSurface / AccentFaint：按钮用主色薄底才分得出来
            Background = Tinted("Accent", 0.18),
            BorderBrush = (Brush)FindResource("Accent"),
            Foreground = (Brush)FindResource("Accent"),
            // 占位：运行中没链接也留着这一格；没在跑就整格收掉，别留大片空白
            Opacity = 0,
            IsEnabled = false,
            Visibility = _model.Running ? Visibility.Visible : Visibility.Collapsed,
        };
        body.Children.Add(seed);
        body.Children.Add(detail);

        var card = new Border
        {
            // 卡片宽度收到 mac 那套 adaptive(104…150) 的量级：一屏多放一倍站点
            Width = 126,
            Padding = new Thickness(10, 8, 10, 8),
            Margin = new Thickness(0, 0, 8, 8),
            CornerRadius = new CornerRadius(8),
            Background = (Brush)FindResource(selected ? "AccentFaint" : "TextSurface"),
            BorderBrush = (Brush)FindResource("Line"),
            BorderThickness = new Thickness(1),
            Cursor = Cursors.Hand,
            Child = body,
            ToolTip = (selected ? "已选为转种目标，点击取消" : "点击选为转种目标") + "\n" + s.Url,
        };
        card.MouseLeftButtonUp += (_, _) => Toggle(s.Id);
        _cards[s.Id] = new CardRefs
        {
            Name = name, Reseed = reseed, ReseedText = reseedText,
            Push = push, PushText = pushText, Seed = seed, Detail = detail,
        };
        return card;
    }

    private void Toggle(string id)
    {
        if (!_targets.Remove(id)) _targets.Add(id);
        SaveTargets();
        RebuildTargetBlocks();
        UpdateRunStatus();
    }

    /// 配置里的转种目标（界面勾选的初始值）
    private HashSet<string> SavedTargets()
    {
        var ids = _model.Config?["targetSites"]?.AsArray() ?? new JsonArray();
        return ids.Select(n => n?.GetValue<string>() ?? "")
            .Where(id => _model.Sites.Any(s => s.Id == id && s.Enabled && s.Managed))
            .ToHashSet();
    }

    /// 勾选写回 core（targetSites）：下次打开还是这批，与 mac 版一致
    private void SaveTargets() =>
        _model.Call("targets.set", new { ids = RunTargets().Select(x => x.Id).ToArray() });

    /// 说明行占几行：三行放不下的是少数，完整文案在悬浮提示与运行记录里
    private const int DetailLines = 3;

    /// 胶囊那一格的高度：两行文案 + 上下内边距。空着时也占住，卡片才不会中途长高
    private const int ChipLinesHeight = 32;

    /// 状态胶囊：先建好放着，运行时才填字（重建整张卡片代价大，改文字便宜）。
    /// 没有事件时不折叠而是铺隐形文字占位——折叠会让卡片中途变高，一排卡片上下错位。
    private static (Border, TextBlock) Chip()
    {
        var text = new TextBlock
        {
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            Text = "\n",
        };
        var box = new Border
        {
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(6, 2, 6, 2),
            Margin = new Thickness(0, 4, 0, 0),
            MinHeight = ChipLinesHeight,
            Opacity = 0,
            Child = text,
        };
        return (box, text);
    }

    // MARK: 运行状态

    /// 每轮快照都要跑一遍：卡片上的胶囊、批次概览、按钮与运行记录
    private void UpdateRunStatus()
    {
        foreach (var (id, refs) in _cards) PaintCard(id, refs);
        ShowSourceChip();
        UpdateSummary();
        BtnRun.IsEnabled = !_model.Running;
        BtnRun.Content = _model.Running ? "运行中…" : "开始运行";
        RunStep.Text = _model.Running ? _model.RunningStep : "";
        HistoryText.Text = _model.LastReport.Length == 0 ? "（还没有运行记录）" : _model.LastReport;
    }

    private void PaintCard(string id, CardRefs r)
    {
        var reseed = _model.ReseedEvent(id);
        var push = _model.PushEvent(id);
        SetChip(r.Reseed, r.ReseedText, reseed);
        SetChip(r.Push, r.PushText, push);
        // 占位只在运行中铺：整排卡片同时变高，一次排版就稳；空跑前不必撑那么高
        r.Reseed.MinHeight = _model.Running ? ChipLinesHeight : 0;
        r.Push.MinHeight = _model.Running ? ChipLinesHeight : 0;
        r.Detail.MinHeight = _model.Running ? DetailLines * 14 : 0;
        var warning = _model.Sites.FirstOrDefault(s => s.Id == id)?.Warning ?? "";
        var link = push?.Url ?? "";
        if (link.Length == 0) link = reseed?.Url ?? "";
        r.Seed.Opacity = link.Length == 0 ? 0 : 1;
        r.Seed.IsEnabled = link.Length > 0;
        if (link.Length == 0)
            r.Seed.Visibility = _model.Running ? Visibility.Visible : Visibility.Collapsed;
        if (link.Length > 0)
        {
            r.Seed.Visibility = Visibility.Visible;
            r.Seed.ToolTip = "在浏览器里打开站内那条种子\n" + link;
            r.Seed.Click -= OpenSeed;
            r.Seed.Tag = link;
            r.Seed.Click += OpenSeed;
        }
        var (text, key) = CardDetail(reseed, push, warning);
        r.Detail.Text = text;
        r.Detail.Foreground = (Brush)FindResource(key);
        r.Detail.ToolTip = text;
        r.Detail.Opacity = text.Length == 0 ? 0 : 1;
    }

    /// 卡片本身点击是「选为转种目标」，跳站内链接得单独一个按钮
    private static void OpenSeed(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string url } || url.Length == 0) return;
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url)
            { UseShellExecute = true });
        }
        catch
        {
            // 没设默认浏览器之类的环境问题：按钮点了没反应就够，不必弹错误框
        }
    }

    private void SetChip(Border box, TextBlock text, RunRow? e)
    {
        if (e == null || e.Text.Length == 0)
        {
            // 空胶囊：留着占位，只把内容擦干净（背景空、无提示）
            text.Text = "\n";
            text.Foreground = (Brush)Application.Current.Resources["TextMuted"];
            box.Background = null;
            box.ToolTip = null;
            box.Opacity = 0;
            return;
        }
        box.Opacity = 1;
        var (icon, key) = Phase(e.Phase);
        text.Text = icon + " " + e.Text;
        text.Foreground = (Brush)FindResource(key);
        box.Background = Tinted(key, 0.16);
        box.ToolTip = string.IsNullOrEmpty(e.Detail) ? e.Text : e.Detail;
        box.Visibility = Visibility.Visible;
    }

    private static (string Icon, string Brush) Phase(string phase) => phase switch
    {
        "done" => ("✓", "Success"),
        "exists" => ("↓", "Accent"),
        "failed" => ("✕", "Warning"),
        _ => ("…", "TextMuted"),
    };

    /// 卡片下那行说明：失败原因 > 该站提醒 > 「已存在」的详情（与 mac 版同一优先级）
    private static (string Text, string Brush) CardDetail(RunRow? reseed, RunRow? push, string warning)
    {
        foreach (var e in new[] { reseed, push })
            if (e?.Phase == "failed" && e.Detail.Length > 0) return (Short(e.Detail), "Warning");
        if (warning.Length > 0) return (warning, "Warning");
        // 「站内已有」不再单独铺一行：卡片上那个「种子页」按钮带的就是那条种子，详情留在胶囊提示里
        return ("", "TextMuted");
    }

    /// 卡片窄：调试页路径那类长尾巴收进鼠标提示
    private static string Short(string s)
    {
        var i = s.IndexOf("（页面已存", StringComparison.Ordinal);
        if (i > 0) s = s[..i];
        // 「已存在」的详情是三行（说明 / 站内那条的标题 / 链接）：卡片窄，收成一行，全文在鼠标提示里
        s = string.Join(" · ", s.Split('\n').Select(x => x.Trim()).Where(x => x.Length > 0));
        return s.Length > 80 ? s[..80] + "…" : s;
    }

    /// 主题色加层薄底（胶囊背景）：主题刷是共享的，不能直接改它的透明度
    private Brush Tinted(string key, double alpha)
    {
        var c = ((SolidColorBrush)FindResource(key)).Color;
        return new SolidColorBrush(Color.FromArgb((byte)(alpha * 255), c.R, c.G, c.B));
    }

    // MARK: 批次概览

    /// 本批实际会转的站点：纳管 + 已开启 + 已勾选（与「开始运行」取目标的口径一致）
    private List<SiteRow> RunTargets() =>
        _model.Sites.Where(s => s.Enabled && s.Managed && _targets.Contains(s.Id)).ToList();

    private List<string> SelectedGroupNames()
    {
        var picked = RunTargets().Select(s => s.Id).ToHashSet();
        var names = new List<string>();
        foreach (var g in _model.Groups)
            if (_model.Sites.Any(s => s.Enabled && s.Managed && s.Group == g.Index && picked.Contains(s.Id)))
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

    // MARK: 几个开关

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

    /// 测速按钮只管手动测一次，不是「开始运行」的前置条件。
    /// 服务器没填全时测不成，直接禁掉并说明去哪儿填
    private void LoadSpeedButton()
    {
        var configured = _model.SectionText("ssh", "host").Trim().Length > 0
                         && _model.SectionText("ssh", "user").Trim().Length > 0;
        BtnSpeed.IsEnabled = configured && !_model.BusySSH;
        BtnSpeed.ToolTip = configured
            ? "到服务器上量一次公网上行，实测速度显示在下一行；不测也能直接开转"
            : "先到「下载器」页的「转种服务器」卡片填服务器地址与用户名，才能测速";
    }

    /// 点「测试上传速度」：核心库连服务器跑几十秒，结果写进按钮下面那一行（与 mac 版同一句文案）
    private async void OnSpeedTest(object sender, RoutedEventArgs e)
    {
        BtnSpeed.IsEnabled = false;
        SpeedResult.Visibility = Visibility.Visible;
        SpeedResult.Foreground = (Brush)FindResource("TextMuted");
        SpeedResult.Text = "正在测试服务器上传速度…";
        var r = await _model.TestSSHAsync();
        SpeedResult.Text = (r.Ok ? "成功: " : "失败: ") + r.Text;
        SpeedResult.Foreground = (Brush)FindResource(r.Ok ? "Success" : "Warning");
        LoadSpeedButton();
    }

    private void OnClearLogs(object sender, RoutedEventArgs e) => _model.Call("logs.clear");

    private void OnOpenDataDir(object sender, RoutedEventArgs e)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(
                "explorer.exe", $"\"{_model.DataDir}\"") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show(Window.GetWindow(this)!, ex.Message, "BoxSend");
        }
    }

    private void OnHistory(object sender, RoutedEventArgs e)
    {
        HistoryBox.Visibility = HistoryBox.Visibility == Visibility.Visible
            ? Visibility.Collapsed : Visibility.Visible;
        BtnHistory.Content = HistoryBox.Visibility == Visibility.Visible ? "收起运行记录" : "运行记录";
    }

    // MARK: 运行

    private void OnRun(object sender, RoutedEventArgs e)
    {
        var url = DetailUrl.Text.Trim();
        if (url.Length == 0)
        {
            MessageBox.Show(Window.GetWindow(this)!, "请先填写源站种子链接。", "BoxSend");
            return;
        }
        var targets = RunTargets().Select(s => s.Id).ToArray();
        if (targets.Length == 0)
        {
            MessageBox.Show(Window.GetWindow(this)!, "没有勾选目标站。", "BoxSend");
            return;
        }
        SaveQuote();
        Start(url, targets);
    }

    private void Start(string url, string[] targets)
    {
        _model.StartRun(url, targets,
                        skipReseed: DoReseed.IsChecked != true,
                        skipPush: DoPush.IsChecked != true,
                        sourceQuote: UseQuote.IsChecked == true ? QuoteText.Text : "",
                        sourceSiteId: _pickedSourceId == AutoId ? null : _pickedSourceId);
        UpdateSummary();
    }
}
