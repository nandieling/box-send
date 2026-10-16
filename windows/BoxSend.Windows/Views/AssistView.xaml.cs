using System.ComponentModel;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;

namespace BoxSend.Windows.Views;

/// <summary>辅种页：扫描下载器 → 每条种子 × 参与站点 → 站内检索 → 比对文件清单 →
/// 先暂停加进下载器，校验到 100% 才算辅成。站点请求的节奏在核心库里收口，
/// 这页只负责发起、以及把逐行进展显示出来（进展随快照回来）。</summary>
public partial class AssistView : UserControl
{
    private readonly AppModel _model;
    private readonly System.Collections.ObjectModel.ObservableCollection<Line> _candidates = new();
    private readonly System.Collections.ObjectModel.ObservableCollection<PlanItem> _plan = new();
    private bool _loading;
    /// 站点勾选列表的重建签名：只有站点集合变了才重建，免得点一下勾选就丢焦点
    private string _siteSignature = "";

    public AssistView(AppModel model)
    {
        _model = model;
        InitializeComponent();
        Candidates.ItemsSource = _candidates;
        PlanRows.ItemsSource = _plan;
        _model.FullRefreshed += (_, _) => Dispatcher.Invoke(() =>
        {
            RebuildSites();
            LoadPace();
        });
        _model.Refreshed += (_, _) => Dispatcher.Invoke(RefreshProgress);
        RebuildSites();
        LoadPace();
        RefreshProgress();
    }

    // MARK: 左栏

    private void RebuildSites()
    {
        var sites = _model.Sites.Where(s => s.Enabled).ToList();
        var picked = AssistField("siteIDs");
        var signature = string.Join(",", sites.Select(s => s.Id)) + "|" + string.Join(",", picked);
        if (_siteSignature == signature) return;
        _siteSignature = signature;

        SiteList.Children.Clear();
        foreach (var site in sites)
        {
            var box = new CheckBox
            {
                Content = site.Name,
                FontSize = 13,
                Margin = new Thickness(0, 2, 0, 2),
                IsChecked = picked.Contains(site.Id),
                Tag = site.Id,
            };
            box.Checked += OnSiteToggled;
            box.Unchecked += OnSiteToggled;
            SiteList.Children.Add(box);
        }
        if (sites.Count == 0)
            SiteList.Children.Add(new TextBlock
            {
                Text = "先在「站点分组」里启用站点",
                FontSize = 13,
                Foreground = (System.Windows.Media.Brush)TryFindResource("TextMuted")!,
            });
    }

    private List<string> AssistField(string field)
    {
        var node = _model.Config?["assist"]?[field];
        if (node is JsonArray arr && field == "siteIDs")
            return arr.Select(n => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : "")
                .Where(s => s.Length > 0).ToList();
        return new List<string>();
    }

    private void OnSiteToggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        var box = (CheckBox)sender;
        var id = (string)box.Tag!;
        _model.PatchSection("assist", o =>
        {
            var ids = (o["siteIDs"] as JsonArray ?? new JsonArray())
                .Select(n => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : "")
                .Where(s => s.Length > 0).ToList();
            if (box.IsChecked == true)
            {
                if (!ids.Contains(id)) ids.Add(id);
            }
            else ids.Remove(id);
            o["siteIDs"] = new JsonArray(ids.Select(s => (JsonNode)s).ToArray());
        });
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
        });
        LoadPace();
    }

    // MARK: 扫描与执行

    private string[] CheckedSites() => SiteList.Children.OfType<CheckBox>()
        .Where(c => c.IsChecked == true).Select(c => (string)c.Tag!).ToArray();

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
        CandidateSummary.Text = $"共 {_candidates.Count} 条。没下完、或按大小/分类筛掉的不在这里。";

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
            }
            else
            {
                item.Status = item.Skip.Length > 0 ? item.Skip : (_model.AssistRunning ? "排队中" : "待检索");
                item.Tip = item.Skip;
            }
        }
        BtnScan.IsEnabled = !_model.BusyAssist;
        BtnStart.IsEnabled = !_model.BusyAssist && _plan.Count > 0;
        BtnStart.Content = DryRun.IsChecked == true ? "开始预演" : "开始辅种";
        if (_model.BusyAssist) State.Text = _model.AssistStep;
        else if (_model.AssistReport.Length > 0) State.Text = _model.AssistReport;
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
