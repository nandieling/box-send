import Foundation

/// 9 优先站的内置 overrides。
/// 由 2026-09-28 用真实账号 cookie 实测各站上传表单生成（POST takeupload.php、字段名、分类表、质量下拉表）；
/// 2026-09-29 补充各站副标题/标签/制作组(地区)字段实测值 + 各站搜索端点实测（查重 searchURL）。
/// 配置 JSON 里的 site.overrides 与这里按 key 合并（配置优先）；新增/修改站点差异请两处同步。
extension SiteOverride {
    /// luckpt（LuckPT）
    static let luckpt = SiteOverride(
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        categoryField: "type",
        searchURL: "search.php?search={name}",  // 2026-09-29 实测可用（查重）
        categoryMap: ["movie": 401, "series": 402, "anime": 405, "documentary": 411, "music": 408, "other": 409],
        extraUploadFields: ["uplver": "yes"],
        qualitySelects: ["medium_sel[4]": "medium", "codec_sel[4]": "codec", "audiocodec_sel[4]": "audiocodec", "standard_sel[4]": "standard"],
        qualityValueMaps: ["medium": ["remux": 3, "uhdbd": 10, "uhdbd8k": 10, "uhd8k": 10, "uhd": 7, "webdl": 11, "bluray": 1, "encode": 7, "hdtv": 5, "dvd": 6, "track": 9], "codec": ["hevc": 6, "avc": 1, "vc1": 3, "mpeg2": 4, "av1": 2, "xvid": 12], "audiocodec": ["dtsma": 16, "dtsc": 15, "truehd atmos": 11, "truehd": 14, "eac3 atmos": 12, "eac3": 12, "ac3": 8, "dts": 3, "flac": 1, "ape": 2, "aac": 6, "mp3": 4, "ogg": 5, "pcm": 19, "lpcm": 13, "wav": 18, "m4a": 17], "standard": ["8k": 7, "2160p": 6, "1080p": 1, "1080i": 1, "720p": 3, "sd": 4]],
        subtitleField: "small_descr",
        sourceLabel: "LuckPT",
        tagField: "tags[4][]",
        tagMap: ["chinese_sub": "23", "hdr10": "20", "hdr10plus": "19", "dovi": "21", "forbid": "8"],
        teamField: "team_sel[4]",
        teamOtherValue: 5,
        teamPatterns: ["LuckWeb": 7, "LuckMusic": 8, "FRDS": 9, "StarfallWeb": 10, "LuckAni": 11, "LuckDIY": 12, "LuckDocu": 13]
    )

    /// hdsky（HDSky）
    static let hdsky = SiteOverride(
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        doubanField: "url_douban",
        doubanValueTemplate: "https://movie.douban.com/subject/{douban}/",
        categoryField: "type",
        searchURL: "torrents.php?search={name}",  // 2026-09-29 实测可用（查重）
        categoryMap: ["movie": 401, "series": 402, "tvshow": 403, "anime": 405, "documentary": 404, "music": 408, "sports": 407, "other": 409],
        extraUploadFields: ["uplver": "yes"],
        qualitySelects: ["medium_sel": "medium", "codec_sel": "codec", "audiocodec_sel": "audiocodec", "standard_sel": "standard"],
        // 编码选格式选项（1=H.264/AVC、12=HEVC）：10=x264、13=x265 是压制器，转种带不出编码器信息，不该选
        qualityValueMaps: ["medium": ["remux": 3, "uhdbd": 13, "uhdbd8k": 13, "uhd8k": 13, "uhd": 7, "webdl": 11, "bluray": 1, "encode": 7, "hdtv": 5, "dvd": 6, "track": 9], "codec": ["hevc": 12, "avc": 1, "vc1": 2, "mpeg2": 4, "av1": 16, "xvid": 3], "audiocodec": ["dtsma": 10, "dtsbr": 14, "dtsc": 16, "truehd atmos": 17, "truehd": 11, "eac3 atmos": 21, "eac3": 20, "ac3": 12, "dts": 3, "flac": 1, "ape": 2, "aac": 6, "mp3": 4, "ogg": 5, "pcm": 19, "lpcm": 13, "wav": 15, "alac": 23, "m4a": 23, "opus": 22], "standard": ["8k": 6, "2160p": 5, "1080p": 1, "1080i": 2, "720p": 3, "sd": 4]],
        subtitleField: "small_descr",
        descrFormat: "bbcode",
        tagField: "option_sel[]",
        tagMap: ["chinese_sub": "6", "hdr10": "9", "hdr10plus": "17", "dovi": "15", "dtsx": "23", "atmos": "21", "forbid": "2", "limited": "25"],
        teamField: "team_sel",
        teamOtherValue: 27,
        teamPatterns: ["HDSky": 6, "HDS3D": 28, "HDSTV": 9, "HDSWEB": 31, "HDSPad": 18, "HDSCD": 22, "HDSpecial": 34, "HDSAB": 36, "BMDru": 30, "AREA11": 25, "Original": 24, "Autoseed": 26, "Request": 33, "HDS": 1]
    )

