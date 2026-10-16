using System.IO;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Text.Json.Nodes;

namespace BoxSend.Windows.Views;

/// <summary>设置页：主题、背景图片与透明度、更新检查、路径信息。</summary>
public partial class SettingsView : UserControl
{
    private readonly AppModel _model;
    private bool _loading;

    public SettingsView(AppModel model)
    {
        _model = model;
        InitializeComponent();
        _model.FullRefreshed += (_, _) => Dispatcher.Invoke(Load);
        Load();
    }

    private void Load()
    {
        _loading = true;
        ThemeList.Items.Clear();
        foreach (var t in _model.Themes)
        {
            var picked = t.Id == _model.CurrentTheme.Id;
            // 渐变色块只作预览，名字写在色块下方的卡片底上：
            // 写在色块上时，「云端白」这类浅色主题在当前深色主题下就是白字配白底，看不清
            var preview = new Border
            {
                Height = 34,
                CornerRadius = new CornerRadius(4),
                Background = Gradient(t.Colors),
            };
            var caption = new TextBlock
            {
                Text = t.Name,
                Margin = new Thickness(3, 5, 3, 0),
                FontSize = 12,
                TextAlignment = TextAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = (Brush)FindResource(picked ? "TextPrimary" : "TextMuted"),
            };
            var body = new StackPanel();
            body.Children.Add(preview);
            body.Children.Add(caption);
            var swatch = new Border
            {
                Width = 150,
                Height = 82,
                Margin = new Thickness(0, 0, 10, 10),
                CornerRadius = new CornerRadius(6),
                BorderBrush = (Brush)FindResource(picked ? "Accent" : "Line"),
                BorderThickness = new Thickness(picked ? 2.5 : 1),
                Background = (Brush)FindResource("BlockSurface"),
                Padding = new Thickness(5),
                Child = body,
                ToolTip = $"切换到「{t.Name}」主题",
            };
            var id = t.Id;
            swatch.MouseLeftButtonUp += (_, _) =>
            {
                _model.Call("appearance.set", new { themeID = id });
                _model.PatchSection("appearance", s => s["themeID"] = id);
            };
            ThemeList.Items.Add(swatch);
        }

        var current = _model.Config?["appearance"]?["bgImage"];
        ImageState.Text = current is { } c && c.GetValue<string>().Length > 0
            ? $"当前背景：{c.GetValue<string>()}" : "未设置背景图片（跟随主题渐变）";
        BgOpacity.Value = _model.Config?["appearance"]?["bgOpacity"] is { } o ? o.GetValue<double>() : 0.45;
        UpdateState.Text = string.IsNullOrEmpty(_model.UpdateMessage)
            ? $"当前版本 {_model.CoreVersion}" : $"{_model.UpdateMessage}（当前 {_model.CoreVersion}）";
        BtnDownload.Content = $"下载 {_model.UpdateVersion} 安装包";
        BtnDownload.Visibility = _model.HasUpdate && !string.IsNullOrEmpty(_model.UpdateDownloadUrl)
            ? Visibility.Visible
            : Visibility.Collapsed;
        AutoUpdate.IsChecked = _model.Config?["autoUpdateCheck"] is not JsonValue v || v.GetValue<bool>();
        if (!TmdbBase.IsKeyboardFocusWithin)
            TmdbBase.Text = _model.SectionText("tmdb", "apiBase");
        if (!TmdbKey.IsKeyboardFocusWithin) TmdbKey.Text = _model.SectionText("tmdb", "apiKey");
        TmdbOn.IsChecked = _model.SectionFlag("tmdb", "enabled");
        About.Text = $"BoxSend {_model.CoreVersion} · 核心库 {_model.CoreVersion} · 平台 {_model.Platform}";
        ConfigPath.Text = $"配置：{_model.ConfigPath}\n数据：{_model.DataDir}";
        _loading = false;
    }

    private static LinearGradientBrush Gradient(string[] hexes)
    {
        var b = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
        for (var i = 0; i < hexes.Length; i++)
            b.GradientStops.Add(new GradientStop((Color)ColorConverter.ConvertFromString(hexes[i]),
                                                hexes.Length == 1 ? 0 : (double)i / (hexes.Length - 1)));
        return b;
    }

    private void OnPickImage(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = "选择背景图片",
            Filter = "图片|*.jpg;*.jpeg;*.png|所有文件|*.*",
        };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        var target = Path.Combine(_model.DataDir, "background.jpg");
        File.Copy(dialog.FileName, target, true);
        _model.Call("appearance.set", new { bgImage = "background.jpg" });
        App.BackgroundImage();
    }

    private void OnClearImage(object sender, RoutedEventArgs e)
    {
        var target = Path.Combine(_model.DataDir, "background.jpg");
        if (File.Exists(target)) File.Delete(target);
        _model.Call("appearance.set", new { bgImage = (string?)null });
    }

    private void OnOpacity(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_loading) return;
        _model.PatchSection("appearance", s => s["bgOpacity"] = Math.Round(e.NewValue, 2));
    }

    private async void OnCheckUpdate(object sender, RoutedEventArgs e)
    {
        UpdateState.Text = "检查中…";
        // 查一次版本要走 GitHub：在界面线程等会把窗口卡成「未响应」
        var error = await _model.TryAsync("update.check");
        UpdateState.Text = error ?? "已提交检查";
    }

    // 有新版本时直接给安装包直链（与 mac 版「下载 x.y.z 安装包」一致）
    private void OnDownloadUpdate(object sender, RoutedEventArgs e) => Open(_model.UpdateDownloadUrl);

    private void OnOpenReleases(object sender, RoutedEventArgs e) =>
        Open(_model.UpdateUrl.Length > 0 ? _model.UpdateUrl : "https://github.com/nandieling/box-send/releases");

    private void Open(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception ex) { MessageBox.Show(Window.GetWindow(this)!, ex.Message, "BoxSend"); }
    }

    private void OnTutorial(object sender, RoutedEventArgs e) =>
        new Dialogs.TutorialWindow { Owner = Window.GetWindow(this) }.ShowDialog();

    private void OnTmdbToggled(object sender, RoutedEventArgs e) => SaveTMDB();

    private void SaveTMDB() => _model.PatchSection("tmdb", s =>
    {
        s["enabled"] = TmdbOn.IsChecked == true;
        s["apiBase"] = TmdbBase.Text.Trim();
        s["apiKey"] = TmdbKey.Text;
    });

    /// 用一条固定片例（银魂剧场版）验一次网关通不通：核心库拿 IMDb 号与豆瓣号各试一遍
    private async void OnTestTMDB(object sender, RoutedEventArgs e)
    {
        SaveTMDB();
        BtnTmdb.IsEnabled = false;
        TmdbState.Text = "查询中…";
        var node = await Task.Run(() => _model.Api.TryInvoke("tmdb.test", out var error)
                                       ?? new JsonObject { ["error"] = error ?? "查询失败" });
        await _model.RefreshAsync(full: false);
        BtnTmdb.IsEnabled = true;
        var link = node?["link"]?.GetValue<string>();
        TmdbState.Text = string.IsNullOrEmpty(link)
            ? "失败: " + (node?["error"]?.GetValue<string>() ?? "TMDB 没有匹配条目")
            : "成功: " + link;
    }

    private void OnAutoUpdate(object sender, RoutedEventArgs e) =>
        _model.Call("config.patch", new JsonObject { ["patch"] = new JsonObject { ["autoUpdateCheck"] = AutoUpdate.IsChecked == true } });
}
