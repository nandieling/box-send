# Windows 移植记录

方案：**核心逻辑继续用 macOS 那套 Swift 代码，Windows 另写一套原生 WPF 界面。**
两端界面不共用，跨边界只有一种调用（`invoke` 收发 JSON），进度靠轮询。

```
macOS    SwiftUI/AppKit ─┐
                         ├─ BoxSendKit（站点/转种流水线/cookie/下载器/Gist·CookieCloud/Web 控制台）
Windows  WPF ──P/Invoke──┘   boxsend-core.dll（C ABI + JSON 契约）
```

选它的理由很直接：核心 1.1 万多行只依赖 Foundation，并且早就在 Debian 上无头跑通
（`scripts/deploy-debian.sh`、`deploy/boxsend-web.service`），移植风险本来就集中在界面，不在逻辑。
Apple 专属的东西只有四处，逐个改成可注入钩子即可；纯算法（AES）改成两端共用一份实现，
省掉「mac 能用、Windows 解不出 cookie」这类最难查的分歧。

## 平台接缝

| 位置 | mac | Windows |
| --- | --- | --- |
| `Platform.hooks.jpegReencode` | ImageIO | 由宿主注入（未注入时直接发原图） |
| `Platform.hooks.ocr` | Vision | 待接 `Windows.Media.Ocr` |
| `Platform.hooks.unzip` | `/usr/bin/unzip` | 系统自带 `tar.exe -xf`，或由宿主注入 |
| AES（CookieCloud） | 纯 Swift 实现 | 同一份纯 Swift 实现（不再用 CommonCrypto） |
| 内置 HTTP 服务 | Darwin socket | Winsock 分支，手写点分 IPv4 解析 |
| 站点名拼音排序 | `CFStringCompareWithOptionsAndLocale` | 同一行 `String.compare(locale:)`（Windows 的 Foundation 没有 CoreFoundation 模块，但同样走 ICU 的 CLDR 排序） |
| 数据目录 | `~/Library/Application Support/BoxSend` | `%APPDATA%\BoxSend` |

钩子都在 `Sources/BoxSendKit/Platform/Platform.swift`，不注入就走 mac 的老路，所以 macOS 版行为一字未改。

## 边界契约

`Sources/BoxSendBridge/Exports.swift`：`boxsend_create` / `boxsend_invoke` / `boxsend_free` /
`boxsend_set_ocr` / `boxsend_version` / `boxsend_destroy` / `boxsend_last_error`。

请求 `{ "method": "sites.add", "params": { … } }`，响应 `{ "ok": true, "result": { … } }`
或 `{ "ok": false, "error": "给人看的一句话" }`。耗时动作立即返回，跑在核心内部后台队列，
界面靠 `snapshot`（整份状态）+ `events(since:)`（游标）轮询取进度。

服务侧实现在 `Sources/BoxSendKit/Bridge/AppService.swift`，方法按界面分区：
`snapshot / events / logs.clear`、`config.get|set|patch / appearance.set`、
`groups.add|rename|remove|move|setLimit|sortSites`、
`sites.add|remove|setEnabled|move|moveBefore|setGroup|setApiKey|setUpLimit|setAutoFree`、
`sites.candidates`（批量添加站点弹窗的候选与顺序）、`sites.matchURL`（按链接认源站）、
`targets.set / sourceQuote.set`、
`cookies.getRaw|setRaw|remove|clear|trim|sync|check|stopCheck|importZip`
（`getRaw`/`setRaw` 按站点类型分流：API 站读写 `site.apiKey` 并回一个 `usesAPIKey`，其余读写 cookie 罐）、
`zip.set / zip.scan`、`downloader.test`、`ssh.test`、`run.start / run.status`、
`tmdb.test`、`update.check`。快照的 `busy` 多一个 `sshTest`，站点行多一对
`supportsAutoFree` / `autoFree`（卡片上要不要放「发种后免费一天」开关）；
`boxsend_set_ssh_exec`（宿主代跑 SSH：Windows 的密码登录用，见 `SSHSpeedTest.perform`）。
`version` 顺带给 `sshDefaults`（私钥路径、每轮数据量、测速地址、限速参考线），
界面两端不必各抄一份默认值。

分组和站点的规则（改名撞号加序号、入组自动启用并继承组限速、删组退回未分组……）从 mac 的
`AppModel` 抽到 `Sources/BoxSendKit/Models/ConfigEdits.swift`，两套界面共用一套规则，
色值同理走 `ThemeCatalog`。mac 的 `AppModel` 目前还留着自己那份实现，等 Windows 版验收后再统一。

## 进度

已完成（都在本机验过）：

- 核心去 Apple 依赖 + 纯 Swift AES（FIPS-197 官方向量对着测）
- Winsock 版内置 HTTP 服务（含 localhost 往返测试）
- 无头服务 JSON 契约、事件流、配置补丁（小节只合并一层）
- C ABI 导出 + .NET 侧冒烟测试 `windows/abi-probe`（加载真库跑一遍 WPF 开机路径）
- WPF 六页界面、托盘、关窗收托盘、单实例、PerMonitorV2 DPI、主题与背景图
- Gist / CookieCloud / 备份目录监控三个定时任务（含配置里那份 `zipWatch.enabled` 的开机续挂）
- 图标 `boxsend.ico`（与 mac 的 AppIcon.icns 同源，`windows/make_icon.py` 生成）
- 打包：`windows/build.ps1` + `windows/installer/boxsend.iss`
- 回归测试从 337 个加到 445 个，全绿（SSH 测速那 27 条按平台分流：密码 askpass 与 sh 桩
  只在类 UNIX 上跑，Windows 上改成验「密码登录被直接拒绝」，并另有一条用系统真 ssh
  连没人监听的端口，把「起进程 + 把 ssh 的抱怨翻成人话」在 Windows 上真跑一遍）

界面这一轮补齐（WPF 端，Windows 上待验）：

- 顶部页签：六个页签居中成一条「分段控件」，图标改为随主题描边的矢量图形，
  最大化时页签整体放大一档（`ThemeManager.ApplyMetrics`，字号/图标/内边距全走 DynamicResource）
- 控件模板全部主题化（按钮 / 输入框 / 下拉 / 勾选 / 分组卡片 / 页签），
  深色主题下不再是系统默认的白底黑字；弹窗底色改用 `DialogBackground`
- 站点分组页对齐 mac：组内站点成块、整组全选、手动填 cookie / Key、上下移、
  移除分组与移除站点都要两次确认；未分组的站点才出现「未分组站点」这一块，
  并给出「全部移出纳管」；支持自动免费的站点卡片上有「发种后免费一天」
- 不再有个去不掉的「未分组」：新配置由核心 `template()` 预置「默认分组」，
  老配置（站点都纳管了却一个分组没有）在 `AppConfig.load` 里补一个同名分组接住它们；
  真要出现没归组的站点（比如内置表新增了站），那块会显示成「未分组站点（N）」并给「全部移出纳管」
- 设置页补 TMDB 反查卡片与使用教程窗口；下载器页补 SSH 上传测速卡片
- 转种页改为按分成分块勾选，「开始运行」旁给出「已选 N 个分组 · M 个站点」，
  并按 mac 的行为在开跑前先测服务器速度

界面这一轮再对齐（WPF 端，Windows 上待验）：

- 分组块：去掉组名的「上移 / 下移」与工具行的「检测本组」（顶部「检测全部 cookie」已覆盖）；
  两处「默认限速」输入框加宽到 116，不再挤掉数字
- 站点卡片：去掉「↑ / ↓ / 移组 / 移除」四个小按钮，改成 mac 那套——拖卡片右侧把手到另一张卡片上
  排序，或在把手左边输入序号回车排到第几位（走 `sites.moveBefore` / `groups.sortSites`）
- 批量添加站点弹窗：卡片式多选、搜索、全选、拖把手与序号排序，分组由入口锁定（不再有下拉选框）；
  候选顺序改由核心 `sites.candidates` 给，C# 不再自己抄一份拼音序
- 下拉框整套重画（`App.xaml`）：框体、下拉面板、条目高亮全走主题色，深色主题上不再是白底白字；
  `SiteRow` 补了 `ToString()`，源站选择与手动填 cookie 的下拉里不再显示类名
- 转种页源站下拉对齐 mac：未点名时按域名识别，标签写成「源站：自动（某站）」，
  旁边给出「源站种子获取中… / 已获取 / 获取失败」那颗状态徽标（认站规则由 `sites.matchURL` 给）
- Cookie 页去掉「本地 cookie」整块（与站点分组页重复），只把「清空本地 cookie」留在备份卡片里
- 设置页主题选择：主题名写在色块下方的卡片底上，浅色主题名在深色主题下不再看不清
- 弹窗（文本输入 / 批量添加站点 / 手动填 cookie）背景补上主题渐变与背景图片，透明度跟设置里一致
- 修掉一处刷新竞态：全量刷新撞上正在跑的局部刷新时，那一轮拿的是改动前的快照，
  表现为「加了站点但卡片没立刻出现」；现在把待办记下来，那一轮结束后补一轮
- 测速弹窗只报测速信息一行（两端共用 `SSHSpeedTest.gateText`），不再附一段限速说明
- 手动填凭据弹窗按站点类型分流（核心 `cookies.getRaw|setRaw`）：馒头这类 API 站读写 `site.apiKey`，
  标题、输入框说明、「清空」按钮文案跟着站点类型走——之前只读写 cookie 罐，API 站是
  「保存成功、再点开输入框是空的」
- 站点卡片状态行去掉 cookie 条数，改用 mac 那套结论词（无 cookie / 未检测 / 已登录 /
  cookie 失效 / API 已连接 / API Key 失效 / 未配置 API Key / 未开启），检测原因放进鼠标提示

## 这一轮（Windows 界面 + 密码登录）

- 转种页改成 mac 那个形状：每个分组一张卡，组名旁整组「全选 / 全不选」，组内是站点卡片
  （站点名 + 上传限速 + 转种胶囊 + 推送胶囊 + 一行详情），点卡片选为目标；底下专门的
  「转种结果」「下载器推送」两块去掉，整批汇总收进可展开的「运行记录」（= mac 的同名折叠区）
- 卡片状态不再靠重建整页刷新：核心每轮快照落地都发一次 `Refreshed`，界面只改胶囊文字与底色
- 「转种前先测上传速度」的勾选框从下载器页挪到转种页「开始运行」左边（服务器地址等仍在原卡片，
  mac 版同步这么改）；服务器没填全时这个勾选框直接禁用并显示未勾选，鼠标提示说去哪儿填
- 分组标题右侧按钮顺序统一为「添加站点 / 重命名 / 移除分组」（两端同改）
- Windows 支持密码登录：下载器页那张卡片多了「登录方式」与密码框，密码那一趟走内置 SSH.NET，
  失败按六类翻成人话（登录被拒 / 端口没监听 / 超时 / 域名解析失败 / 连接被断开 / 算法协商失败）

## 这一轮（源站壳页、蓝光 DIY、压制判定、动漫分类）

- 新版 NexusPHP 主题（LuckPT）的 `details.php` 只回一张「壳」页：有标题、没有简介容器。
  以前只要页面上有 `id="top"` 就算详情页，于是 `ajax=1` 那次重试根本不发，
  豆瓣 / IMDb / 产地 / 类别 / 截图 / 制作引用全带不过去，目标站简介里只剩一段转载引用。
  现在按「有没有简介容器」决定要不要补取 `ajax=1`，两边比信息量取更 full 的那份
- 新增源站信息完整性检查：详情正文几乎为空、又没带出豆瓣/IMDb 链接时，
  日志与运行报告里给一条「源站详情只取到壳页」的提醒（两端同源，Windows 也走这条）
