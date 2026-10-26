using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace BoxSend.Windows.Views;

/// <summary>辅种页：覆盖率 + 待处理队列 + 「一条种子 × 各辅种站」的格子。
/// 归类、计数、覆盖率文案都在核心库里算，这页只画；默认只摊开要人动手的那几类格子，
/// 115 个站全摊开就是满屏灰格子，真结论反倒看不见。</summary>
public partial class AssistView : UserControl
{
    private readonly AppModel _model;
    private readonly ObservableCollection<TorrentBlock> _torrents = new();
    /// 界面当前页与总页数（核心库按设置里的「单页列表条数」切页）
    private int _page;
    private int _pageCount = 1;

    public AssistView(AppModel model)
    {
        _model = model;
        InitializeComponent();
        Torrents.ItemsSource = _torrents;
        Stats.ItemsSource = _model.AssistStats;
        Queue.ItemsSource = _model.AssistQueue;
        _model.FullRefreshed += (_, _) => Dispatcher.Invoke(ShowSites);
        _model.Refreshed += (_, _) => Dispatcher.Invoke(RefreshProgress);
        ShowSites();
        RefreshProgress();
    }

    /// <summary>辅种站点这一页只管显示：名单在「站点分组」页底部的辅种区块里改
    /// （与 mac 版同一处）。</summary>
    private void ShowSites()
    {
        var picked = AssistField("siteIDs");
        var names = picked
            .Select(id => _model.Sites.FirstOrDefault(s => s.Id == id)?.Name ?? id)
            .ToList();
        SiteInfo.Text = names.Count == 0
            ? "还没有辅种站点：在「站点分组」页底部的辅种区块里添加。"
            : $"辅种站点 {names.Count} 个：" + string.Join("、", names.Take(12))
              + (names.Count > 12 ? $" 等 {names.Count} 个" : "");
    }

    private List<string> AssistField(string field)
    {
        var node = _model.Config?["assist"]?[field];
        if (node is JsonArray arr && field == "siteIDs")
            return arr.Select(n => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : "")
                .Where(s => s.Length > 0).ToList();
        return new List<string>();
    }

    // MARK: 扫描与执行

    /// 参与站点 = 辅种名单（在「站点分组」页维护，这一页不再勾）
    private string[] CheckedSites() => AssistField("siteIDs").ToArray();

    private async void OnScan(object sender, RoutedEventArgs e)
    {
        var ids = CheckedSites();
        BtnScan.IsEnabled = false;
        State.Text = "扫描下载器…";
        var (node, error) = await _model.AssistScanAsync(ids.Length > 0 ? ids : null);
        BtnScan.IsEnabled = true;
        if (node == null)
        {
            State.Text = error ?? "扫描下载器失败";
            return;
        }
        Fill(node!.AsObject());
    }

    /// 回查校验：上一轮推进下载器却没等到校验结果的种子，回来问一次下载器。
    /// 一次站点请求都不发，所以跑多快都不给站点添负载。
    private async void OnRecheck(object sender, RoutedEventArgs e)
    {
        BtnRecheck.IsEnabled = false;
        State.Text = "回查校验…";
        var (node, error) = await _model.AssistRecheckAsync();
        BtnRecheck.IsEnabled = true;
        if (node == null)
        {
            State.Text = error ?? "回查校验失败";
            return;
        }
        Fill(node!.AsObject());
    }

    /// 翻页只换这一页的格子：目录与计数还在核心库里，不必重读上万条种子
    private async void OnPrevPage(object sender, RoutedEventArgs e) => await GoPage(_page - 1);
    private async void OnNextPage(object sender, RoutedEventArgs e) => await GoPage(_page + 1);

    private async Task GoPage(int page)
    {
        if (page < 0 || page >= _pageCount) return;
        var (node, error) = await _model.AssistPageAsync(page);
        if (node == null)
        {
            State.Text = error ?? "翻页失败";
            return;
        }
        Fill(node!.AsObject());
    }

