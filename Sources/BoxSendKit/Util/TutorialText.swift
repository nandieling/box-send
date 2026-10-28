import Foundation

/// 使用说明正文。两端（macOS SwiftUI 与 Windows WPF）渲染的必须是这一份：
/// 之前两边各抄一份，改一处漏一处，Windows 那份甚至还在讲早就删掉的「推送结果区块」。
/// 少数几步在两个平台上按钮叫法、安装包格式确实不同，用 {占位} 现场替换，正文仍只有一份。
public enum TutorialText {
    public struct Section {
        public let title: String
        public let steps: [String]
        public let code: String?
        public init(title: String, steps: [String], code: String? = nil) {
            self.title = title
            self.steps = steps
            self.code = code
        }
    }

    /// 措辞按平台分流的词表（正文里的 {占位} 只查这张表）
    public enum OS: String {
        case macos, windows, other

        var tokens: [String: String] {
            switch self {
            case .macos:
                return ["manualCookie": "「手动添加cookie或api key」",
                        "checkCookies": "「检测cookie或api key」",
                        "sourceControl": "「源站」菜单",
                        "sshAuth": "选密钥或密码登录（密钥默认 ~/.ssh/id_ed25519，点「选择…」挑）",
                        "skipCheck": "「添加后跳过校验（skipChecking）」",
                        "autoUpdate": "「启动时自动检查新版本」",
                        "install": "双击 dmg 替换旧版本",
                        "pkg": "dmg",
                        "imageFormats": "PNG/JPG/HEIC"]
            case .windows:
                return ["manualCookie": "「手动填 cookie / Key」",
                        "checkCookies": "「检测全部 cookie」",
                        "sourceControl": "「源站」下拉框",
                        "sshAuth": "选密钥或密码登录（私钥路径写绝对路径或用 ~ 开头）",
                        "skipCheck": "「跳过校验」",
                        "autoUpdate": "「启动时自动检查」",
                        "install": "跑一遍 Setup.exe 覆盖安装",
                        "pkg": "Setup.exe",
                        "imageFormats": "PNG/JPG"]
            case .other:
                return OS.macos.tokens
            }
        }
    }

    public static let title = "BoxSend 使用说明"
    public static let footnote = "本页可与主窗口并排摆放，边看边设。"
    public static let repoLine = "项目地址：https://github.com/nandieling/box-send"

    public static var currentOS: OS {
        #if os(Windows)
        return .windows
        #elseif os(macOS)
        return .macos
        #else
        return .other
        #endif
    }

