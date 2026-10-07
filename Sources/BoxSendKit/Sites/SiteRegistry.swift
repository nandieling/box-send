import Foundation

/// 站点注册表：按 framework 选择适配器；NexusPHP 家族内置优先站点表。
public enum SiteRegistry {

    public static func adapter(for site: SiteConfig, client: HTTPClient, debugDir: String? = nil) -> SiteAdapter {
        switch site.framework {
        case .nexusPHP:
            let es = effectiveSite(site)
            // 肉丝这类 PeerGo 引擎站：上传页是 SPA，发种只能走 JSON API
            if es.overrides?.apiKeyStyle == "peergo" {
                return PeerGoAdapter(site: es, client: client, debugDir: debugDir)
            }
            return NexusPHPAdapter(site: es, client: client, debugDir: debugDir)
        case .blu:
            return BluAdapter(site: effectiveSite(site), client: client, debugDir: debugDir)
        case .gazelle, .gazelleJSONAPI, .xbtit:
            return GazelleAdapter(site: effectiveSite(site), client: client, debugDir: debugDir)
        case .tnode:
            return TNodeAdapter(site: site, client: client, debugDir: debugDir)
        case .haidan:
            return HaidanAdapter(site: effectiveSite(site), client: client, debugDir: debugDir)
        case .yemapt:
            return YemaPTAdapter(site: site, client: client, debugDir: debugDir)
        case .discuz:
            return DiscuzAdapter(site: effectiveSite(site), client: client, debugDir: debugDir)
        case .unit3D, .luminance, .avistaz, .custom:
            let es = effectiveSite(site)
            if let ov = es.overrides, ov.apiBase != nil {
                // API Key 站点（M-Team 等）：走 Unit3D API 适配器
                return Unit3DAdapter(site: es, client: client, debugDir: debugDir)
            }
            // 长尾站（M3）：暂无专属适配器，回退 NexusPHP 通用逻辑（源站解析尽力而为）
            return NexusPHPAdapter(site: es, client: client, debugDir: debugDir)
        default:
            fatalError("框架 \(site.framework.rawValue) 尚未实现适配器")
        }
    }

    /// 配置层 overrides 与内置表合并（内置为底，配置优先；旧配置缺的新字段自动用内置值）
    /// 配置里整段 overrides 缺失时也应用内置值（如馒头未带 overrides 仍需 API Key 标识）
    public static func effectiveSite(_ site: SiteConfig) -> SiteConfig {
        guard let builtin = prioritySites.first(where: { $0.id == site.id })?.overrides else {
            return site
        }
        var s = site
        s.overrides = (site.overrides ?? SiteOverride()).merged(over: builtin)
        return s
    }

