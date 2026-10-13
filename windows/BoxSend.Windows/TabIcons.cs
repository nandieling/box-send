using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Shapes;

namespace BoxSend.Windows;

/// <summary>顶部页签的图标：16x16 线稿，随主题前景色与页签字号缩放。
/// 用矢量而不是字体图标（Segoe MDL2）是因为缺字时会画成方块，而这里宁可稳一点。</summary>
public static class TabIcons
{
    /// <summary>纸飞机：批量转种</summary>
    public static Geometry Run => Parse("M1.6,14.4 L14.4,8 L1.6,1.6 L1.6,6.4 L9.4,8 L1.6,9.6 Z");

    /// <summary>2x2 网格：站点分组</summary>
    public static Geometry Sites => Parse("M2,2 H7 V7 H2 Z M9,2 H14 V7 H9 Z M2,9 H7 V14 H2 Z M9,9 H14 V14 H9 Z");

    /// <summary>挂锁：Cookie</summary>
    public static Geometry Cookie => Parse("M3.6,7.4 H12.4 V14.4 H3.6 Z M5.6,7.4 V5.2 A2.4,2.4 0 0 1 10.4,5.2 V7.4");

    /// <summary>向下箭头 + 托盘线：下载器</summary>
    public static Geometry Downloader => Parse("M8,1.6 V10.2 M4.2,6.6 L8,10.4 L11.8,6.6 M2.6,13.6 H13.4");

    /// <summary>三行清单：日志</summary>
    public static Geometry Logs => Parse("M2.6,3.6 H13.4 M2.6,8 H13.4 M2.6,12.4 H9.6");

    /// <summary>两根推子：设置</summary>
    public static Geometry Settings => Parse("M2.6,5 H13.4 M2.6,11 H13.4 M6,2.4 V7.6 M10,8.4 V13.6");

    private static Geometry Parse(string mini)
    {
        var g = Geometry.Parse(mini);
        g.Freeze();
        return g;
    }

    /// <summary>页签头部：图标 + 标题。两者都跟随页签前景色（未选中偏灰、选中/悬停转亮）。</summary>
    public static object Header(Geometry icon, string title)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        var path = new Path
        {
            Data = icon,
            Fill = null,
            Stroke = Brushes.Gray,
            StrokeThickness = 1.6,
            StrokeLineJoin = PenLineJoin.Round,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            Margin = new Thickness(0, 0, 8, 0),
            VerticalAlignment = VerticalAlignment.Center,
            SnapsToDevicePixels = true,
        };
        // 尺寸走资源：窗口最大化时整体放大一档（ThemeManager.ApplyMetrics）
        path.SetResourceReference(FrameworkElement.WidthProperty, "TabIconSize");
        path.SetResourceReference(FrameworkElement.HeightProperty, "TabIconSize");
        path.SetBinding(Shape.StrokeProperty, new Binding("Foreground")
        {
            RelativeSource = new RelativeSource(RelativeSourceMode.FindAncestor, typeof(TabItem), 1),
        });
        panel.Children.Add(path);
        panel.Children.Add(new TextBlock
        {
            Text = title,
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.NoWrap,
        });
        return panel;
    }
}
