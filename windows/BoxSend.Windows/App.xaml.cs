using System.IO;
using System.Threading;
using System.Windows;
using BoxSend.Windows.Interop;

namespace BoxSend.Windows;

public partial class App : Application
{
    private AppModel? _model;
    private MainWindow? _window;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnExplicitShutdown;

        var single = new Mutex(true, "BoxSend.SingleInstance", out var isNew);
        if (!isNew)
        {
            MessageBox.Show("BoxSend 已经在运行（在托盘里）。", "BoxSend",
                            MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        try
        {
            // 验证码识别先留空：核心库认不出时会重新取图重试，最终放弃该次发帖而不是报错
            _model = new AppModel(new BoxSendApi());
        }
        catch (Exception ex)
        {
            MessageBox.Show("核心库启动失败：" + ex.Message, "BoxSend",
                            MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
            return;
        }

        ThemeManager.Apply(this, _model.CurrentTheme, BackgroundImage(), 0.45);
        _window = new MainWindow(_model);
        _window.Show();
        _model.Start();
        _ = _model.RefreshAsync();
    }

    /// 背景图片存在数据目录的 background.jpg（与 macOS 版同约定）
    public static string? BackgroundImage()
    {
        var path = Path.Combine(Current is App app && app._model != null ? app._model.DataDir : ".", "background.jpg");
        return File.Exists(path) ? path : null;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _model?.Dispose();
        base.OnExit(e);
    }
}