    private void Fill(JsonObject result)
    {
        var totalTorrents = result["torrentTotal"]?.GetValue<int>() ?? 0;
        var rawTorrents = result["torrentRaw"]?.GetValue<int>() ?? totalTorrents;
        _page = result["page"]?.GetValue<int>() ?? 0;
        _pageCount = Math.Max(1, result["pageCount"]?.GetValue<int>() ?? 1);
        var pageSize = result["pageSize"]?.GetValue<int>() ?? 10;
        var dl = Text(result["downloader"]);
        // 同一条片子在各站各有一份 .torrent（tracker 不同 → hash 不同）：先去重再列，不然满屏重复
        TorrentHint.Text = rawTorrents > totalTorrents
            ? $"下载器里 {rawTorrents} 条符合，去掉各站重复后 {totalTorrents} 条。"
            : $"下载器里 {totalTorrents} 条符合。";
        TorrentHint.Text += $"辅种下载器：{(dl.Length > 0 ? dl : "未配置")}（在「设置」页的「辅种扫描用」里换一台）";
        Pager.Text = $"第 {_page + 1} / {_pageCount} 页（共 {totalTorrents} 条，每页 {pageSize} 条）";
        BtnPrev.IsEnabled = _page > 0;
        BtnNext.IsEnabled = _page < _pageCount - 1;

        // 行按种子归堆：一条种子一张卡，卡里是它在各站的小格子
        _torrents.Clear();
        var byHash = new Dictionary<string, TorrentBlock>();
        foreach (var n in result["torrents"]?.AsArray() ?? new JsonArray())
        {
            var hash = Text(n?["hash"]);
            var size = n?["size"]?.GetValue<double>() ?? 0;
            var trackers = n?["trackers"]?.AsArray()?.Count ?? 0;
            var block = new TorrentBlock
            {
                Hash = hash,
                Left = Text(n?["name"]),
                SizeText = $"{size / 1073741824.0:0.0} GiB",
                Right = $"{size / 1073741824.0:0.0} GiB · 已做种 {trackers} 站",
                WideOpen = WideOpen.IsChecked == true,
            };
            byHash[hash] = block;
            _torrents.Add(block);
        }
        foreach (var n in result["rows"]?.AsArray() ?? new JsonArray())
        {
            var hash = Text(n?["hash"]);
            if (!byHash.TryGetValue(hash, out var block)) continue;
            var skip = Text(n?["skip"]);
            block.Cells.Add(new Cell
            {
                Key = Text(n?["key"]),
                SiteName = Text(n?["siteName"]),
                Skip = skip,
                Hash = hash,
                Status = Text(n?["status"]),
                StatusText = Text(n?["statusText"]),
                Tip = Text(n?["siteName"]) + "\n" + Text(n?["torrentName"])
                    + (skip.Length > 0 ? "\n" + skip : ""),
            });
        }
        foreach (var block in _torrents) block.Rebuild();
        ShowCoverage(result);
        var budget = result["budget"]?.GetValue<int>() ?? 0;
        PlanSummary.Text = $"单轮预算 {_model.SectionInt("assist", "roundBudget", 200)} 次请求，"
            + $"本轮剩余额度 {budget} 次；用完接着跑下一轮，站点检索不会被打过头";
        State.Text = $"参与站点 {CheckedSites().Length} 个";
        RefreshProgress();
    }

    /// 覆盖率那一行与进度条：文案由核心库给，两端一字不差
    private void ShowCoverage(JsonObject result)
    {
        if (result["coverage"] is not JsonObject cov)
        {
            CoverageLine.Text = "";
            Coverage.Value = 0;
            return;
        }
        Coverage.Value = cov["percent"]?.GetValue<double>() ?? 0;
        CoverageLine.Text = Text(cov["line"]);
    }

    private async void OnStart(object sender, RoutedEventArgs e)
    {
        var ids = CheckedSites();
        if (ids.Length == 0)
        {
            State.Text = "先在「站点分组」页的辅种区块添加站点";
            return;
        }
        if (_torrents.Count == 0)
        {
            State.Text = "先扫描下载器";
            return;
        }
        _model.ClearAssistRows();
        BtnStart.IsEnabled = false;
        // 只跑界面上这一页：整库上万条一次跑不完，跑眼前这批更可控
        var err = await _model.AssistStartAsync(ids, DryRun.IsChecked == true, null,
            _torrents.Select(t => t.Hash).ToArray());
        BtnStart.IsEnabled = true;
        if (err != null) State.Text = err;
        RefreshProgress();
    }

