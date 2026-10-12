using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using BoxSend.Windows.Interop;

namespace BoxSend.Windows;

public partial class App : Application
{
    private AppModel? _model;
    private MainWindow? _window;

    // 单实例：互斥量与「把窗口叫出来」的事件都得被字段持有，局部变量会被 GC 回收，
    // 句柄一关，第二个实例就以为自己是第一个
    private readonly ManualResetEventSlim _coreReady = new(false);
    private Mutex? _singleInstance;
    private EventWaitHandle? _showRequested;
    private RegisteredWaitHandle? _showWait;
    private bool _crashReported;

    protected override void OnStartup(StartupEventArgs e)
    {
        StartupLog.Write($"—— 启动：{typeof(App).Assembly.GetName().Version}，参数 [{string.Join(" ", e.Args)}]，目录 {AppContext.BaseDirectory}");
        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnExplicitShutdown;

        // 三层兜底：界面线程、其它线程、没人等的 Task。少一层就可能悄悄退进程
        DispatcherUnhandledException += OnDispatcherException;
        AppDomain.CurrentDomain.UnhandledException += (_, ev) =>
            Report(ev.ExceptionObject as Exception, "后台线程");
        TaskScheduler.UnobservedTaskException += (_, ev) =>
        {
            StartupLog.Write("没人等的 Task 异常：" + ev.Exception);
            ev.SetObserved();
        };

        WatchStartup(20);

        var single = new Mutex(true, "BoxSend.SingleInstance", out var isNew);
        if (!isNew)
        {
            StartupLog.Write("已有一个实例在跑，叫它出窗口后自己退出");
            if (EventWaitHandle.TryOpenExisting("BoxSend.ShowRequested", out var existing))
                existing.Set();
            else
                MessageBox.Show("BoxSend 已经在运行（在托盘里）。", "BoxSend",
                                MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }
        _singleInstance = single;

        try
        {
            // 验证码识别先留空：核心库认不出时会重新取图重试，最终放弃该次发帖而不是报错
            StartupLog.Write("核心库：正在创建");
            _model = new AppModel(new BoxSendApi());
            _coreReady.Set();
            StartupLog.Write($"核心库：就绪 v{_model.CoreVersion}（{_model.Platform}），数据目录 {_model.DataDir}");
        }
        catch (Exception ex)
        {
            StartupLog.Write("核心库创建失败：" + ex);
            MessageBox.Show("核心库启动失败：" + ex.Message, "BoxSend",
                            MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
            return;
        }

        try
        {
            // 先把快照取到手再建窗口：主题色、背景图透明度都读自配置，视图也假定配置已在
            StartupLog.Write("首帧快照：读取中");
            _model.Refresh();
            ThemeManager.Apply(this, _model.CurrentTheme, BackgroundImage(), 0.45);
            _window = new MainWindow(_model);
            _window.Show();
            _window.Activate();
            StartupLog.Write($"主窗口已显示：{Geometry()}");
        }
        catch (Exception ex)
        {
            StartupLog.Write("建窗口失败：" + ex);
            MessageBox.Show("界面启动失败：" + ex.Message, "BoxSend",
                            MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
            return;
        }

        _model.Start();

        // 第二个实例双击图标时走这里：托盘图标常常被折叠在溢出区，只弹一句「已在运行」等于没反应
        _showRequested = new EventWaitHandle(false, EventResetMode.AutoReset, "BoxSend.ShowRequested");
        _showWait = ThreadPool.RegisterWaitForSingleObject(_showRequested, (_, _) =>
            Dispatcher.BeginInvoke(() => _window?.ShowFromTray()), null, Timeout.InfiniteTimeSpan, false);
    }

    /// <summary>核心库要是不返回，界面线程就钉在那儿，WPF 自己的定时器也点不亮——
    /// 所以另开一条线程报信，免得「双击了没窗口也没提示」什么线索都没有。</summary>
    private void WatchStartup(int seconds)
    {
        var t = new Thread(() =>
        {
            if (_coreReady.Wait(TimeSpan.FromSeconds(seconds))) return;
            StartupLog.Write($"看门狗：{seconds} 秒了核心库还没返回");
            MessageBox.Show($"核心库启动超过 {seconds} 秒没返回。\n\n走到哪一步写在\n{StartupLog.FilePath}\n" +
                            "（带 core: 前缀的那些行是核心库内部的进度）",
                            "BoxSend", MessageBoxButton.OK, MessageBoxImage.Warning);
        }) { IsBackground = true };
        t.Start();
    }

    /// <summary>窗口在屏幕上的实际位置尺寸（设备像素）＋主屏工作区，用来判「窗口跑到屏幕外」</summary>
    private string Geometry()
    {
        if (_window == null) return "还没有窗口";
        try
        {
            var p = _window.IsVisible ? _window.PointToScreen(new Point(0, 0)) : new Point(double.NaN, double.NaN);
            return $"位置 ({p.X:0},{p.Y:0}) 尺寸 {_window.ActualWidth:0}×{_window.ActualHeight:0} " +
                   $"Visible={_window.IsVisible} State={_window.WindowState} " +
                   $"工作区={SystemParameters.WorkArea} 主屏={SystemParameters.PrimaryScreenWidth:0}×{SystemParameters.PrimaryScreenHeight:0}";
        }
        catch (Exception ex)
        {
            return "读不到（" + ex.GetType().Name + "）";
        }
    }

    private void OnDispatcherException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Report(e.Exception, "界面线程");
        // 窗口已经站起来了就别让整个程序陪葬；还没建好窗口时照常退，交给 WER 记一笔
        e.Handled = _window != null;
    }

    private void Report(Exception? ex, string where)
    {
        if (ex == null) return;
        StartupLog.Write($"未处理异常（{where}）：{ex}");
        if (_crashReported) return;
        _crashReported = true;
        MessageBox.Show(where + "出了点意外：" + ex.Message +
                        "\n\n细节写在 " + StartupLog.FilePath,
                        "BoxSend", MessageBoxButton.OK, MessageBoxImage.Error);
    }

    /// <summary>背景图片存在数据目录的 background.jpg（与 macOS 版同约定）</summary>
    public static string? BackgroundImage()
    {
        var path = Path.Combine(Current is App app && app._model != null ? app._model.DataDir : ".", "background.jpg");
        return File.Exists(path) ? path : null;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        StartupLog.Write($"退出（退出码 {Environment.ExitCode}，代码 {e.ApplicationExitCode}）");
        _showWait?.Unregister(null);
        _showRequested?.Dispose();
        _model?.Dispose();
        _singleInstance?.Dispose();
        base.OnExit(e);
    }
}
