using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using BoxSend.Windows.Interop;

namespace BoxSend.Windows;

/// <summary>界面侧的状态仓库：核心库快照的镜像 + 用户动作的转发。
/// 字段与 macOS 版 AppModel 的 @Published 一一对应，两端行为便于逐项对照。</summary>
public sealed class AppModel : INotifyPropertyChanged, IDisposable
{
    private readonly BoxSendApi _api;
    private readonly System.Windows.Threading.DispatcherTimer _timer;
    private bool _refreshing;
    private bool _pendingFull;

    private readonly System.Windows.Threading.DispatcherTimer _assistTickTimer;
    private readonly AutoTask _gistTask;
    private readonly AutoTask _ccTask;
    private readonly AutoTask _zipTask;
    private (bool On, int Minutes)? _zipArmed;

    public AppModel(BoxSendApi api)
    {
        _api = api;
        var version = api.Invoke("version");
        Platform = version["platform"]?.GetValue<string>() ?? "";
        CoreVersion = version["version"]?.GetValue<string>() ?? "";
        ConfigPath = version["configPath"]?.GetValue<string>() ?? "";
        DataDir = version["dataDir"]?.GetValue<string>() ?? "";
        foreach (var t in version["themes"]?.AsArray() ?? new JsonArray())
            Themes.Add(ThemeRow.From(t!));
        if (version["sshDefaults"] is { } d)
            SSHDefaults = new SshDefaults(
                d["keyPath"]?.GetValue<string>() ?? "~/.ssh/id_ed25519",
                d["testMB"]?.GetValue<int>() ?? 64,
                d["probeURL"]?.GetValue<string>() ?? "https://speed.cloudflare.com/__up",
                d["throttlingMBps"] is JsonValue tv && tv.TryGetValue<double>(out var mb) ? mb : 20);
        foreach (var g in Groups) Groups.Remove(g);

        _timer = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(600)
        };
        _timer.Tick += async (_, _) => await RefreshAsync(full: false);

