using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using BoxSend.Windows.Interop;

// 加载核心库，走完 WPF 界面开机要走的那几条路径：
// version -> snapshot -> 建组 -> 加站 -> 组限速继承 -> 配置补丁 -> 事件流 -> 错误传递。
// 全绿说明 C ABI 声明、UTF-8 字符串归属、OCR 回调整个链路在 .NET 侧是对的。

var failed = 0;

void Check(string name, bool ok, string detail = "")
{
    Console.WriteLine((ok ? "PASS  " : "FAIL  ") + name + (ok || detail.Length == 0 ? "" : "  <- " + detail));
    if (!ok) failed++;
}

var dir = Path.Combine(Path.GetTempPath(), "boxsend-abi-" + Guid.NewGuid().ToString("N")[..8]);
Directory.CreateDirectory(dir);
var configPath = Path.Combine(dir, "config.json");

// OCR 回调约定：宿主往核心给的缓冲区里写候选（换行分隔），返回写入字节数
BoxSendApi.OcrCallback ocr = (image, imageLength, buffer, capacity) =>
{
    if (imageLength <= 0 || buffer == IntPtr.Zero) return 0;
    var bytes = Encoding.UTF8.GetBytes("k6kk\nk6k");
    if (bytes.Length + 1 > capacity) return 0;
    Marshal.Copy(bytes, 0, buffer, bytes.Length);
    Marshal.WriteByte(buffer, bytes.Length, 0);
    return bytes.Length;
};

using var api = new BoxSendApi(configPath, dir, ocr);

var version = api.Invoke("version");
Check("version 返回平台与版本", version["platform"]!.GetValue<string>().Length > 0, version.ToJsonString());
Check("主题表随 version 下发（6 套）", version["themes"]!.AsArray().Count == 6);

var snap = api.Invoke("snapshot");
foreach (var key in new[] { "config", "cookies", "sites", "groups", "run", "busy", "messages", "logs" })
    Check("snapshot 含 " + key, snap[key] is not null);
var sites = snap["sites"]!.AsArray();
Check("空配置也带出内置站点模板", sites.Count > 0, sites.Count + " 个站点");

var firstSiteId = sites[0]!["id"]!.GetValue<string>();

var added = api.Invoke("groups.add", new JsonObject { ["name"] = "源站", ["upLimitMB"] = 5 });
Check("groups.add 建组成功", Names(added).Contains("源站"), Names(added));

var withSite = api.Invoke("sites.add", new JsonObject
{
    ["ids"] = new JsonArray(firstSiteId),
    ["group"] = 0,
});
var row = SiteById(withSite, firstSiteId);
Check("sites.add 把站点放进分组", row?["group"]!.GetValue<int>() == 0, row?.ToJsonString() ?? "站点不见了");
Check("加入分组后站点自动启用", row?["enabled"]!.GetValue<bool>() == true);
Check("站点继承分组限速 5 MB/s", row?["upLimitMB"]!.GetValue<int>() == 5,
      row?["upLimitMB"]!.ToJsonString() ?? "");

api.Invoke("groups.add", new JsonObject { ["name"] = "推送", ["upLimitMB"] = 0 });
// 撞名规则：改名撞上别的组才加序号，改成自己的名字算无操作
var renamed = api.Invoke("groups.rename", new JsonObject { ["index"] = 1, ["name"] = "源站" });
Check("改名撞上别的分组时自动加序号", RenamedToDuplicate(renamed, "源站"), Names(renamed));
var noop = api.Invoke("groups.rename", new JsonObject { ["index"] = 0, ["name"] = "源站" });
Check("改回自己的名字不加序号", Names(noop).Split(',')[0].Trim() == "源站", Names(noop));

var targets = api.Invoke("targets.set", new JsonObject { ["ids"] = new JsonArray(firstSiteId) });
Check("targets.set 写入转种目标", SiteById(targets, firstSiteId)?["managed"]!.GetValue<bool>() == true);

var patched = api.Invoke("config.patch", new JsonObject { ["patch"] = new JsonObject
{
    ["sourceQuoteEnabled"] = true,
    ["sourceQuoteText"] = "转载自 测试站",
} });
var cfg = patched["config"]!.AsObject();
Check("config.patch 覆盖给出的字段", cfg["sourceQuoteEnabled"]!.GetValue<bool>());
Check("config.patch 保留未给出的字段", cfg["sourceSites"]!.AsArray().Count == sites.Count);

var reread = api.Invoke("snapshot");
Check("补丁已落盘（重新读取仍在）",
      reread["config"]!["sourceQuoteEnabled"]!.GetValue<bool>() &&
      reread["config"]!["sourceQuoteText"]!.GetValue<string>() == "转载自 测试站");

var events = api.Invoke("events", new JsonObject { ["since"] = 0 })["events"]!.AsArray();
Check("事件流带序号", events.Count == 0 || events[0]!["seq"] is not null, events.ToJsonString());

var since = events.Count > 0 ? events[^1]!["seq"]!.GetValue<int>() : 0;
var again = api.Invoke("events", new JsonObject { ["since"] = since })["events"]!.AsArray();
Check("事件游标不重复推送", again.Count == 0);

try
{
    api.Invoke("no.such.method");
    Check("未知方法应当报错", false);
}
catch (BoxSendException ex)
{
    Check("未知方法回传人话错误", ex.Message.Length > 0, ex.Message);
}

Check("配置文件已写出", File.Exists(configPath));

api.Dispose();
Check("重复 Dispose 安全", true);

Directory.Delete(dir, true);
Console.WriteLine(failed == 0 ? "\nABI 冒烟测试全部通过" : $"\n{failed} 项失败");
return failed == 0 ? 0 : 1;

static string Names(JsonNode result) =>
    string.Join(", ", result["groups"]!.AsArray().Select(g => g!["name"]!.GetValue<string>()));

/// 改名撞上已有组名时，核心会给新名字加数字后缀，界面靠这条规则去重
static bool RenamedToDuplicate(JsonNode result, string name)
{
    var names = result["groups"]!.AsArray().Select(g => g!["name"]!.GetValue<string>()).ToList();
    return names.Count(n => n == name) == 1 && names.Any(n => n != name && n.StartsWith(name));
}

static JsonNode? SiteById(JsonNode result, string id) =>
    result["sites"]!.AsArray().FirstOrDefault(s => s!["id"]!.GetValue<string>() == id);