    /// 内置站点表（参照 auto_feed 站点清单 + savept.icu 存活清单 + 用户账号实测）。
    /// 前 9 站为优先站（默认启用）；其余默认停用，用户在 GUI 启用并勾选为目标。
        public static let prioritySites: [SiteConfig] = [
        SiteConfig(id: "luckpt", name: "幸运", url: "https://pt.luckpt.de/", framework: .nexusPHP, enabled: true, overrides: .luckpt),
        SiteConfig(id: "hdsky", name: "天空", url: "https://hdsky.me/", framework: .nexusPHP, enabled: true, overrides: .hdsky),
        SiteConfig(id: "chdbits", name: "彩虹岛", url: "https://ptchdbits.co/", framework: .nexusPHP, enabled: true, overrides: .chdbits),
        SiteConfig(id: "hdhome", name: "家园", url: "https://hdhome.org/", framework: .nexusPHP, enabled: true, overrides: .hdhome),
        SiteConfig(id: "cmct", name: "春天", url: "https://springsunday.net/", framework: .nexusPHP, enabled: true, overrides: .cmct),
        SiteConfig(id: "audiences", name: "观众", url: "https://audiences.me/", framework: .nexusPHP, enabled: true, overrides: .audiences),
        SiteConfig(id: "ttg", name: "套", url: "https://totheglory.im/", framework: .nexusPHP, enabled: true, overrides: .ttg),
        SiteConfig(id: "pter", name: "猫", url: "https://pterclub.net/", framework: .nexusPHP, enabled: true, overrides: .pter),
        SiteConfig(id: "hhanclub", name: "憨憨", url: "https://hhanclub.net/", framework: .nexusPHP, enabled: true, overrides: .hhanclub),
        // --- Blu 家族（Layuout UI） ---
        SiteConfig(id: "blutopia", name: "Blutopia", url: "https://blutopia.cc/", framework: .blu, enabled: false, overrides: .blutopia),
        SiteConfig(id: "monika", name: "莫妮卡", url: "https://monikadesign.uk/", framework: .blu, enabled: false, overrides: .monika),
        // --- 经典 Gazelle / xbtit ---
        SiteConfig(id: "hdspace", name: "HD-Space", url: "https://hd-space.org/", framework: .gazelle, enabled: false, overrides: .hdspace),
        SiteConfig(id: "opencd", name: "皇后", url: "https://open.cd/", framework: .gazelle, enabled: false, overrides: .opencd),
        SiteConfig(id: "iptorrents", name: "IPT", url: "https://iptorrents.com/", framework: .gazelle, enabled: false, overrides: .iptorrents),
        // --- 特殊 NexusPHP（自定义字段/分类） ---
        SiteConfig(id: "byr", name: "北邮", url: "https://byr.pt/", framework: .nexusPHP, enabled: false, overrides: .byr),
        SiteConfig(id: "shadow", name: "影", url: "https://star-space.net/", framework: .nexusPHP, enabled: false, overrides: .shadow),
        // --- 通用中文 NexusPHP（动态分类解析，免逐站配置） ---
        SiteConfig(id: "city13", name: "13City", url: "https://13city.org/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "ptba", name: "1PT", url: "https://1ptba.com/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "movie52", name: "52MOVIE", url: "https://www.52movie.top/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "pt52", name: "52PT", url: "https://52pt.site/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "agsvpt", name: "末日", url: "https://www.agsvpt.com/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "railgun", name: "Railgun", url: "https://bilibili.download/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "cangbao", name: "藏宝阁", url: "https://cangbao.ge/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "carpt", name: "车站", url: "https://carpt.net/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "crabpt", name: "蟹黄堡", url: "https://crabpt.vip/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "cspt", name: "财神", url: "https://cspt.top/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "cyanbug", name: "大青虫", url: "https://cyanbug.net/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "discfan", name: "蝶粉", url: "https://discfan.net/", framework: .nexusPHP, enabled: false, overrides: .discfan),
        SiteConfig(id: "dragonhd", name: "龙之家", url: "https://www.dragonhd.xyz/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "dubhe", name: "天枢", url: "https://dubhe.site/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "march", name: "三月", url: "https://duckboobee.org/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "tccf", name: "TCCF", url: "https://et8.org/", framework: .nexusPHP, enabled: false, overrides: .tccf),
        SiteConfig(id: "ggpt", name: "GGPT", url: "https://www.gamegamept.com/", framework: .nexusPHP, enabled: false, overrides: .ggpt),
        SiteConfig(id: "hdarea", name: "高清视界", url: "https://hdarea.club/", framework: .nexusPHP, enabled: false, overrides: .hdarea),
        SiteConfig(id: "hdbao", name: "海德堡", url: "https://hdbao.cc/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "hddolby", name: "杜比", url: "https://www.hddolby.com/", framework: .nexusPHP, enabled: false, overrides: .hddolby),
        SiteConfig(id: "hdfans", name: "红豆饭", url: "http://hdfans.org/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "qilin", name: "麒麟", url: "https://www.hdkyl.in/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "hdtime", name: "时光", url: "https://hdtime.org/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "hdvideo", name: "HDVideo", url: "https://hdvideo.top/", framework: .nexusPHP, enabled: false, overrides: .hdvideo),
        SiteConfig(id: "hitpt", name: "百川", url: "https://www.hitpt.com/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "haitang", name: "海棠", url: "https://www.htpt.cc/", framework: .nexusPHP, enabled: false, overrides: .haitang),
        SiteConfig(id: "hudbt", name: "蝴蝶", url: "https://hudbt.hust.edu.cn/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "haoxue", name: "好学", url: "https://www.hxpt.org/", framework: .nexusPHP, enabled: false, overrides: .haoxue),
        SiteConfig(id: "ziran", name: "自然", url: "https://naturept.top/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "kufei", name: "库非", url: "https://kufei.org/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "lajidui", name: "垃圾堆", url: "https://pt.lajidui.top/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "lemonhd", name: "柠檬不甜", url: "https://lemonhd.net/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "longpt", name: "龙", url: "https://longpt.org/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "iloli", name: "爱萝莉", url: "https://mua.xloli.cc/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "njtupt", name: "蒲园", url: "https://njtupt.top/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "okpt", name: "OK", url: "https://www.okpt.net/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "oshen", name: "奥申", url: "http://www.oshen.win/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "baozi", name: "包子", url: "https://p.t-baozi.cc/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "panda", name: "熊猫", url: "https://pandapt.net/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "piggo", name: "猪猪", url: "https://piggo.me/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "freefarm", name: "农场", url: "https://pt.0ff.cc/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "aling", name: "爱玲", url: "https://pt.aling.de/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "btschool", name: "学校", url: "https://pt.btschool.club/", framework: .nexusPHP, enabled: false, overrides: .btschool),
        SiteConfig(id: "tlf", name: "吐鲁番", url: "http://pt.eastgame.org/", framework: .nexusPHP, enabled: false, overrides: .tlf),
        SiteConfig(id: "gtk", name: "GTK", url: "https://pt.gtkpw.xyz/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "hdclone", name: "独自", url: "https://pt.hdclone.top/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "itzmx", name: "Itz", url: "https://pt.itzmx.com/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "muxuege", name: "慕雪阁", url: "https://pt.muxuege.org/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "novahd", name: "nova", url: "https://pt.novahd.top/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "soulvoice", name: "聆音", url: "https://pt.soulvoice.club/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "hdu", name: "好多油", url: "https://pt.upxin.net/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "xingyunge", name: "星陨阁", url: "https://pt.xingyungept.org/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "yinghua", name: "樱花", url: "http://pt.ying.us.kg/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "ptcafe", name: "咖啡", url: "https://ptcafe.club/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "ptfans", name: "PTFans", url: "https://ptfans.cc/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "pthome", name: "铂金家", url: "https://www.pthome.net/", framework: .nexusPHP, enabled: false, overrides: .pthome),
        SiteConfig(id: "ptlgs", name: "劳改所", url: "https://ptlgs.org/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "ptsbao", name: "烧包", url: "https://ptsbao.club/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "ptskit", name: "拾刻", url: "https://www.ptskit.org/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "ptt", name: "时间", url: "https://www.pttime.org/", framework: .nexusPHP, enabled: false, overrides: .ptt),
        SiteConfig(id: "ptzone", name: "葡萄汁", url: "https://ptzone.xyz/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "qingwa", name: "青蛙", url: "https://qingwapt.com/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "sbpt", name: "SBPT", url: "https://sbpt.link/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "shuioudao", name: "下水道", url: "https://sewerpt.com/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "tangpt", name: "躺平", url: "https://www.tangpt.top/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "tjupt", name: "北洋园", url: "https://www.tjupt.org/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "ubits", name: "优堡", url: "https://ubits.club/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "ultrahd", name: "UltraHD", url: "https://ultrahd.net/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "wtsakura", name: "冬樱", url: "https://wintersakura.net/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "xingtan", name: "杏坛", url: "https://xingtan.one/", framework: .nexusPHP, enabled: false, overrides: .xingtan),
        SiteConfig(id: "zmpt", name: "织梦", url: "https://zmpt.cc/", framework: .nexusPHP, enabled: false, overrides: .zmpt),
        SiteConfig(id: "u2", name: "幼儿圈", url: "http://u2.dmhy.org/", framework: .nexusPHP, enabled: false, overrides: .u2),
        // --- TNode（REST API + SPA） ---
        SiteConfig(id: "zhuque", name: "朱雀", url: "https://zhuque.in/", framework: .tnode, enabled: false, overrides: nil),
        // --- Haidan（NexusPHP 后端 + 自定义详情布局） ---
        SiteConfig(id: "haidan", name: "海胆", url: "https://www.haidan.cc/", framework: .haidan, enabled: false, overrides: .haidan),
        // --- YemaPT（umi.js SPA + REST API） ---
        SiteConfig(id: "yemapt", name: "野马", url: "https://www.yemapt.org/", framework: .yemapt, enabled: false, overrides: .yemapt),
        // --- 中文 NexusPHP（参照 savept.icu 2026-09-30 新增，未逐站实测，通用动态适配） ---
        SiteConfig(id: "azusa", name: "梓喵", url: "https://azusa.wiki/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "dicmusic", name: "海豚", url: "https://dicmusic.com/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "dstudio", name: "Depth Studio", url: "https://dstudio.me/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "kamept", name: "龟站", url: "https://kamept.com/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "nanyang", name: "南洋", url: "https://nanyangpt.com/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "kelu", name: "Kelu", url: "https://our.kelu.one/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "playlet", name: "PlayLet", url: "https://playlet.cc/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "daxiangjiao", name: "大香蕉", url: "https://pt.daxiangjiao.org/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "keepfrds", name: "朋友", url: "https://pt.keepfrds.com/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "mypt", name: "我的PT", url: "https://pt.mypt.cc/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "tey", name: "太乙", url: "https://pt.tey.cc/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "tu88", name: "TU88", url: "https://pt.tu88.men/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "vclib", name: "VC-Lib", url: "https://pt.vclib.online/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "ptlao", name: "忘年桥", url: "https://ptlao.top/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "rousi", name: "肉丝", url: "https://rousi.pro/", framework: .nexusPHP, enabled: false, overrides: .rousi),
        SiteConfig(id: "yzyy", name: "YZYY", url: "https://www.yzyy.org/", framework: .discuz, enabled: false, overrides: SiteOverride(uploadPath: "plugin.php?id=dz_seed:publish")),
        SiteConfig(id: "siqi", name: "思齐", url: "https://si-qi.xyz/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "sunny", name: "阳光", url: "https://sunnypt.top/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "momentpt", name: "瞬间", url: "https://www.momentpt.top/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "musopia", name: "音乐乌托邦", url: "https://www.musopia.vip/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "nicept", name: "老师", url: "https://www.nicept.net/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "tokyo", name: "Tokyo", url: "https://www.tokyo-manga.top/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "xdy", name: "修道院", url: "https://xdypt.vip/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "xingwan", name: "星湾", url: "https://xingwan.cc/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "hdcity", name: "城市", url: "https://hdcity.city/", framework: .nexusPHP, enabled: false, overrides: .hdcity),
        SiteConfig(id: "fenghuang", name: "凤凰", url: "https://pt.521.best/", framework: .nexusPHP, enabled: false, overrides: .nexusCN),
        SiteConfig(id: "generationfree", name: "Generation-Free", url: "https://generation-free.org/", framework: .nexusPHP, enabled: false, overrides: nil),
        // --- Unit3D 家族（暂走 NexusPHP 通用逻辑，M3 待专属适配器） ---
        SiteConfig(id: "mteam", name: "馒头", url: "https://kp.m-team.cc/", framework: .unit3D, enabled: false, overrides: .mteam),
        SiteConfig(id: "oldtoons", name: "Oldtoons", url: "https://oldtoons.world/", framework: .unit3D, enabled: false, overrides: .oldtoons),
        SiteConfig(id: "milkie", name: "奶昔", url: "https://milkie.cc/", framework: .unit3D, enabled: false, overrides: nil),
        SiteConfig(id: "ptneko", name: "超科学PT喵", url: "https://ptneko.com/", framework: .unit3D, enabled: false, overrides: nil),
        SiteConfig(id: "anthelion", name: "Anthelion", url: "https://anthelion.me/", framework: .unit3D, enabled: false, overrides: nil),
        SiteConfig(id: "brokenstones", name: "BrokenStones", url: "https://brokenstones.is/", framework: .unit3D, enabled: false, overrides: nil),
        SiteConfig(id: "exoticaz", name: "ExoticaZ", url: "https://exoticaz.to/", framework: .unit3D, enabled: false, overrides: nil),
        SiteConfig(id: "filelist", name: "FileList", url: "https://filelist.io/", framework: .unit3D, enabled: false, overrides: nil),
        SiteConfig(id: "happyfappy", name: "HappyFappy", url: "https://happyfappy.net/", framework: .unit3D, enabled: false, overrides: nil),
        SiteConfig(id: "jpopsuki", name: "Jpopsuki", url: "https://jpopsuki.eu/", framework: .unit3D, enabled: false, overrides: nil),
        SiteConfig(id: "nebulance", name: "Nebulance", url: "https://nebulance.io/", framework: .unit3D, enabled: false, overrides: nil),
        SiteConfig(id: "orpheus", name: "Orpheus", url: "https://orpheus.network/", framework: .unit3D, enabled: false, overrides: nil),
        SiteConfig(id: "empornium", name: "峨眉派", url: "https://www.empornium.sx/", framework: .unit3D, enabled: false, overrides: nil),
        // --- 经典 Gazelle 家族 ---
        SiteConfig(id: "alpharatio", name: "AlphaRatio", url: "https://alpharatio.cc/", framework: .gazelle, enabled: false, overrides: nil),
        SiteConfig(id: "animez", name: "AnimeZ", url: "https://animez.to/", framework: .gazelle, enabled: false, overrides: nil),
        SiteConfig(id: "sportscult", name: "SportsCult", url: "https://sportscult.org/", framework: .gazelle, enabled: false, overrides: nil),
        // --- xbtit 家族 ---
        SiteConfig(id: "beyondhd", name: "BeyondHD", url: "https://beyond-hd.me/", framework: .xbtit, enabled: false, overrides: nil),
        SiteConfig(id: "clearjav", name: "ClearJAV", url: "https://clearjav.com/", framework: .xbtit, enabled: false, overrides: nil),
        SiteConfig(id: "fappaizuri", name: "Fappaizuri", url: "https://fappaizuri.me/", framework: .xbtit, enabled: false, overrides: nil),
        SiteConfig(id: "huno", name: "HUNO", url: "https://hawke.uno/", framework: .xbtit, enabled: false, overrides: nil),
        SiteConfig(id: "hdtorrents", name: "HD-Torrents", url: "https://hd-torrents.org/", framework: .xbtit, enabled: false, overrides: nil),
        // --- 自研系统（走 NexusPHP 通用逻辑尽力而为，M3 待实测） ---
        SiteConfig(id: "aither", name: "Aither", url: "https://aither.cc/", framework: .custom, enabled: false, overrides: nil),
        SiteConfig(id: "bitporn", name: "BitPorn", url: "https://bitporn.eu/", framework: .custom, enabled: false, overrides: nil),
        SiteConfig(id: "gpw", name: "海豹", url: "https://greatposterwall.com/", framework: .custom, enabled: false, overrides: nil),
        SiteConfig(id: "lst", name: "LST", url: "https://lst.gg/", framework: .custom, enabled: false, overrides: nil),
        SiteConfig(id: "myanonamouse", name: "MyAnonamouse", url: "https://www.myanonamouse.net/", framework: .custom, enabled: false, overrides: nil),
        SiteConfig(id: "ourbits", name: "我堡", url: "https://ourbits.club/", framework: .custom, enabled: false, overrides: nil),
        SiteConfig(id: "sjtu", name: "葡萄", url: "https://pt.sjtu.edu.cn/", framework: .custom, enabled: false, overrides: nil),
        SiteConfig(id: "torrentleech", name: "TorrentLeech", url: "https://www.torrentleech.cc/", framework: .custom, enabled: false, overrides: nil),
    ]
}