        // 定时辅种：每分钟敲一次核心库那张表，该不该跑由它判断（两端共用一把尺）
        _assistTickTimer = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(60)
        };
        _assistTickTimer.Tick += async (_, _) => await AssistTickAsync();
        _assistTickTimer.Start();

        // 自动任务跑在后台线程：同步一次要走网络，不能卡住界面线程
        _gistTask = new AutoTask(() => RunInBackground("cookies.sync", new { source = "gist" }));
        _ccTask = new AutoTask(() => RunInBackground("cookies.sync", new { source = "cookieCloud" }));
        _zipTask = new AutoTask(() => RunInBackground("zip.scan", null));
    }

    /// 定时触发时丢到线程池，回到界面线程再刷一次快照
    private async Task RunInBackground(string method, object? parameters)
    {
        await Task.Run(() => _api.TryInvoke(method, out _, parameters));
        await RefreshAsync(full: false);
    }

    /// 到点自己跑一遍的定时器。间隔由配置决定，最短分别限 5 分钟 / 1 分钟。
    private sealed class AutoTask
    {
        private readonly System.Windows.Threading.DispatcherTimer _timer = new();
        private readonly Func<Task> _fire;

        public AutoTask(Func<Task> fire)
        {
            _fire = fire;
            _timer.Tick += async (_, _) =>
            {
                try { await _fire(); } catch { /* 失败已进核心日志，不打断界面 */ }
            };
        }

        public void Arm(bool on, int minutes, int floorMinutes)
        {
            _timer.Stop();
            if (!on) return;
            _timer.Interval = TimeSpan.FromMinutes(Math.Max(floorMinutes, minutes));
            _timer.Start();
        }

        public void Stop() => _timer.Stop();
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event EventHandler? FullRefreshed;
    /// 每一轮快照落地（含只更新运行状态的局部刷新）：转种页的卡片状态靠它跟上进度
    public event EventHandler? Refreshed;

    public BoxSendApi Api => _api;
    public string Platform { get; }
    public string CoreVersion { get; }
    public string ConfigPath { get; }
    public string DataDir { get; }

    public ObservableCollection<ThemeRow> Themes { get; } = new();

    /// <summary>SSH 测速的默认值（核心库给的，界面只当占位值用）</summary>
    public SshDefaults SSHDefaults { get; } = new("~/.ssh/id_ed25519", 64,
        "https://speed.cloudflare.com/__up", 20);
    public ObservableCollection<GroupRow> Groups { get; } = new();
    public ObservableCollection<SiteRow> Sites { get; } = new();
    public ObservableCollection<CookieHostRow> CookieHosts { get; } = new();
    public ObservableCollection<string> Logs { get; } = new();
    public ObservableCollection<RunRow> RunSites { get; } = new();
    public ObservableCollection<RunRow> RunPushes { get; } = new();
    public RunRow? SourcePush { get; private set; }

    /// <summary>这一站最新的转种 / 推送状态（核心只留每站最后一条，卡片照它画）</summary>
    public RunRow? ReseedEvent(string siteID) => RunSites.FirstOrDefault(r => r.SiteId == siteID);
    public RunRow? PushEvent(string siteID) => RunPushes.FirstOrDefault(r => r.SiteId == siteID);

    public JsonObject? Config { get; private set; }
    public ThemeRow CurrentTheme =>
        Themes.FirstOrDefault(t => t.Id == (Config?["appearance"]?["themeID"]?.GetValue<string>() ?? ""))
        ?? Themes.FirstOrDefault() ?? ThemeRow.Fallback;

    public bool Running { get; private set; }
    public string RunningStep { get; private set; } = "";
    public string LastReport { get; private set; } = "";
    public string CookieMessage { get; private set; } = "";
    public string DownloaderMessage { get; private set; } = "";
    public string ZipMessage { get; private set; } = "";
    public string UpdateMessage { get; private set; } = "";
    public string ConfigError { get; private set; } = "";
    public string LastGistSync { get; private set; } = "";
    public string UpdateVersion { get; private set; } = "";
    public string UpdateUrl { get; private set; } = "";
    public string UpdateDownloadUrl { get; private set; } = "";
    public bool HasUpdate { get; private set; }
    public bool BusyCookieSync { get; private set; }
    public bool BusyCookieCheck { get; private set; }
    public bool BusyDownloader { get; private set; }
    public bool BusyUpdate { get; private set; }
    public bool BusySSH { get; private set; }
    public int CookieTotal { get; private set; }
    public int EventCursor { get; private set; }

    /// 底部状态栏：配置读取错误优先，其次是 cookie 提示
    public string StatusText => string.IsNullOrEmpty(ConfigError) ? CookieMessage : ConfigError;

    public void Start() => _timer.Start();
    public void Stop() => _timer.Stop();

    /// <param name="full">连配置派生的列表（分组、站点）一起重建。
    /// 定时器只做局部刷新，避免用户正在输入的限速/口令框被重建打断。</param>
    public async Task RefreshAsync(bool full = true)
    {
        if (_refreshing)
        {
            if (full) _pendingFull = true;
            return;
        }
        _refreshing = true;
        // 要全量刷就按「取快照之前」的意图算：这一轮跑起来之后才发生的配置改动
        // 记进 _pendingFull，等这轮结束补一轮。只看这一轮的快照会拿到改动前的数据，
        // 表现就是「加了站点但卡片没出现」——定时刷新只做局部刷，永远等不到跟进。
        var wantFull = full || _pendingFull;
        _pendingFull = false;
        try
        {
            var snap = await Task.Run(() => _api.Invoke("snapshot"));
            Apply(snap, wantFull);
        }
        catch (Exception ex)
        {
            CookieMessage = "读取状态失败：" + ex.Message;
            Raise(nameof(CookieMessage), nameof(StatusText));
        }
        finally
        {
            _refreshing = false;
        }
        if (_pendingFull) await RefreshAsync(full: true);
    }

    /// <summary>首帧之前同步取一次快照。核心库就在本进程里，这一问一答只有几毫秒，
    /// 换来的是六个视图构造时配置、分组、站点已经就位（不必各防一遍 Config 还是 null），
    /// 窗口也不会先空一下再填上。</summary>
    public void Refresh()
    {
        _pendingFull = false;
        try
        {
            Apply(_api.Invoke("snapshot"), true);
        }
        catch (Exception ex)
        {
            CookieMessage = "读取状态失败：" + ex.Message;
            Raise(nameof(CookieMessage), nameof(StatusText));
        }
    }

    private void Apply(JsonNode snap, bool full)
    {
        Running = Bool(snap["run"]?["running"]);
        RunningStep = Str(snap["run"]?["step"]);
        LastReport = Str(snap["run"]?["lastReport"]);
        var busy = snap["busy"]?.AsObject();
        BusyCookieSync = Bool(busy?["cookieSync"]);
        BusyCookieCheck = Bool(busy?["cookieCheck"]);
        BusyDownloader = Bool(busy?["downloaderTest"]);
        BusyUpdate = Bool(busy?["update"]);
        BusySSH = Bool(busy?["sshTest"]);
        BusyAssist = Bool(busy?["assist"]);
        var msg = snap["messages"]?.AsObject();
        CookieMessage = Str(msg?["cookie"]);
        DownloaderMessage = Str(msg?["downloader"]);
        ZipMessage = Str(msg?["zip"]);
        UpdateMessage = Str(msg?["update"]);
        ConfigError = Str(msg?["config"]);
        LastGistSync = Str(msg?["lastGistSync"]);
        var upd = snap["update"]?.AsObject();
        HasUpdate = Bool(upd?["hasUpdate"]);
        UpdateVersion = Str(upd?["version"]);
        UpdateUrl = Str(upd?["url"]);
        UpdateDownloadUrl = Str(upd?["downloadURL"]);

        ReplaceFrom(RunSites, snap["run"]?["sites"], "site");
        ReplaceFrom(RunPushes, snap["run"]?["pushes"], "push");
        SourcePush = snap["run"]?["sourcePush"] is { } sp ? RunRow.From(sp!, "push") : null;

        var dl = snap["downloaders"]?.AsArray();
        if (dl != null)
        {
            Downloaders.Clear();
            foreach (var n in dl) Downloaders.Add(DownloaderRow.From(n!));
            ReseedDownloaderID = Text(snap["downloaderRoles"]?["reseed"]);
            AssistDownloaderID = Text(snap["downloaderRoles"]?["assist"]);
        }

        var assist = snap["assist"]?.AsObject();
        AssistRunning = Bool(assist?["running"]);
        AssistAutoNextMinutes = Num(assist?["autoRun"]?["nextInMinutes"]);
        AssistStep = Str(assist?["step"]);
        AssistReport = Str(assist?["report"]);
        ApplyAssistRows(assist?["rows"]);
        ApplyAssistStats(assist?["stats"]);
        ApplyAssistCoverage(assist?["coverage"]);
        ApplyAssistQueue(assist?["queue"]);
        ApplyAssistSiteProgress(assist?["siteProgress"]);
        ApplyAssistBudget(assist?["budget"]);

        var logs = snap["logs"]?.AsArray();
        if (logs != null && (Logs.Count != logs.Count || full))
        {
            Logs.Clear();
            foreach (var l in logs.TakeLast(300)) Logs.Add(l?.GetValue<string>() ?? "");
        }

        if (full)
        {
            Config = snap["config"]?.DeepClone()?.AsObject();
            Groups.Clear();
            foreach (var g in snap["groups"]?.AsArray() ?? new JsonArray()) Groups.Add(GroupRow.From(g!));
            Sites.Clear();
            foreach (var s in snap["sites"]?.AsArray() ?? new JsonArray()) Sites.Add(SiteRow.From(s!));
            _siteIndex = null;      // 行对象全换了，逐站索引跟着作废
            CookieHosts.Clear();
            foreach (var h in snap["cookies"]?["hosts"]?.AsArray() ?? new JsonArray())
                CookieHosts.Add(CookieHostRow.From(h!));
            CookieTotal = snap["cookies"]?["total"]?.GetValue<int>() ?? 0;
            ResyncZipTimer();
            FullRefreshed?.Invoke(this, EventArgs.Empty);
        }
        else ApplySiteStatus(snap["sites"]);
        Refreshed?.Invoke(this, EventArgs.Empty);
        Raise(nameof(Running), nameof(RunningStep), nameof(LastReport), nameof(CookieMessage),
              nameof(DownloaderMessage), nameof(ZipMessage), nameof(UpdateMessage), nameof(ConfigError),
              nameof(LastGistSync), nameof(HasUpdate), nameof(UpdateVersion), nameof(UpdateUrl),
              nameof(UpdateDownloadUrl), nameof(StatusText), nameof(CookieTotal),
              nameof(BusyCookieSync), nameof(BusyCookieCheck), nameof(BusyDownloader), nameof(BusyUpdate),
              nameof(ReseedDownloaderID), nameof(AssistDownloaderID),
              nameof(BusySSH), nameof(BusyAssist), nameof(AssistRunning),
              nameof(AssistStep), nameof(AssistReport), nameof(AssistAutoNextMinutes),
              nameof(AssistCoverageLine), nameof(AssistCoveragePercent), nameof(AssistNeedsAction),
              nameof(CurrentTheme));
    }

    // MARK: 自动同步开关（mac 版同名开关在界面上，只有 zip 监控落进配置）

    public bool GistAuto { get; private set; }
    public bool CookieCloudAuto { get; private set; }

    public void SetGistAuto(bool on)
    {
        GistAuto = on;
        _gistTask.Arm(on, SectionInt("gistSync", "pollMinutes", 30), 5);
        Raise(nameof(GistAuto));
    }

    public void SetCookieCloudAuto(bool on)
    {
        CookieCloudAuto = on;
        _ccTask.Arm(on, SectionInt("cookieCloud", "pollMinutes", 30), 5);
        Raise(nameof(CookieCloudAuto));
    }

    /// 备份目录监控：开关存在配置里，配置一变就按新间隔重挂
    private void ResyncZipTimer()
    {
        var want = (SectionFlag("zipWatch", "enabled"), Math.Max(1, SectionInt("zipWatch", "pollMinutes", 5)));
        if (_zipArmed == want) return;
        _zipArmed = want;
        _zipTask.Arm(want.Item1, want.Item2, 1);
    }

    private void ReplaceFrom(ObservableCollection<RunRow> target, JsonNode? array, string kind)
    {
        if (array == null) return;
        var rows = array.AsArray().Select(n => RunRow.From(n!, kind)).ToList();
        target.Clear();
        foreach (var r in rows) target.Add(r);
    }

    // MARK: 动作转发

    /// 用户改完一组字段后整体提交；patch 只带改动的那一段（如 {"downloader":{...}}）
    public void Patch(object patch)
    {
        Guard(() => _api.Invoke("config.patch", new { patch }));
        _ = RefreshAsync();
    }

    public void Call(string method, object? parameters = null)
    {
        Guard(() => _api.Invoke(method, parameters));
        _ = RefreshAsync();
    }

    /// 需要同步拿返回值的调用；返回 null 表示成功，否则是给用户看的一句原因
    public string? Try(string method, object? parameters = null)
    {
        _api.TryInvoke(method, out var error, parameters);
        return error;
    }

    /// 要走网络的动作都走这条：核心库就在本进程里，但同步一次 cookie 得等几秒网页请求，
    /// 直接在界面线程调用会把整个窗口挂成「未响应」（mac 版这些都在后台队列里跑）。
    /// 跑完补一次快照；返回 null 表示成功。
    public async Task<string?> TryAsync(string method, object? parameters = null)
    {
        var error = await Task.Run(() =>
        {
            _api.TryInvoke(method, out var err, parameters);
            return err;
        });
        await RefreshAsync(full: false);
        return error;
    }

    private Dictionary<string, SiteRow>? _siteIndex;

    /// cookie 检测结论逐站写回现有卡片。整站列表只在配置变化时重建，
    /// 只等重建的话，先检完的站也会一直停在「检测中」。
    private void ApplySiteStatus(JsonNode? array)
    {
        if (array is not JsonArray arr) return;
        foreach (var n in arr)
        {
            if (n is not JsonObject o) continue;
            var id = Text(o["id"]);
            if (id.Length == 0) continue;
            _siteIndex ??= Sites.ToDictionary(r => r.Id, r => r);
            if (_siteIndex.TryGetValue(id, out var row)) row.ApplyStatus(o);
        }
    }

    private static string Text(JsonNode? n) =>
        n is JsonValue v && v.TryGetValue<string>(out var t) ? t : "";

    /// <summary>表单保存：只提交当前区块那一节（downloader / gistSync / zipWatch …），
    /// 其余字段原样保留，避免界面各区块互相覆盖。</summary>
    public void PatchSection(string section, Action<JsonObject> edit)
    {
        var node = Config?[section]?.DeepClone() as JsonObject ?? new JsonObject();
        edit(node);
        Call("config.patch", new JsonObject { ["patch"] = new JsonObject { [section] = node } });
    }

    public string SectionText(string section, string field, string fallback = "") =>
        Config?[section]?[field] is JsonValue v && v.TryGetValue<string>(out var s) ? s : fallback;

    public bool SectionFlag(string section, string field, bool fallback = false) =>
        Config?[section]?[field] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : fallback;

    public int SectionInt(string section, string field, int fallback = 0) =>
        Config?[section]?[field] is JsonValue v && v.TryGetValue<int>(out var i) ? i : fallback;

    private void Guard(Func<JsonNode> call)
    {
        try { call(); }
        catch (Exception ex) { CookieMessage = ex.Message; Raise(nameof(CookieMessage), nameof(StatusText)); }
    }

    public void StartRun(string detailUrl, IEnumerable<string> targets, bool skipReseed, bool skipPush,
                         string sourceQuote, string? sourceSiteId)
    {
        Guard(() => _api.Invoke("run.start", new
        {
            detailURL = detailUrl,
            targets = targets.ToArray(),
            skipReseed,
            skipPush,
            sourceQuote,
            sourceSiteID = sourceSiteId,
        }));
        _ = RefreshAsync(full: false);
    }

    /// <summary>SSH 上传测速：核心库跑几十秒，丢给线程池；结果原样交给界面弹窗，不做判定。
    /// 返回 null 表示调用本身没成（没填服务器之类），Text 是给用户看的那句原因。</summary>
    public async Task<SshTestOutcome> TestSSHAsync()
    {
        var node = await Task.Run(() => _api.TryInvoke("ssh.test", out var error, null)
                                       ?? new JsonObject { ["ok"] = false, ["text"] = error ?? "测速没能启动" });
        if (node == null) return new SshTestOutcome(false, "测速没能启动，请检查 SSH 设置。", 0, false);
        return new SshTestOutcome(
            Bool(node["ok"]),
            Str(node["text"]),
            node["mbps"] is JsonValue mv && mv.TryGetValue<double>(out var d) ? d : 0,
            Bool(node["low"]));
    }

    /// 测速结果（速度、是否偏低、给用户看的一句话）
    public sealed record SshTestOutcome(bool Ok, string Text, double MBps, bool Low);

    /// 测速默认值（私钥路径、每轮数据量、测速地址、限速参考线）
    public sealed record SshDefaults(string KeyPath, int TestMB, string ProbeURL, double ThrottlingMBps);

    // MARK: 多下载器
    //
    // 发种推的那台和辅种扫的那台经常不是同一台机器，列表与用途指派都存在核心里。

    public void AddDownloader() => Call("downloaders.add");

    /// 删除一台（主下载器删不掉，核心库会给出原因）
    public string? RemoveDownloader(string id) => Try("downloaders.remove", new { id });

    public void AssignDownloader(string role, string id) => Call("downloaders.assign", new { role, id });

    /// 保存一台（按 id upsert）。逐站限速在站点分组页改，核心库会原样保留。
    public void SaveDownloader(JsonObject downloader) =>
        Call("downloaders.save", new JsonObject { ["downloader"] = downloader });

    public Task<string?> TestDownloaderAsync(string id) =>
        TryAsync("downloader.test", new { id });

    // MARK: 辅种
    //
    // 辅种不发新种：拿下载器里已有的文件去目标站找同一种子。站点请求节奏由核心库
    // 的节流器收口，界面只发起与显示；进展随快照一起回来，不必另开一条轮询。

    /// 快照里的下载器列表（主 + 附加），以及发种/辅种各用哪台
    public ObservableCollection<DownloaderRow> Downloaders { get; } = new();
    public string ReseedDownloaderID { get; private set; } = "main";
    public string AssistDownloaderID { get; private set; } = "main";

    public bool BusyAssist { get; private set; }
    public bool AssistRunning { get; private set; }
    /// 距下一轮定时辅种还有几分钟（没开定时为 0）
    public int AssistAutoNextMinutes { get; private set; }
    public string AssistStep { get; private set; } = "";
    public string AssistReport { get; private set; } = "";
    /// 逐行进展（按「站点|种子 hash」定位），扫描出的计划行由此上色
    public ObservableCollection<AssistRow> AssistRows { get; } = new();

    /// 5 组计数（核心库归好类）：已完成 / 待你处理 / 出问题 / 不用辅 / 没轮到。
    /// 12 个结论收成这 5 组，归法在核心库里，两端不各写一套
    public ObservableCollection<AssistBucketLine> AssistBuckets { get; } = new();
    public int AssistStatTotal { get; private set; }

    /// 待你处理：失败 / 待复核 / 待人工确认（核心库排好序，上限 200 条）
    public ObservableCollection<AssistQueueItem> AssistQueue { get; } = new();
    /// 你否决过的：界面收进「已处理」那一栏，不跟待办混在一列
    public ObservableCollection<AssistQueueItem> AssistHandled { get; } = new();

    /// 覆盖率那一句话与进度（0…1），文案由核心库给，两端一字不差
    public string AssistCoverageLine { get; private set; } = "";
    public double AssistCoveragePercent { get; private set; }
    public int AssistNeedsAction { get; private set; }

    private void ApplyAssistCoverage(JsonNode? node)
    {
        var o = node as JsonObject;
        var line = Str(o?["line"]);
        var percent = o?["percent"] is JsonValue v && v.TryGetValue<double>(out var d) ? d : 0;
        var action = Num(o?["needsAction"]);
        if (line == AssistCoverageLine && Math.Abs(percent - AssistCoveragePercent) < 0.0001
            && action == AssistNeedsAction) return;
        AssistCoverageLine = line;
        AssistCoveragePercent = percent;
        AssistNeedsAction = action;
        Raise(nameof(AssistCoverageLine), nameof(AssistCoveragePercent), nameof(AssistNeedsAction));
    }

    /// 队列条目不多（上限 200），结论有变就整表重建：比逐字段 diff 少一类对不齐的 bug
    private void ApplyAssistQueue(JsonNode? array)
    {
        var parsed = (array as JsonArray)?.Select(n => AssistQueueItem.From(n!)).ToList()
                       ?? new List<AssistQueueItem>();
        var fingerprint = string.Join("|", parsed.Select(AssistQueueItem.Fingerprint));
        if (parsed.Count == AssistQueue.Count + AssistHandled.Count
            && fingerprint == _queueFingerprint) return;
        _queueFingerprint = fingerprint;
        AssistQueue.Clear();
        AssistHandled.Clear();
        foreach (var p in parsed) (p.Handled ? AssistHandled : AssistQueue).Add(p);
    }

    private string _queueFingerprint = "";

    /// 逐站进度：一站一行（判定到哪、还要检索几次、这一轮先别动它）
    public ObservableCollection<AssistSiteRow> AssistSiteProgress { get; } = new();

    private string _progressFingerprint = "";

    /// 站点名单一百多行，一行有变就整表重建：比逐字段 diff 少一类对不齐的 bug
    private void ApplyAssistSiteProgress(JsonNode? array)
    {
        var parsed = (array as JsonArray)?.Select(n => AssistSiteRow.From(n!)).ToList()
                       ?? new List<AssistSiteRow>();
        // 有问题的站排前面，其余按「还要检索几次」
        parsed.Sort((a, b) => a.StateRank != b.StateRank
            ? a.StateRank.CompareTo(b.StateRank)
            : b.Searches != a.Searches
                ? b.Searches.CompareTo(a.Searches)
                : string.CompareOrdinal(a.SiteName, b.SiteName));
        var fingerprint = string.Join("|", parsed.Select(AssistSiteRow.Fingerprint));
        if (parsed.Count == AssistSiteProgress.Count && fingerprint == _progressFingerprint) return;
        _progressFingerprint = fingerprint;
        AssistSiteProgress.Clear();
        foreach (var p in parsed) AssistSiteProgress.Add(p);
    }

    /// 停止本轮：给核心库正在跑的那条流水线递个话，没在跑就是空操作
    public Task<string?> AssistStopAsync() => TryAsync("assist.stop", null);

    /// 追加本轮请求预算（只追次数上限，逐站间隔照旧）
    public Task<string?> AssistAddBudgetAsync(int add = 200) =>
        TryAsync("assist.budget", new { add });

    private int _assistBudgetUsed;
    private int _assistBudgetTotal;
    public int AssistBudgetUsed => _assistBudgetUsed;
    public int AssistBudgetTotal => _assistBudgetTotal;
    public string AssistBudgetLine => $"已请求 {_assistBudgetUsed:N0} / {_assistBudgetTotal:N0}";

    private void ApplyAssistBudget(JsonNode? node)
    {
        var used = Num(node?["used"]);
        var total = Num(node?["total"]);
        if (used == _assistBudgetUsed && total == _assistBudgetTotal) return;
        _assistBudgetUsed = used;
        _assistBudgetTotal = total;
        Raise(nameof(AssistBudgetUsed), nameof(AssistBudgetTotal), nameof(AssistBudgetLine));
    }

    public void ClearAssistRows() => AssistRows.Clear();

    private void ApplyAssistStats(JsonNode? node)
    {
        if (node is not JsonObject obj) return;
        // 界面摆的是 5 组；细分那 12 行留在核心库的 breakdown 文案里挂悬停提示
        var lines = obj["buckets"]?.AsArray();
        if (lines == null) return;
        var parsed = lines.OfType<JsonObject>().Select(o => (
            Bucket: Text(o["bucket"]), Label: Text(o["label"]), Count: Num(o["count"]),
            Detail: Text(o["detail"]))).ToList();
        AssistStatTotal = Num(obj["total"]);
        // 顺序固定、只改数字：整表重建会让界面在跑动中闪一下
        while (AssistBuckets.Count < parsed.Count) AssistBuckets.Add(new AssistBucketLine());
        while (AssistBuckets.Count > parsed.Count) AssistBuckets.RemoveAt(AssistBuckets.Count - 1);
        for (var i = 0; i < parsed.Count; i++)
            AssistBuckets[i].Apply(parsed[i].Bucket, parsed[i].Label, parsed[i].Count, parsed[i].Detail);
    }

    private void ApplyAssistRows(JsonNode? array)
    {
        if (array is not JsonArray arr) return;
        foreach (var n in arr)
        {
            if (n is not JsonObject o) continue;
            var key = Text(o["key"]);
            if (key.Length == 0) continue;
            var row = AssistRows.FirstOrDefault(r => r.Key == key);
            if (row == null)
            {
                row = new AssistRow { Key = key };
                AssistRows.Add(row);
            }
            row.Apply(o);
        }
    }

    /// 扫描下载器并生成本轮计划。只读：不动下载器，也不发站点请求。
    public async Task<(JsonNode? Node, string? Error)> AssistScanAsync(string[]? siteIDs)
    {
        string? error = null;
        var node = await Task.Run(() => _api.TryInvoke("assist.scan", out error,
            siteIDs is { Length: > 0 } ? new { siteIDs } : null));
        await RefreshAsync(full: false);
        return (node, node == null ? error ?? "扫描下载器失败" : null);
    }

    /// 开始辅种：默认只跑界面上这一页（torrentHashes），整库一轮交给定时任务
    public Task<string?> AssistStartAsync(string[] siteIDs, bool dryRun, string[]? forceKeys = null,
                                         string[]? torrentHashes = null) =>
        TryAsync("assist.start", new { siteIDs, dryRun, forceKeys, torrentHashes });

    /// 翻页：核心库里存着上次扫描的目录与计数，换一页不必重读下载器
    public async Task<(JsonNode? Node, string? Error)> AssistPageAsync(int page)
    {
        string? error = null;
        var node = await Task.Run(() => _api.TryInvoke("assist.page", out error, new { page }));
        await RefreshAsync(full: false);
        return (node, node == null ? error ?? "翻页失败" : null);
    }

    /// 人工采纳一条「待人工确认」：只重跑这一条，负缓存与「已辅过」预筛都让路
    public Task<string?> AssistConfirmAsync(string key) =>
        TryAsync("assist.confirm", new { key });

    /// 回查校验：只问下载器，一次站点请求都不发。回来的载荷与翻页同形，界面直接重画
    public async Task<(JsonNode? Node, string? Error)> AssistRecheckAsync(string[]? keys = null)
    {
        string? error = null;
        var node = await Task.Run(() => _api.TryInvoke("assist.recheck", out error,
            keys is { Length: > 0 } ? new { keys } : null));
        await RefreshAsync(full: false);
        return (node, node == null ? error ?? "回查校验失败" : null);
    }

    /// 人工否决 / 撤销否决一条组合：核心库只改状态表，回来的载荷已按新结论重算
    public async Task<(JsonNode? Node, string? Error)> AssistRejectAsync(string key, bool rejected)
    {
        string? error = null;
        var node = await Task.Run(() => _api.TryInvoke("assist.reject", out error, new { key, rejected }));
        await RefreshAsync(full: false);
        return (node, node == null ? error ?? "这条没改动" : null);
    }

    /// 重试一条失败的组合：只跑这一格
    public Task<string?> AssistRetryAsync(string siteID, string hash) =>
        TryAsync("assist.start", new
        {
            siteIDs = new[] { siteID }, dryRun = false,
            forceKeys = Array.Empty<string>(), torrentHashes = new[] { hash },
        });

    /// 到点问一句核心库：该跑就跑，没到点它什么都不做
    private async Task AssistTickAsync()
    {
        if (BusyAssist || SectionInt("assist", "autoRunMinutes", 0) <= 0) return;
        await RunInBackground("assist.tick", null);
    }

    public void Raise(params string[] names)
    {
        foreach (var n in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }

    // 核心库给的字段都是显式类型；取不到就按空串/false 处理，界面不留 null 分支
    private static string Str(JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";

    private static bool Bool(JsonNode? n) => n is JsonValue v && v.TryGetValue<bool>(out var b) && b;

    private static int Num(JsonNode? n)
    {
        if (n is not JsonValue v) return 0;
        if (v.TryGetValue<int>(out var i)) return i;
        if (v.TryGetValue<long>(out var l)) return (int)l;
        if (v.TryGetValue<double>(out var d)) return (int)d;
        return 0;
    }

    public void Dispose()
    {
        _timer.Stop();
        _assistTickTimer.Stop();
        _gistTask.Stop();
        _ccTask.Stop();
        _zipTask.Stop();
        _api.Dispose();
    }
}

/// <summary>主题（色值来自核心库 ThemeCatalog，两端共用）</summary>
public sealed class ThemeRow
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public string[] Colors { get; init; } = Array.Empty<string>();
    public string Accent { get; init; } = "#4fc3f7";
    public bool Dark { get; init; }

    public static ThemeRow From(JsonNode n) => new()
    {
        Id = n["id"]?.GetValue<string>() ?? "",
        Name = n["name"]?.GetValue<string>() ?? "",
        Colors = (n["colors"]?.AsArray() ?? new JsonArray()).Select(c => c?.GetValue<string>() ?? "").ToArray(),
        Accent = n["accent"]?.GetValue<string>() ?? "#4fc3f7",
        Dark = n["dark"]?.GetValue<bool>() ?? true,
    };

    public static ThemeRow Fallback => new()
    {
        Id = "deepBlue", Name = "深空蓝", Colors = new[] { "#0f2027", "#203a43", "#2c5364" },
        Accent = "#4fc3f7", Dark = true,
    };
}

public sealed class GroupRow
{
    public int Index { get; init; }
    public string Name { get; init; } = "";
    public int UpLimitMB { get; init; }
    public string[] SiteIds { get; init; } = Array.Empty<string>();
    public override string ToString() => Name;
    public static GroupRow From(JsonNode n) => new()
    {
        Index = n["index"]?.GetValue<int>() ?? 0,
        Name = n["name"]?.GetValue<string>() ?? "",
        UpLimitMB = n["upLimitMB"]?.GetValue<int>() ?? 0,
        SiteIds = (n["sites"]?.AsArray() ?? new JsonArray())
            .Select(s => s?.GetValue<string>() ?? "").ToArray(),
    };
}

/// <summary>一个站点的卡片数据。cookie 检测结论会随每一次刷新变（未检测 → 检测中 → 已登录/失效），
/// 这几项做成可通知属性：整页不重建也能看到本站状态变化。</summary>
public sealed class SiteRow : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public string Url { get; init; } = "";
    public string Framework { get; init; } = "";
    public bool Enabled { get; init; }
    public bool Managed { get; init; }
    /// <summary>在辅种名单里（「站点分组」页底部的辅种区块显示）</summary>
    public bool Assist { get; init; }
    public int Group { get; init; }
    public int IndexInBlock { get; init; }
    public int BlockSize { get; init; }
    public bool UsesApiKey { get; init; }
    public bool HasApiKey { get; init; }
    private int _cookieCount;
    private bool _hasCookie;
    private string _warning = "";
    private string _checkMessage = "";
    private bool? _checkOk;
    private bool _checking;

    public int CookieCount
    {
        get => _cookieCount;
        private set { if (_cookieCount == value) return; _cookieCount = value; Raise(nameof(CookieCount)); }
    }
    public bool HasCookie
    {
        get => _hasCookie;
        private set { if (_hasCookie == value) return; _hasCookie = value; Raise(nameof(HasCookie)); }
    }
    public int UpLimitMB { get; init; }
    public string Warning
    {
        get => _warning;
        private set { if (_warning == value) return; _warning = value; Raise(nameof(Warning)); }
    }
    public bool NeedsSourceQuote { get; init; }
    /// <summary>站内有「帖子免费1天」按钮，卡片上才出现「发种后免费一天」开关</summary>
    public bool SupportsAutoFree { get; init; }
    public bool AutoFree { get; init; }
    public string CheckMessage
    {
        get => _checkMessage;
        private set { if (_checkMessage == value) return; _checkMessage = value; Raise(nameof(CheckMessage)); }
    }
    public bool? CheckOk
    {
        get => _checkOk;
        private set { if (_checkOk == value) return; _checkOk = value; Raise(nameof(CheckOk)); }
    }

    /// 这一站正在检测（核心每批并发检 4 个站，界面逐站显示，不是整页一个「检测中」）
    public bool Checking
    {
        get => _checking;
        private set { if (_checking == value) return; _checking = value; Raise(nameof(Checking)); }
    }

    /// 检测结论单独一句（弹窗状态行用，失效时带上原因）
    public string CheckText => Checking ? "检测中"
        : CheckOk == null ? "未检测" : CheckOk == true ? "有效" : CheckMessage;

    /// 卡片状态行：与 mac 版同一套说法，不写 cookie 条数（条数容易被读成站点数）
    public string CredentialText => UsesApiKey
        ? HasApiKey
            ? Checking ? "API 检测中…"
                : CheckOk == null ? "API Key 已配置（未检测）" : CheckOk == true ? "API 已连接" : "API Key 失效"
            : "未配置 API Key"
        : Checking ? "cookie 检测中…"
            : !HasCookie ? "无 cookie"
            : CheckOk == null ? "未检测" : CheckOk == true ? "已登录" : "cookie 失效";

    /// 状态行用哪一档颜色：只有这一站检测通过才给强调色
    public string StatusTone => CheckOk == true && !Checking ? "Accent" : "TextMuted";

    /// 局部刷新：把快照里这一站的检测状态写进现有卡片（整站列表只在配置变化时重建）
    public void ApplyStatus(JsonObject n)
    {
        bool? ok = null;
        if (n["check"]?["ok"] is JsonValue v && v.TryGetValue<bool>(out var b)) ok = b;
        CheckOk = ok;
        CheckMessage = Text(n["check"]?["message"]);
        Checking = Yes(n["checking"]);
        HasCookie = Yes(n["hasCookie"]);
        CookieCount = n["cookieCount"] is JsonValue nv && nv.TryGetValue<int>(out var cnt) ? cnt : 0;
        Warning = Text(n["warning"]);
        Raise(nameof(CredentialText));
        Raise(nameof(CheckText));
        Raise(nameof(StatusTone));
    }

    private void Raise(string name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private static string Text(JsonNode? n) =>
        n is JsonValue v && v.TryGetValue<string>(out var t) ? t : "";

    private static bool Yes(JsonNode? n) =>
        n is JsonValue v && v.TryGetValue<bool>(out var b) && b;

    /// 弹窗里对当前凭据的一句说明
    public string CookieText => UsesApiKey ? (HasApiKey ? "已填 API Key" : "未填 API Key")
        : HasCookie ? "已有 cookie" : "无 cookie";

    /// 下拉框直接把行对象当项用（源站选择、手动填 cookie），没有这句会显示类名
    public override string ToString() => Name;

    public bool CanMoveUp => IndexInBlock > 0;
    public bool CanMoveDown => IndexInBlock >= 0 && IndexInBlock < BlockSize - 1;

    public static SiteRow From(JsonNode n)
    {
        // 未检测过时核心库给的是 JSON null，这里保持 null（界面显示「未检测」）
        bool? ok = null;
        if (n["check"]?["ok"] is JsonValue ov && ov.TryGetValue<bool>(out var b)) ok = b;
        return new SiteRow
        {
            Id = n["id"]?.GetValue<string>() ?? "",
            Name = n["name"]?.GetValue<string>() ?? "",
            Url = n["url"]?.GetValue<string>() ?? "",
            Framework = n["framework"]?.GetValue<string>() ?? "",
            Enabled = n["enabled"]?.GetValue<bool>() ?? false,
            Managed = n["managed"]?.GetValue<bool>() ?? false,
            Assist = n["assist"]?.GetValue<bool>() ?? false,
            Group = n["group"]?.GetValue<int>() ?? -1,
            IndexInBlock = n["indexInBlock"]?.GetValue<int>() ?? -1,
            BlockSize = n["blockSize"]?.GetValue<int>() ?? 0,
            UsesApiKey = n["usesAPIKey"]?.GetValue<bool>() ?? false,
            HasApiKey = n["hasAPIKey"]?.GetValue<bool>() ?? false,
            CookieCount = n["cookieCount"]?.GetValue<int>() ?? 0,
            HasCookie = n["hasCookie"]?.GetValue<bool>() ?? false,
            UpLimitMB = n["upLimitMB"]?.GetValue<int>() ?? 0,
            Warning = n["warning"]?.GetValue<string>() ?? "",
            NeedsSourceQuote = n["needsSourceQuote"]?.GetValue<bool>() ?? false,
            SupportsAutoFree = n["supportsAutoFree"]?.GetValue<bool>() ?? false,
            AutoFree = n["autoFree"]?.GetValue<bool>() ?? false,
            CheckMessage = n["check"]?["message"]?.GetValue<string>() ?? "",
            CheckOk = ok,
            Checking = Yes(n["checking"]),
        };
    }
}

public sealed class CookieHostRow
{
    public string Host { get; init; } = "";
    public int Count { get; init; }
    public override string ToString() => $"{Host}（{Count} 条）";
    public static CookieHostRow From(JsonNode n) => new()
    {
        Host = n["host"]?.GetValue<string>() ?? "",
        Count = n["count"]?.GetValue<int>() ?? 0,
    };
}

/// <summary>转种页的逐站状态（阶段 + 主文案 + 详情行）</summary>
/// 一台下载器（快照 downloaders 里的一项）
public sealed class DownloaderRow
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public string Label { get; init; } = "";
    public string Type { get; init; } = "qbittorrent";
    public string Url { get; init; } = "";
    public string Username { get; init; } = "";
    public string Password { get; init; } = "";
    public string SavePath { get; init; } = "";
    public string Category { get; init; } = "";
    public bool SkipChecking { get; init; } = true;
    public long DefaultUpLimit { get; init; }
    public string PushPolicy { get; init; } = "always";
    public int VpsFreeGB { get; init; }
    public string SizeGuardMode { get; init; } = "warn";
    public int SizeGuardMarginGB { get; init; } = 5;
    public bool IsMain { get; init; }

    public override string ToString() => Label;

    public static DownloaderRow From(JsonNode n)
    {
        var o = n.AsObject();
        var name = o["name"]?.GetValue<string>() ?? "";
        return new DownloaderRow
        {
            Id = o["id"]?.GetValue<string>() ?? "main",
            Name = name,
            Label = o["label"]?.GetValue<string>() ?? (name.Length > 0 ? name : "下载器"),
            Type = o["type"]?.GetValue<string>() ?? "qbittorrent",
            Url = o["url"]?.GetValue<string>() ?? "",
            Username = o["username"]?.GetValue<string>() ?? "",
            Password = o["password"]?.GetValue<string>() ?? "",
            SavePath = o["savePath"]?.GetValue<string>() ?? "",
            Category = o["category"]?.GetValue<string>() ?? "",
            SkipChecking = o["skipChecking"]?.GetValue<bool>() ?? true,
            DefaultUpLimit = o["defaultUpLimit"]?.GetValue<long>() ?? 0,
            PushPolicy = o["pushPolicy"]?.GetValue<string>() ?? "always",
            VpsFreeGB = o["vpsFreeGB"] is JsonValue fv && fv.TryGetValue<int>(out var gi) ? gi : 0,
            SizeGuardMode = o["sizeGuardMode"]?.GetValue<string>() ?? "warn",
            SizeGuardMarginGB = o["sizeGuardMarginGB"]?.GetValue<int>() ?? 5,
            IsMain = o["isMain"]?.GetValue<bool>() ?? false,
        };
    }
}

