using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;

namespace BoxSend.Windows.Views;

/// <summary>辅种页：两块信息 —— 一条种子 × 各辅种站的格子（站名 + 已辅种/待辅种/不存在），
/// 以及整轮的已完成 / 待辅种 / 失败计数。分类与计数都在核心库里算，
/// 这页只画格子；搜索节奏挪到了「设置」页。</summary>
public partial class AssistView : UserControl
{
    private readonly AppModel _model;
    private readonly ObservableCollection<TorrentBlock> _torrents = new();

    public AssistView(AppModel model)
    {
        _model = model;
        InitializeComponent();
        Torrents.ItemsSource = _torrents;
        Stats.ItemsSource = _model.AssistStats;
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

    private void Fill(JsonObject result)
    {
        var totalTorrents = result["torrentTotal"]?.GetValue<int>() ?? 0;
        var dl = Text(result["downloader"]);
        TorrentHint.Text = $"下面列出体积最大的 {result["torrents"]?.AsArray()?.Count ?? 0} 条种子，"
            + $"摊开它在各站的格子（本轮候选按体积取，下载器里共 {totalTorrents} 条符合）。"
            + $"辅种下载器：{(dl.Length > 0 ? dl : "未配置")}（在「设置」页的「辅种扫描用」里换一台）";

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
        var planTotal = result["planTotal"]?.GetValue<int>() ?? 0;
        var willSearch = 0;
        var skips = new List<string>();
        if (result["planCounts"] is JsonObject counts)
            foreach (var kv in counts)
            {
                var c = kv.Value?.GetValue<int>() ?? 0;
                if (kv.Key == "会去站内检索") willSearch = c;
                else skips.Add($"{kv.Key} {c}");
            }
        skips.Sort((a, b) => b.Split(' ').Last().CompareTo(a.Split(' ').Last()));
        var budget = result["budget"]?.GetValue<int>() ?? 0;
        PlanSummary.Text = $"全量 {planTotal} 个组合，其中 {willSearch} 个会去站内检索"
            + $"（单轮预算 {_model.SectionInt("assist", "roundBudget", 200)} 次请求，用完下次接着跑）"
            + $"；本轮剩余额度 {budget} 次"
            + (skips.Count > 0 ? "；跳过：" + string.Join(" · ", skips.Take(4)) : "");
        State.Text = $"参与站点 {CheckedSites().Length} 个";
        RefreshProgress();
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
        var err = await _model.AssistStartAsync(ids, DryRun.IsChecked == true);
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
            block.Right = $"{block.SizeText} · 已辅 {block.Cells.Count(c => c.Status == "assisted")}"
                + $" · 待辅 {block.Cells.Count(c => c.Status is "pending" or "verifying")}"
                + $" · 失败 {block.Cells.Count(c => c.Status == "failed")}";
        }
        BtnScan.IsEnabled = !_model.BusyAssist;
        BtnStart.IsEnabled = !_model.BusyAssist && _torrents.Count > 0;
        BtnStart.Content = DryRun.IsChecked == true ? "开始预演" : "开始辅种";
        if (_model.BusyAssist) State.Text = _model.AssistStep;
        else if (_model.AssistReport.Length > 0) State.Text = _model.AssistReport;
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

    private static string Text(JsonNode? n) =>
        n is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";

    /// 一条种子一张卡
    public sealed class TorrentBlock : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler? PropertyChanged;

        public string Hash { get; init; } = "";
        public string Left { get; init; } = "";
        public string SizeText { get; set; } = "";

        public ObservableCollection<Cell> Cells { get; } = new();

        private string _right = "";
        public string Right
        {
            get => _right;
            set { if (_right == value) return; _right = value; Raise(nameof(Right)); }
        }

        public string Tip => Left;

        private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
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

        public string Tone => Status switch
        {
            "assisted" or "seeding" => "Success",
            "failed" => "DangerText",
            "verifying" => "Accent",
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