- DIY 判定（`QualityTokens.isDIYRelease`）：蓝光原盘与蓝光 DIY 是两个概念 ——
  蓝光盘没中文字幕 = 蓝光原盘，加装了中文字幕 = 蓝光 DIY。所以两条判据：
  1) 发布名把 DIY 写成独立词（`hasDIYToken` 看边界，发布组名 `-LuckDIY` 不算）、
     或源站标签行有 DIY/自压/自制/重制/汉化 —— 明写的什么媒介都跟随；
  2) 没明写时只有蓝光盘（Blu-ray / UHD 碟）用「带中文字幕」推 DIY。
     REMUX 不推：Remux 是原盘无损封装，站点的 DIY 专指蓝光 DIY
     （天空那条 1080p Blu-ray Remux 内封中字曾被误打 DIY）。
  国产（中国大陆）碟自带简繁字幕不算，认不出产地时还要看到外语原声痕迹才判。
  命中后：媒介选本站的 Blu-ray/DIY（铂金家 14、1PT 19、咖啡 5、库非 5、红豆饭 22、
  海德堡 4、52PT 2、冬樱 13、爱玲 2、天空 12），打 DIY 标签，
  「原盘 / 原生原盘」标签不再勾。天空那份写死 `1=Blu-ray` 的内置值表，
  现在遇到本站另有 DIY 选项时会改选 DIY 那项
- x264 / x265 是软件编码器：出现在发布名或 MediaInfo/BDInfo 里就是压制盘（REMUX、
  BDMV/ISO 除外；4K 仍保留 UHD 媒介）。MonikaDesign 的 `1080p BluRay x265` 因此从
  Full Disc 改判 Encode
- 动漫分类按形态细分：站点把动漫拆成「动漫电影 / 动漫剧集分集 / 动漫剧集合集」
  （冬樱）或「完结动漫 / 连载动漫 / 剧场OVA」（蝴蝶）时，单片落进 电影 / 剧场 / OVA，
  连载落进 剧集 / 分集，整季完结偏向 合集；蝴蝶这类把剧场版单列的站先按「剧场 / OVA」找
- Windows：源站下拉换项时整组重建（只换 `Items[0]` 会让 ComboBox 丢掉选中项，
  表现为链接已识别出站点、框里还是「自动识别」）；点名的源站记在界面字段里，
  源站种子取到后立刻刷一次文案
- Windows：站点卡片那行说明去掉限高与省略号，长文案换行显示，不再被裁一半

## 这一轮（Windows：拖拽排序、选中色、默认勾选、托盘）

- 组内卡片顺序改按 `group.sites`（与 mac 的 `groupMembers` 同一口径）。以前照扁平站点列表画，
  那份是站点表顺序，于是拖完、按序号排完看着都没动 —— 排序其实写进配置了，只是显示不认
- 拖拽排序换成共用的 `CardDrag`：整张卡片都能拖起（输入框 / 勾选框 / 按钮这些落点除外），
  拖到哪张卡上就排到它前面。原来只有右上角那个 14px 的「≡」接拖拽，点不中就像「拖不动」；
  把手留着但只当视觉提示。站点分组页与「批量添加站点」弹窗共用一套
- 跨组拖拽顺带改分组（核心 `moveBefore` 只在同组内挪位，不先 `sites.setGroup` 会没反应）；
  序号框除回车外，失焦也生效；序号框按分组各存一份，别组填的数字不再牵连本组
- 转种页选中卡片的底色改用淡一档的 `AccentFaint`（15% 强调色），28% 压在卡片上太沉、站点名发闷
- 转种页默认勾选改看配置里的 `targetSites`（与 mac 同一份）：第一次用就是全不选；
  「本批 N 个站点」只算纳管站点（以前把没纳管的源站也算进去，比卡片多一个）；
  点卡片 / 整组全选后把勾选写回 `targets.set`，下次打开还是这批
- 托盘改用 WinForms 的 `NotifyIcon`（自包含包里 WinForms 本来就有，不额外占体积）：
  折叠区里不再是黑方块，图标随包那份 `boxsend.ico` 由 GDI+ 按系统小图标尺寸挑帧；
  右键菜单加了「打开 BoxSend / 退出 BoxSend」——以前右键只是叫窗口，而关窗又是收托盘，等于没退出口。
  工程里把 WinForms / System.Drawing 的隐式 using 撤掉，免得 `TextBox`、`Application` 在 WPF 侧变二义

## 这一轮（核心：HDVideo 必填「地区」）

- 源站简介的产地行从只认「产　　地」扩到豆瓣「制片国家/地区」、英文「Production Country/Country」，
  取到的值先归一成表内规范产地（Japan/JPN/日本 都算日本），认不出的残句不当产地
- 目标站地区类下拉（`region_sel` / 实为地区表的 `source_sel`、`processing_sel`）填值改成一条兜底链：
  简介产地 -> 发布名国家词元（JPN/USA/HK…）-> 动画按日系发布算日本（国漫/国创带中文标记时不猜）
  -> 地区表里的「其他/其他地区」；后两步只在选项确实是地区表时启用，媒介、来源那类下拉不受影响
- 影响：HDVideo 把地区设成必填，源站简介空着时以前直接不发（服务端回「上传失败！请选择地区」），
  现在按这条链填上；回归测试 `testHDVideoRegionNeverLeftEmpty`、`testRegionSelectAlwaysFilled`、
  `testRegionLabelVariants`

## 这一轮（猫站重复：认对种子、说清是哪条、照常推送）

- 站点回「该种子已存在」时不再抓页面上第一条详情链接：实测猫站那条指向页首横幅广告
  （`/details.php?id=617819`），显示出来的「重复种子」莫名其妙。现在按四步认：
  提示块（`class` 带 exist 的容器，猫站是 `torrent-exists-tbl`，一行 Torrent Name 就是答案）
  -> 页面里那条种子自己的 `download.php?id=` -> 提示语之后有锚文本的详情链接 -> 裸链接兜底；
  抓之前先剥掉 HTML 注释（注释里躺着 Banner 链接），并且不认锚文本为空的链接（横幅只有 `<img>`）
- 重复信息显示：提示语带上站内那条的标题（「站点回「种子已存在」，本次未新发种（站内已有：xxx）」），
  卡片详情行显示「说明 / 已有种子标题 / 链接」三行，Windows 卡片窄，收成一行、全文进鼠标提示
- 站内检索的写法差异：比对用的串与词元会压掉连续重复字母（`foldDoubledLetters`），
  站内把 Blu-ray 写成 BluRay 时去掉分隔符是 blurray，不压就永远认不出是同一种子；
  查询词仍用原样分词（Lagoon 压成 lagon 就查不到东西了）
- 上传前查重多一条候选查询词：去掉标点、只取前几个词（站点检索多按词匹配，
  整名里一个「Blu-」就能让写成 BluRay 的那条查不到）；命中与否仍由名称匹配判
- 「已存在」的站单独记账（`state.existing`）：重跑时不再显示成「转种成功（此前已转种）」，
  而是「站内已有该种子」；那次没找回站内链接的，重跑会补查一次并把站内那条推给下载器，
  推送文案是「推送已有种子」。实测猫站这条从 0 变成 `details.php?id=768037` + 跨种生效

## 这一轮（重跑分得清「我发的」和「别人先发」）

- 上一轮之后重跑还是满屏绿色：本地那条 `uploaded` 记录只说「此前发过」，没说站内那条是谁发的，
  于是别人三月份就发在站里的种子，重跑也报「转种成功 + 已推送」。现在重跑会回站内看一眼
- 新增归属判定 `TorrentOwnership`（ours / theirs / unknown），NexusPHP 系站点按三步认：
  发布者 id 与本页登录用户比对 -> 那条种子上有没有我自己的 `edit.php?id=` 入口 ->
  页面发布时间比本地记下「转种成功」早一天半以上就算别人的
  （猫站允许匿名发布，「由 匿名 发布于」那一行拿不到发布者 id，只能靠时间）
- 认成别人的：卡片显示「站内已有该种子」（蓝色↓，与首次重复同一套），详情三行说明 + 站内那条的
  标题和链接，并且照旧把站内那条推给下载器；认成自己的：清掉「站内已有」标记，继续报「转种成功（此前已转种）」
- 认不出（站点框架不支持、页面读不出、详情页打不开）就沿用此前的判定，不瞎猜
- 非 NexusPHP 的站点（馒头 Discuz、花园、海胆之外的自研框架）走默认 `.unknown`，行为与上一版一致
- 测试：`DuplicatePushTests` 里加了发布者行、匿名+发布时间、编辑入口三条认归属的用例，
  以及两条流水线用例（重跑报重复 / 重跑仍报成功）

## 这一轮（Windows：同步不卡界面、逐站显示检测、备份按主域认站）

- 点「同步 Cookie」整个窗口卡成「未响应」：界面线程直接在核心里跑 Gist/CookieCloud 拉取，
  那是几秒的网络往返。新增 `AppModel.TryAsync`，cookie 同步、zip 扫描、测下载器、查更新
  一律丢到线程池，跑完补一次快照；两个「立即同步」按钮的文案/可用性改由核心的同步标记驱动
  （自动同步走同一条路，所以也会显示「同步中…」，重复点击由核心挡）
- 「一直显示检测中」：卡片只在整页重建时才换内容，而整页重建只跟配置变化走。站点行改为可通知属性，
  600ms 一次的局部刷新会把快照里本站的检测结论写进现有卡片（未检测 → cookie 检测中… → 已登录/失效，
  检测原因还在鼠标提示里），工具条上的「检测全部/停止检测」也跟着局部刷新更新
- 检测本身：核心改为滚动并发（同时在检 4 个站，与 mac 版同一档，不是「一批检完再下一批」），
  站点项新增 `checking`，界面逐站显示进度。同一台机器、同一份 74 站 cookie 实测：
  串行 3 分 58 秒 → 每批 4 个 154 秒 → 滚动并发 58 秒
- 铂金家「同步后显示无 cookie」而 mac 正常：浏览器备份按 cookie 域分组，这站的 cookie 记在
  `pthome.net` 下，站点配的却是 `www.pthome.net`，核心的匹配只比字符串（mac 版按主域/子域认）。
  规则统一到 `CookieRawMerge.hostMatches`：完全相同的那个优先，其次才主域/子域互通；
  子域不同的两个站不会被误认成一个
- 同步里导入备份那段循环拆成 `importBackupRaws`，不联网也能直接验（新增 5 条用例）
- Windows 端待验：窗口不卡、逐站状态与按钮文案；判定逻辑两端共用，不需要另写一份

## 两端有意不同

1. **验证码识别**（唯一功能缺口）。mac 用 Vision 现认 Discuz 发帖验证码；Windows 侧识别器还没接，
   表现是「需要 seccode 的站点放弃自动发帖并写明原因」，其余流程照常。
   补法：把 csproj 的 TFM 提到 `net8.0-windows10.0.19041.0`，在 `BoxSendApi` 构造时传一个
   `OcrCallback`，里面用 `Windows.Media.Ocr.OcrEngine` 把候选写进核心给的缓冲区即可（约 20 行）。
2. **同步后的「跨来源救活」**。mac 在两个来源都提供同一站点、而第一份被站点判失效时，会拿另一份重试。
   服务里这步暂时没做（它依赖逐站真实网络结果，在这里没法验），同批同步后已会自动复检，
   界面能看到失效站点，手动再点一次另一来源即可。
3. **更新**：两端都是「检查版本 + 打开安装包直链/发布页」，都不做静默安装。
4. **关窗**：Windows 关窗收进托盘继续跑（mac 是窗口关了进程还在），托盘双击回界面。
5. **SSH 密码登录的实现不同**。Windows 自带的 OpenSSH 客户端不读 `SSH_ASKPASS`，密码没地方代填，
   所以密码那一半改由宿主代跑：核心把 `Platform.hooks.sshExec` 交出去，WPF 侧用 SSH.NET
   （MIT，纯托管，随自包含包一起发）连。密钥登录两端都走系统 ssh——那条路早就验过，
   换实现只会多一份不确定性。mac 两种登录仍走系统 ssh（密码用 askpass 代填）。
6. **分组之间的顺序**：两端都不能在界面上调，配置里的先后就是执行与显示的先后
   （核心 `groups.move` 留着，谁要做拖拽排序直接能用）。组内排序两端一致：拖把手 + 输入序号。

## 到 Windows 机器上要做的事

