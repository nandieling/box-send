#!/usr/bin/env bash
# 打包 macOS GUI 应用: dist/BoxSend.app
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=dist/BoxSend.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BoxSendApp "$APP/Contents/MacOS/BoxSendApp"
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
	<string>0.2</string>
	<key>CFBundleShortVersionString</key>
	<string>0.2</string>
	<key>CFBundleExecutable</key>
	<string>BoxSendApp</string>
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
codesign --force --sign - "$APP"
echo "构建完成: $APP"
echo "运行: open $APP"
