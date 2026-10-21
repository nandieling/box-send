using System.ComponentModel;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;

namespace BoxSend.Windows.Views;

/// <summary>辅种页：扫描下载器 → 每条种子 × 辅种站点 → 站内检索 → 比对文件清单 →
/// 先暂停加进下载器，校验到 100% 才算辅成。站点请求的节奏在核心库里收口，
/// 这页只负责发起、以及把逐行进展显示出来（进展随快照回来）。</summary>
public partial class AssistView : UserControl
{
    private readonly AppModel _model;
    private readonly System.Collections.ObjectModel.ObservableCollection<Line> _candidates = new();
    private readonly System.Collections.ObjectModel.ObservableCollection<PlanItem> _plan = new();
    private bool _loading;

    public AssistView(AppModel model)
    {
        _model = model;
        InitializeComponent();
        Candidates.ItemsSource = _candidates;
        PlanRows.ItemsSource = _plan;
        _model.FullRefreshed += (_, _) => Dispatcher.Invoke(() =>
        {
            ShowSites();
            LoadPace();
        });
        _model.Refreshed += (_, _) => Dispatcher.Invoke(RefreshProgress);
        ShowSites();
        LoadPace();
        RefreshProgress();
    }

    // MARK: 左栏

    /// <summary>辅种站点这一页只管显示：名单在「站点分组」页底部的辅种区块里改
    /// （与 mac 版同一处）。</summary>
    private void ShowSites()
    {
        var picked = AssistField("siteIDs");
        var names = picked
            .Select(id => _model.Sites.FirstOrDefault(s => s.Id == id)?.Name ?? id)
            .ToList();
        SiteInfo.Text = names.Count == 0
            ? "还没有辅种站点"
            : $"共 {names.Count} 个：" + string.Join("、", names.Take(12))
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

    private void LoadPace()
    {
        _loading = true;
        Interval.Text = Num("perSiteIntervalSec", 8).ToString("0.#");
        Jitter.Text = Num("jitterSec", 3).ToString("0.#");
        Budget.Text = ((int)Num("roundBudget", 200)).ToString();
        MissTTL.Text = ((int)Num("missTTLDays", 7)).ToString();
        AutoAccept.IsChecked = _model.SectionFlag("assist", "autoAcceptSameFiles", true);
        RemoveOnFail.IsChecked = _model.SectionFlag("assist", "removeOnVerifyFail", true);
        AutoRun.Text = ((int)Num("autoRunMinutes", 0)).ToString();
        AutoRunHint.Text = AutoRun.Text == "0"
            ? "0 = 不自动跑。设成 60 之类，到点自己扫描并辅一轮。"
            : $"约 {_model.AssistAutoNextMinutes} 分钟后自动跑下一轮。";
        _loading = false;
    }

    private double Num(string field, double fallback)
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
        });
        LoadPace();
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
        _candidates.Clear();
        foreach (var n in result["torrents"]?.AsArray() ?? new JsonArray())
        {
            var size = n?["size"]?.GetValue<double>() ?? 0;
            var trackers = n?["trackers"]?.AsArray()?.Count ?? 0;
            _candidates.Add(new Line(n?["name"]?.GetValue<string>() ?? "",
                $"{size / 1073741824.0:0.0} GiB · 已做种 {trackers} 站"));
        }
        var delta = Text(result["summary"]?["deltaText"]);
        var dl = Text(result["downloader"]);
        CandidateSummary.Text = $"{(delta.Length > 0 ? delta + "。" : $"共 {_candidates.Count} 条。")}"
            + "没下完、或按大小/分类筛掉的不在这里。"
            + $"辅种下载器：{(dl.Length > 0 ? dl : "未配置")}（在「下载器」页的「辅种扫描用」里换一台）";

        _plan.Clear();
        var sites = result["sites"]?.AsArray()?.Count ?? 0;
        var willSearch = 0;
        foreach (var n in result["rows"]?.AsArray() ?? new JsonArray())
        {
            var skip = Text(n?["skip"]);
            if (skip.Length == 0) willSearch++;
            _plan.Add(new PlanItem
            {
                Key = Text(n?["key"]),
                SiteName = Text(n?["siteName"]),
                TorrentName = Text(n?["torrentName"]),
                Skip = skip,
            });
        }
        var budget = result["budget"]?.GetValue<int>() ?? 0;
        PlanSummary.Text = $"{_plan.Count} 个组合，其中 {willSearch} 个会去站内检索"
            + $"（单轮预算 {_model.SectionInt("assist", "roundBudget", 200)} 次请求，用完下次接着跑）"
            + $"；本轮剩余额度 {budget} 次。";
        State.Text = $"参与站点 {sites} 个，候选 {_candidates.Count} 条";
        RefreshProgress();
    }

    private async void OnStart(object sender, RoutedEventArgs e)
    {
        var ids = CheckedSites();
        if (ids.Length == 0)
        {
            State.Text = "先在左边勾选要辅种的站点";
            return;
        }
        if (_plan.Count == 0)
        {
            State.Text = "先扫描下载器";
            return;
        }
        foreach (var item in _plan.Where(p => !ids.Contains(p.Key.Split('|')[0])).ToList())
            _plan.Remove(item);
        _model.ClearAssistRows();
        BtnStart.IsEnabled = false;
        var err = await _model.AssistStartAsync(ids, DryRun.IsChecked == true);
        BtnStart.IsEnabled = true;
        if (err != null) State.Text = err;
        RefreshProgress();
    }

    private void RefreshProgress()
    {
        foreach (var item in _plan)
        {
            var live = _model.AssistRows.FirstOrDefault(r => r.Key == item.Key);
            if (live != null)
            {
                // 核心库把「种子名｜进展」拼成一句，这行左边已经有种子名了，只留进展
                var text = live.Text;
                var at = text.IndexOf('｜');
                item.Status = (live.PhaseText.Length > 0 ? live.PhaseText + "：" : "")
                    + (at >= 0 ? text[(at + 1)..] : text);
                item.Tip = live.Detail;
                item.NeedConfirm = live.Text.Contains("待人工确认");
            }
            else
            {
                item.Status = item.Skip.Length > 0 ? item.Skip : (_model.AssistRunning ? "排队中" : "待检索");
                item.Tip = item.Skip;
                item.NeedConfirm = false;
            }
        }
        BtnScan.IsEnabled = !_model.BusyAssist;
        BtnStart.IsEnabled = !_model.BusyAssist && _plan.Count > 0;
        BtnStart.Content = DryRun.IsChecked == true ? "开始预演" : "开始辅种";
        if (_model.BusyAssist) State.Text = _model.AssistStep;
        else if (_model.AssistReport.Length > 0) State.Text = _model.AssistReport;
        if (_model.SectionInt("assist", "autoRunMinutes", 0) > 0)
            AutoRunHint.Text = $"约 {_model.AssistAutoNextMinutes} 分钟后自动跑下一轮。";
    }

    /// 人工采纳一条：只重跑这一条，负缓存与「已辅过」预筛都让路
    private async void OnAdopt(object sender, RoutedEventArgs e)
    {
        if (sender is not Button btn || btn.DataContext is not PlanItem item) return;
        item.Status = "已采纳，重新核对这一条…";
        var err = await _model.AssistConfirmAsync(item.Key);
        if (err != null) item.Status = err;
        RefreshProgress();
    }

    private static string Text(JsonNode? n) =>
        n is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";

    /// 候选种子的两列文本
    public sealed record Line(string Left, string Right);

    /// 计划/进展的一行：文本随快照原地更新，整表不重建（滚动位置不动）
    public sealed class PlanItem : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler? PropertyChanged;

        public string Key { get; init; } = "";
        public string SiteName { get; init; } = "";
        public string TorrentName { get; init; } = "";
        public string Skip { get; init; } = "";

        private string _status = "待检索";
        private string _tip = "";
        private bool _needConfirm;

        /// 这行是不是「待人工确认」：是才显示「采纳」按钮
        public bool NeedConfirm
        {
            get => _needConfirm;
            set { if (_needConfirm == value) return; _needConfirm = value; Raise(nameof(NeedConfirm)); }
        }

        public string Status
        {
            get => _status;
            set { if (_status == value) return; _status = value; Raise(nameof(Status)); }
        }
        public string Tip
        {
            get => _tip;
            set { if (_tip == value) return; _tip = value; Raise(nameof(Tip)); }
        }

        private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
