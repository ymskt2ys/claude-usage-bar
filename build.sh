#!/bin/bash
# ClaudeUsageBar.app をビルドする。Xcode プロジェクト不要、swiftc だけ。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClaudeUsageBar"
BUNDLE_ID="jp.subtonic.claudeusagebar"
APP="build/${APP_NAME}.app"

rm -rf build
mkdir -p "${APP}/Contents/MacOS"

swiftc \
  -O \
  -parse-as-library \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -o "${APP}/Contents/MacOS/${APP_NAME}" \
  Sources/Usage.swift Sources/App.swift

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Dock にアイコンを出さない (メニューバー常駐) -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# 署名を固定しておかないと、ビルドのたびに Keychain のアクセス許可を訊かれる。
codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP}"

echo "built: ${APP}"