1. `swift build --product boxsend-core` 与 `swift test` 先全绿 —— 核心在 Windows 上编译过没有别的说法。
   （CI 的 Windows 作业已经在做这件事，本地可以不重复。）
2. `dotnet run --project windows/abi-probe`（Windows 上加载的就是 `boxsend-core.dll`）。
3. `.\windows\build.ps1`，跑 `windows\publish\BoxSend.exe`。首次启动若报缺 DLL，就是 Swift 运行时
   没拷全，按提示名从工具链 `usr\bin` 补进 `BoxSend.Windows\native\`；`dumpbin /dependents boxsend-core.dll` 是权威判据。
4. 六页逐项对照 mac 版：建组、批量加站、组限速、逐站检测、下载器测试、TMDB、主题与背景图。
5. **双跑对拍**：同一份 `boxsend.json`、同一批 cookie，mac 与 Windows 各跑同一条源种链接，
   比对发种结果、推送、限速、日志。这一步是功能等价的真正验收，别省。
6. 长任务：开始转种后关窗口，从托盘回来确认状态与日志连续。
7. 换台干净机器（别装过 .NET、也别装过 VC++ 运行库）装一遍：自包含包不依赖 .NET，
   但 Swift 运行时可能找 `VCRUNTIME140.dll`。脚本会把它随包带一份，验证这条有没有生效就靠这一步。
8. 分发前签名：`boxsend-core.dll` 和 `BoxSend.exe` 都要签，不然 SmartScreen 和杀软各拦一道。

## 体积

按「不让用户装 .NET」定的默认：自包含发布。实测数据如下。

| | 解包 | 压缩后 |
| --- | --- | --- |
| 自包含（默认） | 161 MB / 465 个文件 | 47 MB（`xz -9e`，安装包同量级） |
| 框架依赖（`-FrameworkDependent`） | 0.7 MB 界面 + 2.9 MB 核心 | 几 MB，但用户要先装 .NET 8 桌面运行时 |
| macOS 版 | `BoxSend.app` 7.4 MB | — |

涨的 150 MB 全是 .NET 运行时本体（WPF 不支持 `PublishTrimmed`，裁剪省不动；里面还连带了用不上的
WinForms 约 22 MB，真要抠体积可以在发布后按依赖树删，属于可优化的零头）。
核心库 release 编译 2.9 MB，Swift 工具链那批运行时 DLL 还没在 Windows 上量过，量级十几 MB。

## 这一轮（海胆一页并列多个版本：解析和归属都要裁到本条种子）

现象：源站黑礁 S01 Remux 转海胆，界面写「转种成功」＋「站内同名种子不是本次发布的（发布者或发布时间
对不上）已有种子：details.php?id=985」，推给下载器的也是 985。985 是《爱宠大机密2》，跟本次毫无关系。

根因是海胆的详情页布局：同一部影片的每个版本并列在一页里，每个 `<div class="torrent-wrap">` 一块，
各自有自己的 `download.php?id=N`、标题、发布时间。实测这张页里本次发的 80033（2026-10-16 15:09）排在
2020 年那条 BDrip（1036）后面，整页去读标题和「发布于」都读到 1036：发布时间比刚那次上传早六年，
`pageOwnership` 就判成别人的了。而「发布成功」响应页刮来的那条链接更是另一部片子（985），
链接本身就该丢。海胆检索结果行只写 `details.php?group_id=`，种子 id 只出现在 `download.php?id=`、
`edit.php?id=` 上，这也是之前回站内重查找不回链接的原因。

改法：

- `HaidanAdapter.torrentBlock(forID:in:)` 按 `torrent-wrap` 切块，返回含本 id 的那一段；
  覆写 `NexusPHPAdapter.scopedPage(_:torrentID:)`（默认整页），详情解析、归属判定、重跑归属三处都先裁。
- 上传成功响应页给的那条链接，先回查页面认名字：`conflictingVersion` 判出是另一个发布就丢掉链接
  （`detailURL: nil`），交给流水线按名回站内重查，别把不相干的种子推给下载器。
- 新增 fixture `detail-haidan-two-versions.html` 与 `HaidanVersionTests`（8 条）：分块、两条各自解析、
  找不到 id 时退回整页、刚发一分钟的归属（本块认 ours、整页会误判 theirs）、重跑归属、版本比对。

实测复跑：`转种成功（此前已转种）`，链接解析回 `details.php?id=80033`，推送提示
「已存在于下载器，本站 tracker 已在种子中，跨种已生效」，误标的「站内已有该种子」自动清掉。
测试 445 个全绿。


## 2026-10-16 晚：自动批量辅种（M0–M2，两端同批落地）

辅种与转种是两件事：转种发新种，辅种只是把站内已有的那条挂到本账号下做种。判定、
节流、校验复核全在核心库里（`Assist/`），两端只是发起与显示，见 `ASSIST-PLAN.md` 第十节。

Windows 侧新增：

- 桥方法 `assist.scan`（扫描下载器 + 生成本轮计划，只读）、`assist.start`（后台跑，
  照 `run.start` 的写法）、`assist.status`；进展随 `snapshot` 的 `assist` 段一起回来，
  不另开一条轮询——`AppModel` 里那个 DispatcherTimer 本来就在轮快照。
- `Event` 多带一个 `key`（`站点|种子 hash`）。辅种是「一条种子 × 一个站」的矩阵，
  只给 siteID 定不了行；`AssistView` 拿 `assist.scan` 的计划建行，之后只按 key 覆盖状态文本，
  整表不重建，滚动位置不动（这条正是「全量重建列表会把正在输入的框打掉」那条老坑的翻版）。
- 新页签「辅种」（`Views/AssistView.xaml` + `TabIcons.Assist`）：左栏参与站点勾选与检索节奏，
  右栏候选种子、本轮计划与逐行进展。站点勾选列表带一份签名，只有站点集合真变了才重建复选框。
- 数值设置从配置里按 double 读：核心把 `perSiteIntervalSec` 存成 8.0，用 `GetValue<int>()`
  读会抛「node holds a double」，所以 `AssistView.Num(...)` 先试 double 再退 int/long。

mac 侧对应的是 `Views.swift` 里的 `AssistView`（TabView tag 6）与 `AppModel` 的辅种区块，
mac 不走桥，直接注入 `AssistPipeline`。CLI 加 `box-send assist scan|plan|run`。

测试 472 个全绿。

## 2026-10-17：多下载器（发种一台、辅种一台）+ 增量扫描

配置层：`DownloaderConfig` 加 `id`（主下载器固定 `main`）与 `name`；`AppConfig` 加
`downloaders` / `reseedDownloaderID` / `assistDownloaderID`。老配置只有一个 `downloader`
对象，解码出来照样是一台、两个用途都指它。逐站限速跟着**发种那台**存，辅种推送按辅种
那台自己那份表算。

Windows 侧：

- 快照多带 `downloaders`（每台一行，含 `isMain`）与 `downloaderRoles`，`AppModel.Downloaders`
  直接喂给「正在编辑」「批量发种推送用」「辅种扫描用」三个下拉（`DisplayMemberPath=Label`、
  `SelectedValuePath=Id`）。`DownloaderView.Load()` 改成整页按快照重填，表单不再读
  `Config["downloader"]`，保存走 `downloaders.save`（按 id upsert），删掉老的
  `PatchSection("downloader")` 那条路——两条路并存的话，编辑附加那台会把主下载器覆盖掉。
- `downloader.test` 带可选 `id`：测的是正在编辑的那台，结果文本里回机器名。
- 两个用途下拉的 `SelectionChanged` 与 `DlPick` 的一起受 `_loading` 挡：填表时改选中项
  会回调回来，形成「填表 → 存盘 → 刷新 → 再填表」。
- 辅种页候选区脚注改用核心库给的 `summary.deltaText`（首次扫描 / 与上次一致 / 比上次多几条），
  并写明辅种用的是哪台。

测试 479 个全绿。

### 2026-10-17 晚：辅种的人工采纳与定时自动跑

- 计划表里「待人工确认」那行多一个「采纳」按钮（mac 在行尾，Windows 在行的右侧，
  靠 `PlanItem.NeedConfirm` 的 DataTrigger 控制显示，样式 `BasedOn` 全局按钮样式，
  免得失了主题色）。点了走 `assist.confirm`，只重跑那一条，别的行进展不清空。
- 左栏「检索节奏」多一格「定时自动跑（分，0=关）」，保存走原地的 `assist` 段补丁；
  下面一行提示「约 N 分钟后自动跑下一轮」，N 从快照的 `assist.autoRun.nextInMinutes` 读。
- Windows 不自建一套判定：`AppModel` 里每分钟调一次 `assist.tick`，该不该跑由核心库说，
  与 mac 的 `AssistAutoRun` 同一个类型。`AssistStartAsync` 多一个可选 `forceKeys` 参数。
- 测试 485 个全绿（新增 6 个：人工采纳 3 个 + 定时钟与配置默认值 3 个）。

## 这一轮（体裁判定、静态值表兜底、馒头编码表）

- 体裁（电影 / 剧集 / 动漫…）的取数顺序改为 **站点自己的分类行 > 豆瓣「◎类　　别」行 >
  发布名惯例 > 外链判据（TMDB 的 /movie 与 /tv、IMDb、豆瓣）**。
  LuckPT 这类 PTGen 主题把分类写在详情页「基本信息」一行里（`<b>类型:</b>&nbsp;电影`），
  以前只读豆瓣那行影评分类（剧情 / 爱情），认不出就整批落「其他」——
  天空的 Misc/其他、彩虹岛的 Demo、套的 Game Ebook 都是这么来的。
  站点分类行只认内容体裁词（电影 / 剧集 / 动漫 / 综艺 / 纪录片 / 体育 / 音乐），
  站点自己的「其他 / Misc」不算体裁证据；豆瓣那行仍留在 `ReleaseInfo.genre`
  （题材标签从它取），站点分类行放进新增的 `ReleaseInfo.siteCategory`
- 连载痕迹补 `EP03`、`第3期`、`全24话` 这类写法；带 IMDb 或豆瓣链接、又没有连载痕迹的
  按电影处理。`ReleaseKind.infer` 多了 `siteCategory / imdb / douban / tmdb` 四个入参，
  NexusPHP、Gazelle、Blu、海胆、馒头适配器都传链接（Windows 走同一个核心，无需改前端）
- 静态质量值表没命中不再直接留空：`applyQualitySelects` 在值表缺 token 时改走动态选项匹配
  （彩虹岛的音频值表没有 eac3 → 按回退链选 7=AC3，而不是停在「请选择」）
- Atmos 音频（TrueHD Atmos / E-AC3 Atmos）以前因为 token 找不到回退链而整栏留空，
  现在先找本站的 Atmos 选项、没有再退回同名编码；4K/8K 非碟片媒介也补了降档链
- 馒头（Unit3D）发种补上 媒介 / 分辨率 / 视频编码 / 音频编码 / 来源：
  走站方字典 `POST /api/torrent/{medium,standard,videoCodec,audioCodec,source}List`，
  选项表交给 QualityMatcher 匹配，字典拉不到时用核对过的兜底 id；
  分类按介质与分辨率分档（439 Remux / 421 BluRay / 420 DVDiSo / 401 SD / 419 HD，
  影剧对应 438 / 435 / 403 / 402，动画分 405 与 453）。
  碟片形态看发布名而不是 medium token —— x264 压制的蓝盘 token 是「压制」，
  站方自己仍把它放进 BluRay 档。字典缓存常驻进程（`Unit3DAdapter.resetOptionCache()` 可清）
- 分类选项打分补「形态分」：站点把同一体裁再按分辨率/来源切档（HDArea 把电影分成
  Movie UHD-4K / Movies Blu-ray / Movies REMUX / Movies 1080p / Movies WEB-DL…，
  还把 4K 排第一个）时，1080p WEB-DL 曾被抢进 4K 档。`categoryShapeWords` 现在按发布的
  实际分辨率与介质给 prefer 词（1080 / 720 / 4k / remux / bluray / web / dvd…），
  不同档给 avoid 词（非 4K 发布减「4k / uhd / 2160 / 8k」，非 3D 发布减「3d」）；
  `bestCategoryOption` 改成按命中的 prefer 词条数阶梯加分，选项文案与关键词、prefer、
  avoid 一律过 `QualityMatcher.normalize`（站方 "Blu-ray" / "BluRay" / "WEB-DL" 写法不一）
- 测试 495 个全绿（新增 10 个：站点分类行优先、分类值表兜底、体裁词表、外链判据、
  Atmos 音频、馒头编码表两条、馒头分类分档、HDArea 分辨率分档）

## 这一轮（Remux 片源写法全站点生效、编码与分辨率选项的取舍）

- 主标题「Blu-ray + Remux 必须写 BluRay」从春天逐站配置升级为全站点默认规则
  （青蛙同样拒收：「标题片源拼写错误：Remux 资源，片源必须拼写为 BluRay」）。
  规则搬到新的 `Sites/ReleaseTitle.swift`（`defaultRemuxTokens`、`hasRemuxToken`、
  `rewrite(_:extraTokens:)`、`rewrite(_:tokens:)`），NexusPHP / 馒头 / Discuz / PeerGo /
  TNode / Blu / Gazelle（TTG 的 filename）/ YemaPT 的发种标题都过它一遍；
  站点 `overrides.remuxTitleTokens` 变成「在默认表之上追加」，cmct 那份配置删掉了。
  只在标题含独立 Remux 段时改，整词匹配，长 token 先替换（Windows 用同一核心，无需改前端）
- 编码下拉：站表里同时有压制器名和格式名时选格式项（冬樱 8=x264 与 6=H264/AVC 并存，
  原先按顺序选中 x264）。`QualityMatcher.match` 给纯压制器名（"x264" 且不含 h264/avc）
  在格式项存在时减 9 分；「AVC/H.264/x264」这类合并写法本来就是格式项，不受影响
- 分辨率下拉：`1080p` 规则只认带 p 的写法，裸 "1080" 交给回退链里的 1080i 规则兜，
  否则冬樱的 "1080i" 会因为排在 "2K/1080p" 前面而抢走（站点只写裸数字时仍能兜住）
- 题材标签拆出「情色」：`romance` 的关键词表里原本带着「情色」，而唐PT 的标签列表只有
  「情色」(27) 没有「爱情」，爱情片（豆瓣类别「剧情 / 爱情」）就被动态匹配勾成了情色。
  现在 `romance = ["爱情","romance"]`，新增规范标签 `erotic = ["情色","伦理","三级","erotic"]`，
  只有源站类别行真写了情色/伦理才勾（`genreTags` 从类别行取，不从简介正文取）
- 测试 505 个全绿（新增 10 个：冬樱真实上传页四条下拉、编码格式项优先三例、
  分辨率逐行/隔行三例、默认改写规则四条、无逐站配置的 NexusPHP 与馒头标题各一条、
  唐PT 真实上传页情色标签三例）

## 这一轮（套的主标题写法：点号要写 "{@}"）

- 套（TTG）把「.」当标题分隔符：我们 POST 的标题是 "…DTS-HD MA 5.1-LuckAni"，站点存成
  "MA 5 1-LuckAni"；站内别人发的同类标题存成 "MA 5{@}1"（详情页 <title> 里就是这个转义）。
  新增 `SiteOverride.titleDotAs`，ttg 默认 `"{@}"`，`resolvedTitle` 在 Remux 改写之后整串替换，
  标题里的点按站方保留写法发出去（Windows 走同一核心，无需改前端）
- 副标题按站方排版重拼：套的副标题框写明「此处不再需要加 [ 和 ]」，另有 `highlight`
  「加粗突出」框（占位文案就是 "*内封简繁字幕"）。`splitSubtitleNote` 把源站副标题里
  括号包着的说明（"[内封中字]"、"【全12集】"）拆出去送 highlight（缺 * 才补），
  副标题只留片名；字段带 `maxlength` 时按站方口径裁（套的副标题 55 字）
- 重复复核不受影响：站内已存在种子存的是 "MA 5{@}1"，我们发的是 "5.1"，
  `normalizeSearchName` 只留字母数字（`{@}`、`.` 都剔掉），两边归一化后同串，能认出同一条
- 测试 510 个全绿（新增 5 个：套真实上传页的标题转义 + 副标题拆分 + highlight、
  无 titleDotAs 的站点标题照旧写 5.1、拆分函数四种写法、按 maxlength 裁断、"{@}" 复核重复）
- 踩坑记一笔：`replacingOccurrences(of:options:.regularExpression)` 对非法正则是**静默失败**
  （原串原样返回），`#"...["']…#` 少了个引号会让整段拼进一个原始字符串——两条都靠测试兜住了

