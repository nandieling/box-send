# BoxSend

**v1.0** · PT 站批量转种 + 推送下载器（按源站点限速）。**主体是 macOS 应用**：在 Mac 上解析源站、批量转种到目标站、推送到 VPS 上的 qBittorrent；VPS 只装下载器，不装本软件。

- 仓库: <https://github.com/nandieling/box-send>
- 版本: 1.0（版本号唯一来源 `Sources/BoxSendKit/Util/Version.swift`，见[版本与仓库](#版本与仓库)）
- 语言: Swift（macOS 13+；无第三方依赖，纯 Foundation/URLSession）

## 架构

```
┌───────────────────────────── Mac ─────────────────────────────┐
│  BoxSend.app（GUI）  /  box-send（CLI）                        │
│   ├─ PT-depiler（Safari 扩展）→ 本地备份 zip 或 Gist 提供 cookie │
│   ├─ 直接访问 PT 站（解析/下载 .torrent/上传转种）                │
│   └─ 通过 de5 隧道推送到下载器（按站点 + 分组限速 upLimit）        │
└──────────────────────────────┬─────────────────────────────────┘
                               │ https://qbnet.….de5.net（已有隧道）
┌──────────────────────────────▼─────────────────────────────────┐
│  VPS（Debian 13）：只装 qBittorrent，不装 box-send / Swift        │
└────────────────────────────────────────────────────────────────┘
```

> 推送时**源站与每个目标站各自推送该站自己的 .torrent**：各站 .torrent 内嵌的 tracker 不同、info hash 通常也不同，在下载器中是相互独立的种子；每个 torrent 按**对应站点**的上传限速（站点/分组取更严格者）添加，避免某一站上传过快被盯上。
> 推送时机：**源站种子解析完先推**，目标站**转完一站立刻推该站种子再进下一站**（不等整组转完）；下载器连不上只记「推送失败」，不影响后续转种。

### 支持站（内置 ~145 站，参照 auto_feed + savept.icu 存活清单，全部可作源站）

- **9 个优先站**（默认启用，内置逐站实测的完整上传参数：分类/质量下拉/标签/制作组/搜索查重）：pt.luckpt.de（幸运）、hdsky.me（天空）、ptchdbits.co（彩虹岛）、hdhome.org（家园）、springsunday.net（春天）、audiences.me（观众）、totheglory.im（套）、pterclub.net（猫）、hhanclub.net（憨憨，仅作源站；一般用户无发种权限）。
- **Blu 家族**（Layuout UI 适配器）：blutopia.cc、monikadesign.uk（莫妮卡） —— 详情页解析（标题/简介/MediaInfo/IMDb/种子直链）、上传自动填 category_id / type_id（媒介）/ resolution_id（分辨率）/ 季集数 / IMDb，值表为 2026-09-29 实测创建页选项。
- **经典 Gazelle / xbtit 适配器**：hd-space.org（HDSpace，实测上传表单与分类表）、open.cd、iptorrents.com（分类表为老版结构，站点改版后需按实际选项在配置层修正）。
- **特殊 NexusPHP**：byr.pt（auto_feed 实测 type 表：电影408/剧集401/综艺405/音乐402/动漫404/纪录410）、star-space.net（影，自定义表单：字母 token 分类、medium+分辨率组合的源介质下拉、字符串分辨率/编解码下拉，值表实测）。
- **通用中文 NexusPHP（~70 站）**：13City、1PT、52MOVIE、52PT、末日、Railgun、藏宝阁、车站、蟹黄堡、财神、大青虫、蝶粉、龙之家、天枢、三月、TCCF、GGPT、高清视界、海德堡、杜比、红豆饭、麒麟、时光、HDVideo、百川、海棠、蝴蝶、好学、自然、库非、垃圾堆、柠檬不甜、龙、爱萝莉、蒲园、OK、奥申、包子、熊猫、猪猪、农场、爱玲、学校、吐鲁番、GTK、独自、Itz、慕雪阁、nova、聆音、好多油、星陨阁、樱花、咖啡、PTFans、铂金家、劳改所、烧包、拾刻、时间、葡萄汁、青蛙、SBPT、下水道、躺平、北洋园、优堡、UltraHD、冬樱、杏坛、织梦、幼儿圈（dmhy）等（内置表已用中文站名，id 仍为域名缩写）。
  - 这类站走通用参数（POST `takeupload.php`、标题 `name`、IMDb `url` 字段、副标题 `small_descr`），**全字段动态适配（2026-09-29 对 72 站上传页批量实测后实现，免逐站配置）**：
    - **分类**：上传页分类下拉按类型关键词（电影/剧集/动漫/纪录片/音乐…）动态匹配选项值；新版 NexusPHP（多下拉 + `data-mode`）自动定位到正确下拉并按模式索引质量字段；学术站（星陨阁）走 `ajax.php` 动态取子分类。
    - **质量**：`medium_sel/codec_sel/standard_sel/audiocodec_sel/source_sel` 等按发布名 token（REMUX/BluRay/1080p/VC-1/DTS-HD MA…）匹配选项，无匹配时按年份选编码（如 GGPT）。
    - **标签**：`tags[][]`/`chinese`/`exclusive`/`span[]` 等复选框按种子特征自动勾选（中字/禁转/限转/DIY/首发/杜比视界/HDR…）。
    - **质量选项打分**：同一属性有多个候选文案时按「规则顺序 + 文案命中 + UHD 一致性 + 整季完结」择优，不取第一个含关键词的选项。
      PCM/LPCM 在无 PCM/LPCM 选项的站落 Other（不再误选 WAV）；分辨率支持纯数字选项（1080/720/4K）；REMUX 不被 UHD Remux 抢走；新增 processing_sel（处理/格式）识别 Remux/原盘/Encodes。
    - **地区**：产地按选项文案关键词匹配地区下拉，字段名各站不同（source_sel / processing_sel）也统一处理；匹配不到就留空，不会把「其它」当答案。
    - **豆瓣链接**：按上传页「豆瓣」行自动定位输入框（pt_gen / dburl / *_id 等），id 型字段只填 id，链接型填完整 URL。
    - **完结标签**：整季包（S03 且无单集标记，或源站标完结、文案有「全12集」）自动勾选目标站「完结」标签，源站标「未完结/连载」一票否决；文案含「或」的组合标签（如「原盘或ISO」）不自动勾。
    - **转载来源**：overrides `descrSourcePrefix: true` 的站在简介开头加「转载自〈源站品牌名〉，感谢发布者。」（织梦已开）；分类选项含「不含动漫」这类否定表述不会被「动漫」误命中。
  - 规范标签的依据依次是：发布名/简介/MediaInfo 关键词 + **源站详情页「标签」行原文**（中字/英字/应求这类无法从发布名推断，只能读源站标签行）+ **源站「类别」行**（喜剧/动画/纪录片等题材标签，财神等站缺题材标签会被打回审核）。「官方/官种」是源站自己的评选，不外打到目标站：正常转种不会给目标站勾官方标签。
  - 复选框字段名不含 `tag` 的站点（如猫 pterclub 的 `zhongzi`/`jinzhuan`/`guanfang` 拼音命名）优先用 overrides `tagCheckboxes`（规范标签 → 字段名，提交 `=yes`）；无配置时按复选框文案精确匹配兜底，其它表单项不会被误勾。
    - **标签型下拉**：选项值即文案的标签下拉（城市 `tag1ing`/`tag2ing`）按文案分段精确匹配，一个下拉只填一个标签，`Jazz/爵士乐` 不会被 `zz` 这类关键词误命中。

    - **简介**：含 `technical_info`/`media_info` 字段的站自动把 MediaInfo 填入该字段，简介正文 HTML 清洗（源站链接转文本、图片 src 绝对化、压缩空行）。
    - 需要精调时在「站点 overrides」里补 `qualitySelects`/`qualityValueMaps`/`tagMap` 等，显式配置优先于动态匹配。
  - 实测状态备注：movie52/longpt/ultrahd 的 cookie 当时已过期（请重新用 PT-depiler 备份导入）；hdbao 服务端 500、baozi 被 Cloudflare 403、yinghua 域名解析失败、ziran 有 JS 校验（纯 HTTP 暂无法通过）；u2 为自研多标签表单，按最简参数适配（实验性）；ptt/tjupt 为老式表单，动态分类可用。
  - 未添加的站只存在于内置名录（GUI「站点分组」页「添加站点」批量加入，添加即默认开启；关闭开关的站不参与转种目标 / cookie 检测 / 同步）；内置表新增站点会在启动时自动并入配置，已有条目保持用户设置、站名按内置表同步。
- **TNode（REST API + SPA，2026-09-30 实测）**：ZHUQUE（zhuque.in）—— 选项/详情/下载/搜索/发种全走 `/api/torrent/*` JSON API：分类（电影/剧集/动漫/节目/其它）、媒介（UHD Blu-ray / Remux / WEB-DL…）、编码（H264/H265/Other）、分辨率、标签（中字/禁转/杜比视界/HDR10/完结/分集）全部按 `/api/torrent/option` 返回的选项动态匹配；TMDB id 经 `/api/tmdb/findByImdb` 自动查询；截图从源站简介 `<img>` 提取；MediaInfo 填独立 `mediainfo` 字段；需 `x-csrf-token`（自动从页面 meta 提取）。源站解析（详情/下载/禁转标记）同样走 API。 详情链接 `/torrent/info/<id>` 取 id 用捕获组（整串匹配会把 `/torrent/info/55084` 当 id 拼进 API，推送时 404）；站点回 `HTTP 400 TORRENT_ALREADY_UPLOAD` 按「已存在」处理（不算失败），并按发布名/中文片名检索回填已有种子链接以便照常推送。
- **HDCITY（城市，2026-10-06 实测）**：自研框架 + 两步上传——第一步把 .torrent POST 到上传页表单的 action（独立资源域名 `hctres.leniter.org/upload_receiver.php?spm=…`），站点 302 回本站 `/upload?tfu=…`，第二步在跳转页填元信息（此时不再带种子文件）；跳转必须手动处理（跟随跳转会把本站 cookie 丢给另一个域，第二步被踢回登录页）。成功判定读跳转目标里的 `/t-<id>`；详情页标题带站名品牌后缀，用 overrides `titleStrip` 剥离。标签是「选项值即文案」的下拉（`tag1ing`/`tag2ing`），媒介/编码/分辨率/处理是裸 `xxx_sel` 单选。
- **HAIDAN（海胆之家，2026-09-30 实测）**：NexusPHP 后端 + 自定义详情布局（`movie-content`）—— 详情解析走专属 `HaidanAdapter`（标题块/副标题/`#kdescr` 简介/MediaInfo fieldset/`download.php?id=&passkey=` 直链/豆瓣 `durl` 字段）；上传走经典表单（`takeupload.php`），分类（电影401/剧集402/综艺403/纪录404/动漫405/体育407/音乐408）动态匹配，`tag_list[]` 标签（3中字/4DIY/5国语/7原盘/10粤语/11外语）按标签文案动态勾选。
- **YemaPT（umi.js SPA + REST API，2026-09-30 实测）**：www.yemapt.org —— 选项/详情/下载/查重/发种全走 `/api/torrent/*` JSON API：分类树（电影/剧集/综艺/动漫/纪录片/体育/短剧/MV）、媒介、分辨率、编码、音轨、地区多选（上限 3）、制作组、标签（禁转/中字/杜比视界/HDR10/Atmos/完结…）全部按 `/api/torrent/fetchUploadOptions` 返回的选项动态匹配；详情 longDesc 为 Markdown（与内部 HTML 简介双向转换：图片、链接转 `text (url)` 文本）；截图从源站简介 `<img>` 提取（补 `screenshotList`/`picture` 字段）；MediaInfo 填独立 `mediaInfo` 字段；剧集自动识别 `season`；匿名发种默认值跟随站点 `uploadConfig` 配置。查重双重兜底：`existTorrentWithPiecesHash`（piecesHash = pieces 整个 bencoded 值的 SHA-1）+ IMDb 可用时 `findImdbTorrentList` 名称查重。
- **馒头 M-Team（Unit3D 型 Spring 网关，2026-10-06 实测）**：kp.m-team.cc —— 用 API Key（站点页「个人主页 → 设置 → API」）连接，一律 POST + `x-api-key` 头，响应 `{code,message,data}` 且成功码是字符串 `"0"`：详情 `POST /api/torrent/detail`、种子 `POST /api/torrent/genDlToken`（返回一次性签名地址）、查重 `POST /api/torrent/search`、发种 `POST /api/torrent/createOredit`（multipart：`file/name/descr/category` 必填，另带 `smallDescr/mediainfo/imdb/douban/labelsNew/scope/anonymous`）。**动画分类（动画 405 / 动画-BluRay 453）必须填 Bangumi 条目链接**：源站详情自带则直接复用（馒头详情返回 `bangumi` 完整链接，其它站从简介里的 bangumi.tv/bgm.tv 链接提取），否则按标题里的中日文名/英文名（自动剥离站名标签、季号、清晰度噪声）经 `POST /api/media/bangumi/search` 检索，按「标题命中 + 年份就近 + 动画类型加成」选条目并归一为 `https://bangumi.tv/subject/<id>`；检索不到会明确报错而不是静默漏填。站点有频控（`code=4` 請求過於頻繁），写入接口命中后等 5 秒自动重试一次；同 hash 已存在（種子已存在）按「已存在」处理并推送站内已有种子。
- **长尾与海外站（参照 [savept.icu](https://savept.icu) 2026-09-30 存活清单新增 53 站，已死亡站不收录）**：
  - 中文 NexusPHP（通用动态适配）：梓喵、海豚、Depth Studio、龟站、南洋、Kelu、PlayLet、大香蕉、朋友、我的PT、太乙、TU88、VC-Lib、忘年桥、肉丝、思齐、阳光、瞬间、音乐乌托邦、老师、Tokyo、修道院、星湾、城市、Generation-Free、凤凰（pt.521.best）。
  - Unit3D 家族（Oldtoons oldtoons.world（动画站，.torrent 链接 /torrents/download/\<id\> 已适配）、奶昔 Milkie、超科学PT喵 PTNeko、Anthelion、BrokenStones、ExoticaZ、FileList、HappyFappy、Jpopsuki、Nebulance、Orpheus、峨眉派 Empornium；馒头 M-Team 已走专属 API 适配器）：暂走 NexusPHP 通用逻辑作源站，专属适配器见 M3。
  - 经典 Gazelle 家族：AlphaRatio、AnimeZ、SportsCult；xbtit 家族：BeyondHD、ClearJAV、Fappaizuri、HUNO、HD-Torrents（走 Gazelle/xbtit 适配器）。
  - 自研系统（Aither、BitPorn、海豹 GPW、LST、MyAnonamouse、我堡 OurBits、葡萄 SJTU、TorrentLeech）：走 NexusPHP 通用逻辑尽力而为，待实测。
  - 新站上传表单/详情页**未逐站实测**，转种字段如有偏差请在「站点 overrides」补配置。
  - 域名迁移（旧域名已失效）：自然 zrpt.cc → naturept.top、GTK pt.gtk.pw → pt.gtkpw.xyz。
- **暂未适配（M3）**：PTP / HDB / BTN / CinemaZ 等新版 Unit3D 自研表单站（无账号 cookie 或未实测）。以上长尾站可作**源站**使用（按框架通用逻辑解析），作为转种目标待后续实测。

## 快速开始（Mac，约 5 分钟）

```bash
# 1) 拉代码
git clone git@github.com:nandieling/box-send.git   # HTTPS 私有仓库改用 PAT

# 2) 打包 GUI 应用（首次会 release 编译，1~3 分钟）
cd box-send
bash scripts/make-app.sh
open dist/BoxSend.app
# 首次打开若被 Gatekeeper 拦：右键 → 打开 → 打开
```

首次打开后：

1. **Cookie 页** → 「导入 PTD_backup_*.zip …」：在 PT-depiler 里「备份 → 本地备份」导出 zip（勾选 Cookie 字段；如设置了备份密码，导入时输入）。
2. **下载器页** → 填 VPS 隧道地址（如 `https://qbnet.nandielinghai.de5.net`）+ 账号密码 → 「测试连接」应显示版本信息。
3. **站点分组页** → 「添加分组」（分组名 + 上传限速，默认 10 MB/s；组内新增站点限速默认取此值）→ 点分组名旁的「**添加站点**」（卡片弹窗锁定该分组：列表**默认按拼音字母顺序排列（数字开头的名称在前）**，搜索内置名录、**点击卡片选中**添加（加深色 = 已选中）、「全选 / 全不选」切换整列、拖拽或输入序号排序（**序号 = 目标位置**；序号重复时弹窗提示与哪个站点哪个序号重复；**手动排序结果保存到配置，关闭弹窗后再打开保持**）。已添加的站按分组区块以**卡片**显示（每行 4 张，第一行站点名 + 序号输入框 + 拖拽把手，第二行站点地址）：点击卡片开启/停用（未开启的站不参与转种/检测/同步）、cookie 有效性（无 cookie / 未检测 / 检测中 / 已登录 / 失效，进入页面自动检测）、上传限速输入框（与「批量转种」页卡片同一数值）；所有分组上方有全局「**同步 Cookie**」（同时同步 PT-depiler Gist 与 CookieCloud，互为补充，全程后台不卡界面）与「**检测 Cookie**」（强制重检全部已添加站点）；每区块工具栏有「全选」（一键切换整组开启/停用）、「手动添加cookie」（先点击选中站点卡片，再点此按钮弹窗填 cookie）、「移除站点」（两次确认）；分组名称与「**移除分组**」按钮中间有「**添加站点**」（点击弹窗直接加入该分组，无需再选分组）；「**移除分组**」删除分组（两次确认）；组内站点卡片可拖拽或输入序号排序（**序号 = 目标位置**）。
4. **下载器页**（可选）→ 填「VPS 剩余空间(GB)」并选大小检测策略（提醒/跳过 + 安全边际），避免大种塞满 VPS。
5. **批量转种页** → 粘贴种子详情页链接 → 勾选「转种到目标站」「推送到下载器」（「跳过检验」在「下载器」页设置：推送时 skip_checking，跳过完整性校验直接下载）→ 「转种分组」点击站点卡片选中目标（加深色 = 已选中，可多选；分组卡片上「全选 / 全不选」整组批量；一行 6 张，卡片显示站点名 + 上传限速（与「站点分组」页的站点限速同一数值））→ 「开始运行」；转种/推送进度实时显示在站点卡片上，「运行记录」按钮点开查看结果。

配置与状态都在 `~/Library/Application Support/BoxSend/`（boxsend.json / cookies.json / state.json / debug/）。

## 安装教程（详细）

### 第 0 步：前置条件

- macOS 13+，Xcode 或 Command Line Tools（`xcode-select --install`）
- PT-depiler Safari 扩展（<https://github.com/nandieling/PT-depiler> 或本仓库同级 `PT-depiler-safari`），已登录各 PT 站
- VPS 上已装 qBittorrent 并有可达的 WebUI（本机直连或隧道，如 de5）

### 第 1 步：PT-depiler 导出 cookie（每次 cookie 更新后重复，约 1 分钟）

1. 打开 PT-depiler 界面 → 「备份」→ 勾选 **Cookie**（其它字段随意）→ 「本地备份」，保存 `PTD_backup_*.zip`。
2. 在 BoxSend 的 **Cookie** 页选择该 zip 导入。若 PT-depiler 设置了备份密码，导入时输入（zip 内是 AES 加密的，口令 = MD5(密码) 前 16 位）。

> 备选：Gist 自动同步（可选）。在 PT-depiler 里配置 Gist 备份后，把 gistID / GitHub token / 备份密码填到 BoxSend **Cookie** 页上方的「PT-depiler Gist 同步」区块，可开「自动定时同步」（默认 30 分钟），无需手动导 zip。

### 第 2 步：打包并启动

```bash
bash scripts/make-app.sh && open dist/BoxSend.app
```

### 第 3 步：配置下载器

**下载器页**：

- URL: VPS 的 qBittorrent WebUI 地址（隧道或直连）
- 用户名/密码、保存路径、分类（可空）
- 「测试连接」验证登录

### 第 4 步：首次转种（小流量验证）

1. 批量转种页粘贴一个源站详情页链接。
2. 只勾 1 个目标站（如 天空）、「开始运行」。
3. 看「最近一次结果」与「日志」页：转种成功会给出新种子详情页链接；失败会给出站点返回的错误（上传页 HTML 存到 `~/Library/Application Support/BoxSend/debug/`，便于排查）。
4. 成功后到目标站确认新种子信息正确（标题/分类/简介），再放开全部目标站。

### 第 5 步（可选）：VPS 清理

VPS 之前按旧方案装过 box-send 的话可以卸掉（只保留 qBittorrent）：

```bash
# VPS 上
systemctl disable --now boxsend-gistsync boxsend-web 2>/dev/null
rm -f /etc/systemd/system/boxsend-{gistsync,web}.service && systemctl daemon-reload
rm -f /usr/local/bin/box-send
rm -rf /opt/box-send ~/.boxsend
# Swift 工具链（约 1GB+）
rm -rf /opt/swift-6.4.0-RELEASE-*
```

### 更新版本

```bash
cd box-send
git pull
bash scripts/make-app.sh   # 重新打包（配置/cookie/状态都在 Application Support，不受影响）
open dist/BoxSend.app
```

- 「种子链接」旁的「源站」菜单：源站默认按链接域名自动识别（菜单文案会显示识别到的站点），站点分组里添加过的站点都能点名作源站；域名迁移 / 多入口（`www.`、子域、镜像）都能反查。识别不到才报错。
- 「批量转种」页种子链接下方有可选的「源站引用」：勾选后填入的文本会加在每个目标站发种简介的最上面，按各站简介格式自动选择 `[quote]` / `<blockquote>` / Markdown 引用包裹（cmct 这类「附加信息」型站点直接用原文，不套引用块）。源站简介自带转载说明的不用勾——勾了会以手填文本为准，不再自动加「转载自<源站>，感谢发布者」。配置项为 `sourceQuoteEnabled` / `sourceQuoteText`，CLI 用 `--source-quote` 传同一段文本。

## 使用（GUI）

- **批量转种**（卡片布局，全屏自适应）：种子链接卡片（左对齐输入框 + 「转种到目标站」「推送到下载器」+ 紧随其后的「开始运行」，「**跳过检验**」（推送时 `skip_checking`，跳过种子完整性校验直接开始下载）在「下载器」页设置，源站推送状态实时显示在卡片右上角）→ **转种分组**：每个分组（含「无分组」）一张分组卡片，「**全选 / 全不选**」整组批量；组内每个目标站一张**站点卡片**（**一行 6 张**，**点击卡片选中 / 取消，加深色 = 已选中**，可多选；站点名 + 上传限速（= 「站点分组」页该站限速）），卡片上**实时显示转种状态（转种中…/转种成功/转种失败/已存在跳过）与该站种子推送状态（推送中…/已推送/推送失败）**，运行中分组卡片带进度指示 → 「运行记录」按钮：默认收起，点开才显示最近一次完整结果（每站转种状态 + 推送状态 + 生效限速）。转种成功的目标站会**自动拉取该站新种子的 .torrent 并单独推送到下载器**（按目标站限速），**转完一站立刻推该站再进下一站**，无需手动添加。
- **站点分组**：不默认罗列全部 144 个内置站，只展示**用户已添加**的站点（旧配置中已启用的 9 个优先站自动视为已添加）：顶部「**添加分组**」（分组名 + 上传限速 MB/s，默认 = 10；**组内新增站点限速默认取此值**），站点从**每个分组名旁的「添加站点」**加入（**卡片弹窗**锁定该分组：列表**默认按拼音字母顺序排列（数字开头的名称在前，中文按拼音、纯拉丁名按字母混排）**，搜索站名/id/地址、**点击卡片选中**（加深色 = 已选中）、「**全选 / 全不选**」切换整列、卡片第一行站点名 + **序号输入框** + 拖拽把手、第二行站点地址、可**拖拽**或**输入序号排序**（**序号 = 目标位置**：输入 N 即排到第 N 位，回车重排；**序号重复时弹窗提示与哪个站点、哪个序号重复**，不重排；**拖拽/序号的手动排序写入 `unmanagedSiteOrder` 配置，关闭弹窗后再次打开保持该顺序**）；添加即默认开启），其下是全局「**同步 Cookie**」（左）与「**检测 Cookie**」（右）按钮：「同步 Cookie」**同时同步 PT-depiler Gist 与 CookieCloud 备份**（互为补充：Gist 优先（同名冲突值留待检测实测裁决）、CookieCloud 补齐缺失条目；本地已检测有效的站点保留本地值不被备份旧值覆盖，同步后自动重检；全程后台线程，**勾选自动同步/点击同步不再卡界面**），「检测 Cookie」对**所有分组已添加的站点强制批量检测**；已添加的站**按分组区块以卡片显示**（常规窗口**一行 4 张**，**全屏自动放更多**，另有「无分组」区块）：**点击卡片开启 / 停用，加深色 = 已开启**（未开启的站不参与转种目标 / cookie 检测 / 同步导入）+ 第一行站点名 + **序号输入框**（序号 = 目标位置，回车重排）+ 拖拽把手、第二行站点地址 + **cookie 有效性**（无 cookie / 未检测 / 检测中 / 已登录 / 失效，进入页面自动检测已开启且有 cookie 的站，每批 4 站并发）+ 上传限速输入框；**组内站点卡片可拖拽排序或输入序号排序（序号 = 目标位置）**；**cookie 失效的卡片显示「cookie 失效」红色标记**，先点击选中卡片再点工具栏「**手动添加cookie**」弹窗粘贴 Cookie 头保存（选中多个站点时弹窗内可切换站点）。每区块工具栏：「**全选**」（一个按钮切换整组开启 / 停用）+「**手动添加cookie**」+「**移除站点**」（移除当前选中（加深色）的站点，保留 cookie 与设置，**两次确认**）；**「添加站点」在分组名称与「移除分组」中间**（点击弹窗锁定该分组，无需再选分组），**「移除分组」按钮在分组名称右边**（**两次确认**，组内站点移到「无分组」）。生效上传限速 = 本页「站点分组」设置的站点限速（「批量转种」页卡片显示同一数值）。推送下载器策略：**源站种子在转种开始前先推**，目标站**逐站转完即推**（谁成功推谁，某站失败不影响其它站推送，日志末尾列出失败站点；纯推送不转种时按 state.json 里的目标站链接逐站补推）。转种目标站在「批量转种」页按分组卡片勾选。
- **Cookie**（页面输入框均为**功能名称在上一行、输入框在下一行**，内容居左）：**PT-depiler Gist 同步**（手动/自动，最上：gistID / GitHub token（黑点密码框，右侧眼睛按钮切换显示）/ PT-depiler 备份密码 / 轮询分钟 + 自动定时同步 + 立即同步（勾选项与按钮紧挨轮询输入框右侧、靠左排列，不再贴行尾；仅拉取本来源，站点分组页顶部「同步 Cookie」同时同步两个来源））→ **CookieCloud 同步**（[easychen/CookieCloud](https://github.com/easychen/CookieCloud) 端对端加密云备份：服务器地址（自架 `http://vps:8088` 或第三方）+ **KEY（扩展生成的 UUID）** + **端对端加密密码**（两者均为黑点密码框，右侧眼睛按钮切换显示） + 轮询分钟 + 自动定时同步 + 立即同步；`GET {host}/get/{key}` 只拉密文，本地解密——密钥 = `MD5(KEY + "-" + 密码)` 前 16 位 hex，兼容 legacy（CryptoJS AES-256-CBC）与 aes-128-cbc-fixed（固定零 IV）两种格式，按 cookie host（主/子域）匹配已添加站点，自动清理未启用站点；**与 Gist 同步互为补充**：本地 cookie 已检测有效的站点**保留本地值**（同步不会用备份旧值覆盖成新的失效），同步后自动重检，**仍失效的站点自动拉另一来源补充**；两个来源对同一站点给出不同值时不再固定「Gist 优先」——先按 Gist 装，检测仍失败的站点用 CookieCloud 那份在副本上重试，站点认哪份就用哪份（实测烧包：浏览器已换新 cookie，Gist 里还是一个月前的旧值，固定优先级会让它永远同步不到新值）。CookieCloud 里 `.example.com` 与 `example.com` 两个分组键会合并到同一站点（同名取过期更晚的那份），否则 cf_clearance 一类会整组被覆盖丢掉）→ PT-depiler 本地备份 zip 导入（备份密码 + 导入 + 清空本地 Cookie；zip 导入 / Gist 同步 / 目录监控导入后只保留**已开启站点**的 cookie，PT-depiler 全量备份含未使用的站，自动清理并在结果里提示数量）→ **备份目录监控**（填监控目录或点「**选择目录…**」按钮选择文件夹/备份密码/轮询间隔，目录出现新 PTD_backup*.zip 自动导入）。单站 Cookie 维护在「站点分组」页工具栏「手动添加cookie」，原「单站 Cookie（手动添加）」「已同步的 Cookie 详情」区块已移除。
- **Cookie 有效性检测**：「站点分组」页卡片显示各站 cookie 有效性（进入页面自动检测已添加的站，未开启的站不检测）；所有分组上方全局「检测 Cookie」按钮对**所有分组已添加的站点**强制批量检测。失效卡片显示「cookie 失效」红色标记，点击选中卡片后点工具栏「手动添加cookie」（弹窗保存），或用顶部「同步 Cookie」（同时同步 Gist + CookieCloud，互为补充）恢复。按框架分级判定：YemaPT 走 `fetchUploadOptions` API、TNode 走 `api/torrent/option`（401/403 或 success=false 判失效）、NexusPHP 家族首页标记探测 + `userdetails.php` 二次确认、其余首页探测。超时 / 5xx / 连不上（Cloudflare 522 一类源站抖动，实测龙会长这样）先重试一次，仍不行记「站点未响应」灰色标记（灰色 = 未确认，不当作 cookie 失效）；只有站点明确回到登录页或出现未登录文案才判「cookie 失效」。 收到的 `Set-Cookie` 会逐条入库：URLSession 把多条响应头合并成逗号连接的一串，直接整串保存会把 `Expires=…2026, 06 Oct` 里的逗号当成分隔符，只剩半条 cookie（下次请求被站点当成新会话）。
- **下载器**（页面输入框均为**功能描述在上一行、输入框在下一行**）：qBittorrent/Transmission 参数（密码为黑点框，右侧眼睛按钮切换显示；「添加后跳过校验（skipChecking）」仅在此页设置）+ 连接检测 + **大小检测**：填「VPS 剩余空间(GB)」与「安全边际(GB)」（默认 5），策略选「提醒」或「跳过」；种子大小超过剩余空间（含边际）时，提醒模式只提示、跳过模式直接不转种不推送。剩余空间请手动维护（qB 的 WebAPI 没有磁盘剩余接口）。
- **日志**：最近 500 条运行日志（转种/推送/cookie 变更），**日志时间戳为北京时间**（Asia/Shanghai，`yyyy-MM-dd HH:mm:ss`）。
- **设置**：**使用教程**——「查看使用教程」按钮打开图文教程弹窗（添加站点与分组 / 配置与备份 Cookie / 批量转种 / 推送到 VPS 下载器 / 外观设置，各配一张真实界面截图，图片打包于 app bundle `Resources/tutorial/`）。**主题**：6 个内置**渐变主题**（深空蓝 / 极光紫 / 翡翠绿 / 落日橙 / 玫瑰粉 / 云端白·浅色），点击卡片即时切换；主题渐变、强调色与明暗模式**覆盖所有窗口与区块**（主窗口 + 全部弹窗），风格统一；**主题色、壁纸与透明度同样覆盖各功能区块**（区块背景为半透明表面，让渐变/壁纸透出，明暗两套不透明度保证文字可读性）。背景图片：选择 / 更换 PNG·JPG·HEIC（存入 dataDir），铺满窗口（cover 裁切），**不改变窗口与各弹窗的大小比例**，「移除背景图片」还原；「背景图片透明度」滑条 0–100%（默认 45%）。

幂等：同一种子重复运行，已转种的目标站自动跳过（state.json 记录）；已推过的下载器重复推送按"已存在"处理（qBittorrent 5.2+ 的 409 视为成功）。目标站 torrent 按「目标站#新种子详情页」去重；转种成功后新种子链接存入 state.json，重复运行或 `--skip-reseed` 时也能据此补齐目标站推送。

## 使用（CLI，可选）

同一套核心库，适合脚本/launchd 定时任务：

```bash
swift build -c release
.build/release/box-send <命令>   # 或装到 /usr/local/bin/box-send

box-send sites                 列出配置的站点
box-send info --detail <url>   只解析详情页
box-send run --detail <url> [--site <id>] [--targets a,b] [--skip-reseed] [--skip-push]
box-send push --detail <url>   只推下载器
box-send import-zip --file <PTD_backup_*.zip> [--password <备份密码>]   导入 PT-depiler 本地备份
box-send gist-sync [--loop]    从 Gist 同步 cookie（--loop 常驻轮询）
box-send import-watch         扫描备份目录，自动导入新 PTD_backup*.zip（需配置 zipWatch）
box-send check-cookies [--site <id>]   检测各站 cookie 登录态（仅已开启站；--site 可查单站，YemaPT/TNode 走 API 判定）
box-send add-cookie --site <id> --cookie "k1=v1; k2=v2"   手动添加/覆盖单站 cookie（自动开启该站并加入转种目标）
box-send remove-cookie --site <id>     删除单站 cookie
box-send test-downloader       测试下载器连接
box-send serve [--port 8088] [--token xxx]   Web 控制台（可选，局域网访问用）
box-send cookies / notes / template / list --site <id> / version
# 全局: --config <path>（CLI 默认 Config/boxsend.json；与 GUI 的配置互不影响）
```

## 配置参考（boxsend.json）

GUI 与 CLI 的 JSON 结构一致（GUI 用 `~/Library/Application Support/BoxSend/boxsend.json`，CLI 用 `Config/boxsend.json`；仓库内 `Config/boxsend.example.json` 为模板）：

- `sourceSites`: 源站列表，每项 `id/name/url/framework/enabled` + 可选 `overrides`（9 优先站的 overrides **已内置在代码里** `Sources/BoxSendKit/Sites/SiteDefaults.swift`，由真实账号实测各站上传表单生成；JSON 里写的 overrides 会整体覆盖内置值）：
  - `uploadPath` / `uploadActionPath`：上传页 / 真正 POST 地址（中文 NexusPHP 家族 `takeupload.php`）
  - `titleField` / `descrField` / `imdbField` / `doubanField` / `categoryField` / `fileField`：表单字段名
  - `imdbValueTemplate` / `doubanValueTemplate`：值模板（`{imdb}` / `{douban}` 占位；`url` 型字段要完整链接）
  - `titleMode`: `reseed`（默认）| `torrentName` | `torrentNameDotted`（CMCT 规则：文件名且空格换 `.`）
  - `categoryMap`：`movie/series/anime/documentary/music/other` → 分类 ID；质量型站点（HDHome/TTG）用 `<kind>/<profile>` 键（`8k-bd/8k/uhd-bd/2160p/remux/bluray/1440p/1080p/1080i/720p/dvd/sd`，按发布名自动推断）
  - 分类解析优先级：`categoryMap` 静态表 > `categoryStringMap` 字符串表（影 等字母 token 站）> 上传页分类下拉动态解析（通用站免逐站配置）
  - `qualitySelects` / `qualityValueMaps`：媒介/编码/音轨/分辨率下拉自动填充（从发布名识别 REMUX/UHD/Web-DL/x265/DTS-HD MA 等）
  - `qualityStringMaps`：选项值为字符串的下拉值表（影 的 `tr_resolution` r1-r5）；`sourceSelectField`/`sourceMap`：源介质组合下拉（值依赖 媒介+分辨率，如 影 的 `tr_source`：`"remux/2160p": "s52"`，`"remux": "s42"` 兜底）
  - `forbidReseedMarkers`：命中即视为禁转（默认 `禁转/Excl.`），只推不转种
  - `extraUploadFields`：额外固定字段（如各站 `uplver`）
- `targetSites`: 转种目标站 id 列表（HHanClub 一般用户无发种权限，不作为目标站）
- `groups`: 目标站分组（可选，旧配置无此字段自动按空处理），每项 `name` / `sites`（成员站点 id）/ `upLimitMB`（组带宽上限 MB/s，0 = 不限）。种子推送时生效限速 = 站点限速与组带宽上限取小（旧配置里的 `dailyGB` 字段会被忽略）
- `downloader`:
  - `type`: `qbittorrent` | `transmission`
  - `url/username/password/savePath/category/skipChecking`
  - `defaultUpLimit` / `siteUpLimits`：**按源站点 id 的上传限速（bytes/s）**，0 = 不限速。例：`"cmct": 134217728`（128 MB/s）
  - `pushPolicy`: `always`（默认）| `onSuccess`
  - `vpsFreeGB`: VPS 剩余空间（GB，手动维护）；不填 = 不做大小检测
  - `sizeGuardMode`: `warn`（默认，提醒）| `skip`（超过剩余空间直接跳过该种子）
  - `sizeGuardMarginGB`: 安全边际（GB，默认 5），可用空间 = vpsFreeGB - 边际
- `gistSync`: `gistID` / `token` / `encryptionKey` / `pollMinutes`（GUI「自动定时同步」间隔）
- `zipWatch`: `enabled` / `dir`（PT-depiler 本地备份目录，默认 ~/Downloads）/ `pollMinutes` / `password`（备份密码，未加密备份可空）
- `appearance`: `themeID`（主题 id，见 GUI「设置」页 6 个渐变主题，默认 deepBlue）/ `bgImage`（背景图片文件名，存 dataDir，空 = 无）/ `bgOpacity`（背景图片透明度 0–1，默认 0.45）
- `userAgent` / `webToken`（serve 用）/ `dataDir`（CLI 用，默认 `~/.boxsend`）

> 限速生效方式：qBittorrent 在 `torrents/add` 请求里直接带 `upLimit`；Transmission 在 `torrent-add` 后 `torrent-set` 设 `upload-limit`。
> qBittorrent 5.2+ 推送已存在的种子返回 409 Conflict，视为"已推送"（幂等）。

## 打包与安装 .app

- `bash scripts/make-app.sh` → `dist/BoxSend.app`（release 编译 + 图标 1.webp→AppIcon.icns + Info.plist + ad-hoc 签名）。
- 打包脚本从 `Sources/BoxSendKit/Util/Version.swift` 读版本号写入 Info.plist，不要在脚本里另写版本。
- 分发：zip 后发给别的 Mac，首次打开需右键 → 打开（ad-hoc 签名无开发者账号）。
- 应用无沙盒、ad-hoc 签名：需要网络访问 + 读 `~/Library/Application Support/BoxSend` + 调 `/usr/bin/unzip` 解 PT-depiler 备份。

## 版本与仓库

当前版本 **1.0**。版本号只有一个来源：`Sources/BoxSendKit/Util/Version.swift`。
GUI 窗口标题、`box-send version`、`scripts/make-app.sh` 写进 Info.plist 的
`CFBundleShortVersionString` / `CFBundleVersion` 都读它，发版只改这一处。

不入库（`.gitignore`）：

- `.build/`、`build/`、`dist/`：SwiftPM 构建产物、图标中间产物、打包出来的 `BoxSend.app`。
- `.swiftpm/`：SwiftPM 本地状态。
- `Config/boxsend.json`：本机真实配置，含 GitHub token、CookieCloud KEY/端对端密码、下载器账号密码。
  模板是 `Config/boxsend.example.json`（无凭据），新环境用 `box-send template` 或复制模板。
- `.boxsend/`、`*.log`：有人把 `dataDir` 指进仓库时产生的运行状态与日志。
- `.DS_Store`、`.vscode/`、`.idea/`、`.env`。

入库的：`Sources/`、`Tests/`（含 `Fixtures/` 真实页面与种子样本）、`Config/boxsend.example.json`、
`Resources/tutorial/*.jpg`（教程配图，输入框均为掩码态）、`deploy/*.service`（VPS systemd 单元）、
`scripts/`、`1.webp`（图标源图，打包时转 icns）。

样本里带真实账号痕迹的字段已做脱敏：三个 `.torrent` 样本的 announce passkey / uid
和页面样本里的 passkey 都换成长度不变的占位值（`info` 段未动，info hash 不变，测试照常校验）；
页面样本只保留 `userdetails.php?id=` 这类非凭据字段。真实 cookie/passkey/token 只存在于本机
`~/Library/Application Support/BoxSend/`，不会被提交。

## 测试

`swift test`（222 个用例：NIST AES-256 向量、`openssl enc -aes-256-cbc -a -md md5` 的 Gist 备份解密向量、gist 密钥推导、cookie jar、限速配置、质量标记解析、站点 overrides 解码、真实详情页解析（标题/副标题/类型/MediaInfo/IMDb/豆瓣）、bencode `info.name` 与 info-hash（SHA-1 向量）、HTML→BBCode 简介转换（含 CRLF 空行归一化）、HDSky 上传表单全字段校验、大小检测边界与旧配置兼容、备份目录监控导入与重试、Blu 家族详情解析（blutopia/monika 真实页面）与上传字段映射（分类/媒介/分辨率/季集/IMDb）、Gazelle 详情解析（HDSpace 真实页面）与 xbtit BBCode 还原、影站字符串分类+源介质组合下拉、通用站动态分类解析、内置站点表自动并入、新版 NexusPHP 动态质量/标签/technical_info 填充（多 data-mode 下拉、ajax 子分类、年份兜底选编码）、TNode（ZHUQUE）真实 API 响应解析与字段映射（选项分组/详情/截图提取/分类媒介编码分辨率标签/TMDB）、HAIDAN 自定义详情布局解析与经典上传字段映射（tag_list 标签/豆瓣 durl）、YemaPT 真实 API 响应解析（详情/选项/IMDb 查重列表）与上传字段映射（分类树/媒介/分辨率/编码/音轨/地区/标签/季集/匿名）、Markdown 与 HTML 简介互转、piecesHash（bencoded pieces 值 SHA-1）、savept 长尾 144 站注册表（框架映射/无重复 id/域名迁移/中文站名）、站点名称默认排序（数字开头在前 + 拼音字母序：zh-Hans-CN 语区拼音序、拉丁名按首字母混排、中文数字汉字不进数字组、内置名录 144 站全量排序预览）、内置表站名同步入用户配置、旧配置无 managed 字段时按 enabled 推断（已添加/未添加站点模型）、未加入分组站点手动排序持久化（旧配置缺省空 + 新字段往返）、cookie 单站导入覆盖与删除、CookieCloud 端对端加密协议（MD5 密钥向量、openssl legacy AES-256-CBC 与 AES-128-CBC 固定零 IV 双格式解密、错误密码、cookie_data 解析、host 主/子域匹配、拉取导入与空结果报错）、GistSync 拉取解密（performOverride 注入 gist API 响应 + openssl 加密 cookies.txt 全链路、manifest 备份时间、pull 导入 store 与状态）、猫（pterclub）标签勾选（源站「标签」行解析、拼音命名复选框按文案精确识别、真实上传页字段校验）、LuckPT 56812 转种 10 站真实上传页字段回归（熊猫/PTtime/烧包/优堡/麒麟/咖啡/青蛙/织梦/葡萄汁/蟹黄堡的地区、分辨率、处理、媒介、音频落 Other、豆瓣 pt_gen、完结与动画标签、转载来源前缀、野马已存在判定）、本轮实测修正（官方标签不外打目标站、源站「类别」行转题材标签、财神补喜剧标签、城市两步上传的表单地址/第二步字段/标题剥离品牌后缀、Other 兜底只认纯「其他」、TNode 详情取 id 与 TORRENT_ALREADY_UPLOAD 判定、非 bencode 下载响应里的站点提示提取、HD-Space 搜索结果页查重（& 转义 + 40 位 sha1 id + 属性值里的 ">"）、xbtit 用 info_hash 拼详情页、PeerGo 查重关键词提取、备份来源 cookie 合并（`.example.com` 与 `example.com` 同站合并、同名取过期更晚）、转种目标站实测二轮（「Invalid category」类失败的分类关键词兜底、fieldset/textarea 里的 MediaInfo 提取并从简介剔除、完结标签只认单季完结剧集、存旧配置遮蔽内置字段时的控件名探测兜底（排除 BBCode 按钮）、查重结果相对链接补全、CRLF/emoji 页面提取 div 不越界、3D 分辨率不抢 2K/1080p、DTS-HD 优先于 TrueHD）。

活站实测（可选，需要真实 cookie）：`BOXSEND_LIVE=1 swift test --filter LiveAdapterTests`，用 `BOXSEND_LIVE_SITES` 指定解析站点、`BOXSEND_LIVE_PREVIEW_SITES` 只预览上传字段不真发种、`BOXSEND_LIVE_PUSH_SITE/URL` 验证推送下载器；默认不跑，CI 上无需凭据。

## 里程碑

- M1：Mac GUI 主体（运行/站点限速/Cookie/下载器/日志）+ 核心库（HTTP/站点/转种流水线/下载器/Gist 同步/Web 控制台）+ 9 优先站内置实测 overrides（8 站可转种）+ 质量标记自动填充 + PT-depiler 本地备份 zip 导入（加密/未加密）+ 按站点限速 + 目标站分组（带宽上限）+ 状态幂等 + CLI
- M2（已完成部分加粗）：**PT-depiler 备份目录监控自动导入**、**cookie 健康检测**、**种子大小检测（对比 VPS 剩余空间，提醒/跳过）**、**目标站搜索查重（8 站端点实测）**、**站点覆盖扩展（Blu 家族 blutopia/monika + 经典 Gazelle/xbtit HDSpace/OpenCD/IPTorrents + BYR/影 特殊 NexusPHP + ~70 通用中文 NexusPHP 站，动态分类解析免逐站配置）**、**YemaPT（umi.js SPA + REST API）适配器**（选项/详情/下载/双重查重/发种，真实 API 响应 fixture 测试）；剩余：Unit3D（REST API）适配器、OWSS/WebDAV 同步、简介模板精调、状态存 SQLite（历史查询）
- M3：长尾站点（OurBits/GPW/MTeam/PTP/HDB/BTN/CinemaZ 新版表单、TNode 截图图床校验）、截图搬运图床、动态限速、统计面板

## 已知限制

- 应用为 ad-hoc 签名（无开发者账号）：首次打开需右键 → 打开；从网盘/airdrop 拿到可能被 Gatekeeper 拦。
- 转种失败时上传页 HTML 存 `~/Library/Application Support/BoxSend/debug/upload-<站id>-<时间戳>.html`，错误信息带路径。
- 质量分类/下拉按发布名启发式推断，个别非标准命名可能落到兜底分类，可在 overrides 精调。
- 个别有 Cloudflare/JS 校验的站点纯 HTTP 可能失败，需浏览器兜底（PT-depiler 手动转种）。
- 肉丝（rousi.pro，PeerGo 引擎）发种走 JSON API：`POST /api/v1/torrents`，分类与属性从 `/api/v1/categories?include_disabled=1`、`/api/v1/categories/<id>/facets` 现取现用。写接口只认「会话 cookie + `X-CSRF-Token` + 同源 `Origin`」，API Key 只用于读接口与有效性检测，所以肉丝仍需同步 cookie 才能发种。同一端点匿名与带钥匙是两套 schema（匿名返回裸数组 / `items`，且 `keyword` 参数被忽略；带 `Authorization: Bearer` 才返回 `{code,data:{torrents}}` 并按关键词过滤），所以只有查重请求带钥匙。站点回「种子已存在」时会按标题回查站内：查到就记「已存在」并给出链接；查不到记失败并说明原因——被审核驳回的历史提交会永久占用 info hash（实测 `/api/v1/torrents/<id>` 已 404，重传仍回 409），这时需要换种子文件或联系站点。
- YZYY（Discuz 插件 dz_seed）是两步发种：发布表单投递种子与 ptgen 结果 → 发帖页（先过「发帖须知」）→ 提交 postform。Discuz 发帖页带图片验证码（`misc.php?mod=seccode` 返回 PNG），软件会把种子、豆瓣信息、分类信息都填好，最后一张验证码需人工点「发布」。
- 推下载器只看「有没有站点转种成功」：有任一成功就推，失败的站不影响其它站；全部目标站失败才不推，日志写明「push 跳过：N 个目标站全部转种失败（站点列表）」。目标站回「已存在」按成功算，并回查站内链接以推送该站自己的 .torrent。
- HD-Space（xbtit）结果页与详情页的种子 id 就是 info_hash 的 40 位 hex，且 & 转义成 `&amp;`：响应里没给跳转链接时软件用本地种子的 info_hash 直接拼详情页，「可能已存在」时同样能定位到站内那条种子并推送。
- 源页解析不出简介时不会提交空简介：会兜一句「转载自<源站>，感谢发布者。+ 源站链接」（TTG 的「简述」在 `<div id='kt_d'>`、MediaInfo 在 `Quote:` 虚线引用表里，已单独适配；空简介会让整批目标站一起回「你必须填写简介！」）。
- 上传失败时同目录还会留 `fields-<站id>-<时间戳>.txt`，是本次 POST 的全部字段，站点报「请填写必填项目」时对着它看缺哪一项。
- HHanClub 为候选区上传（offers.php），一般用户无发种权限，故仅作源站。
- de5 隧道只开放了 qBittorrent WebAPI 的部分端点：`auth/login`、`torrents/info`、`torrents/add` 可用；`addtrackers`/`properties`/`remove` 返回 404（隧道未映射）。后果：同一 info hash 的多站种子无法合并 tracker、已推送种子无法从本软件移除/改属性（需在 qB WebUI 里操作）。
- 大小检测的「VPS 剩余空间」是手动维护值（qB WebAPI 无磁盘剩余接口），空间变化大时记得更新配置；建议配「安全边际」留余量。
- 「已存在」路径的目标站种子链接来自站内搜索结果页，常是相对链接（`details.php?id=123`）：读取时按站点主页补成绝对地址，旧 `state.json` 里已存的相对链接同样自愈。
- 站点报「已存在」但站内搜不到（审核驳回占用 info hash 等）时记「已存在（未推送：站内没检索到该种子）」，不误报成功。
- 上传页返回空或站点报错页（无 `<form>`）时直接报「上传页没有表单（页面为空或站点报错），请先检测该站 cookie」，不再抛「未识别的返回」（实测烧包 ptsbao.club 整站 500 时即此提示）。
- 1.0 移除了 RSS 自动转种（RSS 页、`RssPoller`、配置 `rss` 段、CLI `rss-sync`、状态 `rssSeen`）：自动入库走 PT-depiler 备份目录监控 + 「批量转种」手动触发；旧配置里残留的 `rss` / `overrides.rssPath` 字段会被忽略，`state.json` 里的 `rssSeen` 同样忽略。