/// 辅种逐行进展。计划行由 assist.scan 给出，这里的文本/阶段随快照更新。
public sealed class AssistRow : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    public string Key { get; init; } = "";
    public string SiteId => Key.Split('|')[0];

    private string _text = "";
    private string _detail = "";
    private string _phase = "";

    public string Text
    {
        get => _text;
        private set { if (_text == value) return; _text = value; Raise(nameof(Text)); }
    }
    public string Detail
    {
        get => _detail;
        private set { if (_detail == value) return; _detail = value; Raise(nameof(Detail)); }
    }
    public string Phase
    {
        get => _phase;
        private set
        {
            if (_phase == value) return;
            _phase = value;
            Raise(nameof(Phase));
            Raise(nameof(PhaseText));
        }
    }

    private string _status = "";
    private string _statusText = "";

    /// 这一格的归类（assisted / pending / failed…），界面按它上色
    public string Status
    {
        get => _status;
        private set { if (_status == value) return; _status = value; Raise(nameof(Status)); Raise(nameof(Tone)); }
    }

    /// 归类对应的两个字（已辅种 / 待辅种 / 不存在…）：核心库给的，不在这里另翻一套
    public string StatusText
    {
        get => _statusText;
        private set { if (_statusText == value) return; _statusText = value; Raise(nameof(StatusText)); }
    }

    /// 归到界面上的 5 组之一（done / action / trouble / skip / waiting）：核心库给的
    public string Bucket { get; private set; } = "";

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

    public string PhaseText => Phase switch
    {
        "working" => "检索中",
        "verifying" => "校验中",
        "review" => "待复核",
        "done" => "已辅种",
        "failed" => "失败",
        "skipped" => "跳过",
        _ => "",
    };

    public void Apply(JsonObject o)
    {
        Bucket = o["bucket"]?.GetValue<string>() ?? Bucket;
        Text = o["text"]?.GetValue<string>() ?? "";
        Detail = o["detail"]?.GetValue<string>() ?? "";
        Phase = o["phase"]?.GetValue<string>() ?? "";
        Status = o["status"]?.GetValue<string>() ?? "";
        StatusText = o["statusText"]?.GetValue<string>() ?? "";
    }

    private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// 一个站的辅种进度。暂停开关由界面写回配置的 assist.pausedSites，这里只管显示。
