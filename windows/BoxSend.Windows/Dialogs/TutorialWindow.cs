using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace BoxSend.Windows.Dialogs;

/// <summary>使用教程（与 mac 版同一套说明，Windows 上不带配图）。分节写在这里，改一处两端对照着改。</summary>
public sealed class TutorialWindow : Window
{
    private static TutorialWindow? Shared;

    /// <summary>打开（或回到）这份说明：非模态，主窗右侧有地方就贴过去并排摆着，边看边设。
    /// 正文由核心给（与 mac 版同一份），这里只管排版。</summary>
    public static void Open(Window? owner, AppModel model)
    {
        var w = Shared ??= new TutorialWindow(model);
        if (!w.IsLoaded && !ReferenceEquals(w.Owner, owner)) w.Owner = owner;
        if (owner != null && !w.IsLoaded)
        {
            var right = owner.Left + owner.Width + 8;
            var maxRight = SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth;
            if (right + 520 <= maxRight)
            {
                w.WindowStartupLocation = WindowStartupLocation.Manual;
                w.Left = right;
                w.Top = owner.Top;
            }
        }
        if (!w.IsVisible) w.Show();
        w.Activate();
    }

    protected override void OnClosed(EventArgs e)
    {
        Shared = null;
        base.OnClosed(e);
    }

    public TutorialWindow(AppModel model)
    {
        Title = model.TutorialTitle;
        Width = 760;
        Height = 640;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = PromptWindow.Themed("DialogBackground", "#1F2530");

        var body = new StackPanel { Margin = new Thickness(16, 16, 20, 16) };
        foreach (var sec in model.Tutorial)
        {
            body.Children.Add(new TextBlock
            {
                Text = sec.Title,
                FontWeight = FontWeights.SemiBold,
                FontSize = 14,
                Margin = new Thickness(0, 0, 0, 6),
            });
            int n = 1;
            foreach (var step in sec.Steps)
                // 与 mac 版一致：步骤带序号，读的时候能指「第 3 步」
                body.Children.Add(Step($"{n++}.", step));
            if (sec.Code != null)
                // Worker 脚本单独一块等宽底框，选中就能直接抄走
                body.Children.Add(new Border
                {
                    Background = (Brush)Application.Current.Resources["BlockSurface"],
                    CornerRadius = new CornerRadius(6),
                    Padding = new Thickness(8),
                    Margin = new Thickness(10, 2, 0, 4),
                    Child = new TextBlock
                    {
                        Text = sec.Code,
                        FontFamily = new FontFamily("Consolas, Cascadia Mono, monospace"),
                        FontSize = 11.5,
                        TextWrapping = TextWrapping.NoWrap,
                    },
                });
            body.Children.Add(new FrameworkElement { Height = 14 });
        }

        var foot = new StackPanel { Margin = new Thickness(0, 4, 0, 0) };
        foot.Children.Add(new TextBlock
        {
            Text = model.TutorialFootnote,
            FontSize = 12,
            Foreground = (Brush)Application.Current.Resources["TextMuted"],
        });
        foot.Children.Add(new TextBlock
        {
            Text = model.TutorialRepo,
            FontSize = 12,
            Margin = new Thickness(0, 2, 0, 0),
            Foreground = (Brush)Application.Current.Resources["TextMuted"],
        });
        body.Children.Add(foot);

        Content = new ScrollViewer
        {
            Content = body,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
    }

    /// <summary>一步：左边序号、右边正文，正文换行时不压到序号下面</summary>
    private static Grid Step(string num, string text)
    {
        var g = new Grid { Margin = new Thickness(10, 0, 0, 4) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var n = new TextBlock
        {
            Text = num,
            FontSize = 12.5,
            TextAlignment = TextAlignment.Right,
            Foreground = (Brush)Application.Current.Resources["TextMuted"],
        };
        Grid.SetColumn(n, 0);
        var t = new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12.5,
            Margin = new Thickness(6, 0, 0, 0),
        };
        Grid.SetColumn(t, 1);
        g.Children.Add(n);
        g.Children.Add(t);
        return g;
    }
}
