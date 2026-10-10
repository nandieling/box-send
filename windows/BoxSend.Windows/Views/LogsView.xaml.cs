using System.IO;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;

namespace BoxSend.Windows.Views;

/// <summary>日志页：核心库的运行记录（转种过程、同步结果、失败原因）。</summary>
public partial class LogsView : UserControl
{
    private readonly AppModel _model;

    public LogsView(AppModel model)
    {
        _model = model;
        InitializeComponent();
        Lines.ItemsSource = model.Logs;
        Dir.Text = model.DataDir;
        _model.FullRefreshed += (_, _) => Dispatcher.Invoke(() =>
            Lines.ScrollIntoView(Lines.Items.Count > 0 ? Lines.Items[^1] : null));
    }

    private void OnClear(object sender, RoutedEventArgs e) => _model.Call("logs.clear");

    private void OnOpenDir(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo("explorer.exe", $"\"{_model.DataDir}\"") { UseShellExecute = true }); }
        catch (Exception ex) { MessageBox.Show(Window.GetWindow(this)!, ex.Message, "BoxSend"); }
    }
}