public sealed class AssistSiteRow
{
    public string SiteID { get; init; } = "";
    public string SiteName { get; init; } = "";
    public int Total { get; init; }
    public int Resolved { get; init; }
    public int Searches { get; init; }
    public int Failed { get; init; }
    public int Review { get; init; }
    public bool Unsupported { get; init; }
    public bool Paused { get; init; }
    public double Percent { get; init; }
    /// 这一站归哪一组（trouble / review / queued / paused / done / unsupported）：核心库判的
    public string State { get; init; } = "queued";
    /// 卡片排列名次：有问题的排前面（核心库给的 SiteState.rank）
    public int StateRank { get; init; } = 2;
    /// 悬停那句（站名｜归组 + 判定 + 问题）
    public string StateLabel { get; init; } = "";
    /// 卡片那两行字：文案由核心库给，两端一字不差
    public string Line { get; init; } = "";
    /// 第三行：接下来还有多少活儿（暂停站说清压着多少格）
    public string NextLine { get; init; } = "";
    public string Warn { get; init; } = "";

    public string Tip => $"{SiteName}｜{StateLabel}\n{Line}"
        + (NextLine.Length > 0 ? $"　{NextLine}" : "")
        + (Warn.Length > 0 ? $"\n{Warn}" : "");
    public bool HasNext => NextLine.Length > 0;
    public bool HasWarn => Warn.Length > 0;
    public bool HasBar => !Unsupported;
    /// 「还有活儿」：没检索完，或暂停站里压着没结论
    public bool IsBusy => !Unsupported && (Searches > 0 || Paused);
    public string PauseText => Paused ? "继续" : "暂停";
    public string PauseTip => (Paused ? "取消暂停：下一轮这一站接着检索"
        : "暂停这一站：这一轮不去敲门，格子仍算欠着") + "；点卡片任意处都可以";