    /// chdbits（CHDBits）
    static let chdbits = SiteOverride(
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        categoryField: "type",
        fileField: "torrentfile",
        searchURL: "torrents.php?search={name}",  // 2026-09-29 实测可用（查重）
        categoryMap: ["movie": 401, "series": 402, "anime": 405, "documentary": 404, "music": 408, "other": 409],
        extraUploadFields: ["uplver": "yes"],
        qualitySelects: ["medium_sel": "medium", "codec_sel": "codec", "audiocodec_sel": "audiocodec", "standard_sel": "standard"],
        qualityValueMaps: ["medium": ["remux": 3, "uhdbd": 19, "uhdbd8k": 19, "uhd8k": 19, "uhd": 4, "webdl": 18, "bluray": 1, "encode": 4, "hdtv": 6], "codec": ["hevc": 5, "avc": 1, "vc1": 2, "mpeg2": 4, "av1": 3, "xvid": 6], "audiocodec": ["dtsma": 10, "truehd": 11, "ac3": 7, "dts": 3, "flac": 1, "ape": 2, "lpcm": 13, "pcm": 13, "wav": 12, "aac": 6, "alac": 14, "m4a": 14], "standard": ["1080p": 1, "1080i": 2, "720p": 3, "2160p": 6, "8k": 7]],
        subtitleField: "small_descr",
        tagCheckboxes: ["chinese_sub": "cnsub", "limited": "limited"],
        teamField: "team_sel",
        teamOtherValue: 0,
        teamPatterns: ["CHDBits": 14, "CHDHKTV": 11, "CHDWEB": 12, "CHDTV": 2, "CHDPAD": 15, "CHDBPM": 28, "GrammyFan": 29, "OneHD": 8, "blucook": 16, "SGNB": 13, "REMUX": 1, "KAN": 19, "JKCT": 22, "BMDru": 23, "Destiny": 25, "GrassTV": 27, "SP": 26]
    )

