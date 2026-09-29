import Foundation

/// 9 优先站的内置 overrides。
/// 由 2026-09-28 用真实账号 cookie 实测各站上传表单生成（POST takeupload.php、字段名、分类表、质量下拉表）；
/// 2026-09-29 补充各站副标题/标签/制作组(地区)字段实测值。
/// 配置 JSON 里的 site.overrides 与这里按 key 合并（配置优先）；新增/修改站点差异请两处同步。
extension SiteOverride {
    /// luckpt（LuckPT）
    static let luckpt = SiteOverride(
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "url",
        imdbValueTemplate: "http://www.imdb.com/title/{imdb}/",
        categoryField: "type",
        categoryMap: ["movie": 401, "series": 402, "anime": 405, "documentary": 411, "music": 408, "other": 409],
        extraUploadFields: ["uplver": "yes"],
        qualitySelects: ["medium_sel[4]": "medium", "codec_sel[4]": "codec", "audiocodec_sel[4]": "audiocodec", "standard_sel[4]": "standard"],
        qualityValueMaps: ["medium": ["remux": 3, "uhdbd": 10, "uhdbd8k": 10, "uhd8k": 10, "uhd": 7, "webdl": 11, "bluray": 1, "encode": 7, "hdtv": 5, "dvd": 6, "track": 9], "codec": ["hevc": 6, "avc": 1, "vc1": 3, "mpeg2": 4, "av1": 2, "xvid": 12], "audiocodec": ["dtsma": 16, "dtsc": 15, "truehd atmos": 11, "truehd": 14, "eac3 atmos": 12, "eac3": 12, "ac3": 8, "dts": 3, "flac": 1, "ape": 2, "aac": 6, "mp3": 4, "ogg": 5, "pcm": 19, "lpcm": 13, "wav": 18, "m4a": 17], "standard": ["8k": 7, "2160p": 6, "1080p": 1, "1080i": 1, "720p": 3, "sd": 4]],
        subtitleField: "small_descr",
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
        categoryMap: ["movie": 401, "series": 402, "tvshow": 403, "anime": 405, "documentary": 404, "music": 408, "sports": 407, "other": 409],
        extraUploadFields: ["uplver": "yes"],
        qualitySelects: ["medium_sel": "medium", "codec_sel": "codec", "audiocodec_sel": "audiocodec", "standard_sel": "standard"],
        qualityValueMaps: ["medium": ["remux": 3, "uhdbd": 13, "uhdbd8k": 13, "uhd8k": 13, "uhd": 7, "webdl": 11, "bluray": 1, "encode": 7, "hdtv": 5, "dvd": 6, "track": 9], "codec": ["hevc": 13, "avc": 10, "vc1": 2, "mpeg2": 4, "av1": 16, "xvid": 3], "audiocodec": ["dtsma": 10, "dtsbr": 14, "dtsc": 16, "truehd atmos": 17, "truehd": 11, "eac3 atmos": 21, "eac3": 20, "ac3": 12, "dts": 3, "flac": 1, "ape": 2, "aac": 6, "mp3": 4, "ogg": 5, "pcm": 19, "lpcm": 13, "wav": 15, "alac": 23, "m4a": 23, "opus": 22], "standard": ["8k": 6, "2160p": 5, "1080p": 1, "1080i": 2, "720p": 3, "sd": 4]],
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
        categoryMap: ["movie": 401, "series": 402, "anime": 405, "documentary": 404, "music": 408, "other": 409],
        extraUploadFields: ["uplver": "yes"],
        qualitySelects: ["medium_sel": "medium", "codec_sel": "codec", "audiocodec_sel": "audiocodec", "standard_sel": "standard"],
        qualityValueMaps: ["medium": ["remux": 3, "uhdbd": 19, "uhdbd8k": 19, "uhd8k": 19, "uhd": 4, "webdl": 18, "bluray": 1, "encode": 4, "hdtv": 6], "codec": ["hevc": 5, "avc": 1, "vc1": 2, "mpeg2": 4, "av1": 3, "xvid": 6], "audiocodec": ["dtsma": 10, "truehd": 11, "ac3": 7, "dts": 3, "flac": 1, "ape": 2, "lpcm": 13, "pcm": 13, "wav": 12, "aac": 6, "alac": 14, "m4a": 14], "standard": ["1080p": 1, "1080i": 2, "720p": 3, "2160p": 6, "8k": 7]],
        subtitleField: "small_descr",
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
        categoryField: "type",
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
        categoryMap: ["movie": 401, "series": 402, "documentary": 406, "music": 408, "anime": 409, "other": 409],
        extraUploadFields: ["uplver": "yes"],
        qualitySelects: ["medium_sel": "medium", "codec_sel": "codec", "audiocodec_sel": "audiocodec", "standard_sel": "standard"],
        qualityValueMaps: ["medium": ["remux": 3, "uhdbd": 12, "uhdbd8k": 12, "uhd8k": 12, "uhd": 15, "webdl": 10, "bluray": 1, "encode": 15, "hdtv": 5, "dvd": 2, "track": 9], "codec": ["hevc": 6, "avc": 1, "vc1": 2, "mpeg2": 4, "av1": 7], "audiocodec": ["dtsc": 25, "truehd atmos": 26, "dtsma": 19, "truehd": 20, "lpcm": 21, "pcm": 21, "eac3 atmos": 18, "eac3": 18, "ac3": 18, "dts": 3, "aac": 6, "flac": 1, "ape": 2, "opus": 27, "wav": 22, "mp3": 23, "m4a": 24], "standard": ["8k": 10, "2160p": 5, "1080p": 1, "1080i": 2, "720p": 3, "sd": 4]],
        subtitleField: "small_descr",
        tagField: "tags[]",
        tagMap: ["chinese_sub": "zz", "hdr10": "hdr10", "hdr10plus": "hdrm", "dovi": "db", "forbid": "jz", "limited": "xz"]
    )