    public static AssistSiteRow From(JsonNode n) => new()
    {
        SiteID = n["siteID"]?.GetValue<string>() ?? "",
        SiteName = n["siteName"]?.GetValue<string>() ?? "",
        Total = n["total"]?.GetValue<int>() ?? 0,
        Resolved = n["resolved"]?.GetValue<int>() ?? 0,
        Searches = n["searches"]?.GetValue<int>() ?? 0,
        Failed = n["failed"]?.GetValue<int>() ?? 0,
        Review = n["review"]?.GetValue<int>() ?? 0,
        Unsupported = n["unsupported"]?.GetValue<bool>() ?? false,
        Paused = n["pausedSite"]?.GetValue<bool>() ?? false,
        Percent = n["percent"] is JsonValue v && v.TryGetValue<double>(out var d) ? d : 0,
        State = n["state"]?.GetValue<string>() ?? "queued",
        StateRank = n["stateRank"]?.GetValue<int>() ?? 2,
        StateLabel = n["stateLabel"]?.GetValue<string>() ?? "",
        Line = n["stateLine"]?.GetValue<string>() ?? "",
        NextLine = n["nextLine"]?.GetValue<string>() ?? "",
        Warn = n["warnLine"]?.GetValue<string>() ?? "",
    };

    public static string Fingerprint(AssistSiteRow p) =>
        $"{p.SiteID}#{p.Resolved}#{p.Searches}#{p.Failed}#{p.Review}#{p.Paused}"
        + $"#{p.Unsupported}#{p.State}#{p.NextLine}#{p.Warn}";
}

