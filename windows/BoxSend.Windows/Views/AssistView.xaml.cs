using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;

namespace BoxSend.Windows.Views;

/// <summary>辅种页只有三块：进度（覆盖率 + 5 组计数 + 逐站）、待你处理、种子明细。
/// 数字只出现在进度块，按钮只出现在待你处理，格子只在明细里。
/// 归类、计数、文案都在核心库里算，这页只画；一条种子默认收成一行汇总，
/// 有要人处理的才自动摊开，115 个站的格子不会糊满一屏。</summary>
public partial class AssistView : UserControl
{
    private readonly AppModel _model;
    private readonly ObservableCollection<TorrentBlock> _torrents = new();
    /// 界面当前页与总页数（核心库按设置里的「单页列表条数」切页）
    private int _page;
    private int _pageCount = 1;
    /// 逐站进度的筛选视图：勾「只显示还有活的站」只滤显示，不动模型那一表
    private readonly ICollectionView _siteView;
    private bool _busyOnly;

    public AssistView(AppModel model)
    {
        _model = model;
        InitializeComponent();
        Torrents.ItemsSource = _torrents;
        Stats.ItemsSource = _model.AssistBuckets;
        Queue.ItemsSource = _model.AssistQueue;
        HandledQueue.ItemsSource = _model.AssistHandled;
        _siteView = CollectionViewSource.GetDefaultView(_model.AssistSiteProgress);
        _siteView.Filter = o => o is not AssistSiteRow row || !_busyOnly || row.IsBusy;
        SiteProgressList.ItemsSource = _siteView;
        _model.FullRefreshed += (_, _) => Dispatcher.Invoke(ShowSites);
        _model.Refreshed += (_, _) => Dispatcher.Invoke(RefreshProgress);
        ShowSites();
        RefreshProgress();
    }

