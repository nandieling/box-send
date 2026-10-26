using System.IO;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Text.Json.Nodes;

namespace BoxSend.Windows.Views;

/// <summary>设置页：主题、背景图片与透明度、更新检查、路径信息。</summary>
public partial class SettingsView : UserControl
{
    private readonly AppModel _model;
    private bool _loading;

    public SettingsView(AppModel model)
    {
        _model = model;
        InitializeComponent();
        // Cookie 与下载器两页并进设置：区块本身还是原来那两个，只是不再各占一个页签
        CookieHost.Content = new CookiesView(model);
        DownloaderHost.Content = new DownloaderView(model);
        _model.FullRefreshed += (_, _) => Dispatcher.Invoke(Load);
        _model.Refreshed += (_, _) => Dispatcher.Invoke(LoadPaceHint);
        Load();
    }

    private void Load()
    {
        _loading = true;
        ThemeList.Items.Clear();
        foreach (var t in _model.Themes)
        {
            var picked = t.Id == _model.CurrentTheme.Id;
            // 渐变色块只作预览，名字写在色块下方的卡片底上：
            // 写在色块上时，「云端白」这类浅色主题在当前深色主题下就是白字配白底，看不清
            var preview = new Border
            {
                Height = 34,
                CornerRadius = new CornerRadius(4),
                Background = Gradient(t.Colors),
            };
            var caption = new TextBlock
            {
                Text = t.Name,
                Margin = new Thickness(3, 5, 3, 0),
                FontSize = 12,
                TextAlignment = TextAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = (Brush)FindResource(picked ? "TextPrimary" : "TextMuted"),
            };
            var body = new StackPanel();
            body.Children.Add(preview);
            body.Children.Add(caption);
            var swatch = new Border
            {
                Width = 150,
                Height = 82,
                Margin = new Thickness(0, 0, 10, 10),
                CornerRadius = new CornerRadius(6),
                BorderBrush = (Brush)FindResource(picked ? "Accent" : "Line"),
                BorderThickness = new Thickness(picked ? 2.5 : 1),
                Background = (Brush)FindResource("BlockSurface"),
                Padding = new Thickness(5),
                Child = body,
                ToolTip = $"切换到「{t.Name}」主题",
            };
            var id = t.Id;
            swatch.MouseLeftButtonUp += (_, _) =>
            {
                _model.Call("appearance.set", new { themeID = id });
                _model.PatchSection("appearance", s => s["themeID"] = id);
            };
            ThemeList.Items.Add(swatch);
        }

        var current = _model.Config?["appearance"]?["bgImage"];
        ImageState.Text = current is { } c && c.GetValue<string>().Length > 0
            ? $"当前背景：{c.GetValue<string>()}" : "未设置背景图片（跟随主题渐变）";
        BgOpacity.Value = _model.Config?["appearance"]?["bgOpacity"] is { } o ? o.GetValue<double>() : 0.45;
        UpdateState.Text = string.IsNullOrEmpty(_model.UpdateMessage)
            ? $"当前版本 {_model.CoreVersion}" : $"{_model.UpdateMessage}（当前 {_model.CoreVersion}）";
        BtnDownload.Content = $"下载 {_model.UpdateVersion} 安装包";
        BtnDownload.Visibility = _model.HasUpdate && !string.IsNullOrEmpty(_model.UpdateDownloadUrl)
            ? Visibility.Visible
            : Visibility.Collapsed;
        AutoUpdate.IsChecked = _model.Config?["autoUpdateCheck"] is not JsonValue v || v.GetValue<bool>();
        if (!TmdbBase.IsKeyboardFocusWithin)
            TmdbBase.Text = _model.SectionText("tmdb", "apiBase");
        if (!TmdbKey.IsKeyboardFocusWithin) TmdbKey.Text = _model.SectionText("tmdb", "apiKey");
        TmdbOn.IsChecked = _model.SectionFlag("tmdb", "enabled");
        About.Text = $"BoxSend {_model.CoreVersion} · 核心库 {_model.CoreVersion} · 平台 {_model.Platform}";
        ConfigPath.Text = $"配置：{_model.ConfigPath}\n数据：{_model.DataDir}";
        LoadPace();
        BuildSiteFilters();
        _loading = false;
    }

    // MARK: 辅种逐站筛选
    //
    // 站点名单铺满时首轮要检索几十天，能砍分母的就靠这份规则：一个站只辅哪几类、
    // 多大体积。规则存在 assist.siteFilters 里，核心库在建计划时就把不辅的格子挑出去。

