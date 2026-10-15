using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

// 站点分组页与「批量添加站点」弹窗都用它，放在根命名空间下两边都能直接叫到
namespace BoxSend.Windows;

/// <summary>
/// 卡片拖拽排序：整张卡片都能拖起（输入框、勾选框、按钮这些落点除外），拖到哪张卡上就排到它前面。
/// 站点分组页与「批量添加站点」弹窗共用。原来只有右上角那个 14px 的「≡」能拖，
/// 手指基本点不中，看起来就像「拖不动」。</summary>
internal static class CardDrag
{
    /// <summary>正在拖的那张卡的 id（放下前一直有值）</summary>
    public static string? DraggingId { get; private set; }

    /// <summary>刚拖完：卡片上的「点击 = 选中 / 开关」要靠它把自己跳过一次</summary>
    public static bool JustDragged { get; private set; }

    /// <summary>把一张卡片同时装成「可拖起」和「可放下」。</summary>
    /// <param name="card">卡片本体（会被设 AllowDrop）</param>
    /// <param name="id">这张卡代表的站点 id</param>
    /// <param name="moveBefore">放下时调用：把 from 排到 to 之前</param>
    /// <param name="onState">拖起 / 放下时的回调（界面用来画高亮）</param>
    public static void MakeSortable(Border card, string id, Action<string, string> moveBefore,
                                    Action<string?>? onState = null)
    {
        card.AllowDrop = true;
        var start = new Point();
        var armed = false;

        card.PreviewMouseLeftButtonDown += (_, e) =>
        {
            armed = !InsideInput(e.OriginalSource);
            start = e.GetPosition(card);
        };
        card.PreviewMouseMove += (_, e) =>
        {
            if (!armed || e.LeftButton != MouseButtonState.Pressed) return;
            var p = e.GetPosition(card);
            if (Math.Abs(p.X - start.X) < SystemParameters.MinimumHorizontalDragDistance
                && Math.Abs(p.Y - start.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            armed = false;
            DraggingId = id;
            JustDragged = true;
            onState?.Invoke(id);
            DragDrop.DoDragDrop(card, new DataObject(DataFormats.Text, id), DragDropEffects.Move);
            DraggingId = null;
            onState?.Invoke(null);
            // 拖完补一次「不算点击」，等这次输入处理完就收回
            card.Dispatcher.BeginInvoke(() => JustDragged = false, DispatcherPriority.Background);
        };
        card.DragOver += (_, e) =>
        {
            e.Effects = DraggingId != null && DraggingId != id ? DragDropEffects.Move : DragDropEffects.None;
            e.Handled = true;
        };
        card.PreviewDrop += (_, e) =>
        {
            e.Handled = true;   // 卡里有输入框：不截下来会被当成「往输入框里拖文本」
            var from = e.Data.GetData(DataFormats.Text) as string;
            if (!string.IsNullOrEmpty(from) && from != id) moveBefore(from!, id);
        };
    }

    /// <summary>落点是输入框一类控件时不启动拖拽，否则没法在里面选字、勾格子</summary>
    private static bool InsideInput(object? source)
    {
        for (var d = source as DependencyObject; d != null; d = VisualTreeHelper.GetParent(d))
            if (d is TextBoxBase or PasswordBox or CheckBox or RadioButton or ButtonBase or ComboBox)
                return true;
        return false;
    }
}
