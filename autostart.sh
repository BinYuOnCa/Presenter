#!/bin/bash
# 用 crontab 定时自动启动 Presenter（默认每周日 09:09）。
# 用法：
#   bash autostart.sh on                 # 每周日 09:09 自动启动
#   bash autostart.sh on 14:05 daily     # 自定时间和星期：sun mon tue wed thu fri sat，或 daily（每天）
#   bash autostart.sh status             # 查看当前设置
#   bash autostart.sh off                # 取消
# 先用 status/on 14:05 daily 这类近几分钟的时间测试一次，确认能自动打开，再改回 on。
# 注意：到时 Mac 必须开机、已登录且没有锁屏（合盖睡眠时 cron 不会运行，错过不补）。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/Presenter.app"
TAG="# Presenter-autostart"

current() { crontab -l 2>/dev/null || true; }

remove_old_launchd() {
  # 旧版 autostart.sh 用的是 launchd，删掉以免重复启动
  local label="local.presenter.autostart"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
}

case "${1:-}" in
  on)
    [ -d "$APP" ] || { echo "❌ 找不到 $APP"; exit 1; }
    TIME="${2:-09:09}"
    DAY="${3:-sun}"
    if ! [[ "$TIME" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then echo "❌ 时间写法：09:09"; exit 1; fi
    H=$((10#${TIME%%:*}))
    M=$((10#${TIME##*:}))
    if [ "$H" -gt 23 ] || [ "$M" -gt 59 ]; then echo "❌ 时间不对：$TIME"; exit 1; fi
    case "$DAY" in
      sun) WD=0 ;; mon) WD=1 ;; tue) WD=2 ;; wed) WD=3 ;; thu) WD=4 ;; fri) WD=5 ;; sat) WD=6 ;;
      daily) WD='*' ;;
      *) echo "❌ 星期写法：sun mon tue wed thu fri sat daily"; exit 1 ;;
    esac
    # 先结束可能还在运行的旧实例（例如彩排没退出），再启动；结果记到 cron.log
    CMD="/usr/bin/killall Presenter >/dev/null 2>&1; sleep 2; /usr/bin/open -g \"$APP\" >> \"$DIR/cron.log\" 2>&1 && echo \"\$(date) 已启动\" >> \"$DIR/cron.log\""
    LINE="$M $H * * $WD $CMD $TAG"
    OTHERS="$(current | grep -vF "$TAG" || true)"   # 先读出现有的其他任务，保留不动
    { [ -n "$OTHERS" ] && printf '%s\n' "$OTHERS"; printf '%s\n' "$LINE"; } | crontab -
    remove_old_launchd
    printf '✅ 已设置 crontab：%s %02d:%02d 自动启动 Presenter\n' "$DAY" "$H" "$M"
    echo "   查看：crontab -l    启动记录：$DIR/cron.log"
    ;;
  off)
    OTHERS="$(current | grep -vF "$TAG" || true)"
    if [ -n "$OTHERS" ]; then printf '%s\n' "$OTHERS" | crontab -; else crontab -r 2>/dev/null || true; fi
    remove_old_launchd
    echo "✅ 已取消自动启动"
    ;;
  status)
    if current | grep -F "$TAG"; then
      echo "（分 时 日 月 星期；星期 0 = 周日）"
    else
      echo "未设置自动启动"
    fi
    ;;
  *)
    sed -n '2,10p' "$0"
    ;;
esac