/// 待处理队列的一行：站名、种子、结论、原因，外加这一条能点什么
public sealed class AssistQueueItem
{
    public string Key { get; init; } = "";
    public string SiteID { get; init; } = "";
    public string SiteName { get; init; } = "";
    public string Hash { get; init; } = "";
    public string TorrentName { get; init; } = "";
    public string Status { get; init; } = "";
    public string StatusText { get; init; } = "";
    public string Why { get; init; } = "";
    public string Time { get; init; } = "";
    public string Url { get; init; } = "";
    public bool CanAdopt { get; init; }
    public bool CanRetry { get; init; }
    public bool CanRecheck { get; init; }
    public bool CanUndo { get; init; }
    public bool CanReject { get; init; }
    /// 人已经表过态（否决）：归到「已处理」那一栏
    public bool Handled { get; init; }

    public string Tone => Status switch
    {
        "failed" => "DangerText",
        "review" => "Review",
        "manual" => "Warning",
        _ => "TextMuted",
    };

    /// 用来判断这一行有没有变（结论、原因、按钮任一项变了就重画）
    public static string Fingerprint(AssistQueueItem i) =>
        $"{i.Key}#{i.Status}#{i.Why}#{i.Handled}#{i.CanAdopt}{i.CanRetry}{i.CanRecheck}{i.CanUndo}{i.CanReject}";