    /// hdhome（HDHome）
    static let hdhome = SiteOverride(
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        doubanField: "douban_id",
        categoryField: "type",
        searchURL: "torrents.php?search={name}",  // 2026-09-29 实测可用（查重）
        categoryMap: ["movie/8k-bd": 506, "movie/8k": 505, "movie/uhd-bd": 499, "movie/remux": 415, "movie/2160p": 416, "movie/bluray": 450, "movie/1440p": 414, "movie/1080p": 414, "movie/720p": 413, "movie/sd": 411, "series/8k-bd": 523, "series/8k": 526, "series/uhd-bd": 502, "series/remux": 437, "series/2160p": 438, "series/bluray": 453, "series/1440p": 436, "series/1080p": 436, "series/1080i": 435, "series/720p": 434, "series/sd": 432, "documentary/8k-bd": 508, "documentary/8k": 507, "documentary/uhd-bd": 500, "documentary/remux": 421, "documentary/2160p": 422, "documentary/bluray": 451, "documentary/1440p": 420, "documentary/1080p": 420, "documentary/720p": 419, "documentary/sd": 417, "anime/8k-bd": 510, "anime/8k": 509, "anime/uhd-bd": 501, "anime/remux": 448, "anime/2160p": 449, "anime/bluray": 454, "anime/1440p": 447, "anime/1080p": 447, "anime/720p": 446, "anime/sd": 444, "sports/8k": 511, "sports/2160p": 504, "sports/1080p": 443, "sports/1080i": 443, "sports/720p": 442, "music": 440, "movie": 414, "series": 436, "documentary": 420, "anime": 447, "sports": 442, "other": 409],
        extraUploadFields: ["uplver": "yes"],
        qualitySelects: ["medium_sel": "medium", "codec_sel": "codec", "audiocodec_sel": "audiocodec", "standard_sel": "standard"],
        qualityValueMaps: ["medium": ["remux": 3, "uhdbd": 10, "uhdbd8k": 10, "uhd8k": 10, "uhd": 7, "webdl": 11, "bluray": 1, "encode": 7, "hdtv": 5], "codec": ["avc": 1, "hevc": 2, "vc1": 3, "mpeg2": 4], "audiocodec": ["dtsma": 11, "dtsbr": 18, "dtsc": 17, "truehd atmos": 12, "truehd": 13, "lpcm": 14, "pcm": 14, "ac3": 15, "flac": 1, "ape": 2, "aac": 6, "wav": 16], "standard": ["2160p": 1, "1080p": 2, "1080i": 3, "720p": 4, "sd": 5, "8k": 10]],
        subtitleField: "small_descr",
        tagField: "tags[]",
        tagMap: ["chinese_sub": "zz", "hdr10": "hdr10", "hdr10plus": "hdrm", "dovi": "db", "forbid": "jz", "limited": "xz"],
        teamField: "team_sel",
        teamOtherValue: 11,
        teamPatterns: ["HDHWEB": 12, "HDHTV": 3, "HDHPad": 4, "HDHome": 1, "HDH": 2, "M-Team": 7, "TVman": 21, "ARiN": 19, "SHMA": 17, "3201": 20, "TTG": 6, "BMDru": 23, "969154968": 22]
    )

    /// cmct（CMCT）
    static let cmct = SiteOverride(
        uploadActionPath: "takeupload.php",
        titleField: "name",
        titleMode: "torrentNameDotted",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        posterField: "url_poster",        // 海报 = 源简介首图
        descrStyle: "reseedSource",       // descr 字段是"附加信息"：写转种来源，不写简介
        categoryField: "type",
        screenshotField: "url_vimages",   // 必填：截图 URL 文本域（每行一个，取源简介图片，不含海报）
        searchURL: "torrents.php?search={name}",  // 2026-09-29 实测可用（查重）
        categoryMap: ["movie": 501, "series": 502, "documentary": 503, "music": 508, "anime": 509, "other": 509],
        extraUploadFields: ["uplver": "yes"],
        qualitySelects: ["medium_sel": "medium", "codec_sel": "codec", "audiocodec_sel": "audiocodec", "standard_sel": "standard"],
        qualityValueMaps: ["medium": ["remux": 4, "uhdbd": 1, "uhdbd8k": 1, "uhd8k": 1, "uhd": 1, "webdl": 7, "bluray": 6, "encode": 6, "hdtv": 5, "dvd": 10, "track": 99], "codec": ["hevc": 1, "avc": 2, "vc1": 3, "mpeg2": 4, "av1": 5], "audiocodec": ["dtsma": 1, "truehd": 2, "lpcm": 6, "pcm": 6, "dts": 3, "eac3": 11, "ac3": 4, "aac": 5, "flac": 7, "ape": 8, "wav": 9, "mp3": 10, "opus": 12], "standard": ["2160p": 1, "1080p": 2, "1080i": 3, "720p": 4, "sd": 5, "8k": 99]],
        subtitleField: "small_descr"
    )