## 这一轮（海胆「已存在」推错种子：链接要按发布名认）

- 现场：LuckPT 46566 转海胆，报「种子已存在」并把 `details.php?id=28902` 推给了下载器，
  可 28902 是同片 2020 年的 VCB BDRip。海胆把同片每个版本并列在同一页里
  （`torrent-wrap` 一块一块），排在最前的常是别人那条旧版本
- 三处一起补：
  1. `duplicateOutcome` 不再盲取页面上第一条 `download.php?id=`——并列多个 id 时只认
     发布名对得上的那条（`duplicatePageTorrentID` + `torrentTitles`），认不出就不给链接，
     交给流水线回站内按名重查（海胆真正的「该种子已存在！」页根本没有链接）
  2. `verifiedDuplicate` 判成版本冲突时，先在**同一页**按发布名找回本次这条（海胆每个版本
     一块，块里写着自己的标题）；只要判成「已存在」就一律存响应页，别再靠猜
  3. 检索结果行不写发布名也不放详情链接的站（海胆是 `details.php?group_id=…&torrent_id=…`）：
     按行内的 `download.php?id=` 逐条打开复核（≤3 条，站点负载可控），名称严格互含的那条
     优先于词元放宽命中的那条——站内旧标题多一个 2Audios 备注时会选错
- `conflictingVersion` 补「盘 vs 压制」这一档（`discForm`）：`medium()` 里 BDRip 仍按碟片系
  算（各站发种选项就这么归），光看它认不出「1080p Blu-ray AVC」与「BDRip 1080」是两个版本
- 测试 516 个全绿（新增 6 个：海胆真实多版本详情页 / 真实两版本检索页）

## 这一轮（观众的自定义下拉：读不到选项就选不到「Blu-ray DIY」）

- LuckPT 46569 转观众，媒介选成「Blu-ray 原盘」，应为「Blu-ray DIY」。原因不在打分：
  `applyQualitySelects` 早留了「值表写死 Blu-ray、本站另有 DIY 项且本次是 DIY 就改选 DIY」这条
  退路，但观众的选项不写在 `<select>` 里，而是隐藏 `input[name=medium_sel]` + 紧随的
  `<ul class="ui-dropdown-list">` 里 `<a data-value="14">Blu-ray DIY</a>`——`selectGroups`
  读不到选项，那条退路根本没机会跑，值表的 `bluray: 1` 就直接发出去了
- `HTMLUtil.selectGroups` 增读这类自定义下拉（`dropdownGroups`：按 input 名找紧随的 `<ul>`，
  取 `data-value` + 文案），两端共用一份，前端不用动
- 全站点回归：改动前后跑同一源站 76 站的字段审计，只有 `audiences.medium_sel` 从 1 变 14
- 测试 519 个全绿（新增 3 个：下拉选项可读、内封中字蓝光选 DIY、无中字证据仍选原盘）

## 这一轮（刚发完就推送：站内没就绪要重试，馒头整名查不到要补查询词）

- 现象一（hdtime，LuckPT 46569）：发种成功，2 秒后推送报「未找到 .torrent 下载链接」，隔几十分钟
  再推就正常；同日另一条（231430）也是当时失败、半小时后成功。站方是先把详情页建好、再把下载入口
  放出来，所以这是暂时情况。`ReseedPipeline.pushTargetSite` 改成有限重试（`pushRetryWaits = [15, 60]`，
  合计封顶 75 秒），只重试 `transientPushIssue` 认的那几类文案（缺下载入口、审核中、下载频繁），
  会话失效/种子不存在不重试；放弃时把原因写成「站内可能仍在审核，稍后重跑本条即可补推送」，
  并且不标记 `pushed`，下次重跑会自己补上。本次没新发种（站内已有）的推送不重试——那条种子早就就绪了。
- hdtime 的「下载过于频繁，请等待 1 秒后再下载。」是整页没有标签的纯文本，`downloadNotice` 原来
  `guard html.contains("<")` 会把它丢掉；现在按关键词取所在的一句，并把它拼进「未找到 .torrent 下载链接」
  的报错里，用户一眼能看出是站内还没放行而不是我们解析坏了。
- 现象二（馒头）：站内已有 2Audios 那条，但整名检索返 `total:0`，于是报「站内已有这条种子，但两次都没
  定位到它的详情页」。`Unit3DAdapter.searchExists` 现在先整名、再补一条 `NexusPHPAdapter.wordQuery`
  的去标点词元查询，命中后仍用 `searchNamesMatch(tokenTolerant:)` 按发布名复核。
- 两端同源：重试、错误文案、检索都在核心里，WPF 侧不用改；`dotnet build` 只是回归确认（0 错误）。
- 验证：`swift test` 525 绿（新增 `DeferredPushRetryTests` 6 条 + 馒头词元回退 1 条）；
  实测 `box-send info --site hdtime --detail .../id=231456` 已能解析出 `download.php?id=231456`。

## 这一轮（测速改成手动按钮：不再拦「开始运行」）

- 「转种前先测上传速度」勾选框 + 「开始运行」前弹窗放行，改成「开始运行」左边的「测试上传速度」按钮：
  点一下测一次，结果显示在按钮下面那一行；测不测都能直接开转，也不再弹「继续转种 / 先不转种」。
- mac：`AppModel.run()` 去掉 `skipSpeedCheck` 分支与 `speedGate`（`SpeedGate` 结构体一并删），
  RunView 的测速按钮复用既有的 `testSSH()` / `sshTestResult`——和「下载器」页那张卡片同一条文案、
  同一个 `testingSSH` 忙碌位，省掉第二套异步代码；结果行与运行进度行共用一行位置。
- Windows：`RunView.xaml` 的 `SpeedPrecheck` 换成 `BtnSpeed` + 下一行的 `SpeedResult`，
  code-behind 用 `_model.TestSSHAsync()`（核心 `ssh.test`）填那一句，配色走 `Success` / `Warning` 资源；
  `OnRun` 去掉 `SpeedGateAsync()`，同步改回非 async，避免 CS1998。
- 配置里的 `ssh.enabled` 不再被这一页读写，字段留着只为兼容旧配置（`precheckActive` 同义保留给用例）。
- 两端同源：测速本来就在核心 `SSHSpeedTest`，这轮只动两端界面与提示文案（卡片副标题、教程、说明段）。

## 这一轮（界面重新归位：日志进运行记录、辅种进站点页、下载器全部摊开）

- 日志不再单开一页。mac 删掉 `LogsView` 与那个 tab，`RunView` 的运行记录里补「最近一次运行」「运行日志」
  两块（新增 `labeledBlock`），「清空日志」留在按钮行；Windows 同步删 `LogsView.xaml(.cs)`，`HistoryBox`
  改成 StackPanel，`LogLines` 直接绑 `_model.Logs`，清空走 `logs.clear`。标签页顺序两端一致：
  批量转种、辅种、站点分组、Cookie、下载器、设置。
- 辅种站点挪到「站点分组」页：上半是转种分组，底下新增辅种区块，辅种站点不分组。规则收在核心
  （`ConfigEdits.swift`）：`addAssistSites` 只纳管不写进任何分组并记入 `assist.siteIDs`，
  `assistManagedSites` 给辅种区块，`unassignedManagedSites` 把辅种站点从未分组区块剔掉，
  一张卡片只出现一次；`removeAssistSite` 退出辅种，站点不在任何分组时一并移出站点池。
  已在转种分组里的站点两处各画一次（分组管发种与限速，辅种区块只管退出辅种）。
  桥接新增 `assist.addSites` / `assist.removeSite`，站点行多带一个 `assist` 布尔，两端据此画卡片；
  批量添加站点弹窗加 `assist` 形态（隐藏分组选择、标题写清是辅种站点）。
