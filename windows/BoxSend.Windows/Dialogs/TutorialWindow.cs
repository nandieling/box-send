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
        ("2. Cookie：PT-depiler Gist 与 CookieCloud", new[]
        {
            "两路都是「浏览器插件采集 → 云端存一份密文 → 本软件拉回来」：Gist 存 GitHub，CookieCloud 存自己的服务器。两路互为补充，某一站在一路过期时同步会用另一路补上，本地检测有效的 cookie 不会被覆盖。",
            "先搭 PT-depiler Gist：在 github.com/settings/tokens 生成 classic token，scope 只勾 gist（不用勾 repo、delete_repo）。",
            "PT-depiler「设置 → 备份 → Gist 备份」打开开关，粘上 token、填 Gist ID 和设备份密码：它会定时把 cookie 打成 ptgen_cookie_*.zip 加密推到那个 Gist，Gist 设成私密即可。",
            "Gist ID 就是备份 gist 网址 https://gist.github.com/用户名/ID 里那串 32 位十六进制；Gist 里真正的解密口令是「备份密码|GistID」，所以 PT-depiler 用的备份密码要一字不差地填进本页的「PT-depiler 备份密码」。",
            "再搭 CookieCloud：服务器上 docker run -d --name cookie-cloud -p 8088:8088 easychen/cookie-cloud，或用官方公共服务器；服务端只存密文，密钥不出本机。",
            "浏览器装 CookieCloud 扩展（easychen/CookieCloud，Chrome/Edge/Firefox 都能装），设置里填服务器地址，点「上传」后扩展会显示自己的 KEY（一串 UUID）和你设的加密密码。",
            "本软件「CookieCloud 同步」填服务器地址、KEY（UUID）、端对端加密密码（必须与扩展里的密码一致）：拉回 GET {服务器}/get/{KEY} 后在本地解密，再覆盖本地 cookie。",
            "两张卡片的「轮询」最小 5 分钟，打开「自动定时同步」到点自动拉；想立刻拉一次点该卡片的「立即同步」，或到「站点分组」页顶部点「同步 Cookie」两路一起同步，同步完自动复检 cookie。",
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
        ("4. 推送到下载器", new[]
        {
            "「设置」页「下载器」填 Web UI 地址、用户名与密码：qBittorrent 要在首选项里打开 Web UI 并取消「仅本机 localhost」，或经 VPS 隧道 / 反向代理暴露出来。",
            "卡片顶部只显示这台下载器的名字（随手起，如 VPS、家里NAS），地址只在下面输入框里改。",
            "「测试连接」验一次：能列出版本与下载目录才算通。",
            "保存路径留空用下载器默认目录，分类留空不打标签；「添加后跳过校验」按自己的下载习惯决定。",
            "「VPS 剩余空间」与「超过剩余空间时」的提醒 / 跳过策略是推送前的空间保护：qB WebAPI 读不到磁盘容量，这个数字要自己维护。",
            "转种成功的种子自动推到这台下载器；逐站上传限速在「站点分组」页按分组或站点填。",
        }),
        ("5. 转种服务器测速（SSH）", new[]
        {
            "部分服务器 24 小时上传流量到 2T 后，会把上行悄悄压到 20 MB/s 左右：站点照样能发种，但整批下载都变慢。",
            "「设置」页「转种服务器」卡片填写服务器地址、端口、用户名与私钥路径（Windows 版走密钥登录）。",
            "「测试连接并测速」立刻连一次：显示服务器主机名与每轮实测速度。",
            "「批量转种」页「开始运行」左边有「测试上传速度」：随时点一下，实测速度显示在按钮下面那一行，不做自动判定——速度不理想就等一等再转，不测也能直接开转。",
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