    /// audiences（Audiences）
    static let audiences = SiteOverride(
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        doubanField: "douban_id",
        categoryField: "type",
        searchURL: "torrents.php?search={name}",  // 2026-09-29 实测可用（查重）
        categoryMap: ["movie": 401, "series": 402, "documentary": 406, "music": 408, "anime": 409, "other": 409],
        extraUploadFields: ["uplver": "yes"],
        qualitySelects: ["medium_sel": "medium", "codec_sel": "codec", "audiocodec_sel": "audiocodec", "standard_sel": "standard"],
        qualityValueMaps: ["medium": ["remux": 3, "uhdbd": 12, "uhdbd8k": 12, "uhd8k": 12, "uhd": 15, "webdl": 10, "bluray": 1, "encode": 15, "hdtv": 5, "dvd": 2, "track": 9], "codec": ["hevc": 6, "avc": 1, "vc1": 2, "mpeg2": 4, "av1": 7], "audiocodec": ["dtsc": 25, "truehd atmos": 26, "dtsma": 19, "truehd": 20, "lpcm": 21, "pcm": 21, "eac3 atmos": 18, "eac3": 18, "ac3": 18, "dts": 3, "aac": 6, "flac": 1, "ape": 2, "opus": 27, "wav": 22, "mp3": 23, "m4a": 24], "standard": ["8k": 10, "2160p": 5, "1080p": 1, "1080i": 2, "720p": 3, "sd": 4]],
        subtitleField: "small_descr",
        tagField: "tags[]",
        tagMap: ["chinese_sub": "zz", "hdr10": "hdr10", "hdr10plus": "hdrm", "dovi": "db", "forbid": "jz", "limited": "xz"]
    )

    /// ttg（TTG）
    /// .torrent 直链为 /dl/<id>/<随机号>（页面另有 /dl/<id>/zip/<n> 截图包与 /dl/<id>/<32位hex> 种子链接）
    static let ttg = SiteOverride(
        torrentLinkPattern: "/dl/\\d+/\\d+$",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "imdb_c",
        doubanField: "douban_id",
        categoryField: "type",
        fileField: "file",
        searchURL: "browse.php?search_field={name}",   // 2026-10-05 实测：search.php 丢参，表单 action=browse.php 且输入框名为 search_field
        categoryMap: ["movie/uhd-bd": 109, "movie/8k-bd": 109, "movie/2160p": 108, "movie/8k": 108, "movie/remux": 54, "movie/bluray": 54, "movie/1440p": 53, "movie/1080p": 53, "movie/1080i": 53, "movie/720p": 52, "movie/sd": 51, "movie/dvd": 51, "documentary/uhd-bd": 67, "documentary/8k-bd": 67, "documentary/2160p": 67, "documentary/8k": 67, "documentary/remux": 67, "documentary/bluray": 67, "documentary/1440p": 63, "documentary/1080p": 63, "documentary/1080i": 63, "documentary/720p": 62, "documentary/sd": 62, "documentary/dvd": 62, "series/uhd-bd": 70, "series/8k-bd": 70, "series/2160p": 70, "series/8k": 70, "series/remux": 70, "series/bluray": 70, "series/1440p": 70, "series/1080p": 70, "series/1080i": 70, "series/720p": 69, "series/sd": 69, "series/dvd": 69, "anime/uhd-bd": 111, "anime/8k-bd": 111, "anime/2160p": 58, "anime/8k": 58, "anime/remux": 58, "anime/bluray": 58, "anime/1440p": 58, "anime/1080p": 58, "anime/1080i": 58, "anime/720p": 58, "anime/sd": 58, "anime/dvd": 58, "music": 83, "movie": 53, "documentary": 63, "series": 70, "anime": 58, "other": 32],
        extraUploadFields: ["anonymity": "no"],  // -1=请选择 会被服务端拒绝（"请选择是否匿名发布"）
        subtitleField: "subtitle"
    )

    /// pter（PTer）
    static let pter = SiteOverride(
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        doubanField: "douban",
        categoryField: "type",
        searchURL: "torrents.php?search={name}",  // 2026-09-29 实测可用（查重）
        categoryMap: ["movie": 401, "series": 404, "anime": 403, "documentary": 402, "music": 406, "other": 412],
        subtitleField: "small_descr",
        // 标签是拼音命名的独立复选框（auto_feed 同款映射）：禁转/官方/国语/粤语/中字/英字/应求/DIY原盘
        tagCheckboxes: ["chinese_sub": "zhongzi", "forbid": "jinzhuan", "official": "guanfang",
                        "mandarin": "guoyu", "cantonese": "yueyu", "english_sub": "ensub",
                        "demand": "yingqiu", "diy": "diy"],
        regionField: "team_sel",
        regionPatterns: ["中国大陆": 1, "内地": 1, "中国": 1, "香港": 2, "台湾": 3, "美国": 4, "加拿大": 4, "英国": 4, "法国": 4, "德国": 4, "意大利": 4, "西班牙": 4, "瑞典": 4, "韩国": 5, "日本": 6, "印度": 7],
        regionOtherValue: 8
    )

