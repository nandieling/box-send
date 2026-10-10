# Windows 移植记录

方案：**核心逻辑继续用 macOS 那套 Swift 代码，Windows 另写一套原生 WPF 界面。**
两端界面不共用，跨边界只有一种调用（`invoke` 收发 JSON），进度靠轮询。

```
macOS    SwiftUI/AppKit ─┐
                         ├─ BoxSendKit（站点/转种流水线/cookie/下载器/Gist·CookieCloud/Web 控制台）
Windows  WPF ──P/Invoke──┘   boxsend.dll（C ABI + JSON 契约）
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
`sites.add|remove|setEnabled|move|moveBefore|setGroup|setApiKey|setUpLimit`、
`targets.set / sourceQuote.set`、
`cookies.getRaw|setRaw|remove|clear|trim|sync|check|stopCheck|importZip`、
`zip.set / zip.scan`、`downloader.test`、`run.start / run.status`、`tmdb.test`、`update.check`。

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
- 回归测试从 337 个加到 354 个，全绿

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

## 到 Windows 机器上要做的事

1. `swift build --product boxsend` 与 `swift test` 先全绿 —— 核心在 Windows 上编译过没有别的说法。
   （CI 的 Windows 作业已经在做这件事，本地可以不重复。）
2. `dotnet run --project windows/abi-probe`（Windows 上加载的就是 `boxsend.dll`）。
3. `.\windows\build.ps1`，跑 `windows\publish\BoxSend.exe`。首次启动若报缺 DLL，就是 Swift 运行时
   没拷全，按提示名从工具链 `usr\bin` 补进 `BoxSend.Windows\native\`；`dumpbin /dependents boxsend.dll` 是权威判据。
4. 六页逐项对照 mac 版：建组、批量加站、组限速、逐站检测、下载器测试、TMDB、主题与背景图。
5. **双跑对拍**：同一份 `boxsend.json`、同一批 cookie，mac 与 Windows 各跑同一条源种链接，
   比对发种结果、推送、限速、日志。这一步是功能等价的真正验收，别省。
6. 长任务：开始转种后关窗口，从托盘回来确认状态与日志连续。
7. 换台干净机器（别装过 .NET、也别装过 VC++ 运行库）装一遍：自包含包不依赖 .NET，
   但 Swift 运行时可能找 `VCRUNTIME140.dll`。脚本会把它随包带一份，验证这条有没有生效就靠这一步。
8. 分发前签名：`boxsend.dll` 和 `BoxSend.exe` 都要签，不然 SmartScreen 和杀软各拦一道。

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
