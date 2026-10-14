using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using Renci.SshNet;
using Renci.SshNet.Common;

namespace BoxSend.Windows.Interop;

/// <summary>
/// 用 SSH.NET（MIT，纯托管）连一次转种服务器。
///
/// 为什么要宿主代跑：Windows 自带的 OpenSSH 客户端不读 SSH_ASKPASS，密码没人代填，
/// 密码登录在 Windows 上本是死路。密钥登录仍走系统 ssh（那条路早就验过），只有密码这一半走这里。
/// 约定见 <see cref="BoxSendApi.SshExecCallback"/>：0 = 成功，缓冲区放命令输出；
/// 负数 = 失败类别（核心那侧 SSHSpeedTest.HostFailure），缓冲区放原始报错，措辞由核心统一给。
/// </summary>
internal static class SshExec
{
    // 类别码要和 SSHSpeedTest.HostFailure 一一对上
    private const int Ok = 0, AuthFailed = -1, Refused = -2, TimedOut = -3, Dns = -4,
                      Disconnected = -5, Algorithm = -6, Other = -7;

    /// 核心库里存的是这个委托的地址，得有静态字段托着，不然被 GC 掉就是野指针
    internal static readonly BoxSendApi.SshExecCallback Callback = Run;

    private static int Run(string host, int port, string user, string password,
                           string keyPath, string script, int timeoutSeconds,
                           IntPtr outBuffer, int outCapacity)
    {
        var budget = TimeSpan.FromSeconds(Math.Clamp(timeoutSeconds, 5, 900));
        try
        {
            var info = new PasswordConnectionInfo(host, port, user, password) { Timeout = budget };
            using var client = new SshClient(info) { KeepAliveInterval = TimeSpan.FromSeconds(10) };
            client.Connect();
            using var cmd = client.CreateCommand(script);
            cmd.CommandTimeout = budget;
            var stdout = cmd.Execute();
            // 测速脚本自己会打 BS_ERR_* 标记，stderr 一起交回去让核心判读
            var text = cmd.Error.Trim().Length > 0 ? stdout + "\n" + cmd.Error : stdout;
            return Write(outBuffer, outCapacity, text, Ok);
        }
        catch (Exception ex)
        {
            return Write(outBuffer, outCapacity, $"{ex.GetType().Name}: {ex.Message}", Classify(ex));
        }
    }

    /// 异常归到六类里去：界面上那句「为什么没连上」由核心按类别翻，这里只负责分类
    private static int Classify(Exception ex)
    {
        for (Exception? e = ex; e != null; e = e.InnerException)
        {
            var name = e.GetType().Name;
            if (name.Contains("Authentication") || name.Contains("Password")) return AuthFailed;
            if (e is SshOperationTimeoutException) return TimedOut;
            if (name.Contains("Algorithm") || name.Contains("Exchange") || name.Contains("Cipher"))
                return Algorithm;
            if (e is SocketException se)
                return se.SocketErrorCode switch
                {
                    SocketError.HostNotFound or SocketError.HostDown or SocketError.TryAgain => Dns,
                    SocketError.ConnectionRefused => Refused,
                    SocketError.TimedOut => TimedOut,
                    SocketError.NetworkUnreachable or SocketError.HostUnreachable
                        or SocketError.NetworkDown => Refused,
                    SocketError.ConnectionReset or SocketError.ConnectionAborted
                        or SocketError.Interrupted => Disconnected,
                    _ => Other,
                };
            if (e is SshConnectionException) return Disconnected;
        }
        return Other;
    }

    /// 留最后一格给核心预置的 NUL：核心调用前把整块缓冲区清过零，截断处自然是结尾
    private static int Write(IntPtr buffer, int capacity, string text, int code)
    {
        if (buffer == IntPtr.Zero || capacity <= 1) return code;
        var bytes = Encoding.UTF8.GetBytes(text);
        var n = Math.Min(bytes.Length, capacity - 1);
        // 别把一个中文字符劈成一半：往回退到 UTF-8 首字节
        while (n > 0 && (bytes[n - 1] & 0xC0) == 0x80) n--;
        if (n > 0) Marshal.Copy(bytes, 0, buffer, n);
        return code;
    }
}