    /// 织梦（zmpt）：简介需注明转种来源；音频无 PCM/LPCM 选项（自动落 Other）
    static let zmpt = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        categoryField: "type",
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr",
        descrSourcePrefix: true
    )

    /// 城市（HDCity，自研框架）：上传分两步——种子文件 POST 到独立上传域名，
    /// 站点回跳元信息表单页后再提交分类/质量/标签；标签是"选项值即文案"的下拉。
    /// 成功跳转是 /t-<id>，按 successIDPattern 组装详情链接。
    static let hdcity = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "upload.php",
        titleField: "name",
        titleStrip: " - An Advanced City For Entertainment - HDCiTY",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        posterField: "posterimg",
        categoryField: "type",
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr",
        tagSelectFields: ["tag1ing", "tag2ing"],
        uploadTwoStep: true,
        successIDPattern: "/t-(\\d+)"
    )

    /// hhanclub：候选区上传（offers.php），M2；目前无 overrides
    // MARK: - 通用中文 NexusPHP（2026-09-29 批量接入）

    /// 通用中文 NexusPHP 默认值：POST takeupload.php、标题 name、IMDB 走 url 字段。
    /// 分类走 NexusPHPAdapter 动态解析（上传页 <select> 关键词匹配），质量下拉保持服务器默认值；
    /// 个别站字段不同（如 PTFans 的 pt_gen/小描述位置、CHDBits 的 torrentfile）请用配置层 overrides 覆盖。
    /// 肉丝（rousi.pro）：PeerGo 引擎，走 API Key（`Authorization: Bearer`），
    /// 表单字段沿用中文 NexusPHP 命名习惯，但发种必须走 API（HTML 上传页是 SPA，POST 表单会 405）
    static var rousi: SiteOverride {
        var o = SiteOverride.nexusCN
        o.usesAPIKey = true
        o.apiBase = "https://rousi.pro"
        o.apiKeyStyle = "peergo"
        // 查重端点（PeerGoAdapter 用它拼关键词检索；也是流水线「允许预查重」的开关）
        o.searchURL = "api/v1/torrents?keyword={name}"
        return o
    }

    static let nexusCN = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        categoryField: "type",
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr"
    )

    /// hddolby（杜比）：.nexusCN 基础上增加必填截图 URL 文本域（每行一个截图 URL）
    static let hddolby = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        tmdbField: "tmdb_url",   // 必填：源站简介 TMDB 链接
        categoryField: "type",
        screenshotField: "screenshots",
        extraUploadFields: ["uplver": "yes"]
    )

    /// mteam（馒头 M-Team）：不走 cookie 同步，用 API Key 连接（api.m-team.cc，Unit3D API）
    static let mteam = SiteOverride(
        // 查重走 API（/api/torrent/search），这里只作为「启用自动查重」的开关
        searchURL: "https://kp.m-team.cc/torrents/search?keyword={name}",
        apiBase: "https://api.m-team.cc",
        usesAPIKey: true
    )

    /// yemapt（YemaPT）：umi.js SPA + REST API；查重走 findImdbTorrentList（imdb 必填才生效）
    static let yemapt = SiteOverride(
        searchURL: "api/torrent/findImdbTorrentList?imdbId={imdb}"
    )

    /// byr（BYR）：分类走 auto_feed 实测 type 表（电影408 剧集401 综艺405 音乐402 动漫404 纪录410）
    /// haidan（HAIDAN 海胆之家）：NexusPHP 后端，豆瓣字段 durl，tag_list[] 由动态标签匹配（3中字/4DIY/7原盘）
    static let haidan = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        doubanField: "durl",
        categoryField: "type",
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr"
    )

    static let byr = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        categoryField: "type",
        categoryMap: ["movie": 408, "series": 401, "tvshow": 405, "music": 402, "anime": 404, "documentary": 410, "other": 408],
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr"
    )

    // MARK: - 通用站逐站实测修正（2026-09 上传页批量探测：分类表/豆瓣字段/标签/动态分类）

    /// 北理工PT：imdb/豆瓣为裸 ID 字段，标签为 span[] 数字值
    static let btschool = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "imdbid",
        doubanField: "doubanid",
        categoryField: "type",
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr",
        tagField: "span[]",
        tagMap: ["chinese_sub": "6", "forbid": "1", "diy": "4"]   // 首发（值 2）不跟随源站，见 QualityTokens.tagTextMap
    )

    /// 动漫花园 U2：多 Tab 表单（动漫/漫画/音乐），标题取 .torrent 文件名；type 值实测
    static let u2 = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleMode: "torrentName",
        imdbField: "imdbid",
        categoryField: "type",
        categoryMap: ["movie": 12, "series": 12, "tvshow": 12, "anime": 22, "documentary": 12, "music": 30, "other": 40],
        extraUploadFields: ["uplver": "yes"]
    )

    /// GGPT（游戏站）：分类仅 412 PC / 418 其他；codec 下拉实为年份（动态年份匹配）
    static let ggpt = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        categoryField: "type",
        categoryMap: ["movie": 412, "series": 412, "tvshow": 412, "anime": 412, "documentary": 412, "music": 418, "other": 418],
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr"
    )

    /// 海棠（戏曲曲艺站）：无影视分类，统一入 小曲
    static let haitang = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        categoryField: "type",
        categoryMap: ["movie": 4099, "series": 4099, "tvshow": 4099, "anime": 4099, "documentary": 4099, "music": 4099, "other": 4099],
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr"
    )

    /// 好学（教育站）：纪录片入 410，其余入 教育
    static let haoxue = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        categoryField: "type",
        categoryMap: ["movie": 406, "series": 406, "tvshow": 406, "anime": 406, "documentary": 410, "music": 406, "other": 406],
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr"
    )

    /// TCCF（电驴教学）：纪录片 624，其余入 Elearning 杂项
    static let tccf = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        categoryField: "type",
        categoryMap: ["movie": 628, "series": 628, "tvshow": 628, "anime": 628, "documentary": 624, "music": 628, "other": 628],
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr"
    )

    /// DiscFan：电影按地区细分，转发统一入 世界
    static let discfan = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        categoryField: "type",
        categoryMap: ["movie": 410, "series": 411, "tvshow": 416, "anime": 419, "documentary": 413, "music": 414, "other": 410],
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr"
    )

    /// 杏坛（学术站）：type 下拉由 ajax.php 异步生成；分类 = 学科
    /// Oldtoons（Unit3D v9，动画站）：.torrent 下载链接为 /torrents/download/<id>（非 download.php 型）
    static let oldtoons = SiteOverride(
        torrentLinkPattern: "torrents/download/\\d+"
    )

    static let xingtan = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        categoryField: "type",
        ajaxCategoryPath: "ajax.php",
        ajaxCategoryModes: ["movie": 94, "series": 94, "tvshow": 94, "anime": 94, "documentary": 94, "music": 93, "other": 220],
        ajaxCategorySubMap: ["movie": 842, "anime": 849, "other": 1968],
        ajaxCategoryKeywords: ["series": "广播电视", "tvshow": "戏剧影视文学", "documentary": "电影学", "music": "音乐"],
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr"
    )

    /// HDArea：豆瓣字段为 dburl（URL 型）
    static let hdarea = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        doubanField: "dburl",
        doubanValueTemplate: "https://movie.douban.com/subject/{douban}/",
        categoryField: "type",
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr"
    )

    /// 劳改所（PTLGS）：海报/截图/MediaInfo 各有独立输入框，"其它信息"（descr）只放转种来源与源站引用
    static let ptlgs = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        posterField: "cover",
        descrStyle: "reseedSource",
        categoryField: "type",
        screenshotField: "screenshots",
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr"
    )

    /// PTT：imdb 为裸 ID，豆瓣为 dburl
    static let ptt = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "imdb_id",
        doubanField: "dburl",
        doubanValueTemplate: "https://movie.douban.com/subject/{douban}/",
        categoryField: "type",
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr"
    )

    /// PTHome：豆瓣为裸 ID
    static let pthome = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        doubanField: "douban_id",
        categoryField: "type",
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr"
    )

    /// TLF：豆瓣为 douban_url（URL 型）
    static let tlf = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        doubanField: "douban_url",
        doubanValueTemplate: "https://movie.douban.com/subject/{douban}/",
        categoryField: "type",
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr"
    )

    /// HDVideo：豆瓣为 douban_url（URL 型）
    static let hdvideo = SiteOverride(
        uploadPath: "upload.php",
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        doubanField: "douban_url",
        doubanValueTemplate: "https://movie.douban.com/subject/{douban}/",
        categoryField: "type",
        extraUploadFields: ["uplver": "yes"],
        subtitleField: "small_descr"
    )

    /// 影（StarSpace）：自定义 NexusPHP 变体，分类值是字母 token，源介质需 medium+resolution 组合选值
    static let shadow = SiteOverride(
        uploadPath: "p_torrent/video_upload.php",
        uploadActionPath: "video_upload_act.php",
        titleField: "name",
        descrField: "descr",
        imdbField: "imdb_url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        doubanField: "douban_url",
        doubanValueTemplate: "https://movie.douban.com/subject/{douban}/",
        categoryField: "tr_category",
        categoryStringMap: ["movie": "mo", "series": "tv", "tvshow": "tv", "anime": "an", "documentary": "do", "music": "mv", "sports": "sp", "other": "ot"],
        sourceSelectField: "tr_source",
        sourceMap: [
            "remux/2160p": "s52", "remux/8k": "s52", "remux/1080p": "s42", "remux/1080i": "s42",
            "bluray/1080p": "s41", "bluray/720p": "s41", "bluray/1080i": "s41",
            "webdl/2160p": "s13", "webdl/1080p": "s13", "webdl/720p": "s13",
            "hdtv/1080p": "s22", "hdtv/720p": "s22",
            "dvd/sd": "s32",
            "encode/2160p": "s51", "encode/1080p": "s41",
            "remux": "s42", "bluray": "s41", "webdl": "s13", "hdtv": "s22", "dvd": "s32", "encode": "s41", "track": "s11"
        ],
        qualitySelects: ["tr_video_codec": "codec", "tr_audio_codec": "audiocodec", "tr_resolution": "standard"],
        qualityValueMaps: [
            "codec": ["hevc": 2, "avc": 1, "vc1": 5, "mpeg2": 3, "av1": 4, "xvid": 4],
            "audiocodec": ["dtsma": 6, "dtsc": 7, "truehd": 13, "eac3": 3, "ac3": 3, "dts": 4, "flac": 8, "ape": 2, "aac": 1, "mp3": 11, "ogg": 12, "m4a": 10, "pcm": 13]
        ],
        qualityStringMaps: [
            "standard": ["8k": "r5", "2160p": "r4", "1080p": "r3", "1080i": "r3", "720p": "r2", "sd": "r1"]
        ],
        subtitleField: "small_desc",
        tagCheckboxes: ["chinese_sub": "tag_chs_sub", "forbid": "tag_jz"]
    )

    // MARK: - Blu 家族

    /// blutopia（Blu）：分类 1=Movie 2=TV Show 8=Other；媒介 1=Full Disc 3=Remux 4=WEB-DL 5=WEBRip 6=HDTV 12=Encode 15=Other；分辨率 11=4320p 1=2160p 2=1080p 3=1080i 5=720p 10=Other（2026-09-29 实测创建页选项表）
    static let blutopia = SiteOverride(
        uploadPath: "torrents/create",
        uploadActionPath: "torrents",
        categoryMap: ["movie": 1, "series": 2, "tvshow": 2, "anime": 2, "documentary": 2, "music": 8, "other": 8],
        qualityValueMaps: [
            "medium": ["remux": 3, "uhdbd": 1, "uhdbd8k": 1, "uhd8k": 1, "uhd": 1, "bluray": 1, "webdl": 4, "webrip": 5, "hdtv": 6, "dvd": 15, "encode": 12, "track": 15, "default": 15],
            "standard": ["8k": 11, "2160p": 1, "1080p": 2, "1080i": 3, "720p": 5, "sd": 10, "music": 10, "default": 10]
        ]
    )

    /// monika（MonikaDesign）：分类 1=Movie 2=TV 6=Anime Movie 8=Anime TV 9=Music of TV；媒介 1=Full Disc 2=Remux 3=Encode 4=WEB-DL 5=WEBRip 6=HDTV 7=ALBUM；分辨率 1=4320p 2=2160p 3=1080p 4=1080i 5=720p 10=Other 11=Lossless（2026-09-29 实测）
    static let monika = SiteOverride(
        uploadPath: "upload/1",
        uploadActionPath: "upload",
        categoryMap: ["movie": 1, "series": 2, "tvshow": 2, "anime": 8, "documentary": 2, "music": 9, "other": 1],
        qualityValueMaps: [
            "medium": ["remux": 2, "uhdbd": 1, "uhdbd8k": 1, "uhd8k": 1, "uhd": 1, "bluray": 1, "webdl": 4, "webrip": 5, "hdtv": 6, "dvd": 1, "encode": 3, "track": 7, "default": 3],
            "standard": ["8k": 1, "2160p": 2, "1080p": 3, "1080i": 4, "720p": 5, "sd": 10, "music": 11, "default": 10]
        ]
    )

    // MARK: - 经典 Gazelle / xbtit

    /// hdspace（HD-Space，xbtit 皮肤）：分类 15=Blu-Ray 18/19=Movie 720/1080 40=Remux 41=4K UHD 24/25/47=Doc 720/1080/2160 27/28/48=Anime 720/1080/2160 30=HQ Audio 36=Trailers 38=Other（2026-09-29 实测上传页）
    static let hdspace = SiteOverride(
        uploadPath: "index.php?page=upload",
        searchURL: "index.php?page=torrents&search={name}&options=contains",
        categoryMap: [
            "movie/remux": 40, "movie/uhd-bd": 41, "movie/8k-bd": 41, "movie/8k": 41, "movie/2160p": 41,
            "movie/bluray": 15, "movie/1440p": 19, "movie/1080p": 19, "movie/1080i": 19, "movie/720p": 18,
            "movie/dvd": 38, "movie/sd": 38,
            "documentary/2160p": 47, "documentary/8k": 47, "documentary/8k-bd": 47, "documentary/uhd-bd": 47,
            "documentary/remux": 25, "documentary/1080p": 25, "documentary/1080i": 25, "documentary/1440p": 25,
            "documentary/720p": 24, "documentary/sd": 24, "documentary/dvd": 24,
            "anime/2160p": 48, "anime/8k": 48, "anime/8k-bd": 48, "anime/uhd-bd": 48,
            "anime/remux": 28, "anime/1080p": 28, "anime/1080i": 28, "anime/1440p": 28,
            "anime/720p": 27, "anime/sd": 27, "anime/dvd": 27,
            "series": 38, "music": 30, "other": 38,
            "movie": 19, "documentary": 25, "anime": 28
        ]
    )

    /// opencd（OpenCD，经典 Gazelle）：分类表沿用 OpenCD 老版结构，站点改版后需按实际选项修正
    static let opencd = SiteOverride(
        categoryMap: [
            "movie/1080p": 3, "movie/720p": 2, "movie/sd": 1, "movie/dvd": 1,
            "movie/2160p": 3, "movie/8k": 3, "movie/uhd-bd": 3, "movie/8k-bd": 3, "movie/remux": 3,
            "series": 9, "documentary": 6, "anime": 7, "music": 8, "other": 9, "movie": 3
        ]
    )

    /// iptorrents（IPTorrents，经典 Gazelle）：分类表为 2023 改版后的结构，需按实际选项修正
    static let iptorrents = SiteOverride(
        categoryMap: [
            "movie/1080p": 3, "movie/720p": 2, "movie/sd": 1, "movie/dvd": 1,
            "movie/2160p": 4, "movie/8k": 4, "movie/uhd-bd": 4, "movie/8k-bd": 4, "movie/remux": 4,
            "series/1080p": 7, "series/720p": 6, "series/sd": 5, "series/2160p": 8, "series": 7,
            "documentary": 9, "anime": 10, "music": 11, "other": 12, "movie": 3
        ]
    )

    static let hhanclub: SiteOverride? = nil
}
