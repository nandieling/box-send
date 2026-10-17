# 自动批量辅种方案（v1 草案）

辅种 = 站内已经有别人发的同一种子，我们只把**站点那份 .torrent** 加进下载器，让它校验到磁盘上
已有的文件后开始做种。不发种、不过审、不占新空间。

和现有转种的分工：转种要填表单发新种；辅种是「白捡一份做种资格」。现链路里
`QBittorrent.attachSiteTracker`（同 hash 时补挂本站 tracker）已经把辅种的最后一步做完了，
要新建的是前面几步：**扫描下载器 → 提取种子指纹 → 站内检索 → 确认同一种子**。

## 一、主流程

```
下载器                      本站状态                    目标站
 │ 1 扫描种子清单  ─→  2 指纹（hash / 文件清单 / 大小）
 │                              │
 │                    3 筛掉不该搜的站（已在做种 / 未开辅种 / 负缓存期内）
 │                              │
 │                              └─→ 4 站内检索（复用转种的多级查询词）
 │                                     ↓ 候选详情链接
 │                          5 下载候选 .torrent，算 info hash 比对
 │                                     ↓ 确认是同一种子
 │ 6 添加种子（沿用本地保存路径，先暂停）
 │ 7 等校验：100% → 启动 + 记账；不足 → 按策略回滚
```

## 二、「是同一种子」的判定级别

检索只能拿到名字，名字会因站点改写、组标签、截断而失真。所以名字只用来**挑候选**，
定性靠下载那份 .torrent 来比。按代价从低到高，命中即停：

| 级别 | 依据 | 处理 |
| --- | --- | --- |
| A 同 hash | 站点 .torrent 的 info hash == 本地种子 hash | 直接辅种（最可靠，覆盖绝大多数情况） |
| B 同内容不同打包 | 文件数、每个文件的相对路径尾段与字节数、总大小**全部相等** | 辅种，状态记为「非同一 hash」，供事后核对 |
| C 名字像但清单不符 | 只有名称匹配 | 不动下载器，进「待人工确认」列表 |
| D 检索不到 / 检索能力没有 | 站点无此种子、cookie 无效、框架无检索 | 本轮跳过，写明原因 |

框架支持面（各适配器现在都只回「第一条命中的链接」，改成候选列表要各自解析结果页）：

| 框架 | 检索现状 | 辅种 v1 |
| --- | --- | --- |
| NexusPHP 家族（含海胆、肉丝这类走 override 的） | 通用检索端点 + 多级查询词，最成熟 | 做，主力站点全在这 |
| Unit3D（馒头等 API Key 站） | 走 JSON 搜索，结果字段规整（含 size） | 做，改动小 |
| TNode / YemaPT / Gazelle | 各自有 `searchExists`，结果页差异大 | 逐个验，验不过先标「暂不支持」 |
| Blu（Blutopia、莫妮卡） | `BluAdapter.searchExists` 直接 `return nil`，override 也没配 `searchURL`：适配器压根没接检索（站点自己有搜索页） | v1 不做，补一段结果页解析就能上（M3） |
| Discuz 帖式站（YZYY） | 复用 NexusPHP 的检索，回落到 `torrents.php?search=`——论坛站没这个端点；站内种子挂在帖子附件上，详情链接是 thread id | v1 排除，要单独设计（见下） |

不支持的站在界面上写清楚原因，别让用户以为是软件漏了。

Discuz 帖式站排除得更彻底，原因是站点结构与辅种的前提对不上，不只是没写检索：

- 辅种要「一条种子一个可下载的 .torrent」，论坛站是**一个帖子带多个附件**（正片、字幕、修补包），
  哪一份才算那条种子没有唯一答案；比 hash 时也没有明确的比较对象。
- 站内搜索是论坛搜索，结果混着帖子，很多站还按积分/等级限制，解析出来的候选噪声大。
- 这两个站（blutopia、monika、yzyy）在内置 147 站里都默认未启用，也不是中文 PT 转种的常见目标站，
  先不为一两个站做一套独立解析。