    /// 带 {占位} 的原文，测试按这份查覆盖率
    public static let rawSections: [Section] = [
        Section(title: "1. 添加站点与分组", steps: [
            "「站点分组」页顶部输入分组名并设置上传限速（默认 10 MB/s），点「添加分组」。",
            "点分组名旁的「添加站点」批量添加：搜索站点、点击卡片选中（加深色 = 已选），拖右侧把手或输入序号排序（序号重复会弹窗提示），点「添加 N 个站点」；添加后默认开启，限速默认取分组上传限速。",
            "点击站点卡片开启 / 停用该站；组名旁的「全选」一键切换整组；{manualCookie} 给选中的站点填 cookie 或 API Key（馒头等 API 站的 key 不显示在卡片上，只在该弹窗里填写）。",
            "{checkCookies} 批量检查 cookie / API Key 有效性，检测中旁边出现「停止检测」，点击可提前停止；「移除站点」「移除分组」均需两次确认。",
            "支持「帖子免费1天」的站点（如猫站）卡片上会出现「发种后免费一天」开关：打开后发种成功就自动点一次站内免费按钮（要扣站内积分）；帖子已在免费满一天时不重复扣。",
        ]),
        Section(title: "2. Cookie：PT-depiler Gist 与 CookieCloud", steps: [
            "两路都是「浏览器插件采集 → 云端存一份密文 → 本软件拉回来」：Gist 存 GitHub，CookieCloud 存自己的服务器。两路互为补充，某一站在一路过期时同步会用另一路补上，本地检测有效的 cookie 不会被覆盖。",
            "先搭 PT-depiler Gist：在 github.com/settings/tokens 生成 classic token，scope 只勾 gist（不用勾 repo、delete_repo）。",
            "PT-depiler「设置 → 备份 → Gist 备份」打开开关，粘上 token、填 Gist ID 和设备份密码：它会定时把 cookie 打成 ptgen_cookie_*.zip 加密推到那个 Gist，Gist 设成私密即可。",
            "Gist ID 就是备份 gist 网址 https://gist.github.com/用户名/ID 里那串 32 位十六进制；Gist 里真正的解密口令是「备份密码|GistID」，所以 PT-depiler 用的备份密码要一字不差地填进本页的「PT-depiler 备份密码」。",
            "再搭 CookieCloud：服务器上 docker run -d --name cookie-cloud -p 8088:8088 easychen/cookie-cloud，或用官方公共服务器；服务端只存密文，密钥不出本机。",
            "浏览器装 CookieCloud 扩展（easychen/CookieCloud，Chrome/Edge/Firefox 都能装），设置里填服务器地址，点「上传」后扩展会显示自己的 KEY（一串 UUID）和你设的加密密码。",
            "本软件「CookieCloud 同步」填服务器地址、KEY（UUID）、端对端加密密码（必须与扩展里的密码一致）：拉回 GET {服务器}/get/{KEY} 后在本地 AES 解密，再覆盖本地 cookie。",
            "两张卡片的「轮询」最小 5 分钟，打开「自动定时同步」到点自动拉；想立刻拉一次点该卡片的「立即同步」，或到「站点分组」页顶部点「同步 Cookie」两路一起同步，同步完自动复检 cookie。",
            "只有 PT-depiler 在本机导出过 zip 时才用得上「PT-depiler 本地备份」与备份目录监控；配好上面两路就够了。",
        ]),
        Section(title: "3. 批量转种", steps: [
            "「批量转种」页粘贴种子详情页链接，勾选「转种到目标站」与「推送到下载器」。",
            "源站默认按链接域名识别（种子链接旁边的{sourceControl}会显示识别结果）；站点分组里添加过的站点都能点名作源站。",
            "勾选转种分组（「全选」= 全部分组）后点「开始运行」，按钮旁会显示本批「已选几个分组 · 几个站点」。",
            "按分组顺序执行：获取种子 → 依次上传到组内已开启站点（限速取分组上传限速）→ 转种成功的种子自动推送到下载器。",
            "需要注明转种来源时勾选「源站引用」并填写文本：软件会把这段文字用引用块加在每个目标站简介的最上面；源站自带引用的不用勾。cmct、劳改所的「附加信息」框只用这段文字，没勾选时留空并在站点卡片上提示。",
            "每个站点的转种 / 推送结果写在它自己的卡片上；点「运行记录」展开看整批汇总与日志。",
        ]),
        Section(title: "4. 推送到下载器", steps: [
            "「设置」页「下载器」填 Web UI 地址、用户名与密码：qBittorrent 要在首选项里打开 Web UI 并取消「仅本机 localhost」，或经 VPS 隧道 / 反向代理暴露出来。",
            "卡片顶部只显示这台下载器的名字（随手起，如 VPS、家里NAS），地址只在下面输入框里改。",
            "「测试连接」验一次：能列出版本与下载目录才算通。",
            "保存路径留空用下载器默认目录，分类留空不打标签；{skipCheck} 按自己的下载习惯决定。",
            "「VPS 剩余空间」与「超过剩余空间时」的提醒 / 跳过策略是推送前的空间保护：qB WebAPI 读不到磁盘容量，这个数字要自己维护。",
            "转种成功的种子自动推到这台下载器；逐站上传限速在「站点分组」页按分组或站点填。",
        ]),
        Section(title: "5. 转种服务器测速（SSH）", steps: [
            "部分服务器 24 小时上传流量到 2T 后，会把上行悄悄压到 20 MB/s 左右：站点照样能发种，但整批下载都变慢。",
            "「设置」页「转种服务器」卡片填写服务器地址、端口、用户名，{sshAuth}。",
            "「测试连接并测速」立刻连一次：显示服务器主机名、每轮实测速度。",
            "「批量转种」页「开始运行」左边有「测试上传速度」：随时点一下，实测速度显示在按钮下面那一行，不做自动判定——速度不理想就等一等再转，不测也能直接开转。",
            "测速是在服务器上往公网推数据（默认每轮 64 MB、共两轮），只多花这一份上行；测速地址可换成自己的接收端。",
        ]),
        Section(title: "6. TMDB 反查与自建网关（Cloudflare Workers）", steps: [
            "部分站点（如杜比）把 TMDB 链接设为必填，源站简介里没有 TMDB 时发种会被拒；勾选「发种时自动补 TMDB 链接」后，发种前用种子的 IMDb 号或豆瓣号去查条目号填进目标站，查不到就留空由你手填。",
            "国内直连 api.themoviedb.org 常不通，拿自己的网关顶上去：「API 代理网关地址」留空即走官方接口；地址要写到版本号那一层（末尾带 /3，如 https://tmdb.我的名字.de5.net/tmdb123/3），漏写软件会自动补一次再试。网关只做转发时仍要填 TMDB 的 API Key，只有网关代填 Key 时才留空。",
            "① 拿域名：在 my.dnshe.com 注册账号（邮箱 + 密码，点一下邮箱验证），进会员中心「免费域名」申请一个 de5.net 的名字（如 myname，得到 myname.de5.net）；这种免费域名不用每年续，只要接入 Cloudflare 后 DNS 解析正常，就一直有效。",
            "② 接入 Cloudflare：dash.cloudflare.com 注册后点「Add a site」，主机名填完整那串 myname.de5.net（Cloudflare 允许把这种子域当成一个独立站点/区域），选 Free 计划，它会给你两台 NS，形如 evan.ns.cloudflare.com / irma.ns.cloudflare.com。",
            "③ 交出解析权：回 my.dnshe.com 的域名管理，把这两台 NS 填进该域名的独立解析 / NS 托管并保存（父域 de5.net 的 NS 仍是 dnshe 的，靠这条子域 NS 记录把解析权交给 Cloudflare）。等几十分钟后用 dig NS myname.de5.net 验证，返回应是 cloudflare.com 那两台。",
            "④ 部署 Worker：Cloudflare 控制台「Workers & Pages → Create → Worker」，把下面这段贴进去 Deploy。UPSTREAM 固定是 TMDB 官方接口，PREFIX 是自己随手起的暗号段（如 /tmdb123），只有带这个前缀的路径才转发，别人不知道前缀就蹭不动你的额度。",
            "⑤ 绑域名：该 Worker 的 Settings → Domains & Routes → Add → Custom domain，填 tmdb.myname.de5.net（主机名 tmdb），Cloudflare 会自动写 CNAME、签 HTTPS 证书，保持橙云（代理）即可。",
            "⑥ 填回软件：网关地址填 https://tmdb.myname.de5.net/tmdb123/3，点「测试查询」应回成功；浏览器直接打开同地址加 ?query=city&api_key=你的Key 也能出 JSON。不带 Key 会回 401，那说明网关已通、只是缺 Key。",
            "Workers 免费版每天 10 万次请求，转种这点查询量远远用不完；de5.net 域名本身不用续期，要盯的是 Cloudflare 那边的解析别被删掉。",
        ], code: workerCode),
        Section(title: "7. 软件更新", steps: [
            "更新地址就是项目仓库 https://github.com/nandieling/box-send，「设置」页「软件更新」卡片能看到当前版本并检查新版本。",
            "默认每次启动在后台查一次（只读 GitHub 的发布接口，不上传任何本机数据）；不想自动查就关掉{autoUpdate}，改成手动点「检查更新」。",
            "发现新版本点「下载 x.y 安装包」，{install}即可：站点、Cookie、限速与主题设置都存在本机，升级不会被动到。",
            "直连 GitHub 不通时会提示连不上，此时点「打开发布页」自己下载最新 {pkg}。",
        ]),
        Section(title: "8. 外观设置", steps: [
            "「设置」页选择渐变主题；主题渐变、强调色与明暗模式覆盖所有窗口与区块。",
            "可添加背景图片（{imageFormats}）并用滑块调整透明度，不改变窗口与各弹窗的大小比例。",
            "「使用教程」单独一扇窗口，可与主窗口并排摆着边看边设。",
        ]),
    ]

