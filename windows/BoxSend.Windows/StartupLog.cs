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
                File.AppendAllText(FilePath,
                    $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}  {what}{Environment.NewLine}");
            }
        }
        catch
        {
            // 记日志本身失败不该再拖住启动
        }
    }
}
