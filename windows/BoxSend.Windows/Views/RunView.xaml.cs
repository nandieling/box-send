using System.Windows;
using System.Windows.Controls;

namespace BoxSend.Windows.Views;

/// <summary>批量转种页：源站链接、可选项、分组与目标站勾选、逐站实时状态。</summary>
public partial class RunView : UserControl
{
    private readonly AppModel _model;

    public RunView(AppModel model)
    {
        _model = model;
        InitializeComponent();
        SiteEvents.ItemsSource = model.RunSites;
        _model.FullRefreshed += (_, _) => Dispatcher.Invoke(RebuildPickers);
        RebuildPickers();
    }

    private void RebuildPickers()
    {
        var pickedGroup = (GroupPick.SelectedItem as GroupRow)?.Name;
        var pickedSource = (SourceSitePick.SelectedItem as SiteRow)?.Id;
        var checkedTargets = CheckedTargets();

        GroupPick.Items.Clear();
        foreach (var g in _model.Groups) GroupPick.Items.Add(g);
        GroupPick.SelectedItem = GroupPick.Items.Cast<GroupRow>().FirstOrDefault(g => g.Name == pickedGroup)
                                 ?? GroupPick.Items.Cast<GroupRow>().FirstOrDefault();

        SourceSitePick.Items.Clear();
        foreach (var s in _model.Sites.Where(s => s.Enabled)) SourceSitePick.Items.Add(s);
        SourceSitePick.SelectedItem = SourceSitePick.Items.Cast<SiteRow>().FirstOrDefault(s => s.Id == pickedSource);

        RebuildTargets(checkedTargets);
    }

    /// 目标站勾选框：重建时保留已勾选状态（刷新不能把用户勾的清空）
    private void RebuildTargets(HashSet<string> previouslyChecked)
    {
        var picked = previouslyChecked.Count > 0 ? previouslyChecked : _targets;
        TargetsList.Items.Clear();
        foreach (var s in _model.Sites.Where(s => s.Managed || s.Enabled))
        {
            var box = new CheckBox
            {
                Content = s.Name,
                Tag = s.Id,
                Margin = new Thickness(0, 2, 14, 2),
                IsChecked = picked.Count > 0 ? picked.Contains(s.Id) : s.Enabled,
            };
            TargetsList.Items.Add(box);
        }
        _targets = CheckedTargets();
    }

    private HashSet<string> _targets = new();

    private HashSet<string> CheckedTargets()
    {
        var set = new HashSet<string>();
        foreach (var obj in TargetsList.Items)
            if (obj is CheckBox { IsChecked: true, Tag: string id }) set.Add(id);
        return set;
    }

    private void OnRun(object sender, RoutedEventArgs e)
    {
        var url = DetailUrl.Text.Trim();
        if (url.Length == 0)
        {
            MessageBox.Show(Window.GetWindow(this)!, "请先填写源站种子链接。", "BoxSend");
            return;
        }
        _targets = CheckedTargets();
        var group = GroupPick.SelectedItem as GroupRow;
        var targets = group != null
            ? group.SiteIds.Where(_targets.Contains).ToArray()
            : _targets.ToArray();
        if (targets.Length == 0)
        {
            MessageBox.Show(Window.GetWindow(this)!, "没有勾选目标站。", "BoxSend");
            return;
        }
        _model.StartRun(url, targets,
                        skipReseed: DoReseed.IsChecked != true,
                        skipPush: DoPush.IsChecked != true,
                        sourceQuote: UseQuote.IsChecked == true ? QuoteText.Text : "",
                        sourceSiteId: (SourceSitePick.SelectedItem as SiteRow)?.Id);
    }
}
