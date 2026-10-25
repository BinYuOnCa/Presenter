#!/bin/bash
# 编译 Presenter.app（只需做一次；改了 presenter.swift 才需要重新编译）
# 生成的是通用版本（M 系列芯片和 Intel 都能运行，macOS 10.15 及以上），
# 可以在一台有 Xcode 的 Mac 上编译，然后拷到别的 Mac 上运行。
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

BUILT=()
for ARCH in arm64 x86_64; do
  echo "▶ 正在编译 $ARCH …"
  if xcrun swiftc -O -swift-version 5 \
       -target "${ARCH}-apple-macos10.15" \
       -framework Cocoa -framework WebKit -framework PDFKit -framework Carbon \
       presenter.swift -o "$TMP/Presenter-$ARCH"; then
    BUILT+=("$TMP/Presenter-$ARCH")
  else
    echo "⚠️  $ARCH 编译失败"
  fi
done

if [ ${#BUILT[@]} -eq 0 ]; then
  echo "❌ 编译失败，请把上面的错误信息发给我"
  exit 1
fi
xcrun lipo -create -output "$APP/Contents/MacOS/Presenter" "${BUILT[@]}"

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
  <key>LSMinimumSystemVersion</key><string>10.15</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "✅ 已生成 $HERE/$APP（$(xcrun lipo -archs "$APP/Contents/MacOS/Presenter")）"

# 打一个可以直接拷到别的 Mac 的压缩包（ditto 会完整保留 App 的签名）
ZIP="$(dirname "$HERE")/Presenter-ready.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$HERE" "$ZIP"
echo "📦 拷到别的 Mac 用：$ZIP"
echo
echo "   本机彩排：open Presenter.app --args --test --countdown 10"
echo "   正式：双击 Presenter.app（10:25 之前打开即可）"