    /// <summary>辅种站点这一页只管显示：名单在「站点分组」页底部的辅种区块里改
    /// （与 mac 版同一处）。</summary>
    private void ShowSites()
    {
        var names = AssistField("siteIDs")
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

    /// 全部回查：上一轮推进下载器却没等到校验结果的种子，回来问一次下载器。
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

        // 行按种子归堆：一条种子一行汇总，点开才是它在各站的格子
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
                // 折叠标题那句话与要不要默认展开，都由核心库算好
                SeedSummary = Text(n?["summary"]),
                Attention = n?["attention"]?.GetValue<bool>() ?? false,
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
                Bucket = Text(n?["bucket"]),
                Tip = Text(n?["siteName"]) + "\n" + Text(n?["torrentName"])
                    + (skip.Length > 0 ? "\n" + skip : ""),
            });
        }
        foreach (var block in _torrents) block.Rebuild(BucketLabels());
        ShowCoverage(result);
        var budget = result["budget"]?.GetValue<int>() ?? 0;
        PlanSummary.Text = $"单轮预算 {_model.SectionInt("assist", "roundBudget", 200)} 次请求，"
            + $"本轮剩余额度 {budget} 次；用完接着跑下一轮，站点检索不会被打过头";
        State.Text = $"参与站点 {CheckedSites().Length} 个";
        RefreshProgress();
    }

    /// 5 组的名称与顺序：核心库给的计数牌就是这份，明细行那句话照它拼
    private List<(string Bucket, string Label)> BucketLabels() =>
        _model.AssistBuckets.Select(b => (b.Bucket, b.Label)).ToList();

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
        var labels = BucketLabels();
        foreach (var block in _torrents)
        {
            foreach (var cell in block.Cells)
            {
                var live = _model.AssistRows.FirstOrDefault(r => r.Key == cell.Key);
                if (live == null) continue;
                cell.Status = live.Status;
                cell.StatusText = live.StatusText;
                if (live.Bucket.Length > 0) cell.Bucket = live.Bucket;
                // 详情里带上跳过原因或站点那条种子链接，悬停能看清为什么
                cell.Tip = cell.SiteName + "\n" + block.Left
                    + (live.Detail.Length > 0 ? "\n" + live.Detail : "");
                cell.NeedConfirm = live.Status == "manual";
            }
            block.Rebuild(labels);
        }
        Coverage.Value = _model.AssistCoveragePercent;
        CoverageLine.Text = _model.AssistCoverageLine;

        var open = _model.AssistQueue.Count;
        var handled = _model.AssistHandled.Count;
        var review = _model.AssistQueue.Count(i => i.Status == "review");
        QueueBox.Header = $"待你处理（{open}）";
        QueueBox.Visibility = open + handled == 0 ? Visibility.Collapsed : Visibility.Visible;
        BtnRecheck.Visibility = review > 0 ? Visibility.Visible : Visibility.Collapsed;
        BtnRecheck.Content = $"全部回查（{review}）";
        HandledBox.Visibility = handled == 0 ? Visibility.Collapsed : Visibility.Visible;
        HandledBox.Header = $"已处理（{handled}）：你否决过的";

        var rows = _model.AssistSiteProgress;
        var shown = rows.Count(r => !_busyOnly || r.IsBusy);
        SiteSection.Visibility = rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        SiteListHeader.Text = $"逐站（{shown}）";
        SiteTotals.Text = $"合计 已判定 {rows.Sum(r => r.Resolved):N0} / {rows.Sum(r => r.Total):N0}"
            + $"　还要检索 {rows.Sum(r => r.Searches):N0}";
        ProgressBox.Visibility = rows.Count == 0 && _model.AssistStatTotal == 0
            ? Visibility.Collapsed : Visibility.Visible;

        RunningPanel.Visibility = _model.BusyAssist ? Visibility.Visible : Visibility.Collapsed;
        Budget.Text = $"运行中，{_model.AssistBudgetLine}";
        BtnScan.IsEnabled = !_model.BusyAssist;
        BtnStart.IsEnabled = !_model.BusyAssist && _torrents.Count > 0;
        BtnStart.Content = DryRun.IsChecked == true ? "预演这一页" : "跑这一页";
        BtnPrev.IsEnabled = _page > 0 && !_model.BusyAssist;
        BtnNext.IsEnabled = _page < _pageCount - 1 && !_model.BusyAssist;
        if (_model.BusyAssist) State.Text = _model.AssistStep;
        else if (_model.AssistReport.Length > 0) State.Text = _model.AssistReport;
    }

    /// 停止本轮：核心库处理完手头那一格才收摊，中途打断不会把推一半的种子扔下
    private async void OnStop(object sender, RoutedEventArgs e) => await _model.AssistStopAsync();

    /// 追加本轮请求预算：这一轮跑得顺就想让它多跑一会儿，不必收工再点一次
    private async void OnBudget(object sender, RoutedEventArgs e) =>
        await _model.AssistAddBudgetAsync();

    /// 暂停 / 取消暂停一个辅种站：卡片上那个按钮是开关，按现值翻一次，
    /// 写 assist.pausedSites，卡片底色跟着下一次快照变灰
    /// 整张站点卡片都是暂停开关：点一下暂停/恢复这一站（不支持检索的站没什么可暂停）
    private void OnPauseSite(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string id }) return;
        if ((sender as FrameworkElement)?.DataContext is AssistSiteRow { Unsupported: true }) return;
        _model.PatchSection("assist", o =>
        {
            var list = (o["pausedSites"] as JsonArray ?? new JsonArray())
                .Select(x => x?.GetValue<string>() ?? "")
                .Where(x => x.Length > 0).ToList();
            var wasPaused = list.Contains(id);
            if (wasPaused) list = list.Where(x => x != id).ToList();
            else list.Add(id);
            var arr = new JsonArray();
            foreach (var k in list) arr.Add(JsonValue.Create(k));
            o["pausedSites"] = arr;
        });
    }

    /// 逐站进度只看有活儿的站：筛选只作用于显示，模型那一表整表留着
    private void OnBusyOnly(object sender, RoutedEventArgs e)
    {
        _busyOnly = BusyOnly.IsChecked == true;
        _siteView.Refresh();
        RefreshProgress();
    }

    /// 点标题行 = 展开/收起这一条种子的格子（人点过之后就不再自动改它）
    private void OnToggleBlock(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string hash }) return;
        _torrents.FirstOrDefault(b => b.Hash == hash)?.Toggle();
    }

    /// 点计数牌 = 展开/收起那一类的格子
    private void OnChip(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: Chip chip }) return;
        var block = _torrents.FirstOrDefault(b => b.Hash == chip.Hash);
        block?.ToggleStatus(chip.Status);
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

    // MARK: 待你处理那一块的按钮

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

    /// 一条种子一行：汇总那句话 + 点开才是计数牌与格子
    public sealed class TorrentBlock : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler? PropertyChanged;

        public string Hash { get; init; } = "";
        public string Left { get; init; } = "";
        public string SizeText { get; set; } = "";

        /// 这一页里这条种子的全部格子（含没展开的）
        public ObservableCollection<Cell> Cells { get; } = new();
        /// 画出来的格子：整条收起时为空
        public ObservableCollection<Cell> VisibleCells { get; } = new();
        public ObservableCollection<Chip> Chips { get; } = new();

        /// 手动改过的展开状态；没改过的按默认走
        private readonly Dictionary<string, bool> _fold = new();

        /// 与核心库 RowStatus 的声明顺序一致，界面照这个排计数牌
        private static readonly string[] Order =
        {
            "assisted", "pending", "verifying", "review", "manual",
            "failed", "rejected", "missing", "seeding", "unsupported", "filtered", "paused",
        };

        /// 默认就摊开的：问题不该要人先去点计数牌才看得见
        private static readonly string[] AutoOpen = { "failed", "manual", "review" };

        /// 5 组的固定顺序（核心库 Bucket 的声明顺序）；名字用核心库给的那份
        private static readonly string[] BucketOrder = { "done", "action", "trouble", "skip", "waiting" };

        /// 载荷给的汇总（格子还没 bucket 时的垫底文案）
        public string SeedSummary { get; init; } = "";

        /// 载荷给的「这条有要人处理的」：没人手动展开过之前拿它决定默认展开
        public bool Attention { get; set; }

        private bool _touched;
        private bool _expanded;
        private string _summary = "";
        private string _right = "";

        public string Summary
        {
            get => _summary;
            private set { if (_summary == value) return; _summary = value; Raise(nameof(Summary)); }
        }

        public string Right
        {
            get => _right;
            set { if (_right == value) return; _right = value; Raise(nameof(Right)); }
        }

        public string Arrow => _expanded ? "▾" : "▸";
        public Visibility ShowDetails => _expanded ? Visibility.Visible : Visibility.Collapsed;
        public string Tip => Left;

        /// 人点标题行：展开状态交给人，之后不再自动改
        public void Toggle()
        {
            _touched = true;
            _expanded = !_expanded;
            Raise(nameof(Arrow));
            Raise(nameof(ShowDetails));
        }

        public void ToggleStatus(string status)
        {
            _fold[status] = !IsOpen(status);
            Rebuild(null);
        }

        /// 格子结论可能刚变过：计数牌、可见格子、汇总那句话都按当前状态重算
        public void Rebuild(List<(string Bucket, string Label)>? labels)
        {
            var groups = new Dictionary<string, List<Cell>>();
            var counts = new Dictionary<string, int>();
            var bucketed = false;
            foreach (var c in Cells)
            {
                if (!groups.TryGetValue(c.Status, out var list)) groups[c.Status] = list = new List<Cell>();
                list.Add(c);
                if (c.Bucket.Length == 0) continue;
                bucketed = true;
                counts[c.Bucket] = counts.TryGetValue(c.Bucket, out var n) ? n + 1 : 1;
            }
            var statuses = Order.Where(groups.ContainsKey)
                .Concat(groups.Keys.Where(k => !Order.Contains(k))).ToList();
            Replace(Chips, statuses.Select(st => new Chip(Hash, st, groups[st][0].StatusText,
                groups[st].Count, IsOpen(st))).ToList());
            Replace(VisibleCells,
                _expanded ? Cells.Where(c => IsOpen(c.Status)).ToList() : new List<Cell>());
            if (!bucketed)
            {
                if (SeedSummary.Length > 0) Summary = SeedSummary;
                if (!_touched) SetExpanded(Attention);
                return;
            }
            var named = labels is { Count: > 0 } ? labels : BucketOrder.Select(b => (b, b)).ToList();
            var parts = named
                .Where(p => counts.TryGetValue(p.Item1, out var n) && n > 0)
                .Select(p => $"{p.Item2} {counts[p.Item1]:N0}")
                .ToList();
            Summary = parts.Count == 0 ? "没有格子" : string.Join(" · ", parts);
            var attention = (counts.TryGetValue("action", out var a) && a > 0)
                || (counts.TryGetValue("trouble", out var t) && t > 0);
            Attention = attention;
            if (!_touched) SetExpanded(attention);
        }

        private void SetExpanded(bool on)
        {
            if (_expanded == on) return;
            _expanded = on;
            Raise(nameof(Arrow));
            Raise(nameof(ShowDetails));
        }

        private bool IsOpen(string status) =>
            _fold.TryGetValue(status, out var v) ? v : AutoOpen.Contains(status);

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
        private string _bucket = "";
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

        /// 归到 5 组里的哪一组（核心库给的）：明细行那句汇总靠它拼
        public string Bucket
        {
            get => _bucket;
            set { if (_bucket == value) return; _bucket = value; Raise(nameof(Bucket)); }
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
