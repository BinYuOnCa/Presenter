#!/bin/bash
# 编译 Presenter.app（改了 presenter.swift 才需要重新编译）
# 生成 Apple 芯片（M1 及以后）版本，需 macOS 11 及以上。
#
#   ./build.sh                 编译，并打包 Presenter-ready.zip（只含发布文件，不含 *-local.*、凭证、日志）
#   ./build.sh --release       编译后发布到 GitHub 的 release 分支（只保留最近 10 个版本），
#                              直播电脑上运行 ./presenter.sh update 就能更新
#   ./build.sh --release --no-push   只在本地生成 release 提交，不推送
#   环境变量：KEEP_RELEASES=10（保留几个版本）、FORCE=1（有未提交的修改也发布）
#   版本号：VERSION 手动改；BUILD 自动算（见下面），源代码提交号和上一个发布版本不同时自动 +1
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"

VERSION="2.5"
BUILD_START="7"     # 找不到上一个发布版本时用的 BUILD
BRANCH="release"
KEEP="${KEEP_RELEASES:-10}"

RELEASE=0
PUSH=1
for a in "$@"; do
  case "$a" in
    --release) RELEASE=1 ;;
    --no-push) PUSH=0 ;;
    *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
  esac
done

# ---------- BUILD：从上一个发布版本的提交说明“Presenter 2.5 (7) · 源代码 main@956c250”算出来 ----------
#   源代码提交号和上一个发布版本相同（且没有未提交的修改）→ BUILD 不变；不同 → +1；
#   VERSION 改了 → 从 1 开始；找不到上一个发布版本 → BUILD_START
[ "$RELEASE" = 1 ] && { git fetch -q origin "$BRANCH" 2>/dev/null || true; }
LAST_REF="$(git rev-parse -q --verify "refs/remotes/origin/$BRANCH" || git rev-parse -q --verify "refs/heads/$BRANCH" || true)"
LAST_MSG="$( [ -n "$LAST_REF" ] && git log -1 --format=%s "$LAST_REF" || true)"
LAST_VER="$(printf '%s' "$LAST_MSG" | sed -n 's/^Presenter \([^ ]*\) (\([0-9]*\)) .*/\1/p')"
LAST_BUILD="$(printf '%s' "$LAST_MSG" | sed -n 's/^Presenter \([^ ]*\) (\([0-9]*\)) .*/\2/p')"
LAST_SRC="$(printf '%s' "$LAST_MSG" | sed -n 's/.*@\([0-9a-f]\{7,\}\).*/\1/p')"
DIRTY="$(git status --porcelain --untracked-files=no)"
SAME_SRC=0
if [ -n "$LAST_SRC" ] && [ -z "$DIRTY" ] && \
   [ "$(git rev-parse -q --verify "$LAST_SRC^{commit}" 2>/dev/null || true)" = "$(git rev-parse HEAD)" ]; then
  SAME_SRC=1
fi
if [ -z "$LAST_BUILD" ]; then
  BUILD="$BUILD_START"; WHY="找不到上一个发布版本，用 BUILD_START"
elif [ "$LAST_VER" != "$VERSION" ]; then
  BUILD=1; WHY="VERSION 从 ${LAST_VER} 改成 ${VERSION}，BUILD 从 1 开始"
elif [ "$SAME_SRC" = 1 ]; then
  BUILD="$LAST_BUILD"; WHY="源代码和上一个发布版本相同（@${LAST_SRC}）"
else
  BUILD=$((LAST_BUILD + 1)); WHY="上一个发布版本是 (${LAST_BUILD}) @${LAST_SRC}，源代码变了"
fi
echo "▶ 版本 ${VERSION} (${BUILD})：${WHY}"

# 发布哪些文件（Presenter.app 之外）。这里没有的文件（*-local.*、rclone、凭证、日志、字幕记录）都不会发布或打包。
RELEASE_FILES=(
  config.json
  config-local.example.json
  stage.html
  glossary.csv
  glossary-bible.csv
  presenter.sh
  autostart.sh
  README.md
  OP_Manual.md
  "images/把LogoNew.png放这里.txt"
  pdf/sample.pdf
  tools/presenter-upload.gs
)

if [ "$RELEASE" = 1 ]; then
  if [ -n "$(git status --porcelain --untracked-files=no)" ] && [ "${FORCE:-}" != 1 ]; then
    echo "❌ 有未提交的修改。请先提交，这样每个发布版本都能对应到一个源代码版本（确实要发布就加 FORCE=1）。"
    exit 1
  fi
fi

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "❌ 没有找到 Swift 编译器。请先在“终端”里运行：xcode-select --install"
  echo "   （已装 Xcode 的话，运行：sudo xcode-select -s /Applications/Xcode.app）"
  exit 1
fi

APP="Presenter.app"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/presenter-build.XXXXXX")"
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
     -framework Cocoa -framework WebKit -framework PDFKit -framework Carbon -framework Network \
     ${EXTRA[@]+"${EXTRA[@]}"} \
     presenter.swift -o "$TMP/Presenter"; then
  echo "❌ 编译失败，请把上面的错误信息发给我"
  exit 1
fi
cp "$TMP/Presenter" "$APP/Contents/MacOS/Presenter"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.presenter</string>
  <key>CFBundleName</key><string>Presenter</string>
  <key>CFBundleDisplayName</key><string>Presenter</string>
  <key>CFBundleExecutable</key><string>Presenter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
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

# ---------- 准备发布文件（打包和 release 分支用同一份） ----------
STAGE="$TMP/stage/Presenter"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
for f in "${RELEASE_FILES[@]}"; do
  [ -f "$f" ] || { echo "❌ 缺少发布文件：$f"; exit 1; }
  mkdir -p "$STAGE/$(dirname "$f")"
  cp -p "$f" "$STAGE/$f"