- 辅种页去掉「参与站点」多选：mac 换成表头一行「辅种站点：N 个」，Windows 换成只读卡片，名单统一去
  站点页改。检索节奏去掉步进器——mac 新增 `NumField`（只收数字、回车或失焦提交、占位显示推荐值），
  Windows 沿用 TextBox 但把推荐值写进标签；`AssistConfig` 默认值就是推荐值（间隔 8 秒、抖动 3 秒、
  单轮预算 200 次、查无保留 7 天），老配置不改也照样显示。
- 下载器摊平成「一台一张卡片」，不再有「正在编辑哪一台」。mac `AppModel` 的编辑态从
  `editingDownloaderID` 改为按 id 取用：`downloader(id)` / `canRemoveDownloader(id)` /
  `updateDownloader(id:_:)` / `removeDownloader(id)` / `testDownloader(id)`，测试结果显示在
  `downloaderTestResults[id]`；Windows 去掉「正在编辑」下拉与整块 `ConnCard`，`DlCards` 按
  `_model.Downloaders` 逐台建卡片，每台自带保存 / 测试连接 / 删除这台。用途指派（发种用、辅种用）留在顶部。
- 验证：`swift test` 527 绿（新增辅种区块桥接回归 1 条：入池不进组、不进未分组、退出辅种清名单）；
  `dotnet build` 0 错误。

## 这一轮（藏宝阁把动画拆成两栏：剧场版归「动画」、整季归「动漫」）

- 藏宝阁（cangbao.ge）类型下拉里 404「动画」与 405「动漫」并存。抓上传页与两栏列表实测分工：
  404 是单片与剧场版（阿基德第三章、银魂完结篇、玩具总动员），405 是整季番剧（Black Lagoon S02、
  魔禁 S03、Jade Dynasty S04）。通用关键词把「动漫」排在「动画」前面，LuckPT 46641 转种时三部剧场版
  全被 405 收走。新增 `NexusPHPAdapter.kindKeywordsFor(_:shape:)`：按发布形态换首选——单片先找
  「动画」、整季仍先找「动漫」；只写「动漫」或只写「动画」的站两条关键词都只命中同一项，不受影响。
- 站点页那块标题改成「添加转种分组和站点」（Windows 侧原来没有这行，一并补上），辅种区块在下方独立成块。
- 辅种弹窗候选改了口径：不看转种分组（已纳管、已在分组里的站都能拉来辅种），只排掉已经在
  `assist.siteIDs` 里的站——加过的立刻从弹窗消失。名单与排序收在核心（`assistCandidateIDs` /
  `assistDisplayOrder`，与转种那份共用 `dialogDisplayOrder`），桥接 `sites.candidates` 多收一个
  `assist` 参数；两份弹窗共用同一份手动排序（那份数组里出现已纳管的站是有意为之，读的时候各自按
  自己的候选集过滤）。
- 验证：`swift test` 531 绿（新增 `CangbaoCategoryTests` 3 条：剧场版进 404、整季进 405、其余体裁不变；
  辅种候选 1 条：不受分组影响、加过即消失）；`dotnet build` 0 错误。

## 这一轮（辅种扫描 0 条：Transmission 的 RPC 响应读错了一层）

- 现象：辅种站点与辅种下载器（Transmission，12470 条已下完种子）都配好了，点「扫描下载器」显示 0 条。
  原因是 `Transmission.rpc` 把整包响应直接给上层，上层又把 `arguments` 当种子数组读——
  TR 回的是 `{"arguments":{"torrents":[…]},"result":"success"}`，于是 `(arguments as? [[String:Any]])`
  必然失败，`?? []` 之后就是 0 条。同一处错读还让 `torrent-add` 取不到 id、`testConnection` 永远报
  「未知版本，登录成功」，连不上/超时也被吞成空清单。现在 `rpc` 只交 `arguments` 那一层，
  解包抽成 `Transmission.arguments(of:method:status:)`（连不上与 result 非 success 都明确报错）。
- Transmission 另外两处补齐：`torrentProgress` 之前用协议默认实现（每次拉整份 7 MB 清单轮询），
  现在单条查询，并顺手把「暂停着加进来、TR 不会自己校验」这条补上——首次问到就 `torrent-start`，
  status 2/3（排队校验/正在校验）映射成流水线认的 `checking`，否则一条大种子会被判成
  「校验后只到 0%」直接删掉；`labels` 是数组，之前只把第一个当 category，其余标签丢了，
  「只辅这些分类」在 TR 上会一条都匹配不上。
- 一万条种子 × 115 站 = 143 万个组合（实测 `assist plan` 就是这个数），整份塞进界面会把界面钉死：
  核心新增 `AssistPipeline.roundCandidates`（本轮按体积取前 200 条）与 `planPreview`（计数按全量、
  行只留前 400 条 + 各结论条数）。桥接 `assist.scan` 多回 `torrentTotal` / `planTotal` / `planCounts`，
  mac 与 Windows 都显示「下载器里 N 条符合，本轮按体积取前 M 条 / 全量 X 个组合，其中 Y 会去检索」。
  单轮真正发出去的站点请求照旧由 `roundBudget` 兜住。
- 验证：`swift test` 535 绿（新增 `TransmissionAssistTests` 4 条，用真机响应形状：整数 percentDone、
  50 GB size、labels、tracker host 提取、校验状态映射、连不上报错）；`dotnet build` 0 错误；
  真机 `box-send assist scan` 从 0 条变成 12470 条。

### 辅种页摊成「种子 × 站点」格子，Cookie / 下载器并进设置

- 选中态去掉蓝框：mac 三处卡片（批量转种目标卡、站点分组卡、批量添加弹窗卡）只留淡强调色底，
  Windows 同一处改 `AccentFaint` 底 + `Line` 边框。两端仍然一眼看出选了谁，但不再满屏描边。
- 归类挪进核心库（`Assist/AssistRowStatus.swift`）：`RowStatus`（已辅种 / 待辅种 / 失败 / 校验中 /
  待确认 / 不存在 / 已做种 / 不支持检索）＋ `status(of:live:)` ＋ `Tally` ＋ `tally(rows:live:)`。
  跑过的行以进展为准、没跑过的按计划，两端不再各写一套判断。
  `AssistOutcome` 多一个 `failed`：真做砸（读不到站点那条、推下载器失败、校验不满被删）与
  「跳过」「还没轮到」分开，失败数才统计得出来。
- `planPreview` 改成按**种子**裁（`planTorrentCap = 12`）而不是按行裁：界面一条种子要摊开它在全站的
  格子，只裁行会摊不满；`total` / `counts` 仍按全量算。`PlanRow` 自带 `rowKey`，mac 那份扩展删掉了。
  115 个辅种站 × 12 条种子 = 1380 格，mac 靠 `LazyVGrid` 懒画，Windows 那份 `ItemsControl`+`WrapPanel`
  不虚拟化，外层换成自带滚动、按块回收的 `ListBox`，否则切个页签都要等一下。
- 桥接 `assist.scan` 与快照 `assist` 段多回 `stats`（`{total, lines:[{status,label,count}]}`），
  逐行多回 `status` / `statusText`：C# 侧只画不判。新增 `AppModel.AssistStats` / `AssistStatLine`，
  配色键走 `ThemeManager` 新加的 `DangerText`。
- 辅种搜索节奏挪进「设置」（mac `SettingsView.paceCard`、WPF `SettingsView.xaml` 的 GroupBox），
  顶部去掉 Cookie / 下载器两个页签：`CookiesView` / `DownloaderView` 两个区块原样搬进设置页
  （mac 直接嵌进 `SettingsView`，WPF 用 `ContentControl` 宿主），输入框统一收窄一半。
- `AppService` 多一个 `assistPipelineFactory` 注入点：假下载器就能跑通 `assist.scan` 的整份载荷，
  不必连真下载器。
- 验证：`swift test` 544 绿（新增 `AssistRowStatusTests` 5 条 + `PlanPreviewCapTests` +
  快照 / `assist.scan` 载荷 2 条：3 条种子 × 2 站 = 6 格、每格 `status`/`statusText`、`stats.total` 与
  快照里的同一份计数）；`dotnet build` 0 错误。
  实站（`BOXSEND_LIVE=1`，本机真配置）跑 `assist.scan`：下载器里 12490 条符合 → 界面回 12 条种子、
  1380 格，计数按全量 23000 格（200 条候选 × 115 站），响应从「上百 MB」缩回一份能直接画的量。

## 这一轮（杜比换域名、种子页跳转、辅种整库分页）

四条改动都是「界面能点、核心算数」，接缝没动。

- 杜比域名 `www.hddolby.com` → `www.uhddolby.com`：只改内置表里那一条 + `effectiveSite` 里加一张
  `legacyHosts`（旧域名按站点 id 认回新地址）。老配置不用迁移，用户自己填的第三方镜像不被改写。
  cookie 按 host 存，旧域名那份自然作废，去新站重新同步一次即可。
- 「跳到站内种子页」：`ReseedPipeline.SiteStatus` 多一个 `url`，转种成功 / 站内已有 / 已推送 /
  推送已有种子 / 推送失败这几种事件都带上；桥接 `Event` 与 `eventJSON` 同步多回一个 `url` 字段。
  mac `TargetEvent` 是 `SiteStatus` 的别名，字段直接流到界面；WPF `RunRow.Url` 解析后在卡片上放一个
  「种子页」按钮（卡片本身点击是勾选目标站，跳转必须另给一个按钮）。
  顺带把上传前查重命中那句「站内已有该种子（别人先发或此前已发）」删了：卡片上已经写着
  「种子已存在，跳过」，详情里留站内那条的标题与链接就够。
- 辅种整库分页：下载器里同一份片子常有好几份（各站 tracker 不同 → hash 不同、名字与体积一样），
  原先「按体积列前 12 条」看着就是一屏重复。核心加 `dedupe`/`catalog`（先按 hash，再按归一化名字
  + 体积 1 MiB 容差），目录整份留着、界面翻页。
  计数不再摊全库那 144 万格（去重后也还有 38 万）：`planCatalog` 每个站只取一次三张表（已辅 / 站内没有 / 失败），
  「已在该站做种」用 tracker host → 站点这一层一遍种子就分完，之后全是集合运算。
  `AssistConfig.listPageSize` 是新的「单页列表条数」（旧配置文件按默认 10 解码）。
  `StateStore` 新增 `assistedHashes` / `assistMissHashes` / `assistFailHashes` 三个批量取表口，
  外加一张辅种失败表（失败不算「站内没有」，下轮照常重试，但界面要数得出失败几条）。
- 执行范围也跟着改成「本页」：`assist.start` 多收一个 `torrentHashes`，mac 的「辅种本页」与
  WPF 的「辅种本页」都只跑界面上这一页；定时那轮仍按体积取前 N 条整轮跑。
  `assist.page` 是新动作：目录与计数还在核心库里，翻一页不再重读一遍上万条种子。
- 验证：`swift test` 556 绿（新增 `AssistCatalogTests` 8 条：去重三条、分桶计数、失败记账与重试、
  进展改记；`DolbyDomainAndSeedLinkTests` 3 条：新域名、旧域名改写、镜像不改写、
  查重命中事件带 url 且不再带那句提示；`assist.page` 载荷与快照计数）；`dotnet build` 0 错误。
  实站（`BOXSEND_LIVE=1`，本机真配置）：下载器 12526 条符合 → 去重后 3319 条、381685 格，
  读下载器 10.2s、建计划 0.2s、翻页 0.14s；mac 界面显示「第 1 / 332 页（共 3319 条，每页 10 条）」，
  翻到第 2 页换的是另一批种子。

## 这一轮（旧域名落地成配置、卡片少一行字、辅种格子减半）

