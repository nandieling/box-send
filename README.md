# box-send

PT 站批量转种 + 推送下载器（按源站点限速）。**主体是 macOS 应用**：在 Mac 上解析源站、批量转种到目标站、推送到 VPS 上的 qBittorrent；VPS 只装下载器，不装本软件。

- 仓库: <https://github.com/nandieling/box-send>（私有）
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

支持站（9 个优先站，内置实测过的上传参数，全部可作源站）：
pt.luckpt.de、hdsky.me、ptchdbits.co、hdhome.org、springsunday.net（CMCT）、audiences.me、totheglory.im（TTG）、pterclub.net、hhanclub.net（仅作源站；一般用户无发种权限，其 offers 候选区不使用）。

## 快速开始（Mac，约 5 分钟）

```bash
# 1) 拉代码
git clone git@github.com:nandieling/box-send.git   # 私有仓库输 PAT

# 2) 打包 GUI 应用（首次会 release 编译，1~3 分钟）
cd box-send
bash scripts/make-app.sh
open dist/BoxSend.app
# 首次打开若被 Gatekeeper 拦：右键 → 打开 → 打开
```

首次打开后：

1. **Cookie 页** → 「导入 PTD_backup_*.zip …」：在 PT-depiler 里「备份 → 本地备份」导出 zip（勾选 Cookie 字段；如设置了备份密码，导入时输入）。
2. **下载器页** → 填 VPS 隧道地址（如 `https://qbnet.nandielinghai.de5.net`）+ 账号密码 → 「测试连接」应显示版本信息。
3. **站点与限速页**（可选）→ 给站点设上传限速（整数 MB/s）、把多个目标站加入同一分组（组带宽上限，避免 VPS 带宽超限）。
4. **下载器页**（可选）→ 填「VPS 剩余空间(GB)」并选大小检测策略（提醒/跳过 + 安全边际），避免大种塞满 VPS。
5. **运行页** → 粘贴种子详情页链接 → 勾选目标站 → 「开始运行」。

配置与状态都在 `~/Library/Application Support/BoxSend/`（boxsend.json / cookies.json / state.json / debug/）。

## 安装教程（详细）

### 第 0 步：前置条件

- macOS 13+，Xcode 或 Command Line Tools（`xcode-select --install`）
- PT-depiler Safari 扩展（<https://github.com/nandieling/PT-depiler> 或本仓库同级 `PT-depiler-safari`），已登录各 PT 站
- VPS 上已装 qBittorrent 并有可达的 WebUI（本机直连或隧道，如 de5）

### 第 1 步：PT-depiler 导出 cookie（每次 cookie 更新后重复，约 1 分钟）

1. 打开 PT-depiler 界面 → 「备份」→ 勾选 **Cookie**（其它字段随意）→ 「本地备份」，保存 `PTD_backup_*.zip`。
2. 在 BoxSend 的 **Cookie** 页选择该 zip 导入。若 PT-depiler 设置了备份密码，导入时输入（zip 内是 AES 加密的，口令 = MD5(密码) 前 16 位）。

> 备选：Gist 自动同步（可选）。在 PT-depiler 里配置 Gist 备份后，把 gistID / GitHub token / 备份密码填到 BoxSend **Cookie** 页上方的「Gist 同步」区块，可开「自动定时同步」（默认 30 分钟），无需手动导 zip。

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

1. 运行页粘贴一个源站详情页链接。
2. 只勾 1 个目标站（如 HDSky）、「开始运行」。
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

## 使用（GUI）

- **运行**：粘贴详情页链接（一行说明 + 一行输入框）→ 勾选「转种到目标站」「推送到下载器」→ 勾选参与本次转种的目标站 → 「开始运行」。结果含每站转种状态 + 推送状态 + 生效的上传限速。转种成功的目标站会**自动拉取该站新种子的 .torrent 并单独推送到下载器**（按目标站限速），无需手动添加。
- **站点与限速**：每个站一行，设置**该站种子的上传限速（整数 MB/s，空 = 不限速）**（推送到下载器时生效，避免上传速度过高被站管/带宽策略盯上）、并把它**加入分组**；**目标站分组**为组内站点提供共用带宽上限（整数 MB/s，空 = 不限），用于避免 VPS 上传带宽超限；生效限速 = 站点限速与分组带宽取更严格者；另有全局默认限速、推送策略（总是推 / 全部转种成功才推）。转种目标站在「运行」页勾选。
- **Cookie**：Gist 同步（手动/自动，最上）→ PT-depiler 本地备份 zip 导入 → **备份目录监控**（填监控目录/备份密码/间隔，目录出现新 PTD_backup*.zip 自动导入）→ 已同步的 Cookie 详情（站点数/总数/站点列表 + 「检测登录状态」逐站探测 cookie 是否失效，最下）。
- **下载器**：qBittorrent/Transmission 参数 + 连接检测 + **大小检测**：填「VPS 剩余空间(GB)」与「安全边际(GB)」（默认 5），策略选「提醒」或「跳过」；种子大小超过剩余空间（含边际）时，提醒模式只提示、跳过模式直接不转种不推送。剩余空间请手动维护（qB 的 WebAPI 没有磁盘剩余接口）。
- **RSS**：自动转种。给各源站填 RSS passkey（留空不参与）、设轮询间隔（分钟）、开「启用 RSS 自动转种」或点「立即轮询一次」；新种自动走完整流水线（查重 → 大小检测 → 转种 → 按站限速推送）。每个 RSS 条目按 guid/link 去重（每站记录 500 条），处理过的不会重复转种。
- **日志**：最近 500 条运行日志（转种/推送/cookie 变更）。

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
box-send rss-sync             轮询一次 RSS：自动转种 + 推下载器（需配置 rss）
box-send import-watch         扫描备份目录，自动导入新 PTD_backup*.zip（需配置 zipWatch）
box-send check-cookies [--site <id>]   检测各站 cookie 登录态
box-send test-downloader       测试下载器连接
box-send serve [--port 8088] [--token xxx]   Web 控制台（可选，局域网访问用）
box-send cookies / notes / template / list --site <id>
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
  - `qualitySelects` / `qualityValueMaps`：媒介/编码/音轨/分辨率下拉自动填充（从发布名识别 REMUX/UHD/Web-DL/x265/DTS-HD MA 等）
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
- `rss`: `enabled` / `pollMinutes`（轮询间隔，分钟，最小 1）/ `passkeys`（源站 id → RSS passkey，留空的站不参与；地址默认 `passkey.php?rss={passkey}`，可用 overrides.rssPath 覆盖）
- `zipWatch`: `enabled` / `dir`（PT-depiler 本地备份目录，默认 ~/Downloads）/ `pollMinutes` / `password`（备份密码，未加密备份可空）
- `userAgent` / `webToken`（serve 用）/ `dataDir`（CLI 用，默认 `~/.boxsend`）

