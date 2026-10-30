using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace BoxSend.Windows;

/// <summary>表单小部件：设置区（含并进来的 Cookie 与下载器）统一「一行一个字段」的形状。</summary>
public static class Widgets
{
    /// <summary>一行一个字段：标签在上、输入框在下。width 给输入框定宽（0 = 跟着内容），
    /// 数字类给 100~130，URL / 路径给 420~460，别把整张卡片拉成一条宽带。</summary>
    public static FrameworkElement Field(string label, FrameworkElement input, double width = 0, string? tip = null)
    {
        if (width > 0)
        {
            input.Width = width;
            input.HorizontalAlignment = HorizontalAlignment.Left;
        }
        input.MinHeight = 32;
        if (!string.IsNullOrEmpty(tip)) ToolTipService.SetToolTip(input, tip);

        var panel = new StackPanel { Margin = new Thickness(0, 0, 0, 8) };
        panel.Children.Add(new Label
        {
            Content = label,
            Padding = new Thickness(0, 0, 0, 2),
            Foreground = (Brush)Application.Current.Resources["TextMuted"],
        });
        panel.Children.Add(input);
        return panel;
    }
}

/// <summary>口令输入框：默认按圆点显示（PasswordBox 天生打星），右边「显示」切成明文、
/// 再点回「隐藏」。这是 mac 版 RevealField 的对应物，两端要打星的字段保持一致：
/// Gist Token、Gist 加密 KEY、CookieCloud 的 KEY 与密码、PT-depiler 备份密码、
/// 下载器密码、SSH 密码、TMDB API Key。
/// PasswordBox 没有绑定，明文那侧改动时回填到它，取值永远读 Password。</summary>
public sealed class SecretField : Grid
{
    private readonly PasswordBox _hidden = new();
    private readonly TextBox _shown = new();
    private readonly Button _toggle = new();
    private bool _syncing;

    public SecretField()
    {
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var box = new Grid();
        _shown.Visibility = Visibility.Collapsed;
        box.Children.Add(_hidden);
        box.Children.Add(_shown);
        Children.Add(box);

        _toggle.Content = "显示";
        _toggle.MinWidth = 54;
        _toggle.Margin = new Thickness(6, 0, 0, 0);
        _toggle.ToolTip = "显示已经输入的口令";
        _toggle.Click += (_, _) => Toggle();
        SetColumn(_toggle, 1);
        Children.Add(_toggle);

        _shown.TextChanged += (_, _) =>
        {
            if (_syncing) return;
            _syncing = true;
            _hidden.Password = _shown.Text;
            _syncing = false;
        };
    }

    private void Toggle()
    {
        var reveal = (string)_toggle.Content != "隐藏";
        if (reveal) _shown.Text = _hidden.Password;
        _hidden.Visibility = reveal ? Visibility.Collapsed : Visibility.Visible;
        _shown.Visibility = reveal ? Visibility.Visible : Visibility.Collapsed;
        _toggle.Content = reveal ? "隐藏" : "显示";
        _toggle.ToolTip = reveal ? "收起明文，回到打星" : "显示已经输入的口令";
        // SelectAll 不在 Control 上，各自叫自己那个（TextBox / PasswordBox 都有）
        if (reveal) { _shown.Focus(); _shown.SelectAll(); }
        else { _hidden.Focus(); _hidden.SelectAll(); }
    }

    /// <summary>取值/赋值都走这里（打星与否不影响）</summary>
    public string Password
    {
        get => _hidden.Password;
        set
        {
            _syncing = true;
            _hidden.Password = value ?? "";
            _shown.Text = value ?? "";
            _syncing = false;
        }
    }

    /// <summary>与 TextBox 的写法对齐：这几处原先就是 TextBox，调用方不必跟着改</summary>
    public string Text
    {
        get => Password;
        set => Password = value;
    }
}
