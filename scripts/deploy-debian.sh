#!/usr/bin/env bash
# box-send 一键部署 (Debian 12/13 VPS)
# 用法: sudo bash scripts/deploy-debian.sh   或   bash scripts/deploy-debian.sh (自动 sudo)
set -euo pipefail

SWIFT_VERSION="${SWIFT_VERSION:-6.4.0}"
INSTALL_DIR=/opt
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# DEB_MAJOR 在后面确定后填入 SWIFT_DIST（debian12 / debian13）
SWIFT_DIST=""
SWIFT_DIR_NAME() { echo "swift-${SWIFT_VERSION}-RELEASE-${SWIFT_DIST}"; }
TARBALL() { echo "https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_DIST}/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-${SWIFT_DIST}.tar.gz"; }

log() { echo "[deploy] $*"; }

# 0) 权限
if [ "$(id -u)" -ne 0 ]; then
  log "需要 root 权限，自动 sudo 重启..."
  exec sudo env SWIFT_VERSION="$SWIFT_VERSION" bash "$0" "$@"
fi

# 1) 系统检查
. /etc/os-release
[ "$ID" = "debian" ] || { echo "仅支持 Debian（当前 ID=$ID）"; exit 1; }
DEB_MAJOR="${VERSION_ID%%.*}"
case "$DEB_MAJOR" in
  12) SWIFT_DIST=debian12 ;;
  13) SWIFT_DIST=debian13 ;;
  *)
    echo "Swift 官方构建目前支持 Debian 12/13；当前是 Debian $VERSION_ID。"
    echo "建议: 升级 VPS 到 Debian 12+，或手动使用 Ubuntu 22.04 的 Swift 构建。"
    exit 1
    ;;
esac
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|aarch64) log "架构: $ARCH" ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac
log "系统: $PRETTY_NAME"

# 2) 运行时依赖（Swift 工具链标准集合）
log "安装依赖..."
apt-get update -qq
case "$DEB_MAJOR" in
  12) GCC_PKG=12 ;;
  13) GCC_PKG=13 ;;
esac
apt-get install -y -qq binutils git gnupg2 libc6-dev libcurl4-openssl-dev \
  libedit2 libgcc-${GCC_PKG}-dev libpython3-dev libsqlite3-0 libstdc++-${GCC_PKG}-dev \
  libxml2-dev libz3-dev libncurses6 libtinfo6 pkg-config tzdata unzip zlib1g-dev ca-certificates

# 3) Swift 工具链
SWIFT_DIR_NAME="$(SWIFT_DIR_NAME)"
if [ ! -d "$INSTALL_DIR/$SWIFT_DIR_NAME" ]; then
  log "下载 Swift ${SWIFT_VERSION} ($(TARBALL))"
  tmp="$(mktemp -d)"
  curl -fSL --retry 3 -o "$tmp/swift.tar.gz" "$(TARBALL)"
  log "解压到 $INSTALL_DIR ..."
  tar -C "$INSTALL_DIR" -xzf "$tmp/swift.tar.gz"
  rm -rf "$tmp"
else
  log "Swift 已安装: $INSTALL_DIR/$SWIFT_DIR_NAME"
fi
export PATH="$INSTALL_DIR/$SWIFT_DIR_NAME/usr/bin:$PATH"
swift --version | head -1

# 4) 构建并安装 box-send
log "构建 box-send (release)..."
cd "$REPO_DIR"
# 本地配置不入库（含 token）；新环境从示例生成
if [ ! -f Config/boxsend.json ]; then
  if [ -f Config/boxsend.example.json ]; then
    cp Config/boxsend.example.json Config/boxsend.json
    log "已从 Config/boxsend.example.json 生成 Config/boxsend.json（填入 gistSync/downloader 后再启用服务）"
  fi
fi
# 把示例里最新的站点 overrides/targetSites 同步进本地配置（保留本地 token、下载器等）
if [ -f Config/boxsend.json ] && [ -f Config/boxsend.example.json ]; then
  log "同步站点 overrides 到 Config/boxsend.json ..."
  python3 - <<'PYEOF_CFG'
import json
try:
    local = json.load(open("Config/boxsend.json"))
    ex = json.load(open("Config/boxsend.example.json"))
except Exception as e:
    print(f"  (跳过配置同步: {e})")
    raise SystemExit(0)
exmap = {s["id"]: s for s in ex.get("sourceSites", [])}
changed = False
for s in local.get("sourceSites", []):
    e = exmap.get(s["id"])
    if e and "overrides" in e and s.get("overrides") != e["overrides"]:
        s["overrides"] = e["overrides"]
        changed = True
ids = {s["id"] for s in local.get("sourceSites", [])}
new_targets = [t for t in ex.get("targetSites", []) if t in ids]
if local.get("targetSites") != new_targets:
    local["targetSites"] = new_targets
    changed = True
if changed:
    json.dump(local, open("Config/boxsend.json", "w"), ensure_ascii=False, indent=2)
    open("Config/boxsend.json", "a").write("\n")
    print("  已更新 Config/boxsend.json（站点 overrides / targetSites）")
else:
    print("  Config/boxsend.json 已是最新")
PYEOF_CFG
fi
swift build -c release
install -m 755 .build/release/BoxSend /usr/local/bin/box-send
box-send sites | head -3
log "box-send 已安装到 /usr/local/bin/box-send"

# 5) systemd 服务: Gist cookie 自动同步（常驻轮询）+ Web 配置控制台
# WorkingDirectory 指向实际仓库位置
for u in gistsync web; do
  sed "s|^WorkingDirectory=.*|WorkingDirectory=$REPO_DIR|" "deploy/boxsend-${u}.service" \
    > "/etc/systemd/system/boxsend-${u}.service"
done
systemctl daemon-reload
log "配置 systemd 服务（先不启动，等 Config/boxsend.json 填好 gistSync + downloader 后再启用）:"
echo "    systemctl enable --now boxsend-gistsync"
echo "    systemctl enable --now boxsend-web   # Web 控制台 http://127.0.0.1:8088"

echo
echo "部署完成。下一步:"
echo "  1) 编辑 /opt/box-send/Config/boxsend.json（gistSync + downloader），或启动 web 控制台后在网页上改"
echo "  2) 手动验证:  box-send gist-sync"
echo "  3) 启动常驻同步: systemctl enable --now boxsend-gistsync"
echo "  4) 启动 Web 控制台: systemctl enable --now boxsend-web"
echo "     本机访问: http://127.0.0.1:8088"
echo "     Mac 远程访问: ssh -L 8088:127.0.0.1:8088 user@vps 然后浏览器开 http://127.0.0.1:8088"