四条都是界面边角，跨边界契约没动。

- 杜比域名只在上一次「读取时改写」，配置文件里存的还是 `www.hddolby.com`，站点分组照旧显示老网址。
  这轮把改写挪进 `AppConfig.mergedWithRoster()`：按 `SiteRegistry.legacyHosts` 认旧域名，
  就地改 `site.url`，用户自填的第三方镜像不动；`load(path:)` 顺带把改写后的配置写回文件，
  两端（mac 直接读、Windows 走 `snapshot`）看到的都是新地址。
  cookie 仍按 host 存，旧域名那份作废，去新站重新同步一次。
- 站点卡片少一行：`.exists` 那条事件的详情（「站点回「种子已存在」，本次未新发种，响应页已存 …」）
  不再在卡片下面铺一行——卡片上那个「种子页」按钮带的就是同一条种子，全文还在胶囊的悬浮提示里。
  mac 的 `detailText` 与 WPF 的 `CardDetail` 同步删掉这一支，失败原因与警告照旧显示。
- 「种子页」按钮跟界面其余小按钮一套样式：mac 用 `.bordered` + `.controlSize(.small)` + `Color.accentColor`，
  WPF 用主色薄底（`Tinted("Accent", 0.18)`）+ Accent 描边与文字，落在卡片上不再是一块灰。
- 辅种格子收窄：mac 从固定 6 列改成 `GridItem(.adaptive(minimum: 96, maximum: 140))`，
  WPF 那条 `Width="152"` 改成 `MinWidth="96" MaxWidth="132"`；一行放得下的站名多了一倍，
  站名和结论都不截断（长说明仍在格子提示里）。
- 验证：`swift test` 558 绿（`DolbyDomainAndSeedLinkTests` 加两条：配置里的旧域名被改写、
  改写结果落盘；镜像地址不被改写那条照旧）；`dotnet build` 0 错误。

## 这一轮（卡片再收窄、辅种格子换成底色说话）

- 批量转种站点卡片再收窄一半：mac 从固定 6 列改成 `GridItem(.adaptive(minimum: 104, maximum: 150))`，
  WPF 站点卡片 `Width` 172 → 126。窄卡片里胶囊与说明行本来就会换行撑高，不受影响。
- 辅种格子去掉站名前面那个符号（mac 删掉 `Image(systemName:)`，WPF 本来就没画）：
  一格一格看下来符号是噪音，结论改由底色说。
- 格子底色 = 结论：mac 用 `cellWash` / `cellEdge` 在 `blockSurface` 上铺一层结论色（0.14~0.18）并把描边同色收边；
  WPF 在格子 `Border.Style` 里按 `Status` 上 DataTrigger（`#2E…` 这类半透明 ARGB，深浅主题都能压住底）。
  绿=已辅种、红=失败、蓝=校验中、橙=待确认、青=已在该站做种、灰=站内不存在（整格压到 80% 透明）；
  不支持检索铺更淡的灰并把整格压到 55%，待辅种保持素底——一眼就能挑出要动手的格子。
  两边都用同一套状态词（`assisted` / `failed` / `verifying` / `manual` / `seeding`），
  WPF 那份跟着 `Cell.Status` 的变更通知走，跑起来会当场换色。
- 验证：`swift test` 558 绿（这轮全是界面改动）；`dotnet build` 0 错误。

## 这一轮（辅种页第一批：覆盖率、待复核收尾、待处理队列、格子收牌）

- 状态表加两张表、改一张表：`assistReview`（推进了下载器却没等到校验结果）、
  `assistReject`（人工判定不是同一种子）、`assistFail` 的值从时间戳换成 `{time, why}`。
  旧 `state.json` 里那个纯数字仍能读出来（`AssistFailRec.init(from:)` 先试单值容器），原因留空。
  待复核记录里存的是 `siteHash`——站点重新打包过时它与本地 hash 不同，回查校验只能按它问下载器。
- 归类多两档：`RowStatus.review`（待复核，紫）与 `RowStatus.rejected`（已否决，灰）。
  `Status.Phase` 同步多一个 `review`，跨边界的阶段名就是 `"review"`，
  WPF 的 `AssistRow.PhaseText` / `Tone` 与 `AssistStatLine.Tone` 都跟着加了这一档（配色键 `Review`）。
  预筛顺序：已做种 > 已辅过 > 待复核 > 已否决 > 站内没有 > 上次失败。
- 覆盖率与队列都在核心里算，两端只画：`CatalogPlan.coverage(live:)` 出 `Coverage`，
  `Coverage.line` 那句「已判定 x / y（z%）；还要站内检索 n 次…不间断跑完约 3 天 4 小时」直接上界面；
  `AssistPipeline.queueItems(...)` 出待处理清单（待确认 > 待复核 > 失败 > 已否决，上限 200，
  下载器里已经没掉的条目不收）。千分位由 `AssistPipeline.grouped` 统一。
- 边界上新增两个动作：`assist.recheck`（可带 `keys` 只回查一条）、`assist.reject`（`key` + `rejected`）。
  两者都只改状态表 / 问下载器，不发站点请求，回来的载荷与 `assist.page` 同形，界面直接重画。
  `assist.scan` / `assist.page` 的返回和快照的 `assist` 段都多带 `coverage`、`queue` 两个键。
- mac：统计卡顶部加进度条与那句覆盖率；新增「待处理」卡，一行一条带采纳 / 重试 / 回查 / 否决 / 撤销；
  「种子与站点」里每条种子默认只摊开 `failed` / `manual` / `review` 三类格子，其余收成计数牌，
  点牌子展开那一类，另有「展开全部格子」开关（`folded` 记手动改过的那些类）。
- Windows：同一条边界契约下只画界面。`AssistView.xaml` 加 `BtnRecheck`、`Coverage` + `CoverageLine`、
  `QueueBox` / `Queue`（`BooleanToVisibilityConverter` 控按钮显隐）、格子多 `review` / `rejected` 两组 DataTrigger；
  `TorrentBlock` 拆出 `Cells`（全部）与 `VisibleCells`（画出来的）并带 `Chips`，`Rebuild()` 一次算完；
  `AssistQueueItem` 是队列 VM，动作走 `AssistRecheckAsync` / `AssistRejectAsync` / `AssistRetryAsync`。
- 验证：`swift test` 569 绿（新增 `AssistReviewQueueTests` 11 条：待复核落盘与重启仍在、
  回查两种收尾、否决挡住检索、覆盖率算式与那句文案、队列排序与上限、旧失败表读得动）；
  `dotnet build` 0 错误。

## 这一轮（转种卡片先占格 + 辅种逐站筛选）

- 批量转种卡片运行中会盖住下面那排：`LazyVGrid` 的行高只在排版那一刻按各卡片当时的高度算，
  胶囊、种子页按钮、说明行事后冒出来把卡片撑高，画得下去却已经把邻居顶歪。这轮不猜像素，改成先占格：
  mac 把可变的那三格各铺一个同字号的隐形影子（`chipSlot` / `seedSlot` / `detailSlot` 都是
  `ZStack` 里先放 `.opacity(0)` 的空壳再盖真的），说明行从 4 行收成 3 行并同样占位，
  卡片高度从此与有没有事件无关；`eventChip` 抽出 `chipView(_:tint:icon:tip:)` 好让影子复用同一段排版。
- Windows 同一个道理，只是用 WPF 的手法：`RunView.xaml.cs` 里 `ChipLinesHeight = 32`、`DetailLines = 3`，
  胶囊那格是个 `MinHeight` 的空 `Border`，说明行 `MinHeight = DetailLines * 14`；
  隐藏一律走 `Opacity` + `IsEnabled` 而不是 `Visibility="Collapsed"`——塌掉布局就又会被重新量一次，
  正是要避开的那个坑。
- 占位只在运行中铺（`reserve: model.running` / WPF 里 `_model.Running` 决定 `MinHeight` 与
  种子页按钮的 `Visibility`）：空卡片也占满会白给一大片高度，一屏少放一半站点；
  开跑那一刻整排一起变高，还是一次排版，稳。mac 的逐站筛选列表套了 `ScrollView`（`maxHeight: 280`），
  与 WPF 那个 `MaxHeight="260"` 一回事——115 个辅种站铺平会把设置页顶没，Cookie 与下载器就看不见了。
- 辅种多了逐站筛选：`AssistConfig.siteFilters: [String: SiteFilter]`，
  `SiteFilter { include, exclude, minSizeGB, maxSizeGB }` 配 `isEmpty` 与 `reject(_:sizeGB:)`（返回中文原因），
  `assistFilter(_:)` 把「只填了空格」当成没设规则。走已有的 `config.patch`，键 `assist.siteFilters[id]`，
  清空就是删键，两端都不必加新动作。
- 归类多一档 `RowStatus.filtered`（本站不辅，统计行「按本站筛选不辅」），并计入 `resolved`：
  这一格永远不会去敲门，不该再算在「待辅种」里让人误会还要等。`SiteBucket` 多
  `filtered` / `filteredReason`，`planCatalog` 在算完做种与已辅之后扣掉这一批、并从 missing/failed 里减掉，
  `preSkip` 在负缓存之前先判规则，原因后面缀一句「在「设置 → 辅种」的逐站筛选里改」。
  核心里判，两端只填表：实站那 381,685 格 / 还要检索 347,259 次这个分母，只有这条规则砍得动。
- mac：设置页「辅种节奏」下面加「辅种逐站筛选」卡，`AssistFilterRow` 一行一个站
  （只辅 / 不辅 / 上下限 GB，回车提交，逗号中英文都算），带「只显示设过规则的站」和一句汇总。
  Windows：`SettingsView.xaml` 加 `Expander`「辅种逐站筛选」，`BuildSiteFilters()` 先比指纹再决定是否重建，
  免得轮询把正在敲的框刷没；`FilterRow` 用 `LostFocus`/回车提交，`CommitFilter` 写同一个键。
- WPF 的计数牌排序 `Order` 补上 `"filtered"`，底色走默认那档灰，站名与结论仍走核心给的文案。
- 验证：`swift test` 572 绿（新增 `AssistSiteFilterTests` 3 条：判定本身、计划里标成本站不辅并算已判定、
  跑起来一次检索都不发）；`BOXSEND_LIVE=1` 实站仍报 3,319 条 / 381,685 格，覆盖率行照旧；
  `dotnet build` 0 错误。界面截图这轮还是被「Mac is locked」挡住，靠实站测试与构建验。

## 这一轮（卡片只在该长时长 + 辅种第三批：暂停单站、逐站进度、停止本轮）

- 上一轮的「运行中就整排占位」太糙：整组卡片一起变高，白给一大片空白。改成各自按内容长，
  排版交给自写的 `SiteFlow: Layout`（mac）：每次排版都按当排最高的那张卡重新量行高，
  卡片中途长高会把整排连同分组外框一起顶开，而不是画到下面那排上面；没信息的卡片保持光板两行。
  `LazyVGrid` 不行是因为它只在排版那一刻量一次行高，不是「不能变高」。
  Windows 侧本来就是 `WrapPanel`（每次内容变化都重排当排），所以只是把空胶囊、种子页按钮、
  说明行改回 `Visibility="Collapsed"`，不再用 `MinHeight` 占位。
- 暂停单站：`AssistConfig.pausedSites: [String]` + `isPaused(_:)`。与逐站筛选是两回事——
  筛选是「这站本来就不辅这类」，暂停是「这一轮先别动这站」，所以暂停的格子算欠着（不进 `resolved`），
  但不计入还要检索的次数（这一轮根本不会去敲门）。归类多一档 `RowStatus.paused`（本站已暂停），
  覆盖率那句多一段「暂停站里压着 N 格」，`coverage.siteCount` 也不再把它算作在跑的站。
  `run()` 在站点那一层就跳过（只发一条「跳过：本站已暂停」，不逐格发事件）。
  两端写回的都是 `assist.pausedSites`：mac 用 `assistUpdate`，WPF 用 `PatchSection("assist", …)`。