done
chmod +x "$STAGE/presenter.sh" "$STAGE/autostart.sh"
cat > "$STAGE/.gitignore" <<'IGN'
# 这台电脑自己的文件：presenter.sh update 不会动它们
*-local.*
!*-local.example.*
images/LogoNew.png
rclone
bin/
gdrive-sa.json
*-sa.json
*.key.json
presenter.log
cron.log
hotkey-usage.csv
upload-state.json
gdrive-state.json
transcripts/
caption-dump-*
terms-*.csv
terms-*.txt
config.old.json
*.bak
.DS_Store
IGN
cat > "$STAGE/.gitattributes" <<'ATT'
Presenter.app/** -text -diff
*.pdf binary
*.png binary
ATT
if find "$STAGE" -type l | grep -q .; then echo "❌ 发布文件里有符号链接，git 发布不支持"; exit 1; fi

# 打一个可以直接拷到别的 Mac 的压缩包（ditto 会完整保留 App 的签名）
ZIP="$HERE/Presenter-ready.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$STAGE" "$ZIP"
echo "📦 压缩包（不含 *-local.*、凭证）：$ZIP"

# ---------- 发布到 release 分支 ----------
if [ "$RELEASE" = 1 ]; then
  echo "▶ 发布到 $BRANCH 分支（保留最近 $KEEP 个版本）…"
  git fetch -q origin "$BRANCH" 2>/dev/null || true
  OLD_REMOTE="$(git rev-parse -q --verify "refs/remotes/origin/$BRANCH" || true)"
  PARENT="$OLD_REMOTE"
  [ -n "$PARENT" ] || PARENT="$(git rev-parse -q --verify "refs/heads/$BRANCH" || true)"

  # 用临时 index 把发布文件做成一个提交，不切换分支、不动当前工作区
  export GIT_INDEX_FILE="$TMP/release-index"
  git read-tree --empty
  ( cd "$STAGE" && find . -type f ) | sed 's|^\./||' | sort | while IFS= read -r f; do
    mode=100644; [ -x "$STAGE/$f" ] && mode=100755
    git update-index --add --cacheinfo "$mode,$(git hash-object -w -- "$STAGE/$f"),$f"
  done
  TREE="$(git write-tree)"
  unset GIT_INDEX_FILE

  if [ -n "$PARENT" ] && [ "$(git rev-parse "$PARENT^{tree}")" = "$TREE" ]; then
    echo "ℹ️ 和上一个发布版本完全一样，不用发布"
    exit 0
  fi
  SRC="$(git rev-parse --short HEAD)"
  [ -z "$(git status --porcelain --untracked-files=no)" ] || SRC="$SRC+未提交的修改"
  MSG="Presenter $VERSION ($BUILD) · 源代码 $(git rev-parse --abbrev-ref HEAD)@$SRC"
  NEW="$(git commit-tree "$TREE" ${PARENT:+-p "$PARENT"} -m "$MSG")"

  # 只保留最近 KEEP 个版本：把最近 KEEP 个提交重新串起来，最旧的那个没有父提交
  TOTAL="$(git rev-list --count --first-parent "$NEW")"
  if [ "$TOTAL" -gt "$KEEP" ]; then
    KEPT=()
    while IFS= read -r c; do KEPT+=("$c"); done < <(git rev-list --first-parent --max-count="$KEEP" --reverse "$NEW")
    P=""
    for c in "${KEPT[@]}"; do
      P="$(
        GIT_AUTHOR_NAME="$(git log -1 --format=%an "$c")" GIT_AUTHOR_EMAIL="$(git log -1 --format=%ae "$c")" \
        GIT_AUTHOR_DATE="$(git log -1 --format=%aD "$c")" GIT_COMMITTER_DATE="$(git log -1 --format=%cD "$c")" \
        git commit-tree "$(git rev-parse "$c^{tree}")" ${P:+-p "$P"} -m "$(git log -1 --format=%B "$c")"
      )"
    done
    NEW="$P"
    echo "   共 $TOTAL 个版本，删掉最旧的 $((TOTAL - KEEP)) 个"
  fi
  git update-ref "refs/heads/$BRANCH" "$NEW"
  echo "✅ 本地 $BRANCH 分支：$MSG"

  if [ "$PUSH" = 1 ]; then
    # force-with-lease：只在远程还是我们刚看到的那个版本时才覆盖（删旧版本需要强推）
    git push --force-with-lease="$BRANCH:$OLD_REMOTE" origin "$BRANCH"
    echo "🚀 已推送。直播电脑上运行：~/Presenter/presenter.sh update"
  else
    echo "   推送：git push --force-with-lease=$BRANCH:$OLD_REMOTE origin $BRANCH"
  fi
  if ! git branch -r --contains HEAD 2>/dev/null | grep -q .; then
    echo "   ⚠️ 源代码 $SRC 还没推送到 GitHub，记得 git push（以后要重新编译这个版本时用得到）"
  fi
fi

echo
echo "   彩排：./presenter.sh test tomorrow"
echo "   注意：每次重新编译后，第一次运行时系统会询问能否读取“下载”文件夹，请点“好/允许”。"
echo "         第一次使用本机识别时，还会询问“麦克风”和“语音识别”权限，也请点“允许”。"
echo "   自动启动：./presenter.sh autostart on 09:09（每周日 9:09）"
echo "   复查字幕记录：./presenter.sh review（最近一天；或 review 20261115）"
echo "   OBS 字幕页：http://127.0.0.1:8765/caption（OBS › 来源 › 浏览器）"
