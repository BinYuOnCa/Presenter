#!/bin/bash
# （可选）每周定时自动打开 Presenter，省得手动双击。
# 用法：
#   bash autostart.sh on                # 每周日 10:10 自动打开
#   bash autostart.sh on 09:50 sun      # 自定时间和星期：sun mon tue wed thu fri sat，或 daily（每天）
#   bash autostart.sh off               # 取消
# 注意：Mac 必须开机并已登录；若那时在睡眠，会在唤醒后补开。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/Presenter.app"
LABEL="local.presenter.autostart"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

case "${1:-}" in
  on)
    [ -d "$APP" ] || { echo "❌ 找不到 $APP，请先运行 bash build.sh"; exit 1; }
    TIME="${2:-10:10}"
    DAY="${3:-sun}"
    H=$((10#${TIME%%:*}))
    M=$((10#${TIME##*:}))
    case "$DAY" in
      sun) WD=0 ;; mon) WD=1 ;; tue) WD=2 ;; wed) WD=3 ;; thu) WD=4 ;; fri) WD=5 ;; sat) WD=6 ;;
      daily) WD="" ;;
      *) echo "❌ 星期写法：sun mon tue wed thu fri sat daily"; exit 1 ;;
    esac
    WDXML=""
    [ -n "$WD" ] && WDXML="<key>Weekday</key><integer>$WD</integer>"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>-g</string><string>$APP</string></array>
  <key>StartCalendarInterval</key>
  <dict>$WDXML<key>Hour</key><integer>$H</integer><key>Minute</key><integer>$M</integer></dict>
</dict>
</plist>
EOF
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    printf '✅ 已设置：%s %02d:%02d 自动打开 Presenter\n' "${DAY}" "$H" "$M"
    ;;
  off)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "✅ 已取消自动打开"
    ;;
  *)
    sed -n '2,8p' "$0"
    ;;
esac
