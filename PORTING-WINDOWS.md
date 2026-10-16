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
- 回归测试从 337 个加到 432 个，全绿（SSH 测速那 27 条按平台分流：密码 askpass 与 sh 桩
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

## 踩过记在这儿

- 跨边界的字符串由分配它的模块释放：核心里 `strdup`，只能由同模块的 `boxsend_free` 回收。
- OCR 回调让宿主往核心给的缓冲区里写，不传所有权，省一类泄漏；C# 侧那份委托必须一直被持有，
  否则 GC 收了它，回调回来就是野指针（`BoxSendApi` 里那句 `GC.KeepAlive`）。
- 服务内部必须用可重入锁：写日志会回调进同一个对象，普通锁自己等自己。
- 界面轮询要分全量/部分两种刷新，全量重建列表会把正在输入的框打掉。
- Windows 没有 `inet_pton`，`sockaddr_in.sin_port` 要自己 `bigEndian`。
- `Array.move(fromOffsets:toOffset:)` 是 SwiftUI 带来的扩展，核心里得自己实现（`Util/CollectionMove.swift`）。