    /// 展开/收起、切「只显示设过规则」都要重排；输入中的框由指纹挡着，不会被打掉
    private void OnFiltersOpen(object sender, RoutedEventArgs e) => BuildSiteFilters();

    private void BuildSiteFilters()
    {
        var ids = AssistSiteIDs();
        var filters = AssistFilters();
        FilterSummary.Text = $"共 {ids.Count} 个辅种站，其中 {filters.Count} 个设了规则";
        var want = ids.Where(id => OnlySetFilters.IsChecked != true || filters.ContainsKey(id)).ToList();
        var print = string.Join("|", want.Select(id => id + "#" +
            (filters.TryGetValue(id, out var f) ? f.Key : "")));
        if (print == _filterPrint) return;
        _filterPrint = print;
        SiteFilters.Children.Clear();
        foreach (var id in want) SiteFilters.Children.Add(FilterRow(id, filters.TryGetValue(id, out var f) ? f : null));
    }

    private string _filterPrint = "";

    /// 辅种站点名单（顺序照配置，界面上不重排）
    private List<string> AssistSiteIDs() =>
        (_model.Config?["assist"]?["siteIDs"] as JsonArray)?.Select(n =>
            n is JsonValue v && v.TryGetValue<string>(out var s) ? s : "")
            .Where(id => id.Length > 0 && _model.Sites.Any(x => x.Id == id)).ToList()
        ?? new List<string>();

    /// siteFilters → 界面用的四条文本（关键词回显时用逗号连，与输入格式一致）
    private Dictionary<string, FilterDraft> AssistFilters()
    {
        var outMap = new Dictionary<string, FilterDraft>();
        if (_model.Config?["assist"]?["siteFilters"] is not JsonObject map) return outMap;
        foreach (var kv in map)
        {
            if (kv.Value is not JsonObject o) continue;
            var inc = Words(o["include"]);
            var exc = Words(o["exclude"]);
            var lo = Dbl(o["minSizeGB"]);
            var hi = Dbl(o["maxSizeGB"]);
            if (inc.Count == 0 && exc.Count == 0 && lo <= 0 && hi <= 0) continue;
            outMap[kv.Key] = new FilterDraft(string.Join("，", inc), string.Join("，", exc),
                lo > 0 ? ((int)lo).ToString() : "", hi > 0 ? ((int)hi).ToString() : "");
        }
        return outMap;
    }

    private static List<string> Words(JsonNode? n) =>
        (n as JsonArray)?.Select(x => x is JsonValue v && v.TryGetValue<string>(out var s) ? s : "")
            .Where(x => x.Length > 0).ToList() ?? new List<string>();

    private static double Dbl(JsonNode? n)
    {
        if (n is not JsonValue v) return 0;
        if (v.TryGetValue<double>(out var d)) return d;
        return v.TryGetValue<int>(out var i) ? i : 0;
    }