- 逐站进度：`CatalogPlan.SiteProgress` + `siteProgress(live:)`。一站一行——铺了多少格、
  已判定多少、还要检索几次、失败/待复核几条、是不是暂停/不支持检索；实时进展按 `live` 挪格子，
  所以跑起来那一条百分比会当场走。边界上 `assist.page` / `assist.scan` / 快照的 `assist` 段
  多带 `siteProgress` 数组，`coverage` 多一个 `paused`。mac 直接调核心库那份，WPF 只画 JSON。
- 停止本轮：核心里 `requestStop()` / `stopRequested`，`run()` 在处理下一格之前看一次；
  `Report.stopped` 一路带到两端的运行文案（「（已手动停止本轮）」）。
  mac 记下正在跑的流水线实例（`assistRunner`）；Windows 走边界动作 `assist.stop`，
  核心库那边同样记 `assistRunner`，两端一个语义：只停这一轮，状态表原样留着。
  标志用 `StopFlag`（`NSLock` 包一个 Bool）——界面线程写、跑轮的线程读，裸 Bool 是数据竞争。
- mac：辅种页「待处理」与「种子与站点」之间插「按站点」卡（一行一站 + 暂停开关，
  列表自己滚 `maxHeight: 280`，可只看还有活的站），运行中顶部多一颗「停止本轮」；
  Windows：同一张卡是 `GroupBox` + `ScrollViewer MaxHeight="240"`，`AssistSiteRow` 是它的 VM，
  `BtnStop` 只在 `BusyAssist` 时露面，格子 `paused` 走一组淡灰 DataTrigger，
  计数牌 `Order` 补 `"paused"`。
- 验证：`swift test` 576 绿（新增 `AssistPauseProgressTests` 4 条：暂停站的格子欠着但不计检索、
  暂停站一次请求不发、逐站进度三站各算各的且实时进展推动百分比、停止本轮只跑完手头那一格）；
  `BOXSEND_LIVE=1` 实站照旧出覆盖率那句；`dotnet build` 0 错误。

## 这一轮（上传文件名洗成 ASCII + 辅种第四批：报错不算「站内没有」、宽松重试、中途追加预算）

- 大部分目标站报「转种失败 无效的文件名！」：源站把中文片名写进了 .torrent 文件名
  （实测 LuckPT 47762「[LuckPT].南家三姐妹 再来一碗.Minami-ke: Okawari.2008.S02.1080p.…」，
  debug 里 audiences/cmct/hdhome/chdbits/hdsky 的 upload-*.html 全写着「无效的文件名！」）。
  NexusPHP 家族那条校验只认 ASCII，最窄的一种形如 `^[\w.-]+\.torrent$`，
  所以 `ReseedPipeline.uploadFilename(_:title:)` 直接收到最窄那一档：中文、空格、方括号、
  冒号等一律收成一个点，首尾分隔去掉，超过 120 字在分隔处截断；洗完全空就改用发给目标站的
  主标题，主标题也不能用才兜底 `release.torrent`。改完的名字会往状态里记一句
  「torrent 文件名改为上传用：A → B」，原本那份照旧推给下载器（下载器认中文名，站点不认）。
  **这层在共用的核心里，两端一起好**：Windows 一行都不用改，走的是同一个 `upload(filename:)`。
- 站内检索「报错」与「站内没有」分家（`attempt`）：cookie 失效、站点 500 这类以前也走
  `markAssistMiss`，等于把整站的格子钉在负缓存里 7 天不再问；现在只 `markAssistFail`，
  结论写「站内检索失败：…」（`failed`），下一轮照问。新增 `AssistSearchErrorRetryTests` 验这条。
- 宽松重试：严格那档没命中时换宽松查询词再问一次（`SiteAdapter.searchExists(_:relaxed:)`，
  NexusPHP 那边本来就有多组候选词与容忍分词的匹配，辅种此前只用严格那档）。
  开关是 `AssistConfig.relaxedRetrySearch`（默认开），两端都放在「设置 → 辅种」：
  mac 是 `Toggle`，WPF 是 `CheckBox RelaxedRetry`，读写同一个 `assist.relaxedRetrySearch`。
  只在「干净没命中」后才追加，已经点了停止本轮就不追这次；命中的那一格会在结论里带
  「换宽松查询词才找到」，整轮跑完的文案多一句「其中 N 条换宽松查询词才找到」。
  代价：一条站外确实没有的种子从 1 次请求变成 2 次，所以旧的两条只数请求次数的测试
  改用关掉宽松重试的 `quietCfg`。
- 中途追加预算：`SiteThrottle.budget` / `addBudget(_:)`（上限只增不减，负数忽略）。
  边界多两个动作：`assist.stop`（上一轮就有）与 `assist.budget`，`assist` 段多带
  `budget: {used, total}`；mac 那棵「追加 200 次」直接问手里的流水线实例，
  WPF 走 `AssistAddBudgetAsync()` 再等下一次快照。两端语义一致：只抬这一轮的次数上限，
  逐站间隔与抖动照旧。
- 验证：`swift test` 588 绿（新增 `UploadFilenameTests` 7 条——真名、中文名回退主标题、
  兜底名、干净名不动、标点收点、长名截断、`asciiSafeName` 字面；
  `AssistSearchErrorRetryTests` 5 条——报错不进负缓存且下轮再问、干净没命中问两次再进负缓存、
  宽松档捞回重新打包的那条、开关关掉只问一次、`addBudget` 抬上限）；
  `dotnet build` 0 错误。

## 这一轮（馒头「種子檔案含有非法檔名」：包内文件名只检测、只报错，不代改）

- 同一颗种子（LuckPT 47762）传馒头被整单打回：
  `種子檔案含有非法檔名: 南家三姐妹 再来一碗.Minami-ke: Okawari.2008.S02E04.1080p.Blu-Ray.Remux.AVC.LPCM 2.0-LuckAni.mkv`。
  跟上轮的「无效的文件名」不是一回事：那次是 multipart 里那个 .torrent 文件名，这次是**种子内部**
  的文件名——馒头按 Windows 那套禁令校验包内文件，中文合法、`<>:"/\|?*` 与控制字符不合法，
  这条片名里「Minami-ke: Okawari」的冒号就是钉子。
- 先按「上传前改写包内文件名」做过一版（`SiteAdapter.prepareTorrentForUpload` 钩子 +
  只改上传那一份）。实测不行：包内文件名一改 info hash 就变，下载器手里那批文件对不上号，
  加进去显示丢文件、整份重下——跨种本来就是为了让下载器认出手里的文件，这样等于白跨。
  钩子与流水线那处调用一并撤了。**结论：站方规矩与本地文件冲突时报错让人决定，不要自作主张改名。**
  主标题（发给站台的 `name` 字段）要调无所谓，那只是个标题。
- 现在是 `Unit3DAdapter.illegalTorrentNames`：走值树看 `info.name` / `name.utf-8` 与每个
  `files[].path`（含 unpaired 那种一段两个串的写法），点名报出所有不合法的条目；
  `upload` 第一件事就是 `guardTorrentNames`，**一个请求都不发**就抛 `badInput`，
  消息里带站名、哪个名字（过长从中间省略）、卡在哪个字符、手动发种能改成什么、
  以及「不代改：改名会换 info hash，下载器认不出手里那批文件」。站点卡片上的转种失败就是这句。
- 为此新增两块地基留着用：`BValue`（通用 bencode 值树，解码按原始字节、编码走规范字典序，
  真种子往返 hash 不变）与 `SiteFileName`（站点文件名规则收在一处：`uploadName`/`asciiName`
  是上传文件名的 ASCII 白名单，`illegalChars`/`legalComponent` 是包内文件名的 Windows 合法性
  与「能改成什么」；两者宽严不同，别混用）。包内名字一律按**字节**判——老种子常是 GBK 命名，
  解码成 String 再编回去就换字节了。`ReseedPipeline.uploadFilename` 改为转调，
  馒头那份 `uploadFilename` 也从「只去斜杠」换成同一个 ASCII 白名单（中文名以前照原样发上去）。
- 顺带修一个既有解析 bug：`Bencode.fileList` 遇到 unpaired 种子（path 一段是 `[utf8, 原字节]`）
  只跳了内层列表的第一个元素，把内层的 `e` 当成 path 的结尾，整份清单被判解析失败——
  辅种靠这份清单逐文件比对，碰上这种种子会白落到「待复核」。现在整段跳过。
- **Windows 不需要改**：检测、报错、清洗都在共用的核心里，WPF 照旧显示那句转种失败原因。
- 验证：`swift test` 598 绿（`TorrentIllegalNameTests` 9 条——三份真种子值树往返 hash/清单/tracker
  都不变、真名点名到 `Minami-ke:` 那一处、合法种子（含三份真种子）一条都不点名、多文件根目录与
  每段 path 都点名、unpaired 两个串只点一次、GBK 名按字节也认得出、报错里带的非法字符与建议改名、
  馒头上传名洗成 ASCII；`Unit3DAdapterTests` 加一条：包内名不合法时零请求抛 `badInput`；
  另修 `Unit3DAdapterTests` 那条对上传文件名的旧期望）；`dotnet build` 0 错误。

## 这一轮（辅种页重排：5 块变 3 块，12 个计数收成 5 组）

- 上一版辅种页五张卡（辅种统计 / 按站点 / 待处理 / 种子与站点 + 顶部一排按钮）、四套进度数字、
  12 个平铺结论，没人能在两秒内看出「现在该干什么」。这轮按「数字只在一处、按钮只在一处」重排。
- **归组进核心**：`AssistPipeline.Bucket`（done / action / trouble / skip / waiting，短名
  已完成 / 待你处理 / 出问题 / 不用辅 / 没轮到）+ `RowStatus.bucket` + `Tally.count(_:)` /
  `Tally.buckets` / `Tally.breakdown(_:)`（每组里的细分说法，挂悬停）/ `Tally.summaryLine`
  （一条种子的汇总句）。12 个结论一个都不能漏，`testEveryStatusLandsInExactlyOneBucket`
  逐条钉住——漏一组就表现为「数字凭空少一截」，两端各写一套归法迟早对不齐。
- **mac**：`AssistView` 五块改三块——进度（覆盖率条 + 5 组计数 + 逐站那一截，合计写在逐站标题行
  右侧）、待你处理（整页唯一动手的地方，一行最多两个按钮：采纳/重试/回查/撤销四选一 + 否决；
  否决过的收进「已处理」展开栏）、种子明细（一条种子一行汇总，点开才是计数牌与格子，
  要人处理的默认已展开，不再有「展开全部格子」那个开关）。顶部按钮改名
  「重新扫描（不发检索）」「跑这一页」，「回查校验」挪进待你处理那栏变「全部回查（N）」，
  跑起来只剩一行「运行中，已请求 12 / 200」旁边挂停止与追加。
- **Windows 要改**：桥那边三处扩了字段，WPF 不跟着改就画不出新形状——`stats.buckets`
  （5 组：bucket/label/hint/detail/count，`AssistStatLine`→`AssistBucketLine`）、
  每格与每行实时进展都带 `bucket`、`torrents[].summary` + `attention`（明细行那句汇总与
  要不要默认展开，都由核心拼好）、`queue[].handled`（否决过的分到 `AssistHandled`）。
  逐站那一截加了「只显示还有活的站」，用 `ICollectionView.Filter` 只滤显示，模型那表不重建；
  种子块改成标题行即展开开关（`TorrentBlock.Toggle`），没人点过时按 `attention` 自动展开，
  人点过就固定不再自动改（mac 的 `touched` 同一套）。`AssistBudgetLine` 改成「已请求 x / y」，
  前面由界面拼「运行中，」。
- 验证：`swift test` 600 绿（新增 5 组归类两条：五组计数与汇总句、每个结论恰好落一组；
  快照与 `assist.scan` 载荷各加断言：`stats.buckets` 五组齐全且都给细分说明、格子带 `bucket`、
  `torrents[].summary` == 「没轮到 2」、`attention` 为 false）；`dotnet build` 0 错误。

## 这一轮（逐站那一截：行列表改站点卡片）