    public static AssistQueueItem From(JsonNode n) => new()
    {
        Key = n["key"]?.GetValue<string>() ?? "",
        SiteID = n["siteID"]?.GetValue<string>() ?? "",
        SiteName = n["siteName"]?.GetValue<string>() ?? "",
        Hash = n["hash"]?.GetValue<string>() ?? "",
        TorrentName = n["torrentName"]?.GetValue<string>() ?? "",
        Status = n["status"]?.GetValue<string>() ?? "",
        StatusText = n["statusText"]?.GetValue<string>() ?? "",
        Why = n["why"]?.GetValue<string>() ?? "",
        Time = n["time"]?.GetValue<string>() ?? "",
        Url = n["url"]?.GetValue<string>() ?? "",
        CanAdopt = n["canAdopt"]?.GetValue<bool>() ?? false,
        CanRetry = n["canRetry"]?.GetValue<bool>() ?? false,
        CanRecheck = n["canRecheck"]?.GetValue<bool>() ?? false,
        CanUndo = n["canUndo"]?.GetValue<bool>() ?? false,
        CanReject = n["canReject"]?.GetValue<bool>() ?? false,
        Handled = n["handled"]?.GetValue<bool>() ?? (n["status"]?.GetValue<string>() == "rejected"),
    };
}