    private UIElement FilterRow(string id, FilterDraft? d)
    {
        var name = _model.Sites.FirstOrDefault(x => x.Id == id)?.Name ?? id;
        var inc = Box(d?.Inc ?? "", 180, "不限");
        var exc = Box(d?.Exc ?? "", 180, "不排除");
        var min = Box(d?.Min ?? "", 52, "0");
        var max = Box(d?.Max ?? "", 52, "0");
        void Commit() => CommitFilter(id, inc, exc, min, max);
        foreach (var t in new[] { inc, exc, min, max })
        {
            t.LostFocus += (_, _) => Commit();
            t.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter) Commit(); };
        }
        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
        var clear = new Button
        {
            Content = "清除", FontSize = 11, Padding = new Thickness(7, 0, 7, 0),
            Margin = new Thickness(6, 0, 0, 0), Visibility = d == null ? Visibility.Collapsed : Visibility.Visible,
        };
        clear.Click += (_, _) =>
        {
            inc.Text = exc.Text = min.Text = max.Text = "";
            CommitFilter(id, inc, exc, min, max);
        };
        DockPanel.SetDock(clear, Dock.Right);
        var sizes = new StackPanel { Orientation = Orientation.Horizontal };
        sizes.Children.Add(min);
        sizes.Children.Add(new TextBlock { Text = " / ", FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
        sizes.Children.Add(max);
        DockPanel.SetDock(sizes, Dock.Right);
        var excBox = new Border { Width = 188, Margin = new Thickness(8, 0, 0, 0), Child = exc };
        var incBox = new Border { Width = 188, Margin = new Thickness(8, 0, 0, 0), Child = inc };
        row.Children.Add(clear);
        row.Children.Add(sizes);
        row.Children.Add(excBox);
        row.Children.Add(incBox);
        row.Children.Add(new TextBlock
        {
            Text = name, Width = 96, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        });
        return row;
    }

    private static TextBox Box(string text, double width, string hint) => new()
    {
        Text = text,
        Width = width,
        FontSize = 12,
        ToolTip = hint,
    };

    /// 写回 assist.siteFilters：四条全空 = 这个站不设限（整条摘掉，别留空壳）
    private void CommitFilter(string id, TextBox inc, TextBox exc, TextBox min, TextBox max)
    {
        var incList = Words(inc.Text);
        var excList = Words(exc.Text);
        var lo = Parse(min.Text);
        var hi = Parse(max.Text);
        _model.PatchSection("assist", o =>
        {
            var map = o["siteFilters"] as JsonObject ?? new JsonObject();
            if (incList.Count == 0 && excList.Count == 0 && lo <= 0 && hi <= 0) map.Remove(id);
            else map[id] = new JsonObject
            {
                ["include"] = Arr(incList), ["exclude"] = Arr(excList),
                ["minSizeGB"] = lo, ["maxSizeGB"] = hi,
            };
            o["siteFilters"] = map;
        });
    }

    private static JsonArray Arr(List<string> items)
    {
        var a = new JsonArray();
        foreach (var i in items) a.Add(JsonValue.Create(i));
        return a;
    }

    /// 界面上填的关键词按逗号（中英文都算）切；数字留空当 0
    private static List<string> Words(string s) =>
        s.Split(new[] { ',', '，', '、' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.Trim()).Where(x => x.Length > 0).ToList();

    private static double Parse(string s) => double.TryParse(s, out var d) ? Math.Max(0, d) : 0;

    private sealed record FilterDraft(string Inc, string Exc, string Min, string Max)
    {
        /// 指纹：内容一致就不重画那一行，免得正在输入的框被刷新打掉
        public string Key => Inc + "|" + Exc + "|" + Min + "|" + Max;
    }

    // MARK: 辅种搜索节奏（站点在「站点分组」页的辅种区块里加）

    private void LoadPace()
    {
        Interval.Text = PaceNum("perSiteIntervalSec", 8).ToString("0.#");
        Jitter.Text = PaceNum("jitterSec", 3).ToString("0.#");
        Budget.Text = ((int)PaceNum("roundBudget", 200)).ToString();
        MissTTL.Text = ((int)PaceNum("missTTLDays", 7)).ToString();
        AutoRun.Text = ((int)PaceNum("autoRunMinutes", 0)).ToString();
        ListPageSize.Text = ((int)PaceNum("listPageSize", 10)).ToString();
        AutoAccept.IsChecked = _model.SectionFlag("assist", "autoAcceptSameFiles", true);
        RemoveOnFail.IsChecked = _model.SectionFlag("assist", "removeOnVerifyFail", true);
        LoadPaceHint();
    }

    private void LoadPaceHint()
    {
        AutoRunHint.Text = AutoRun.Text == "0" || AutoRun.Text.Length == 0
            ? "0 = 不自动跑。设成 60 之类，到点自己扫描并辅一轮。"
            : $"约 {_model.AssistAutoNextMinutes} 分钟后自动跑下一轮。";
    }

    private double PaceNum(string field, double fallback)
    {
        if (_model.Config?["assist"]?[field] is JsonValue v)
        {
            if (v.TryGetValue<double>(out var d)) return d;
            if (v.TryGetValue<int>(out var i)) return i;
            if (v.TryGetValue<long>(out var l)) return l;
        }
        return fallback;
    }

    private void OnSavePace(object sender, RoutedEventArgs e)
    {
        _model.PatchSection("assist", o =>
        {
            if (double.TryParse(Interval.Text, out var iv)) o["perSiteIntervalSec"] = Math.Max(0, Math.Min(120, iv));
            if (double.TryParse(Jitter.Text, out var jt)) o["jitterSec"] = Math.Max(0, Math.Min(30, jt));
            if (int.TryParse(Budget.Text, out var bd)) o["roundBudget"] = Math.Max(1, Math.Min(2000, bd));
            if (int.TryParse(MissTTL.Text, out var tt)) o["missTTLDays"] = Math.Max(0, Math.Min(90, tt));
            o["autoAcceptSameFiles"] = AutoAccept.IsChecked == true;
            o["removeOnVerifyFail"] = RemoveOnFail.IsChecked == true;
            if (int.TryParse(AutoRun.Text, out var ar)) o["autoRunMinutes"] = Math.Max(0, Math.Min(1440, ar));
            if (int.TryParse(ListPageSize.Text, out var ps)) o["listPageSize"] = Math.Max(1, Math.Min(200, ps));
        });
        LoadPace();
    }

    private static LinearGradientBrush Gradient(string[] hexes)
    {
        var b = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
        for (var i = 0; i < hexes.Length; i++)
            b.GradientStops.Add(new GradientStop((Color)ColorConverter.ConvertFromString(hexes[i]),
                                                hexes.Length == 1 ? 0 : (double)i / (hexes.Length - 1)));
        return b;
    }

    private void OnPickImage(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = "选择背景图片",
            Filter = "图片|*.jpg;*.jpeg;*.png|所有文件|*.*",
        };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        var target = Path.Combine(_model.DataDir, "background.jpg");
        File.Copy(dialog.FileName, target, true);
        _model.Call("appearance.set", new { bgImage = "background.jpg" });
        App.BackgroundImage();
    }

    private void OnClearImage(object sender, RoutedEventArgs e)
    {
        var target = Path.Combine(_model.DataDir, "background.jpg");
        if (File.Exists(target)) File.Delete(target);
        _model.Call("appearance.set", new { bgImage = (string?)null });
    }

    private void OnOpacity(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_loading) return;
        _model.PatchSection("appearance", s => s["bgOpacity"] = Math.Round(e.NewValue, 2));
    }

    private async void OnCheckUpdate(object sender, RoutedEventArgs e)
    {
        UpdateState.Text = "检查中…";
        // 查一次版本要走 GitHub：在界面线程等会把窗口卡成「未响应」
        var error = await _model.TryAsync("update.check");
        UpdateState.Text = error ?? "已提交检查";
    }

    // 有新版本时直接给安装包直链（与 mac 版「下载 x.y.z 安装包」一致）
    private void OnDownloadUpdate(object sender, RoutedEventArgs e) => Open(_model.UpdateDownloadUrl);

    private void OnOpenReleases(object sender, RoutedEventArgs e) =>
        Open(_model.UpdateUrl.Length > 0 ? _model.UpdateUrl : "https://github.com/nandieling/box-send/releases");

    private void Open(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception ex) { MessageBox.Show(Window.GetWindow(this)!, ex.Message, "BoxSend"); }
    }

    private void OnTutorial(object sender, RoutedEventArgs e) =>
        new Dialogs.TutorialWindow { Owner = Window.GetWindow(this) }.ShowDialog();

    private void OnTmdbToggled(object sender, RoutedEventArgs e) => SaveTMDB();

    private void SaveTMDB() => _model.PatchSection("tmdb", s =>
    {
        s["enabled"] = TmdbOn.IsChecked == true;
        s["apiBase"] = TmdbBase.Text.Trim();
        s["apiKey"] = TmdbKey.Text;
    });

    /// 用一条固定片例（银魂剧场版）验一次网关通不通：核心库拿 IMDb 号与豆瓣号各试一遍
    private async void OnTestTMDB(object sender, RoutedEventArgs e)
    {
        SaveTMDB();
        BtnTmdb.IsEnabled = false;
        TmdbState.Text = "查询中…";
        var node = await Task.Run(() => _model.Api.TryInvoke("tmdb.test", out var error)
                                       ?? new JsonObject { ["error"] = error ?? "查询失败" });
        await _model.RefreshAsync(full: false);
        BtnTmdb.IsEnabled = true;
        var link = node?["link"]?.GetValue<string>();
        TmdbState.Text = string.IsNullOrEmpty(link)
            ? "失败: " + (node?["error"]?.GetValue<string>() ?? "TMDB 没有匹配条目")
            : "成功: " + link;
    }

    private void OnAutoUpdate(object sender, RoutedEventArgs e) =>
        _model.Call("config.patch", new JsonObject { ["patch"] = new JsonObject { ["autoUpdateCheck"] = AutoUpdate.IsChecked == true } });
}