    /// ttg（TTG）
    static let ttg = SiteOverride(
        uploadActionPath: "takeupload.php",
        titleField: "name",
        imdbField: "imdb_c",
        doubanField: "douban_id",
        categoryField: "type",
        fileField: "file",
        categoryMap: ["movie/uhd-bd": 109, "movie/8k-bd": 109, "movie/2160p": 108, "movie/8k": 108, "movie/remux": 54, "movie/bluray": 54, "movie/1440p": 53, "movie/1080p": 53, "movie/1080i": 53, "movie/720p": 52, "movie/sd": 51, "movie/dvd": 51, "documentary/uhd-bd": 67, "documentary/8k-bd": 67, "documentary/2160p": 67, "documentary/8k": 67, "documentary/remux": 67, "documentary/bluray": 67, "documentary/1440p": 63, "documentary/1080p": 63, "documentary/1080i": 63, "documentary/720p": 62, "documentary/sd": 62, "documentary/dvd": 62, "series/uhd-bd": 70, "series/8k-bd": 70, "series/2160p": 70, "series/8k": 70, "series/remux": 70, "series/bluray": 70, "series/1440p": 70, "series/1080p": 70, "series/1080i": 70, "series/720p": 69, "series/sd": 69, "series/dvd": 69, "anime/uhd-bd": 111, "anime/8k-bd": 111, "anime/2160p": 58, "anime/8k": 58, "anime/remux": 58, "anime/bluray": 58, "anime/1440p": 58, "anime/1080p": 58, "anime/1080i": 58, "anime/720p": 58, "anime/sd": 58, "anime/dvd": 58, "music": 83, "movie": 53, "documentary": 63, "series": 70, "anime": 58, "other": 32],
        extraUploadFields: ["anonymity": "-1"],
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
        categoryMap: ["movie": 401, "series": 404, "anime": 403, "documentary": 402, "music": 406, "other": 412],
        subtitleField: "small_descr",
        regionField: "team_sel",
        regionPatterns: ["中国大陆": 1, "内地": 1, "中国": 1, "香港": 2, "台湾": 3, "美国": 4, "加拿大": 4, "英国": 4, "法国": 4, "德国": 4, "意大利": 4, "西班牙": 4, "瑞典": 4, "韩国": 5, "日本": 6, "印度": 7],
        regionOtherValue: 8
    )

    /// hhanclub：候选区上传（offers.php），M2；目前无 overrides
    static let hhanclub: SiteOverride? = nil
}