    /// 逐格结论由核心库算好随快照回来，这里只把文本与配色搬过去（整表不重建，滚动位置不动）
    private void RefreshProgress()
    {
        foreach (var block in _torrents)
        {
            foreach (var cell in block.Cells)
            {
                var live = _model.AssistRows.FirstOrDefault(r => r.Key == cell.Key);
                if (live == null) continue;
                cell.Status = live.Status;
                cell.StatusText = live.StatusText;
                // 详情里带上跳过原因或站点那条种子链接，悬停能看清为什么
                cell.Tip = cell.SiteName + "\n" + block.Left
                    + (live.Detail.Length > 0 ? "\n" + live.Detail : "");
                cell.NeedConfirm = live.Status == "manual";
            }
            block.Rebuild();
        }
        Coverage.Value = _model.AssistCoveragePercent;
        CoverageLine.Text = _model.AssistCoverageLine;
        QueueBox.Visibility = _model.AssistQueue.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        QueueBox.Header = $"待处理（{_model.AssistQueue.Count}）";
        BtnScan.IsEnabled = !_model.BusyAssist;
        BtnStart.IsEnabled = !_model.BusyAssist && _torrents.Count > 0;
        BtnRecheck.IsEnabled = !_model.BusyAssist;
        BtnPrev.IsEnabled = _page > 0 && !_model.BusyAssist;
        BtnNext.IsEnabled = _page < _pageCount - 1 && !_model.BusyAssist;
        BtnStart.Content = DryRun.IsChecked == true ? "预演本页" : "辅种本页";
        if (_model.BusyAssist) State.Text = _model.AssistStep;
        else if (_model.AssistReport.Length > 0) State.Text = _model.AssistReport;
    }

    /// 全展开 / 全收起：切完每张卡重算一遍可见格子
    private void OnWideOpen(object sender, RoutedEventArgs e)
    {
        foreach (var block in _torrents)
        {
            block.WideOpen = WideOpen.IsChecked == true;
            block.Rebuild();
        }
    }

