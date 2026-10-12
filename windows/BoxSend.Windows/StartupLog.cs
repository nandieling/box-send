using System.IO;

namespace BoxSend.Windows;

/// <summary>启动轨迹与崩溃现场。
///
/// 界面是双击启动的 WinExe，没有控制台，双击之后起不来就是「一点反应都没有」：
/// 异常发生在弹框之前时连框都没有，装到用户机器上什么也看不见。所以每一步都往
/// %LOCALAPPDATA%\BoxSend\startup.log 追加一行，出问题时那行停在哪就是答案。</summary>
public static class StartupLog
{
    /// <summary>日志位置（AppData\Local\BoxSend\startup.log）</summary>
    public static readonly string FilePath = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "BoxSend", "startup.log");

    private static readonly object Gate = new();

    public static void Write(string what)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(FilePath)!);
                // 核心库那边也往这个文件追加（Trace.swift），所以开成读写都能共享；
                // AppendAllText 只允许读共享，两边会抢
                var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}  {what}{Environment.NewLine}";
                using var fs = new FileStream(FilePath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
                using var w = new StreamWriter(fs, new System.Text.UTF8Encoding(false));
                w.Write(line);
            }
        }
        catch
        {
            // 记日志本身失败不该再拖住启动
        }
    }
}
