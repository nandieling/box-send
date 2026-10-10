using System.Windows;
using System.Windows.Controls;

namespace BoxSend.Windows.Views;

/// <summary>下载器页：qBittorrent / Transmission 连接信息、限速与推送策略。</summary>
public partial class DownloaderView : UserControl
{
    private readonly AppModel _model;

    public DownloaderView(AppModel model)
    {
        _model = model;
        InitializeComponent();
        _model.FullRefreshed += (_, _) => Dispatcher.Invoke(Load);
        Load();
    }

    private void Load()
    {
        Result.Text = _model.DownloaderMessage;
        var type = _model.SectionText("downloader", "type", "qbittorrent");
        Select(Type, type);
        Url.Text = _model.SectionText("downloader", "url", "http://127.0.0.1:8080");
        User.Text = _model.SectionText("downloader", "username");
        Pass.Password = _model.SectionText("downloader", "password");
        SavePath.Text = _model.SectionText("downloader", "savePath");
        Category.Text = _model.SectionText("downloader", "category");
        SkipCheck.IsChecked = _model.SectionFlag("downloader", "skipChecking");
        DefaultLimit.Text = (_model.SectionInt("downloader", "defaultUpLimit", 10485760) / 1048576).ToString();
        Select(PushPolicy, _model.SectionText("downloader", "pushPolicy", "onSuccess"));
        Select(GuardMode, _model.SectionText("downloader", "sizeGuardMode", "warn"));
        GuardMargin.Text = _model.SectionInt("downloader", "sizeGuardMarginGB", 20).ToString();
        VpsFree.Text = _model.Config?["downloader"]?["vpsFreeGB"] is { } v && v.GetValue<int>() > 0
            ? v.GetValue<int>().ToString() : "";
    }

    private static void Select(ComboBox box, string tag)
    {
        foreach (var item in box.Items.OfType<ComboBoxItem>())
            if ((item.Tag as string) == tag) { box.SelectedItem = item; return; }
        box.SelectedIndex = 0;
    }

    private static string SelectedTag(ComboBox box) => (box.SelectedItem as ComboBoxItem)?.Tag as string ?? "";

    private static int Mb(TextBox box, int fallback) =>
        int.TryParse(box.Text.Trim(), out var mb) ? mb * 1048576 : fallback;

    private void OnSave(object sender, RoutedEventArgs e) => Save();

    private void Save() => _model.PatchSection("downloader", s =>
    {
        s["type"] = SelectedTag(Type);
        s["url"] = Url.Text.Trim();
        s["username"] = User.Text;
        s["password"] = Pass.Password;
        s["savePath"] = string.IsNullOrWhiteSpace(SavePath.Text) ? null : SavePath.Text.Trim();
        s["category"] = string.IsNullOrWhiteSpace(Category.Text) ? null : Category.Text.Trim();
        s["skipChecking"] = SkipCheck.IsChecked == true;
        s["defaultUpLimit"] = Mb(DefaultLimit, 10485760);
        s["pushPolicy"] = SelectedTag(PushPolicy);
        s["sizeGuardMode"] = SelectedTag(GuardMode);
        s["sizeGuardMarginGB"] = int.TryParse(GuardMargin.Text.Trim(), out var g) ? g : 20;
        if (int.TryParse(VpsFree.Text.Trim(), out var free)) s["vpsFreeGB"] = free;
        else s.Remove("vpsFreeGB");
    });

    private void OnTest(object sender, RoutedEventArgs e)
    {
        Save();
        var error = _model.Try("downloader.test");
        Result.Text = error ?? "测试中…";
        _ = _model.RefreshAsync(full: false);
    }

    private void OnReveal(object sender, RoutedEventArgs e)
    {
        PassPeek.Text = Pass.Password;
        Pass.Visibility = Reveal.IsChecked == true ? Visibility.Collapsed : Visibility.Visible;
        PassPeek.Visibility = Reveal.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }
}