- 115 个站用一行一站的列表读不动：横向一大截空白、进度条几乎全在 0、要找那家有问题的站得滚到底。
  改成一站一卡片（卡片是这个软件已有的语言：转种分组、种子明细都是卡片）。
- **归组进核心**：`AssistPipeline.SiteState`（trouble / review / queued / paused / done / unsupported，
  带 `label` 与 `rank`）+ `SiteProgress.pausedSite`（人按没按暂停，跟「暂停站里压着几格」是两回事）
  + `SiteProgress.state` / 卡片那三行字 `stateLine`（「已判定 0 / 3,325」）、
  `nextLine`（「还要检索 3,325」/「已暂停，压着 129,660 格」/「这一站已铺完」）、
  `warnLine`（那行红字，没事是空串）。三行分开是因为卡片宽 130 上下，
  「已判定 x / y　还要检索 n」挤一行会被省略号砍掉。
  优先级：不支持检索 > 暂停 > 失败 > 待复核 > 已铺完 > 排队中；`rank` 让有问题的站排前面、
  辅不了的沉底。颜色归组也归核心判：两端给出两种颜色的话，同一份下载器会看着像两个状态。
- **mac**：`siteList` 那截换 `LazyVGrid`（132…184 自适应）卡片——站名 + 迷你进度条 +
  那三行字，右上一个 暂停/继续 图标按钮（`pause.circle` / `play.circle`），底色与描边按 `state`
  走（`siteWash`/`siteEdge`），排序 `state.rank` → 检索数 → 站名。
  覆盖率、5 组计数、「只显示还有活的站」、「合计 …」那几样不动。
- **Windows 要改**：`siteProgress` 每项多 `state` / `stateLabel` / `stateRank` / `stateLine` /
  `nextLine` / `warnLine`，`AssistSiteRow.Line`/`NextLine`/`Warn` 改为直接用核心给的文案（不再自己拼），
  排序按 `stateRank`；`AssistView.xaml` 那一截换 `WrapPanel` + 164px 卡片，底色走 `State` 的
  DataTrigger；暂停从 CheckBox 换成 暂停/继续 按钮，`OnPauseSite` 因此改成按现值翻开关。
- 验证：`swift test` 601 绿（新增 `testSiteProgressStateAndCardLines`：六种归组各判对各、
  不支持检索的站不被失败数抢颜色、卡片那三行文案各说各的、`rank` 顺序；`assist.scan` 载荷加断言：
  `siteProgress` 带 `state`/`stateRank`/`stateLine`）；`dotnet build` 0 错误。

## 这一轮（逐站暂停当场见效：不必重新扫描）

- 症状：站点卡片上按了暂停，什么都没变——颜色不变、数字不动，得重新扫描（那一下要好几秒）
  才看得出效果。根因是暂停在 `planCatalog` 那一刻烤进了计划：`SiteBucket.pausedSite`、
  `Tally` 的 `.pending`/`.paused`、`pendingBySite`、`counts["本站已暂停"]`、`willSearch`
  全是那时算好的。执行本身倒是每次都现读配置（`run` 里 `cfg.isPaused(id)`），
  所以只有「报数」是旧的。
- **核心库**：`CatalogPlan.applyingPaused(_:)` 按当前名单把派生数推平——待辅种 ↔ 已暂停、
  这一站还要检索几次、`counts` 那两项、`willSearch`、分桶里的暂停标记一次全改；
  名单没变原样返回（那几万个 hash 集合只共享不复制）。`counts` 里那两个键名收成
  `CatalogPlan.pausedKey` / `searchKey`，两处写数的地方共用，免得改一处漏一处。
  不支持站内检索的站不再顺手标 `pausedSite`（暂停它没意义，卡片也不给点）。
- **mac**：`assistStats` / `assistSiteProgress` / `assistCoverage` 走 `assistLivePlan`
  （= 计划 `applyingPaused(当前名单)`）；新增 `assistSetPaused(_:paused:)`，改完名单顺手
  把 `assistPlan` 与这一页的格子换成推平后的那份，卡片当场变脸、变位置。
  卡片整张换成一个 `.plain` 按钮（原来只有右上那个小图标能点），悬停描边提「这儿能点」，
  图标只报状态：实心 = 暂停中。
- **Windows 要改**：不用加代码——载荷与快照里的 `siteProgress` 现在就按当前名单算，
  `pausedSite` 直接取 `SiteProgress.pausedSite`（不再自己拿配置比）。
  暂停一个站仍走 `config.patch`（改 `assist.pausedSites`）+ 600ms 快照轮询，点完下一拍就刷新。
  `AssistView.xaml`：整张卡片 Border 挂 `MouseLeftButtonUp="OnPauseSite"`（按钮照留，
  Button 会吃掉 MouseLeftButtonUp，不会翻两次），手型与「不支持检索回落到箭头」都收进
  Style 的 Setter/Trigger（写在元素上会盖住 Trigger），`IsMouseOver` 提亮描边；
  `AssistSiteRow.Fingerprint` 加上 `NextLine`/`Warn`，否则只有文案变会被指纹判成没变。
- 验证：`swift test` 603 绿（新增 `testPausingASiteTakesEffectWithoutRescan`：暂停/恢复来回
  推平、总数不动、覆盖率那句改口、格子结论与跳过原因跟着变、名单没变原样返回、
  暂停不支持检索的站一格不动；`testPauseSiteIsReflectedWithoutRescan`：`config.patch` 之后
  `assist.page` 的格子、`siteProgress` 卡片、快照的 `stats`/`coverage` 当场按新名单算）；
  `dotnet build` 0 错误。

## 这一轮（辅种整条线收起来：界面上没有，命令也不接）

- 需求是「不运行」而不是「删掉」：流水线、状态表、已辅记录、两端界面代码全留着，
  只在入口处收。收成核心库一个开关：`AssistFeature.enabled = false`
  （`Assist/AssistFeature.swift`），两端都问它，不各写一份判断。
- **核心库**：`AppService.invoke` 在最前面挡掉所有 `assist.*`（含 `assist.tick`），
  回一句 `AssistFeature.offMessage`；`version` 载荷多带 `features.assist`，
  快照的辅种块多带 `enabled`——界面据此收块，不必自己猜这一版有没有。
  `unassignedManagedSites` 跟着改：辅种收起时那份辅种名单没地方列，
  只进过辅种区块的站点退回「未分组」，否则它们会从站点分组页上凭空消失
  （实测这台机器上 45 站回到未分组，cookie 检测照旧覆盖——那一段按 `sourceSites` 遍历）。
- **mac**：`ContentView` 用 `if AssistFeature.enabled` 决定摆不摆「辅种」页签，
  `BOXSEND_START_TAB=6` 在收起时回落到首页，免得停在一个不存在的标签上；
  站点分组页的辅种站点区块、设置页的「辅种搜索节奏」「辅种逐站筛选」、下载器里那栏
  「辅种扫描用」同样按开关摆；`startAssistAutoTimer` 直接不开那把一分钟的钟，
  `assistScan`/`assistTick` 再加一道 guard。
- **Windows 要改**：`AppModel` 从 `version.features.assist` 读 `AssistEnabled`
  （默认 false，快照里的 `assist.enabled` 会再校正一次），据此
  ① 不开 `_assistTickTimer`，② `MainWindow` 把 `TabAssist` 设 Collapsed，
  ③ `SitesView.Reload` 不摆辅种区块、未分组那份把辅种站点收回来，
  ④ `SettingsView` 把 `AssistBox`（含逐站筛选 Expander）收起，
  ⑤ `DownloaderView` 收掉「辅种扫描用」那一栏、标题与说明文案换成不提辅种的那份。
  收起状态一律走 `_model.AssistEnabled`，别在 XAML 里写死。
- 测试：辅种那批用例（`AssistSnapshotStatsTests`、`WindowsBridgeTests`）在 `setUp`
  里临时把开关打开，测的是真代码；另加 `testAssistIsHiddenWhileFeatureOff`
  测收起时 `version.features.assist == false`、`assist.scan` 抛「先收起来」、
  快照 `assist.enabled == false`。`swift test` 604 绿，`dotnet build` 0 错误。

## 这一轮（1.3：种子框收成一半、下载器只留一台、教程重写）

- **种子链接输入框**：mac 用 `SeedCardWidthKey` 把区块实测宽度从 `GeometryReader`
  背景读回来，输入框 `.frame(maxWidth: 宽/2)`（窄于 460 不收，免得挤成一条缝）。
  Windows 不用测宽：标题那行 `DockPanel LastChildFill="False"`，输入框单独放进
  一个两等分列的 `Grid`，占第一列——两边都是「正好一半」，不靠魔法数字。
- **下载器只留一台**：多下载器本就为辅种而存在，所以收起条件复用 `AssistFeature`
  而不是新加开关。mac 走 `AppModel.visibleDownloaders`（收起时只回 `reseedDownloader`），
  卡片列表、`rolesCard` 里的「添加一台」与两个用途下拉、卡片上的「删除这台」都按它摆；
  Windows 加同名的 `AppModel.VisibleDownloaders`，`BuildCards` 用它，构造时按
  `AssistEnabled` 把 `AddRow`/`RoleRow` 收起、`CardFor` 不再挂「删除这台」。
  两边卡片标题都只报输入的名字（空回「下载器」），地址留在输入框里不再上标题。
- **版本 1.3**：`Util/Version.swift` 一处改，`make-app.sh` 写进 Info.plist；
  `BoxSend.Windows.csproj` 的 `<Version>` 跟到 1.3.0。`UpdateTests.testCurrentVersion`
  原来写死 `isNewer("1.3", than: 当前)`，升版本必炸，改用 `99.0` 比对。
- **使用教程**：mac `TutorialSheet` 不再走 `.boxsendAppearance()`（那层会铺壁纸，
  字压在图上读不动），改贴新的 `BoxSendThemeBackground`——只走主题渐变再压深一层，
  段落字号从 `.caption` 提到 `.footnote` 且用主文本色。Windows 的 `TutorialWindow`
  本来就是实心主题底，不用动背景，正文与 mac 同步改。
  第 2 节重写为 CookieCloud 与 PT-depiler Gist 的搭建步骤：token 只勾 `gist` scope、
  Gist ID 取网址里那串 32 位十六进制、Gist 解密口令是「备份密码|GistID」，
  CookieCloud 服务端 `docker run ... easychen/cookie-cloud` + 扩展给的 KEY(UUID) 与密码、
  `GET {host}/get/{KEY}` 拉回本地解密。第 4 节按单下载器改写（旧文案还在讲「检验连接」
  与多机用途指派）；第 5 节把「『下载器』页的转种服务器」改成「『设置』页」——那两块现在
  都在设置页里。教程配图还是旧版标签布局那批，页脚说明已改成「截图为旧版界面示例，
  Cookie 与下载器现已并入「设置」页」，重拍图另说。两端教程正文一处改一处对照，别只改一边。
- 收起辅种后下载器卡片上那两个标签也跟着改了：`名字（列表与用途下拉里显示）` →
  `名字（卡片标题显示）`、区块标题 `下载器（推送用这一台）`，Windows 同一处按
  `_model.AssistEnabled` 分岔。别在收起状态下还提「用途下拉」——那栏根本不摆。

## 踩过记在这儿

- 跨边界的字符串由分配它的模块释放：核心里 `strdup`，只能由同模块的 `boxsend_free` 回收。
- OCR 回调让宿主往核心给的缓冲区里写，不传所有权，省一类泄漏；C# 侧那份委托必须一直被持有，
  否则 GC 收了它，回调回来就是野指针（`BoxSendApi` 里那句 `GC.KeepAlive`）。
- 服务内部必须用可重入锁：写日志会回调进同一个对象，普通锁自己等自己。
- 界面轮询要分全量/部分两种刷新，全量重建列表会把正在输入的框打掉。
- Windows 没有 `inet_pton`，`sockaddr_in.sin_port` 要自己 `bigEndian`。
- `Array.move(fromOffsets:toOffset:)` 是 SwiftUI 带来的扩展，核心里得自己实现（`Util/CollectionMove.swift`）。