两个坑：

- qBittorrent 一条种子可能同时给 `hash`（v1）和 `infohash_v2`，站点那份多半只有 v1：两边都要拿来比，
  只比一个会把大量 A 级误降成 B 级。
- 站点整季一个种子、本地按集存放（B 级天然不符），属 C 级，报告里写清「按集存放，无法整季辅种」。

## 三、保存路径规则（辅种最容易翻车的地方）

站点种子的内层目录名（`info.name`）决定下载器去哪儿找文件。对不上时它会报 missingFiles
并**开始重下一整份**，白占一倍空间。所以：

- 站点种子 `info.name` == 本地内容根名 → 沿用本地那份的 `save_path` 原样添加；
- 单文件种子 → `save_path` 用文件所在目录；
- 内层目录名不一致 → 默认**添加为暂停 + 校验后不足 100% 就删掉这条种子（保留文件）**并提示；
  v1.1 再补「用 `renameFolder` 把站点种子的期望路径改到已有目录」（qB 4.6+）。

校验通过前不启动，是这条链路的保险丝；`Downloader.addTorrent` 目前写死 `started=true`，要加参数。

## 四、成本控制（PT 站的检索次数是稀缺资源）

种子数 × 站点数很容易上千次检索，站点还常带搜索频控。四层收窄：

1. **已在做种的站不搜**：本地种子的 tracker 列表里已有该站 announce host → 这份文件早在那站做种了，
   一次请求都不发。这一条能砍掉大部分组合。host 取自 `torrents/info` 的 `tracker_hosts`
   （4.6+）或 `trackers`；老版本没这两个字段就退回逐种查 `/torrents/trackers`
   （`QBittorrent.trackerURLs` 已实现，含 `hash`/`infohash` 参数名差异的兼容）。
2. **命中即停**：A 级命中后不再跑剩下的查询词（转种那套查询词最多五级：整名、去组标签名、去标点词元、前 32 字符、中文副标题）。
3. **负缓存**：站内没找到，记 7 天（可配），期内不再搜；站点后来新发种靠增量扫描 + 缓存到期补上。
4. **节流**：每站检索间隔（默认 8 秒）、全局并发 2、单轮检索上限（默认 200 次）、整轮时长上限
   （沿用 `ReseedPipeline.bounded` 那套限时）。

另外：cookie 已检测失效的站本轮直接跳过（复用 `CookieCheck` 结果），否则登录页会被当成「站内没搜到」，
既浪费配额又污染负缓存。

## 五、要新增的代码接缝

| 位置 | 加什么 |
| --- | --- |
| `Downloader` 协议 | `listTorrents(filter:)`、`torrentFiles(hash:)`、`setPaused(hash:paused:)`、`removeTorrent(keepFiles:)`；`addTorrent` 增 `paused` 参数。qB 走 `/torrents/info`、`/torrents/files`（参数名按现有 `trackerHashParams` 的经验做 `hash`/`hashes` 双试）；Transmission 走 `torrent-get` |
| `Util/Bencode.swift` | `fileList(_:) -> [(path, size)]` 与 `contentRootName(_:)`（现在只有 `totalLength`、`filesTotal` 这类聚合值，比不了逐文件清单） |
| `Assist/AssistMatcher.swift` | 纯函数：输入本地指纹 + 站点 .torrent → 输出 A/B/C/D。表驱动单测 |
| `Sites/SiteAdapter.swift` | `searchCandidates(_:AssistQuery) -> [SearchHit]`：现有 `searchExists` 只回**第一条**名字命中的链接，辅种常常要在多条同名结果里按 hash 挑，需要一份带 名字/大小/详情页 的候选列表（名字仍只做初筛） |
| `Assist/AssistPipeline.swift` | 编排：扫描 → 筛站 → 检索 → 下载候选 → 判定 → 推送 → 校验复核。复用 `SiteRegistry.adapter` 的 `searchExists`/`fetchDetail`/`downloadTorrentFile` |
| `StateStore` | 三张表：`assisted[siteID#hash]`（含 detailURL、判定级别）、`assistMiss[siteID#hash]`（负缓存时间戳）、`assistScan`（上次扫描时间、当时的 hash 集合摘要） |
| `AppService` | `assist.scan` / `assist.candidates` / `assist.start` / `assist.status` / `assist.confirm`，照 `run.start` 的写法：立即返回、后台队列跑、界面靠 `snapshot` + `events(since:)` 轮询 |
| 站点配置 | `SiteOverride.assistEnabled`（白名单式，默认关）；辅种参数进 `AppConfig.assist` |
| 界面 | mac 新标签「辅种」（`Views.swift` 的 TabView tag 6）、Windows 新 `AssistView` |
| CLI | `box-send assist scan\|plan\|run`，先能在 Debian 上无头跑 |

