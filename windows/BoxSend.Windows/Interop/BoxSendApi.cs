using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace BoxSend.Windows.Interop;

/// <summary>
/// 核心库（Swift 侧 boxsend.dll）的进程内调用。
/// 契约只有一个：<see cref="Invoke"/> 收发 JSON 字符串，耗时动作在服务内部后台线程跑，
/// 界面靠 snapshot / events 轮询取进度。
/// </summary>
public sealed class BoxSendApi : IDisposable
{
    private const string Lib = "boxsend";

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr boxsend_create(string? configPath, string? dataDir);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr boxsend_invoke(IntPtr handle, string requestJson);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    private static extern void boxsend_free(IntPtr ptr);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    private static extern void boxsend_set_ocr(IntPtr handle, OcrCallback? callback);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    private static extern void boxsend_destroy(IntPtr handle);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr boxsend_last_error();

    /// <summary>验证码识别回调：宿主往缓冲区里写候选（换行分隔），返回写入字节数；0 = 没认出</summary>
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int OcrCallback(IntPtr image, int imageLength, IntPtr outBuffer, int outCapacity);

    private IntPtr _handle;
    private readonly OcrCallback? _ocr;

    /// macOS 上验证 ABI 时用绝对路径加载；Windows 从程序目录按常规解析 boxsend.dll
    static BoxSendApi()
    {
        NativeLibrary.SetDllImportResolver(typeof(BoxSendApi).Assembly, Resolve);
    }

    private static IntPtr Resolve(string libraryName, System.Reflection.Assembly assembly, DllImportSearchPath? path)
    {
        if (libraryName != Lib) return IntPtr.Zero;
        foreach (var candidate in new[]
                 {
                     Path.Combine(AppContext.BaseDirectory, "boxsend.dll"),
                     Path.Combine(AppContext.BaseDirectory, "libboxsend.dylib"),
                     Path.Combine(AppContext.BaseDirectory, "libboxsend.so"),
                 })
        {
            if (File.Exists(candidate) && NativeLibrary.TryLoad(candidate, out var loaded)) return loaded;
        }
        return IntPtr.Zero;
    }

    /// <param name="ocr">注入验证码识别器（Windows 用 Windows.Media.Ocr）；null = 不做自动识别</param>
    public BoxSendApi(string? configPath = null, string? dataDir = null, OcrCallback? ocr = null)
    {
        _ocr = ocr;
        _handle = boxsend_create(configPath, dataDir);
        if (_handle == IntPtr.Zero)
        {
            var errPtr = boxsend_last_error();
            var why = Marshal.PtrToStringUTF8(errPtr) ?? "未知错误";
            boxsend_free(errPtr);
            throw new InvalidOperationException($"核心库启动失败：{why}");
        }
        if (_ocr != null) boxsend_set_ocr(_handle, _ocr);
    }

    /// 调一个动作；失败抛异常（消息就是核心库给的那句人话）
    public JsonNode Invoke(string method, object? parameters = null)
    {
        var request = new JsonObject { ["method"] = method };
        request["params"] = parameters switch
        {
            null => new JsonObject(),
            JsonNode node => node.DeepClone().AsObject(),
            _ => JsonSerializer.SerializeToNode(parameters) ?? new JsonObject(),
        };

        var ptr = boxsend_invoke(_handle, request.ToJsonString());
        var text = Marshal.PtrToStringUTF8(ptr) ?? "{\"ok\":false,\"error\":\"空响应\"}";
        boxsend_free(ptr);

        using var doc = JsonDocument.Parse(text);
        var root = doc.RootElement.Clone();
        if (root.TryGetProperty("ok", out var ok) && ok.GetBoolean())
            return root.TryGetProperty("result", out var r) ? JsonNode.Parse(r.GetRawText()) ?? new JsonObject() : new JsonObject();
        throw new BoxSendException(root.TryGetProperty("error", out var e) ? e.GetString() ?? "调用失败" : "调用失败");
    }

    /// 同 Invoke，但把异常换成「null + 错误文本」，界面上想直接把错误显示出来的场合用
    public JsonNode? TryInvoke(string method, out string? error, object? parameters = null)
    {
        try
        {
            error = null;
            return Invoke(method, parameters);
        }
        catch (BoxSendException ex)
        {
            error = ex.Message;
            return null;
        }
    }

    public void Dispose()
    {
        if (_handle == IntPtr.Zero) return;
        boxsend_destroy(_handle);
        _handle = IntPtr.Zero;
        GC.KeepAlive(_ocr);        // 回调必须比句柄活得久
    }
}

public sealed class BoxSendException : Exception
{
    public BoxSendException(string message) : base(message) { }
}

internal static class Utf8
{
    public static string ToUtf8(this byte[] data) => Encoding.UTF8.GetString(data);
}