    /// Worker 脚本原样展示，抄走就能用
    public static let workerCode = """
    const UPSTREAM = "https://api.themoviedb.org";
    const PREFIX = "/tmdb123";              // 自己的暗号段，与网关地址里那段保持一致
    export default {
      async fetch(req, env) {
        const u = new URL(req.url);
        if (!u.pathname.startsWith(PREFIX)) return new Response("no", { status: 404 });
        const url = new URL(UPSTREAM + u.pathname.slice(PREFIX.length) + u.search);
        const key = env.TMDB_KEY || "";      // 配在 Worker 的 Variables 里；不配就得在软件里填 Key
        if (key && !url.searchParams.has("api_key")) url.searchParams.set("api_key", key);
        const r = await fetch(url, { method: req.method, headers: req.headers,
                                     body: req.body, redirect: "follow" });
        return new Response(r.body, { status: r.status, headers: r.headers });
      }
    }
    """

    /// 按平台出正文：{占位} 换成那一平台的叫法
    public static func sections(for os: OS) -> [Section] {
        rawSections.map { sec in
            Section(title: expand(sec.title, os.tokens),
                    steps: sec.steps.map { expand($0, os.tokens) },
                    code: sec.code.map { expand($0, os.tokens) })
        }
    }

    public static var current: [Section] { sections(for: currentOS) }

    /// 走 JSON 边界时的那份（Windows 端渲染用）
    public static func payload(for os: OS = .windows) -> [String: Any] {
        ["title": title, "footnote": footnote, "repo": repoLine,
         "sections": sections(for: os).map { s -> [String: Any] in
            var row: [String: Any] = ["title": s.title, "steps": s.steps]
            if let c = s.code { row["code"] = c }
            return row
        }]
    }

    private static func expand(_ s: String, _ tokens: [String: String]) -> String {
        var out = s
        for (k, v) in tokens { out = out.replacingOccurrences(of: "{\(k)}", with: v) }
        return out
    }
}