`SiteStatus.Phase` 要加一态 `.verifying`（校验中）：辅种的成败取决于校验结果，不能把「已添加」当成「已辅种」。

## 六、界面（mac / Windows 同一套信息结构）

- 顶部：下载器状态 +「扫描下载器」+ 上次扫描时间 + 本轮预算（已用/上限 次检索）
- 站点选择沿用站点分组卡片，每站多显示一项「可辅 N / 已在做种 M / 不支持」
- 本地种子表：名称、大小、分类、已在做种站点、候选站点；可按大小/分类/未辅过筛
- 运行中的逐站逐种卡片，文案固定：`搜索中…` / `校验中…` / `辅种成功` / `文件对不上` /
  `站内无此种子` / `跳过：已在该站做种` / `辅种失败`，完整原因放悬浮与说明行
- 「待人工确认」列表：C 级候选（站点名、大小、文件数差异），一键采纳或忽略
- 辅种设置：检索间隔、并发、单轮上限、负缓存天数、B 级是否自动采纳、校验不满 100% 是否自动删除

## 七、分期

| 期 | 内容 | 验收 |
| --- | --- | --- |
| M0 | 协议扩展 + 数据模型 + qB/Transmission 列举种子（fixture JSON 驱动） | `assist scan` 能列出本地种子与已在做种的站 |
| M1 | `AssistMatcher` + 检索 + 判定，**只出报告不动下载器**（dry-run） | 实测 5 个站，A/B/C/D 分类与人工判断一致 |
| M2 | 执行 + 校验复核 + 回滚 + 节流 + 记账；mac 新页 | 真实辅种 20 条，无一例触发重下 |
| M3 | 增量扫描、定时、预算、统计、Web 控制台 | 第二轮扫描只处理新种子，检索次数下降到零头 |
| M4 | Windows 移植（桥方法 + WPF 页 + 主题） | 两端行为与文案一字不差 |

## 八、测试

- `Bencode.fileList` 单测：单文件 / 多文件 / 中文路径 / 带 `./` 前缀 / v2 种子
- `AssistMatcher` 表驱动：A/B/C/D 各例，含 qB v2 hash 不同、站点多加 `.srt` 一个文件
- 假下载器（现有测试已有注入风格）覆盖「添加 → 校验 → 100%」与「不足 100% → 回滚」两条路
- 节流与负缓存：第二次运行不发检索请求；cookie 失效站不发请求
- 站点搜索页存档沿用 `debug/search-<site>-*.html` 的习惯，改版时先看存档再改解析

## 九、需要你拍板的四件事（已按建议定稿）

1. **B 级（文件清单全等但 hash 不同）自动采纳吗？** 自动（`assist.autoAcceptSameFiles` 默认 true），
   只在内层目录名不一致时退回人工。
2. **校验不满 100% 时删不删刚加的那条？** 删（保留文件），`assist.removeOnVerifyFail` 默认 true。
3. **站点参与范围**：白名单式，`AppConfig.assist.siteIDs` 默认空，站点卡片上逐个开。
4. **触发方式**：v1 手动「扫描 + 开始」，定时增量放 M3。

