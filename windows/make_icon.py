#!/usr/bin/env python3
"""从 build/AppIcon.iconset 里的 PNG 生成 Windows 图标 windows/BoxSend.Windows/boxsend.ico。

ICO 里直接塞 PNG（Vista 起支持），所以不需要额外的图像库：
mac 换图标 -> 重跑 scripts/make-app.sh 生成 iconset -> 再跑这个脚本，两端图标就一致。
"""
import struct
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
src = root / "build" / "AppIcon.iconset"
dst = root / "windows" / "BoxSend.Windows" / "boxsend.ico"

# (文件, 声明尺寸) —— 超过 256 的条目在 ICO 头里放不下，交给系统缩放
wanted = [
    ("icon_16x16.png", 16),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_256x256.png", 256),
]

entries = []
for name, size in wanted:
    path = src / name
    if not path.exists():
        print(f"跳过 {name}（不存在）", file=sys.stderr)
        continue
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"{path} 不是 PNG")
    entries.append((size, data))

if not entries:
    sys.exit(f"找不到 {src} 里的图标，请先跑 scripts/make-app.sh")

# 目录项必须全部排在前面，图片数据紧跟其后
header_size = 6 + 16 * len(entries)
dirs = [struct.pack("<HHH", 0, 1, len(entries))]
blobs = []
offset = header_size
for size, data in entries:
    wh = 0 if size >= 256 else size          # 字节 0 表示 256
    dirs.append(struct.pack("<BBBBHHII", wh, wh, 0, 0, 1, 32, len(data), offset))
    blobs.append(data)
    offset += len(data)

dst.write_bytes(b"".join(dirs + blobs))
print(f"{dst}  {dst.stat().st_size} 字节，包含 " + ", ".join(f"{s}px" for s, _ in entries))
