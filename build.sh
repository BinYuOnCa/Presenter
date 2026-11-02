#!/bin/bash
# 编译 Presenter.app（只需做一次；改了 presenter.swift 才需要重新编译）
# 生成 Apple 芯片（M1 及以后）版本，需 macOS 11 及以上。
# 可以在一台有 Xcode 的 Mac 上编译，然后拷到别的 Apple 芯片 Mac 上运行。
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "❌ 没有找到 Swift 编译器。请先在“终端”里运行：xcode-select --install"
  echo "   （已装 Xcode 的话，运行：sudo xcode-select -s /Applications/Xcode.app）"
  exit 1
fi

APP="Presenter.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "▶ 正在编译（Apple 芯片 arm64）…"
if ! xcrun swiftc -O -swift-version 5 \
     -target arm64-apple-macos11.0 \
     -framework Cocoa -framework WebKit -framework PDFKit -framework Carbon \
     presenter.swift -o "$TMP/Presenter"; then
  echo "❌ 编译失败，请把上面的错误信息发给我"
  exit 1
fi
cp "$TMP/Presenter" "$APP/Contents/MacOS/Presenter"

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
  <key>CFBundleShortVersionString</key><string>2.1</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDownloadsFolderUsageDescription</key><string>Presenter 需要读取“下载”文件夹里当天的 PDF。</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "✅ 已生成 $HERE/$APP"

# 打一个可以直接拷到别的 Mac 的压缩包（ditto 会完整保留 App 的签名）
ZIP="$(dirname "$HERE")/Presenter-ready.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$HERE" "$ZIP"
echo "📦 拷到别的 Mac 用：$ZIP"
echo
echo "   彩排：killall Presenter; open Presenter.app --args --test"
echo "   注意：每次重新编译后，第一次运行时系统会询问能否读取“下载”文件夹，请点“好/允许”。"
echo "   自动启动：bash autostart.sh on（每周日 9:09）"