## 十、M0–M2 已落地（本轮）

核心（两端共用）：

| 位置 | 实到什么程度 |
| --- | --- |
| `Util/Bencode.swift` | `fileList(_:) -> [(path, size)]`：多文件把 `info.name` 补成路径首段，单文件返回 `[(name, length)]`。没做 `contentRootName`——`infoName` 已经够用 |
| `Assist/AssistModels.swift` | `LocalTorrent`（含 `hashV2`、`trackerHosts`、`allHashes`）、`TorrentFingerprint`、`AssistLevel`（A `sameHash` / B `sameFiles` / C `nameOnly` / D `skip`）、`AssistOutcome` |
| `Assist/AssistMatcher.swift` | 纯函数判定 + `layout(localPaths:sitePaths:)`：`same` / `rootDiffers`（只差最外层目录名）/ `differs`。目录名不一致就不动下载器 |
| `Assist/SiteThrottle.swift` | 每站最小间隔 8s + 抖动 3s + 站点报限流后该站间隔翻倍（上限 240s）+ 单轮预算 200 次请求。检索、详情、下载 .torrent **一律各算一次**，不按「是不是搜索页」区别对待 |
| `Assist/AssistPipeline.swift` | `scanCandidates()`（已下完 + 大小/分类筛选）、`plan(torrents:siteIDs:)`（不发请求就能看出哪些组合会跑）、`run(torrents:opts:)`（站点在外层、逐条判定、先暂停加进下载器、轮询校验、满 100% 才 resume，不满按策略 remove 保留文件） |
| `Downloader` | `listTorrents`、`torrentFiles`、`setPaused`、`removeTorrent`、`torrentProgress`、`addTorrent(…, paused:)`（这条写进协议要求而不是只放扩展里：扩展方法静态派发，实现方的覆写会被无声吞掉） |
| `StateStore` | `assisted` / `assistMiss`（负缓存，默认 7 天）/ `assistScan` 摘要 |
| `AppConfig` | `assist: AssistConfig?`（间隔、抖动、预算、负缓存天数、A/B 策略、大小与分类筛选、校验等待） |

界面与入口：

- mac：新标签「辅种」（TabView tag 6）。左栏参与站点勾选 + 检索节奏，右栏候选种子 + 本轮计划与逐行进展。
- Windows：`Views/AssistView.xaml`，同一套信息结构；桥方法 `assist.scan` / `assist.start` / `assist.status`，
  进展随 `snapshot` 里的 `assist` 段回来（不另开一条轮询），`Event` 多带一个 `key`（站点|hash）供界面定位行。
- CLI：`box-send assist scan|plan|run [--sites a,b] [--limit N] [--dry-run]`。

判定口径与节流都在核心里，两端只是显示。当时测试 479 个全绿（新增 34 条：`BencodeFileListTests` 5、
`AssistMatcherTests` 6、`SiteThrottleTests` 5、`AssistPipelineTests` 11）。

## 十一、多下载器（发种与辅种各一台）

发种推的那台和辅种扫的那台经常不是同一台机器：VPS 上只放正在做的片，辅种要读的是家里
那台存全量文件的。所以：

- `DownloaderConfig` 加 `id`（主下载器固定 `main`）与 `name`；`AppConfig` 加
  `downloaders`（附加的那几台）、`reseedDownloaderID`、`assistDownloaderID`。
  老配置只有 `downloader` 一个对象，解码后 `allDownloaders` 就一台，两个用途都指它，行为不变。
- `DownloaderFactory.make(_:)` 解析成发种那台，新增 `makeForAssist(_:)` 解析辅种那台，
  另有 `make(_:client:)` 直接按某台配置建。`ReseedPipeline` 里的 savePath / 跳过校验 /
  大小检测一律读 `config.reseedDownloader`，辅种流水线读 `config.assistDownloader`。
