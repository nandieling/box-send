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
    private bool _fullWhilePartial;

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
        foreach (var g in Groups) Groups.Remove(g);

        _timer = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(600)
        };
        _timer.Tick += async (_, _) => await RefreshAsync(full: false);

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

    public BoxSendApi Api => _api;
    public string Platform { get; }
    public string CoreVersion { get; }
    public string ConfigPath { get; }
    public string DataDir { get; }

    public ObservableCollection<ThemeRow> Themes { get; } = new();
    public ObservableCollection<GroupRow> Groups { get; } = new();
    public ObservableCollection<SiteRow> Sites { get; } = new();
    public ObservableCollection<CookieHostRow> CookieHosts { get; } = new();
    public ObservableCollection<string> Logs { get; } = new();
    public ObservableCollection<RunRow> RunSites { get; } = new();
    public ObservableCollection<RunRow> RunPushes { get; } = new();
    public RunRow? SourcePush { get; private set; }

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
            if (full) _fullWhilePartial = true;
            return;
        }
        _refreshing = true;
        try
        {
            var snap = await Task.Run(() => _api.Invoke("snapshot"));
            Apply(snap, full || _fullWhilePartial);
            _fullWhilePartial = false;
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
            CookieHosts.Clear();
            foreach (var h in snap["cookies"]?["hosts"]?.AsArray() ?? new JsonArray())
                CookieHosts.Add(CookieHostRow.From(h!));
            CookieTotal = snap["cookies"]?["total"]?.GetValue<int>() ?? 0;
            ResyncZipTimer();
            FullRefreshed?.Invoke(this, EventArgs.Empty);
        }
        Raise(nameof(Running), nameof(RunningStep), nameof(LastReport), nameof(CookieMessage),
              nameof(DownloaderMessage), nameof(ZipMessage), nameof(UpdateMessage), nameof(ConfigError),
              nameof(LastGistSync), nameof(HasUpdate), nameof(UpdateVersion), nameof(UpdateUrl),
              nameof(UpdateDownloadUrl), nameof(StatusText), nameof(CookieTotal),
              nameof(BusyCookieSync), nameof(BusyCookieCheck), nameof(BusyDownloader), nameof(BusyUpdate),
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

    public void Raise(params string[] names)
    {
        foreach (var n in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }

    // 核心库给的字段都是显式类型；取不到就按空串/false 处理，界面不留 null 分支
    private static string Str(JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";

    private static bool Bool(JsonNode? n) => n is JsonValue v && v.TryGetValue<bool>(out var b) && b;

    public void Dispose()
    {
        _timer.Stop();
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

public sealed class SiteRow
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public string Url { get; init; } = "";
    public string Framework { get; init; } = "";
    public bool Enabled { get; init; }
    public bool Managed { get; init; }
    public int Group { get; init; }
    public int IndexInBlock { get; init; }
    public int BlockSize { get; init; }
    public bool UsesApiKey { get; init; }
    public bool HasApiKey { get; init; }
    public int CookieCount { get; init; }
    public bool HasCookie { get; init; }
    public int UpLimitMB { get; init; }
    public string Warning { get; init; } = "";
    public bool NeedsSourceQuote { get; init; }
    public string CheckMessage { get; init; } = "";
    public bool? CheckOk { get; init; }

    /// 状态徽标文字（与 mac 版一致：未检测 / 有效 / 失效 + 原因）
    public string CheckText => CheckOk == null ? "未检测" : CheckOk == true ? "有效" : CheckMessage;
    public string CookieText => UsesApiKey ? (HasApiKey ? "已填 Key" : "缺 Key")
        : HasCookie ? $"{CookieCount} 条 cookie" : "无 cookie";
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
            CheckMessage = n["check"]?["message"]?.GetValue<string>() ?? "",
            CheckOk = ok,
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
public sealed class RunRow
{
    public int Seq { get; init; }
    public string Kind { get; init; } = "site";
    public string SiteId { get; init; } = "";
    public string Text { get; init; } = "";
    public string Detail { get; init; } = "";
    public string Phase { get; init; } = "";

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
    };
}