/// 计数牌的一格：5 组之一，标签与细分说明都由核心库给（mac 与 Windows 同一份文案）
public sealed class AssistBucketLine : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    public string Bucket { get; private set; } = "";
    public string Label { get; private set; } = "";
    /// 这一组里细分的结论（「已完成辅种 12，校验中 3」）
    public string Tip { get; private set; } = "";

    private int _count;
    public int Count
    {
        get => _count;
        private set { if (_count == value) return; _count = value; Raise(nameof(Count)); }
    }

    public string Tone => Bucket switch
    {
        "done" => "Success",
        "trouble" => "DangerText",
        "action" => "Warning",
        _ => "TextMuted",
    };

    public void Apply(string bucket, string label, int count, string detail)
    {
        Bucket = bucket;
        Label = label;
        Count = count;
        Tip = detail;
        Raise(nameof(Bucket));
        Raise(nameof(Label));
        Raise(nameof(Tip));
        Raise(nameof(Tone));
    }

    private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public sealed class RunRow
{
    public int Seq { get; init; }
    public string Kind { get; init; } = "site";
    public string SiteId { get; init; } = "";
    public string Text { get; init; } = "";
    public string Detail { get; init; } = "";
    public string Phase { get; init; } = "";
    /// 站内那条种子的详情页（转种成功 / 已推送 / 站内已有时才有）
    public string Url { get; init; } = "";

    public string PhaseText => Phase switch
    {
        "working" => "进行中",
        "done" => "完成",
        "exists" => "已存在",
        "failed" => "失败",
        _ => "",
    };

    public static RunRow From(JsonNode n, string kind) => new()
    {
        Seq = n["seq"]?.GetValue<int>() ?? 0,
        Kind = n["kind"]?.GetValue<string>() ?? kind,
        SiteId = n["site"]?.GetValue<string>() ?? "",
        Text = n["text"]?.GetValue<string>() ?? "",
        Detail = n["detail"]?.GetValue<string>() ?? "",
        Phase = n["phase"]?.GetValue<string>() ?? "",
        Url = n["url"]?.GetValue<string>() ?? "",
    };
}