> 限速生效方式：qBittorrent 在 `torrents/add` 请求里直接带 `upLimit`；Transmission 在 `torrent-add` 后 `torrent-set` 设 `upload-limit`。
> qBittorrent 5.2+ 推送已存在的种子返回 409 Conflict，视为"已推送"（幂等）。

## 打包与安装 .app

- `bash scripts/make-app.sh` → `dist/BoxSend.app`（release 编译 + Info.plist + ad-hoc 签名）。
- 分发：zip 后发给别的 Mac，首次打开需右键 → 打开（ad-hoc 签名无开发者账号）。
- 应用无沙盒、ad-hoc 签名：需要网络访问 + 读 `~/Library/Application Support/BoxSend` + 调 `/usr/bin/unzip` 解 PT-depiler 备份。

## 测试

`swift test`（45 个用例：NIST AES-256 向量、`openssl enc -aes-256-cbc -a -md md5` 的 Gist 备份解密向量、gist 密钥推导、cookie jar、限速配置、质量标记解析、站点 overrides 解码、真实详情页解析（标题/副标题/类型/MediaInfo/IMDb/豆瓣）、bencode `info.name` 与 info-hash（SHA-1 向量）、HTML→BBCode 简介转换（含 CRLF 空行归一化）、HDSky 上传表单全字段校验、大小检测边界与旧配置兼容、RSS 解析/feed URL/状态去重、备份目录监控导入与重试）。

## 里程碑

- M1（当前）：Mac GUI 主体（运行/站点限速/Cookie/下载器/RSS/日志）+ 核心库（HTTP/站点/转种流水线/下载器/Gist 同步/Web 控制台）+ 9 优先站内置实测 overrides（8 站可转种）+ 质量标记自动填充 + PT-depiler 本地备份 zip 导入（加密/未加密）+ 按站点限速 + 目标站分组（带宽上限）+ 状态幂等 + CLI
- M2（已完成部分加粗）：**RSS 自动转种（新种自动查重/大小检测/转种/推送）**、**PT-depiler 备份目录监控自动导入**、**cookie 健康检测**、**种子大小检测（对比 VPS 剩余空间，提醒/跳过）**、**目标站搜索查重（8 站端点实测）**；剩余：Unit3D（REST API）/Gazelle 适配器、OWSS/WebDAV 同步、简介模板精调、状态存 SQLite（历史查询）
- M3：长尾站点（MTeam/YemaPT/Rousi 等定制站）、截图搬运图床、动态限速、统计面板

## 已知限制

- 应用为 ad-hoc 签名（无开发者账号）：首次打开需右键 → 打开；从网盘/airdrop 拿到可能被 Gatekeeper 拦。
- 转种失败时上传页 HTML 存 `~/Library/Application Support/BoxSend/debug/upload-<站id>-<时间戳>.html`，错误信息带路径。
- 质量分类/下拉按发布名启发式推断，个别非标准命名可能落到兜底分类，可在 overrides 精调。
- 个别有 Cloudflare/JS 校验的站点纯 HTTP 可能失败，需浏览器兜底（PT-depiler 手动转种）。
- HHanClub 为候选区上传（offers.php），一般用户无发种权限，故仅作源站。
- de5 隧道只开放了 qBittorrent WebAPI 的部分端点：`auth/login`、`torrents/info`、`torrents/add` 可用；`addtrackers`/`properties`/`remove` 返回 404（隧道未映射）。后果：同一 info hash 的多站种子无法合并 tracker、已推送种子无法从本软件移除/改属性（需在 qB WebUI 里操作）。
- 大小检测的「VPS 剩余空间」是手动维护值（qB WebAPI 无磁盘剩余接口），空间变化大时记得更新配置；建议配「安全边际」留余量。
- RSS 依赖各站 passkey 与 `passkey.php?rss=` 端点（NexusPHP 家族通用）；个别站若关闭 RSS 需在 overrides.rssPath 覆盖或换用备份目录监控 + 手动/其它触发。
