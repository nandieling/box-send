#!/usr/bin/env bash
# 打包 macOS GUI 应用: dist/BoxSend.app
set -euo pipefail
cd "$(dirname "$0")/.."

# 版本号唯一来源：Sources/BoxSendKit/Util/Version.swift
VERSION=$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' Sources/BoxSendKit/Util/Version.swift | head -1)
: "${VERSION:?读不到版本号（Sources/BoxSendKit/Util/Version.swift）}"

swift build -c release
APP=dist/BoxSend.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BoxSendApp "$APP/Contents/MacOS/BoxSendApp"

# 应用图标: 1.webp -> AppIcon.icns（缺失时跳过，保持无图标构建）
if [[ -f 1.webp ]]; then
    ICONSET=build/AppIcon.iconset
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
                "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
                "512:512x512" "1024:512x512@2x"; do
        sips -s format png -z "${spec%%:*}" "${spec%%:*}" 1.webp --out "$ICONSET/icon_${spec##*:}.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# 使用教程配图
if ls Resources/tutorial/*.jpg >/dev/null 2>&1; then
    mkdir -p "$APP/Contents/Resources/tutorial"
    cp Resources/tutorial/*.jpg "$APP/Contents/Resources/tutorial/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST' 
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>BoxSend</string>
	<key>CFBundleDisplayName</key>
	<string>BoxSend</string>
	<key>CFBundleIdentifier</key>
	<string>com.nan.boxsend</string>
	<key>CFBundleVersion</key>
	<string>__VERSION__</string>
	<key>CFBundleShortVersionString</key>
	<string>__VERSION__</string>
	<key>CFBundleExecutable</key>
	<string>BoxSendApp</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
</dict>
</plist>
PLIST
sed -i '' "s/__VERSION__/${VERSION}/" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "构建完成: $APP"
echo "运行: open $APP"
