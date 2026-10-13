using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace BoxSend.Windows.Dialogs;

/// <summary>使用教程（与 mac 版同一套说明，Windows 上不带配图）。分节写在这里，改一处两端对照着改。</summary>
public sealed class TutorialWindow : Window
{
    private static readonly (string Title, string[] Steps)[] Sections =
    {
        ("1. 添加站点与分组", new[]
        {
            "「站点分组」页顶部输入分组名并设置上传限速（默认 10 MB/s），点「添加分组」。",
            "点分组名旁的「添加站点」批量添加：搜索站点、勾选后要加入的站点，选好后点「添加所选」。",
            "点站点卡片可开启 / 停用该站；组名旁的「全选」一键切换整组；「手动填 cookie / Key」为已开启的站点手工填写。",
            "组内排序：拖卡片右侧的把手拖到另一张卡片上，或在把手左边输入序号回车排到第几位（与 mac 版一致）。",
            "顶部「检测全部 cookie」批量检查 cookie / API Key 有效性，每张卡片上直接显示结果，检测中可「停止检测」；「移除站点」「移除分组」均需两次确认。",
            "支持「帖子免费1天」的站点（如猫站）卡片上会出现「发种后免费一天」开关：打开后发种成功就自动点一次站内免费按钮（要扣站内积分）；帖子已在免费满一天时不重复扣。",
        }),
        ("2. 配置与备份 Cookie", new[]
        {
            "PT-depiler Gist 同步：填写 GitHub Token 与 Gist ID，可开启自动同步并设置间隔分钟。",
            "CookieCloud 同步备份：填写服务器地址、用户 KEY 与端对端加密密码。",
            "两路备份互为补充：某一站点在一处的 cookie 失效时，同步后自动用另一来源补充。",
            "「同步 Cookie」立即执行两路同步；「立即扫描」检查 PT-depiler 备份目录里的 zip。",
        }),
        ("3. 批量转种", new[]
        {
            "「批量转种」页粘贴种子详情页链接，勾选「转种到目标站」与「推送到下载器」。",
            "源站默认按链接域名识别；已添加的站点都能在下拉里点名作源站。",
            "目标站按分成分块，组名旁的勾选框选整组；「开始运行」旁会显示本批「已选几个分组 · 几个站点」。",
            "按分组顺序执行：获取种子 → 依次上传到组内已开启站点（限速取站点设置，新增时默认跟分组限速）→ 转种成功的种子自动推送到下载器。",
            "需要注明转种来源时勾选「源站引用」并填写文本：软件会把这段文字用引用块加在每个目标站简介最上面；源站自带引用的不用勾。",
            "页面下半部分左栏是逐站转种结果，右栏是下载器推送结果。",
        }),
        ("4. 推送到 VPS 下载器", new[]
        {
            "「下载器」页填写 qBittorrent Web UI / Transmission 的地址、用户名与密码。",
            "「测试连接」验证可用性；勾选「跳过校验」后推送时不再校验。",
            "默认上传限速与推送时机也在这一页；VPS 剩余空间用于推送前的空间保护。",
        }),
        ("5. 转种服务器测速（SSH）", new[]
        {
            "部分服务器 24 小时上传流量到 2T 后，会把上行悄悄压到 20 MB/s 左右：站点照样能发种，但整批下载都变慢。",
            "「下载器」页「转种服务器」卡片填写服务器地址、端口、用户名与私钥路径（Windows 版走密钥登录）。",
            "「测试连接并测速」立刻连一次：显示服务器主机名与每轮实测速度。",
            "勾选「批量转种前先测服务器上传速度」后，每次点「开始运行」会先测速再弹窗把速度报给你：可以就点「确定」继续转种，觉得被限速了就点「取消」等一等，不设自动判定线。",
            "测速是在服务器上往公网推数据（默认每轮 64 MB、共两轮），只多花这一份上行；测速地址可换成自己的接收端。",
        }),
        ("6. TMDB 链接自动反查", new[]
        {
            "部分站点（如杜比）把 TMDB 链接设为必填，源站简介里没有 TMDB 时发种会被拒。",
            "「设置」页勾选「发种时自动补 TMDB 链接」：发种前用种子的 IMDb 号或豆瓣号去查条目号，填进目标站的 TMDB 输入框；查不到时留空，由你手动填写。",
            "国内直连 api.themoviedb.org 常不通：在「API 代理网关地址」填自己的网关，留空即走官方接口；地址要写到版本号那一层（末尾带 /3，如 https://gw.example.com/tmdb0512/3），漏写会先按你填的试、404 再自动补 /3 重试。",
            "网关只是转发时仍要填 TMDB 的 API Key；只有网关自己代填 Key 时才留空。",
            "「测试查询」用一条固定片例验证网关是否可用。",
        }),
        ("7. 软件更新", new[]
        {
            "更新地址就是项目仓库 https://github.com/nandieling/box-send，「设置」页「软件更新」卡片能看到当前版本并检查新版本。",
            "默认每次启动在后台查一次（只读 GitHub 的发布接口，不上传任何本机数据）；不想自动查就关掉「启动时自动检查」。",
            "发现新版本点「下载 x.y.z 安装包」，装新的即可：站点、Cookie、限速与主题设置都存在本机，升级不会被动到。",
        }),
        ("8. 外观设置", new[]
        {
            "「设置」页选择渐变主题；主题渐变、强调色与明暗模式覆盖窗口、页签与所有弹窗。",
            "可添加背景图片（PNG/JPG）并用滑块调整透明度，不改变窗口与各区块的大小比例。",
            "窗口最大化时顶部页签会自动放大一档，方便远距离点选。",
        }),
    };

    public TutorialWindow()
    {
        Title = "BoxSend 使用教程";
        Width = 760;
        Height = 640;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = PromptWindow.Themed("DialogBackground", "#1F2530");

        var body = new StackPanel { Margin = new Thickness(16, 16, 20, 16) };
        foreach (var (title, steps) in Sections)
        {
            body.Children.Add(new TextBlock
            {
                Text = title,
                FontWeight = FontWeights.SemiBold,
                FontSize = 14,
                Margin = new Thickness(0, 0, 0, 6),
            });
            foreach (var step in steps)
                body.Children.Add(new TextBlock
                {
                    Text = "· " + step,
                    TextWrapping = TextWrapping.Wrap,
                    FontSize = 12.5,
                    Margin = new Thickness(10, 0, 0, 4),
                    Foreground = (Brush)Application.Current.Resources["TextMuted"],
                });
            body.Children.Add(new FrameworkElement { Height = 14 });
        }
        body.Children.Add(new TextBlock
        {
            Text = "项目地址：https://github.com/nandieling/box-send",
            FontSize = 12,
            Foreground = (Brush)Application.Current.Resources["TextMuted"],
        });

        Content = new ScrollViewer
        {
            Content = body,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
    }
}
