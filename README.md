# box-send

在 VPS（"盒子"服务器）上运行的 Swift 工具：从源 PT 站批量转种到其它 PT 站，并把种子推送到本机下载器（qBittorrent / Transmission），**按源站点设置上传限速**（避免上传过快被站点风控/封禁）。

- 仓库：<https://github.com/nandieling/box-send>（私有）
- 转种流程与 [auto_feed 油猴脚本](https://greasyfork.org/zh-CN/scripts/424132-auto-feed) 一致，限速机制参考其 `siteUpLimits`
- cookie 由 [PT-depiler-safari](../PT-depiler-safari) 的 Gist 备份功能自动提供，无需手工导出
- 支持 Mac（开发）/ Debian 12 / 13 VPS（生产）

## 架构

```
Mac (Safari + PT-depiler)
  │  浏览器里登录各站；PT-depiler 每 N 小时自动备份 cookie 到 GitHub 私有 Gist
  ▼
GitHub 私有 Gist（_manifest.json + cookies.txt, AES-256-CBC 加密）
  │  box-send gist-sync 轮询拉取（fine-grained PAT, Gists: Read）
  ▼
VPS: box-send（Swift 常驻进程）
  ├─ CookieStore（按站 host 管理 cookie）
  ├─ NexusPHP 适配器（M1 覆盖 9 个优先站）：解析详情 / 下载 .torrent / 查重 / 上传
  ├─ ReseedPipeline：源站详情 → 逐目标站查重+上传（禁转检测、幂等状态）
  └─ Downloader：qBittorrent Web API（add 时带 upLimit）/ Transmission RPC（torrent-set 限速）
```

状态存 `~/.boxsend/state.json`（每站已转种记录、已推送记录、运行日志），重复执行幂等。

## 快速开始（VPS 一键，约 10 分钟）

前置：一台 Debian 12/13 的 VPS（有 root 或 sudo）、VPS 上已装好下载器并开启 WebUI/RPC、一台登录了 PT 站的 Mac（Safari + PT-depiler）、一个 GitHub 账号。

```bash
# 1) VPS 上放仓库（git clone 或 scp 均可，位置随意，示例 /opt/box-send）
git clone https://github.com/nandieling/box-send.git /opt/box-send
# 私有仓库：clone 时输账号 nandieling + 一个对 box-send 有 Contents 读写权限的 PAT
cd /opt/box-send

# 2) 一键部署：装 Swift 6.4 工具链 + 依赖 → release 构建 → 装 /usr/local/bin/box-send → 注册 systemd 服务
bash scripts/deploy-debian.sh

# 3) 启动 Web 控制台（先不注册服务，手动跑一次填配置）
box-send serve --token 你定一个密码 &

# 4) Mac 上开 SSH 隧道，浏览器访问
ssh -L 8088:127.0.0.1:8088 user@vps
# → http://127.0.0.1:8088  在网页里填：Gist 同步 + 下载器 + 各站限速 → 保存

# 5) 验证 cookie 同步
box-send gist-sync        # 应输出 "同步完成: N 条 cookie, hosts=..."

# 6) 小流量试转种（只解析 → 单目标站试跑 → 看日志）
box-send info --detail "https://hdhome.org/details.php?id=xxxxx"
box-send run  --detail "https://hdhome.org/details.php?id=xxxxx" --targets hdhome
box-send notes

# 7) 都正常后，停掉第 3 步手动跑的 serve（端口相同），启用常驻服务
pkill -f "box-send serve"
systemctl enable --now boxsend-gistsync   # cookie 按 pollMinutes 自动轮询
systemctl enable --now boxsend-web        # Web 控制台 http://127.0.0.1:8088
```

之后在 Mac 上保持 PT-depiler 登录并开着自动备份，VPS 侧全自动收 cookie；转种入口目前是"贴详情页 URL"（Web 控制台或 CLI），M2 增加源站 RSS 轮询全自动追新。

## 安装教程（详细）

### 第 0 步：前置条件

| 项 | 要求 |
| --- | --- |
| VPS | Debian 12 或 13，x86_64 / arm64，可 `apt`、可 `curl` 外网 |
| 下载器 | 装在 VPS 上，且开启网络接口：<br>qBittorrent：`qbittorrent-noqt` 设置里启用 WebUI（默认 8080），记下用户名/密码<br>Transmission：`transmission-daemon`，RPC 开启远程访问（默认 9091），设好 RPC 密码 |
| Mac | Safari + [PT-depiler-safari](../PT-depiler-safari) 扩展，已登录要做源站/目标站的 PT 站 |
| GitHub | 任意账号（cookie 备份走私有 Gist） |

> 下载器与 Web 控制台端口不同（8080 vs 8088），不冲突。若 qBittorrent WebUI 也想换端口，在 qBittorrent 设置里改即可。

### 第 1 步：配置 PT-depiler 的 Gist 备份（一次性，约 5 分钟）

1. 打开 <https://gist.github.com> → **Create a new gist** → 填个说明 → 选 **Secret gist** 创建。gist 地址形如 `https://gist.github.com/<用户>/<gistID>`，**记下 `<gistID>`**。
2. 创建 fine-grained PAT：<https://github.com/settings/tokens> → Generate new token → **fine-grained token** →
   - Repository access: 任选（本工具不需要仓库权限）
   - Permissions: 在 **Gists** 一栏勾 **Read and write**
   - 生成后复制 `github_pat_...`，**记为 access token**
3. Safari 里打开 PT-depiler 扩展 → 备份设置：
   - 备份方式选 **Gist**，填入上一步的 `gist_id` 和 access token
   - 设置**自动备份间隔**（建议 6~24 小时），保存后手动触发一次备份
   - **备份密码**：留空最省事；若设置了，记住它（第 3 步要填进 box-send）
4. 此时 Gist 里会出现 `_manifest.json` 和 `cookies.txt`（`cookies.txt` 为 AES-256-CBC 加密，密钥 = `MD5(备份密码 + "|" + gistID)` 前 16 位 hex，box-send 会自动还原，无需手工计算）。

> 备份里包含**所有已启用备份的站点** cookie，登录一个站、触发一次备份，就会出现在 Gist 里。

### 第 2 步：在 VPS 安装 box-send

```bash
# 方式 A：git（需要 VPS 能访问 GitHub；私有仓库输账号 + PAT）
git clone https://github.com/nandieling/box-send.git /opt/box-send
git config credential.helper store   # 首次输入后免再输

# 方式 B：本地打包 scp（Mac 上）
#   cd ~/Downloads/swift && tar czf /tmp/box-send.tgz --exclude 'box-send/.build' box-send
#   scp /tmp/box-send.tgz root@<vps-ip>:/opt/ && ssh root@<vps-ip> 'cd /opt && tar xzf box-send.tgz'
```

```bash
cd /opt/box-send
bash scripts/deploy-debian.sh        # 非 root 会自动 sudo
```

脚本做的事：
1. 检查 Debian 12/13 + x86_64/arm64（自动选 `debian12`/`debian13` 官方 Swift 包，可用 `SWIFT_VERSION=6.4.0` 环境变量覆盖版本）
2. `apt` 安装运行时依赖（libcurl/libxml2/z3/libgcc-12|13-dev 等，gcc 包名按发行版版本自动选择）
3. 下载并解压 Swift 官方工具链到 `/opt/swift-6.4.0-RELEASE-debian13`（已装则跳过）
4. `swift build -c release`，安装到 `/usr/local/bin/box-send`
5. 若 `Config/boxsend.json` 不存在，自动从 `Config/boxsend.example.json` 生成
6. 注册 `boxsend-gistsync.service`（cookie 常驻轮询）与 `boxsend-web.service`（Web 控制台），`WorkingDirectory` 自动指向仓库实际路径，**均不自动启动**

手动分步（与脚本等价，Debian 13 用 13 的包名）：

```bash
apt install -y binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 \
  libgcc-13-dev libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev \
  libz3-dev libncurses6 libtinfo6 pkg-config tzdata unzip zlib1g-dev ca-certificates
curl -fSL -o /tmp/swift.tar.gz \
  "https://download.swift.org/swift-6.4.0-release/debian13/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE-debian13.tar.gz"
tar -C /opt -xzf /tmp/swift.tar.gz
export PATH=/opt/swift-6.4.0-RELEASE-debian13/usr/bin:$PATH
swift build -c release && install -m 755 .build/release/BoxSend /usr/local/bin/box-send
```

### 第 3 步：填配置

**方式 A：Web 控制台（推荐，不用 vi）**

```bash
box-send serve --token 你定一个密码     # 后台常驻见第 6 步
```

Mac 上开隧道后浏览器访问 `http://127.0.0.1:8088`（首次输入令牌）：
- **Gist Cookie 同步**：gistID / access token / 备份密码（没设就留空）/ 轮询间隔
- **下载器**：类型、地址、账号密码、保存路径、分类、默认限速（MB/s）、推送策略
- **站点上传限速**：按源站点填 MB/s（0 = 跟随全局默认），例：CMCT 128、Audiences 125
- **转种目标站**：勾选要转种的站
- 底部「完整配置 boxsend.json」可看/改全部字段，保存前会做 JSON + 结构校验，失败不写盘

**方式 B：直接编辑文件**

`vi /opt/box-send/Config/boxsend.json`，关键字段：

```jsonc
{
  "webToken": "",                    // Web 控制台令牌（空 = 不校验，建议设置）
  "sourceSites": [ ... ],            // 9 个优先站已预置，可增删/停用
  "targetSites": ["hdhome", "ttg"],  // 要转种的目标站 id，按顺序执行
  "downloader": {
    "type": "qbittorrent",           // qbittorrent | transmission
    "url": "http://127.0.0.1:8080",
    "username": "admin", "password": "你的WebUI密码",
    "savePath": "", "category": "pt", "skipChecking": true,
    "defaultUpLimit": 0,             // 全局默认上传限速 bytes/s，0 = 不限
    "siteUpLimits": { "cmct": 134217728, "audiences": 131072000 },  // 按源站限速
    "pushPolicy": "always"           // always | onSuccess
  },
  "gistSync": {
    "gistID": "<gistID>", "token": "github_pat_...",
    "encryptionKey": "",             // PT-depiler 备份密码，没设就留空
    "pollMinutes": 30
  }
}
```

其余字段说明见仓库 `Config/boxsend.json` 与 [配置参考](#配置参考configboxsendjson)。

### 第 4 步：验证 cookie 同步

```bash
box-send gist-sync        # 首次手动拉一次
# 期望: 同步完成: N 条 cookie, hosts=hdhome.org, totheglory.im, ... (备份时间 ...)
box-send cookies          # 查看本地各站 cookie 条数
```

若报 404：token 的 Gists 权限没勾对；若解密失败：`encryptionKey` 与 PT-depiler 备份密码不一致；若 hosts 里没有某个站：那个站还没在 PT-depiler 里登录过/没被备份。

### 第 5 步：首次转种（小流量验证）

```bash
# 1) 只解析不上传，确认详情解析正常（名称/IMDB/大小/torrent 链接）
box-send info --detail "https://hdhome.org/details.php?id=xxxxx"

# 2) 只转一个目标站试跑（--targets 限定，失败不影响其它站）
box-send run --detail "https://hdhome.org/details.php?id=xxxxx" --targets hdhome

# 3) 看执行结果与日志
box-send notes
```

检查点：目标站出现新发布的种子（标题带原站名）；下载器里出现该任务且上传限速生效（qBittorrent 任务列表的"限制上传速度"列）。重复执行同一 URL 是幂等的（已转种/已推送的会跳过）。

### 第 6 步：启用常驻服务

```bash
systemctl enable --now boxsend-gistsync   # cookie 按 pollMinutes 轮询（默认 30 分钟）
systemctl enable --now boxsend-web        # Web 控制台 http://127.0.0.1:8088

journalctl -u boxsend-gistsync -f         # 看 cookie 同步日志
journalctl -u boxsend-web -f              # 看 Web 控制台日志
```

- `boxsend-web.service` 默认 `--host 127.0.0.1 --port 8088`，只监听回环；对局域网/公网暴露前改 `/etc/systemd/system/boxsend-web.service` 的 `--host` 并务必加 `--token`。
- 若第 3 步是在网页里填的 `webToken`，systemd 服务会自动读取配置里的令牌，无需再传 `--token`。

## 使用（CLI）

```bash
box-send sites                 # 站点/下载器配置概览
box-send serve [--port 8088] [--host 127.0.0.1] [--token xxx]   # Web 控制台
box-send gist-sync [--loop]    # 从 PT-depiler Gist 同步 cookie（--loop 常驻轮询）
box-send info --detail <url>   # 只解析源站详情页（名称/IMDB/大小/下载链接）
box-send run --detail <url> [--site <id>] [--targets a,b] [--skip-reseed] [--skip-push]
box-send push --detail <url>   # 只推下载器（不转种，带源站限速）
box-send list --site <id>      # 拉取源站种子列表
box-send test-downloader       # 测试下载器连接（实际登录一次）
box-send cookies               # 查看本地 cookie 状态
box-send notes                 # 最近运行日志
box-send template              # 重新生成模板配置
```

所有命令支持 `--config <path>` 指定配置文件（默认 `Config/boxsend.json`）。

## 配置参考（Config/boxsend.json）

> `Config/boxsend.json` 含 token/密码，**不入 git**（见 `.gitignore`）；仓库里带的是模板 `Config/boxsend.example.json`。新环境用 `box-send template` 生成，或 `cp Config/boxsend.example.json Config/boxsend.json`。VPS 上 `git pull` 不会覆盖本地已填的配置。

- `sourceSites`: 可作源站的站点。每项 `id/name/url/framework/enabled` + 可选 `overrides`：
  - `uploadPath` / `titleField` / `descrField` / `imdbField`：上传表单字段名
  - `categoryMap`：`movie/series/anime/documentary/music/other` → 站点分类 ID
  - `searchURL`：查重模板，`{imdb}` / `{name}` 占位；nil = 关闭自动查重
  - `forbidReseedMarkers`：命中即视为禁转（只推下载器、不转种）
  - `extraUploadFields`：上传时额外提交的固定字段
- `targetSites`: 转种目标站 id 列表（按顺序执行）
- `downloader`:
  - `type`: `qbittorrent` | `transmission`
  - `url/username/password/savePath/category/skipChecking`
  - `defaultUpLimit`: 全局默认上传限速（**bytes/s**，0 = 不限速）
  - `siteUpLimits`: **按源站点 id 的上传限速**（bytes/s）。例：`"cmct": 134217728`（128 MB/s，与 auto_feed 默认一致）
  - `pushPolicy`: `always`（默认，转种失败也推）| `onSuccess`（全部成功才推）
- `gistSync`: `gistID` / `token` / `encryptionKey` / `pollMinutes`
- `webToken`: Web 控制台访问令牌（空 = 不校验）
- `dataDir`: 状态目录（默认 `~/.boxsend`）

> qBittorrent 5.2+ 推送时若种子已存在于下载器，`torrents/add` 返回 409 Conflict，box-send 视为"已推送"（幂等，重复执行不报错）。

限速生效方式：qBittorrent 在 `torrents/add` 请求里直接带 `upLimit`；Transmission 在 `torrent-add` 成功后用 `torrent-set` 设 `upload-limit` + `upload-limit-enabled`。

## 升级（Mac push / VPS pull）

Mac 上开发提交后推送：

```bash
cd ~/Downloads/swift/box-send
git push origin main
```

VPS 上拉取更新（本地 boxsend.json 不入 git，不会被覆盖）：

```bash
cd /opt/box-send
git pull
bash scripts/deploy-debian.sh   # Swift 已装则跳过下载，只重新构建 + 装二进制
# systemd 方式：
systemctl restart boxsend-gistsync boxsend-web
# 手动 serve 方式：
pkill -f "box-send serve" && box-send serve --token 你的令牌
```

## 卸载

```bash
systemctl disable --now boxsend-gistsync boxsend-web
rm /etc/systemd/system/boxsend-{gistsync,web}.service && systemctl daemon-reload
rm /usr/local/bin/box-send
rm -rf /opt/box-send ~/.boxsend          # 状态与本地 cookie 缓存
# Swift 工具链 /opt/swift-6.4.0-RELEASE-* 如需释放磁盘一并删除
```

## Web 配置控制台

- 页面功能：运行状态（cookie 站点数/上次同步/日志）、Gist 同步、下载器（含**测试连接**按钮：保存表单后实际登录一次下载器，返回版本信息）、按源站点限速表、目标站勾选、手动「转种 + 推 / 仅推」、完整 JSON 编辑保存。
- 令牌：`webToken` 或 `--token` 非空时 `/api/*` 需要令牌（请求头 `X-BoxSend-Token` 或 `?token=`），页面首次输入后存浏览器 localStorage。
- Mac 远程访问（推荐，端口不暴露公网）：`ssh -L 8088:127.0.0.1:8088 user@vps` → 浏览器开 `http://127.0.0.1:8088`。
- cookie 一致性：`serve` 与 `gist-sync --loop` 两个进程共享 `~/.boxsend/cookies.json`——loop 进程写盘，serve 按 mtime 热加载，无需重启。
- 并发：单任务锁，同一时间只跑一个「同步/转种」任务，并发请求返回 409。

## 测试

`swift test`（12 个用例：NIST AES-256 向量、`openssl enc -aes-256-cbc -a -md md5` 生成的 Gist 备份解密向量、gist 密钥推导、cookie jar、限速配置）。

## 里程碑

- M1（当前）：骨架 + Gist cookie 同步/解密 + NexusPHP 适配器（9 优先站通用解析+上传）+ qBittorrent/Transmission 推送（含每站限速）+ 状态幂等 + CLI + Web 配置控制台
- M2：Unit3D（REST API）/Gazelle 适配器、源站 RSS 轮询全自动、OWSS/WebDAV 同步、按站分类映射精调与简介模板
- M3：长尾站点（MTeam/YemaPT/Rousi 等定制站）、截图搬运图床、动态限速、统计面板

## 已知限制

- 9 个优先站均为 NexusPHP，M1 用通用实现 + overrides 微调；首跑先 `info` 验证解析，再单站 `run --targets` 小流量验证。
- 个别有 Cloudflare/JS 校验的站点纯 HTTP 可能失败，需浏览器兜底（PT-depiler 手动转种）。
- `serve` 与 `gist-sync --loop` 同时运行时，`state.json` 由两进程各自加锁写盘，极小概率互相覆盖（M2 换 SQLite 后消除）；cookie 已通过 cookies.json mtime 热加载解决。
- Web 控制台单任务锁：同一时间只跑一个「同步/转种」任务，并发请求返回 409。