    /// 点计数牌 = 展开/收起那一类的格子
    private void OnChip(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: Chip chip }) return;
        var block = _torrents.FirstOrDefault(b => b.Hash == chip.Hash);
        block?.Toggle(chip.Status);
    }

    /// 人工采纳一条：只重跑这一条，负缓存与「已辅过」预筛都让路
    private async void OnAdopt(object sender, RoutedEventArgs e)
    {
        if (sender is not Button btn || btn.DataContext is not Cell cell) return;
        cell.StatusText = "核对中…";
        var err = await _model.AssistConfirmAsync(cell.Key);
        if (err != null) cell.StatusText = err;
        RefreshProgress();
    }

    // MARK: 待处理队列上的按钮

    private async void OnAdoptQ(object sender, RoutedEventArgs e) =>
        await RunQueueAction(sender, item => _model.AssistConfirmAsync(item.Key));

    private async void OnRetryQ(object sender, RoutedEventArgs e) =>
        await RunQueueAction(sender, item => _model.AssistRetryAsync(item.SiteID, item.Hash));

    private async void OnRecheckQ(object sender, RoutedEventArgs e) =>
        await RunQueueAction(sender, item => _model.AssistRecheckAsync(new[] { item.Key }).ContinueWith(
            t => (string?)t.Result.Error));

    private async void OnRejectQ(object sender, RoutedEventArgs e) =>
        await RunQueueAction(sender, item => _model.AssistRejectAsync(item.Key, true).ContinueWith(
            t => (string?)t.Result.Error));

    private async void OnUndoQ(object sender, RoutedEventArgs e) =>
        await RunQueueAction(sender, item => _model.AssistRejectAsync(item.Key, false).ContinueWith(
            t => (string?)t.Result.Error));

    /// 队列按钮统一走这一趟：调用完刷新一次，界面按新状态重画那一行
    private async Task RunQueueAction(object sender, Func<AssistQueueItem, Task<string?>> action)
    {
        if (sender is not FrameworkElement { DataContext: AssistQueueItem item }) return;
        State.Text = $"处理 {item.SiteName} · {item.TorrentName}…";
        var err = await action(item);
        State.Text = err ?? $"{item.SiteName}：已处理";
        RefreshProgress();
    }

    private static string Text(JsonNode? n) =>
        n is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";

    /// 一条种子一张卡：标题 + 各类计数牌 + 展开的那些格子
    public sealed class TorrentBlock : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler? PropertyChanged;

        public string Hash { get; init; } = "";
        public string Left { get; init; } = "";
        public string SizeText { get; set; } = "";

        /// 这一页里这条种子的全部格子（含没展开的）
        public ObservableCollection<Cell> Cells { get; } = new();
        /// 画出来的格子：默认只有要人动手的那几类
        public ObservableCollection<Cell> VisibleCells { get; } = new();
        public ObservableCollection<Chip> Chips { get; } = new();

        /// 手动改过的展开状态；没改过的按默认走
        private readonly Dictionary<string, bool> _fold = new();

        /// 与核心库 RowStatus 的声明顺序一致，界面照这个排计数牌
        private static readonly string[] Order =
        {
            "assisted", "pending", "verifying", "review", "manual",
            "failed", "rejected", "missing", "seeding", "unsupported", "filtered",
        };

        /// 默认就摊开的：问题不该要人先去点计数牌才看得见
        private static readonly string[] AutoOpen = { "failed", "manual", "review" };

        public bool WideOpen { get; set; }

        private string _right = "";
        public string Right
        {
            get => _right;
            set { if (_right == value) return; _right = value; Raise(nameof(Right)); }
        }

        public string Tip => Left;

        /// 格子结论可能刚变过：计数牌与可见格子都按当前状态重算
        public void Rebuild()
        {
            var groups = new Dictionary<string, List<Cell>>();
            foreach (var c in Cells)
            {
                if (!groups.TryGetValue(c.Status, out var list)) groups[c.Status] = list = new List<Cell>();
                list.Add(c);
            }
            var statuses = Order.Where(groups.ContainsKey)
                .Concat(groups.Keys.Where(k => !Order.Contains(k))).ToList();
            Replace(Chips, statuses.Select(st => new Chip(Hash, st, groups[st][0].StatusText,
                groups[st].Count, IsOpen(st))).ToList());
            Replace(VisibleCells, Cells.Where(c => IsOpen(c.Status)).ToList());
            int N(string st) => groups.TryGetValue(st, out var l) ? l.Count : 0;
            Right = $"{SizeText} · 已辅 {N("assisted")} · 待辅 {N("pending") + N("verifying")}"
                + $" · 失败 {N("failed")} · 待复核 {N("review")} · 待确认 {N("manual")}";
        }

        public void Toggle(string status)
        {
            _fold[status] = !IsOpen(status);
            Rebuild();
        }

        private bool IsOpen(string status) =>
            WideOpen || (_fold.TryGetValue(status, out var v) ? v : AutoOpen.Contains(status));

        private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

        /// 整表替换：一次几十条，比逐条 diff 便宜，也不会漏通知
        private static void Replace<T>(ObservableCollection<T> target, List<T> items)
        {
            target.Clear();
            foreach (var i in items) target.Add(i);
        }
    }

    /// 一类格子的小计数牌：底色说结论，数字说有几格，点一下展开那一类
    public sealed class Chip
    {
        public Chip(string hash, string status, string label, int count, bool open)
        {
            Hash = hash;
            Status = status;
            Label = label;
            Count = count;
            IsOpen = open;
            Wash = open ? WashBrush(status) : Brushes.Transparent;
            Tip = $"{label} {count} 格：{(open ? "点击收起" : "点击展开")}";
        }

        public string Hash { get; }
        public string Status { get; }
        public string Label { get; }
        public int Count { get; }
        public bool IsOpen { get; }
        public Brush Wash { get; }
        public string Tip { get; }

        /// 展开的那类铺一层结论色薄底；没展开的保持透明
        private static Brush WashBrush(string status)
        {
            var hex = status switch
            {
                "assisted" => "#3D2EA244",
                "failed" => "#3DE5484D",
                "verifying" => "#3D4C8EFF",
                "review" => "#3D9B5BE0",
                "manual" => "#3DE89B2C",
                "seeding" => "#3D2AA4A4",
                _ => "#33808A94",
            };
            return _cache.TryGetValue(hex, out var b) ? b : _cache[hex] = new SolidColorBrush(
                (Color)ColorConverter.ConvertFromString(hex));
        }

        private static readonly Dictionary<string, Brush> _cache = new();
    }

    /// 一格 = 一条种子在一个站的结论
    public sealed class Cell : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler? PropertyChanged;

        public string Key { get; init; } = "";
        public string SiteName { get; init; } = "";
        public string Skip { get; init; } = "";
        public string Hash { get; init; } = "";

        private string _status = "";
        private string _statusText = "";
        private string _tip = "";
        private bool _needConfirm;

        public string Status
        {
            get => _status;
            set
            {
                if (_status == value) return;
                _status = value;
                Raise(nameof(Status));
                Raise(nameof(Tone));
            }
        }

        /// 计划阶段先按计划显示（待辅种 / 不支持检索…），跑起来后由核心库的结论覆盖
        public string StatusText
        {
            get => _statusText;
            set { if (_statusText == value) return; _statusText = value; Raise(nameof(StatusText)); }
        }

        /// 该用哪个配色键
        public string Tone => Status switch
        {
            "assisted" or "seeding" => "Success",
            "failed" => "DangerText",
            "verifying" => "Accent",
            "review" => "Review",
            "manual" => "Warning",
            _ => "TextMuted",
        };

        public string Tip
        {
            get => _tip;
            set { if (_tip == value) return; _tip = value; Raise(nameof(Tip)); }
        }

        public bool NeedConfirm
        {
            get => _needConfirm;
            set { if (_needConfirm == value) return; _needConfirm = value; Raise(nameof(NeedConfirm)); }
        }

        private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
