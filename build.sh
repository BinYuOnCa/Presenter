#!/bin/bash
# 编译 Presenter.app（只需做一次；改了 presenter.swift 才需要重新编译）
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "❌ 没有找到 Swift 编译器。请先在“终端”里运行：xcode-select --install"
  echo "   装完（约 5–15 分钟）后再运行：bash build.sh"
  exit 1
fi

ARCH="$(uname -m)"          # arm64（M 系列芯片）或 x86_64（Intel）
APP="Presenter.app"
echo "▶ 正在编译（$ARCH）…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

xcrun swiftc -O -swift-version 5 \
  -target "${ARCH}-apple-macos11.0" \
  -framework Cocoa -framework WebKit -framework PDFKit -framework Carbon \
  presenter.swift -o "$APP/Contents/MacOS/Presenter"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.presenter</string>
  <key>CFBundleName</key><string>Presenter</string>
  <key>CFBundleDisplayName</key><string>Presenter</string>
  <key>CFBundleExecutable</key><string>Presenter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "✅ 已生成 $(pwd)/$APP"
echo "   彩排：open Presenter.app --args --test --countdown 10"
echo "   正式：双击 Presenter.app（10:25 之前打开即可）"