- 逐站上传限速跟着**发种那台**存（`setSiteUpLimitMB` 走 `mutateReseedDownloader`）：
  换了机器再不改的话，界面上设了等于没设。辅种推送按辅种那台自己那份逐站表算，没有就用不限速。
- 界面：mac 与 Windows 的「下载器」页顶部多一张卡——列表（正在编辑哪台）、添加一台、
  删除这台（主下载器不可删）、以及「批量发种推送用」「辅种扫描用」两个下拉；
  「辅种」页顶部写明现在用的是哪台。桥方法 `downloaders.add/save/remove/assign`、
  `downloader.test` 带可选 `id`，快照多带 `downloaders` 与 `downloaderRoles`。
- Web 控制台仍只编辑主下载器（那台就是发种那台），辅种不进网页端。

## 十二、增量扫描与统计（M3 的一部分）

`AssistPipeline.scanAndRecord()` 在扫描时把种子集合摘要（FNV-1a，跨进程稳定：Swift 的
`hashValue` 换个进程就换种子，用它每次都会报「有变化」）、条数与时间记进 `state.json`，
界面上报「首次扫描 N 条 / 与上次一致 / 比上次多 M 条」，并显示各站「辅过 N」。
真正的增量靠已有的两张表拦着：已辅过、以及「站内没有」的负缓存（默认 7 天），
它们让重跑的请求数掉到零头，摘要只是让人看得出这批里哪些是新面孔。

## 十三、人工采纳与定时自动跑（M3 收尾）

**人工采纳**。「待人工确认」这条线是留给人的：名字对得上、逐文件清单对不上（站点拆了
字幕、多加了个 nfo）。以前到了这一步就只能手动去站内点下载，现在计划表里那行多一个
「采纳」按钮——人比对过觉得就是同一种子，就照人的判断走一遍推送：仍旧先暂停加进下载器、
仍旧等校验、仍旧在进度不满时按设置回滚。差别只在两道闸门让路：

- `AssistPipeline.Options.forceKeys`（`"站点|种子 hash"`）：命中的组合跳过全部预筛，
  负缓存期内的、此前已辅过的都照样再查一次——人既然比对过，就别拿旧账拦着。
- 目录结构对不上（内层目录名不同、结构不同）默认拦下，采纳过就照推，但把
  「可能会重下一部分」留在结论里；`autoAcceptSameFiles` 关掉的「站点重打包」也照样放行。
- 判定明确说不是同一种子（`.skip`）时不因为一句「采纳」就硬加：那是站点那份种子本身读不出
  清单或压根对不上号，点了也没用。
- 记进 `assisted` 表时级别写 `manual`，日后能回看这条是怎么过的。
- 采纳只跑被点名的那一条（`assist.confirm`），也不清空别的行的进展——单条操作不该把整表
  打回「待检索」。

**定时自动跑**。`AssistConfig.autoRunMinutes`（0 = 关）。判定收在 `AssistAutoRun`
一个类型里：`due(minutes:now:)` / `minutesLeft(...)` / `noteRun(now:)`，从上一轮起跑时间起算，
构造即「刚跑过」，所以开机不会立刻自己动起来。mac 端摆一个一分钟的 `Timer` 直接用它；
Windows 端每分钟敲一次桥的 `assist.tick`，让核心库替它判断——两端共用一把尺，
不会出现一个按启动时间起算、另一个按上次跑完起算。到点跑的就是「扫描 + 辅种」整套，
站点请求仍受逐站间隔与单轮预算约束，界面左栏会写「约 N 分钟后自动跑下一轮」。

测试 485 个全绿（这一节新增 6 条：`AssistPipelineTests` 的人工采纳 3 条、
`AssistAutoRunTests` 的定时钟与配置默认值 3 条）。

还没做（留后面）：`searchCandidates(_:)` 多候选列表（现在沿用 `searchExists` 取第一条命中，
站点请求更少但同名多版本时只能挑第一条）、Blu/Discuz 检索、
`SiteOverride.assistEnabled`（现在按 `assist.siteIDs` 白名单一处管）、Web 控制台看辅种。
