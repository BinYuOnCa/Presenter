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

SDKV="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo 0)"
SDKMAJOR="${SDKV%%.*}"
EXTRA=()
if [ "${SDKMAJOR:-0}" -ge 26 ] 2>/dev/null; then
  # 本机语音识别 + 翻译（macOS 26 的新功能）
  EXTRA=(-framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework Speech -framework Translation)
  echo "▶ macOS SDK ${SDKV}：包含本机识别 + 翻译"
else
  echo "⚠️  macOS SDK ${SDKV}（低于 26）：这次编译不包含本机识别功能。要用本机识别，请把 Xcode 更新到 26 以上。"
fi

echo "▶ 正在编译（Apple 芯片 arm64）…"
if ! xcrun swiftc -O -swift-version 5 \
     -target arm64-apple-macos11.0 \
     -framework Cocoa -framework WebKit -framework PDFKit -framework Carbon \
     ${EXTRA[@]+"${EXTRA[@]}"} \
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
  <key>CFBundleShortVersionString</key><string>2.2</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDownloadsFolderUsageDescription</key><string>Presenter 需要读取“下载”文件夹里当天的 PDF。</string>
  <key>NSMicrophoneUsageDescription</key><string>Presenter 需要听音频输入，把讲话实时转成字幕。</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Presenter 在本机把讲话转成文字，显示成字幕。</string>
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
echo "         第一次使用本机识别时，还会询问“麦克风”和“语音识别”权限，也请点“允许”。"
echo "   自动启动：bash autostart.sh on 09:05（每周日 9:05）"
