#!/bin/bash
# Presenter 日常操作（在 Presenter 文件夹里运行，例如 ~/Presenter/presenter.sh test）
#
#   ./presenter.sh test [日期] [参数…]   彩排（测试模式）。日期：tomorrow（明天）或 20261122；
#                                       其他参数原样传给 Presenter，例如 --apple --pdftime 300
#   ./presenter.sh start                 正式启动（和自动启动一样）
#   ./presenter.sh stop                  退出 Presenter
#   ./presenter.sh autostart on [09:09] [sun|mon|…|daily]   用 crontab 定时自动启动（默认每周日 09:09）
#   ./presenter.sh autostart off|status  取消 / 查看自动启动
#   ./presenter.sh update                从 GitHub 的 release 分支更新到最新版本
#   ./presenter.sh review [20261115]     复查字幕记录（默认最近一次）
#   ./presenter.sh log                   看实时日志（Ctrl+C 结束）
#
# 自动启动：到时 Mac 必须开机、已登录且没有锁屏（合盖睡眠时 cron 不会运行，错过不补）。
# 先用 autostart on 14:05 daily 这类近几分钟的时间测试一次，确认能自动打开，再改回 on。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/Presenter.app"
TAG="# Presenter-autostart"
REPO_URL="${PRESENTER_REPO:-https://github.com/BinYuOnCa/Presenter.git}"
BRANCH="${PRESENTER_BRANCH:-release}"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }
need_app() { [ -d "$APP" ] || { echo "❌ 找不到 $APP"; exit 1; }; }
running() { pgrep -x Presenter >/dev/null 2>&1; }
stop_app() {
  if running; then
    /usr/bin/killall Presenter 2>/dev/null || true
    for _ in 1 2 3 4 5; do running || break; sleep 1; done
  fi
}

# ---------- crontab ----------
current_cron() { crontab -l 2>/dev/null || true; }
remove_old_launchd() {
  # 旧版 autostart.sh 用的是 launchd，删掉以免重复启动
  local label="local.presenter.autostart"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
}
autostart() {
  case "${1:-}" in
    on)
      need_app
      local TIME="${2:-09:09}" DAY="${3:-sun}" H M WD
      if ! [[ "$TIME" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then echo "❌ 时间写法：09:09"; exit 1; fi
      H=$((10#${TIME%%:*})); M=$((10#${TIME##*:}))
      if [ "$H" -gt 23 ] || [ "$M" -gt 59 ]; then echo "❌ 时间不对：$TIME"; exit 1; fi
      case "$DAY" in
        sun) WD=0 ;; mon) WD=1 ;; tue) WD=2 ;; wed) WD=3 ;; thu) WD=4 ;; fri) WD=5 ;; sat) WD=6 ;;
        daily) WD='*' ;;
        *) echo "❌ 星期写法：sun mon tue wed thu fri sat daily"; exit 1 ;;
      esac
      # 先结束可能还在运行的旧实例（例如彩排没退出），再启动；结果记到 cron.log
      local CMD="/usr/bin/killall Presenter >/dev/null 2>&1; sleep 2; /usr/bin/open -g \"$APP\" >> \"$DIR/cron.log\" 2>&1 && echo \"\$(date) 已启动\" >> \"$DIR/cron.log\""
      local LINE="$M $H * * $WD $CMD $TAG"
      local OTHERS; OTHERS="$(current_cron | grep -vF "$TAG" || true)"   # 现有的其他任务保留不动
      { [ -n "$OTHERS" ] && printf '%s\n' "$OTHERS"; printf '%s\n' "$LINE"; } | crontab -
      remove_old_launchd
      printf '✅ 已设置 crontab：%s %02d:%02d 自动启动 Presenter\n' "$DAY" "$H" "$M"
      echo "   查看：./presenter.sh autostart status    启动记录：$DIR/cron.log"
      ;;
    off)
      local OTHERS; OTHERS="$(current_cron | grep -vF "$TAG" || true)"
      if [ -n "$OTHERS" ]; then printf '%s\n' "$OTHERS" | crontab -; else crontab -r 2>/dev/null || true; fi
      remove_old_launchd
      echo "✅ 已取消自动启动"
      ;;
    status)
      if current_cron | grep -F "$TAG"; then echo "（分 时 日 月 星期；星期 0 = 周日）"; else echo "未设置自动启动"; fi
      ;;
    *) usage; exit 1 ;;
  esac
}

# ---------- 更新 ----------
# 被跟踪的文件如果在本机改过，更新前先备份成 文件名.bak（本机的设置应写在 *-local.* 里）
backup_changed() {
  local target="$1" has_head="$2" f local_hash base_hash
  while IFS= read -r f; do
    case "$f" in Presenter.app/*) continue ;; esac
    [ -f "$DIR/$f" ] || continue
    local_hash="$(git hash-object "$DIR/$f")"
    if [ "$has_head" = 1 ]; then
      base_hash="$(git rev-parse -q --verify "HEAD:$f" 2>/dev/null || true)"
    else
      base_hash="$(git rev-parse -q --verify "$target:$f" 2>/dev/null || true)"
    fi
    if [ "$local_hash" != "$base_hash" ]; then
      cp -p "$DIR/$f" "$DIR/$f.bak"
      echo "   ⚠️ $f 在本机改过，已备份为 $f.bak（以后请把改动写进对应的 *-local 文件）"
    fi
  done < <(git ls-tree -r --name-only "$target")
}
update() {
  if ! git --version >/dev/null 2>&1; then
    echo "❌ 这台 Mac 还没有 git。请先运行：xcode-select --install（安装命令行工具），再运行一次。"
    exit 1
  fi
  cd "$DIR"
  if [ ! -d .git ]; then
    echo "▶ 第一次更新：把这个文件夹接到 $REPO_URL 的 $BRANCH 分支"
    git init -q
    git remote add origin "$REPO_URL"
  fi
  echo "▶ 下载最新版本…"
  git fetch -q --depth 1 origin "$BRANCH"
  local NEW HAS_HEAD=0
  NEW="$(git rev-parse FETCH_HEAD)"
  if git rev-parse -q --verify HEAD >/dev/null; then
    HAS_HEAD=1
    if [ "$(git rev-parse HEAD)" = "$NEW" ]; then
      echo "✅ 已经是最新版本：$(git log -1 --format='%s')"
      return
    fi
  fi
  if running; then
    read -r -p "Presenter 正在运行，更新要先退出它。继续吗？[y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "已取消"; exit 1; }
    stop_app
  fi
  backup_changed "$NEW" "$HAS_HEAD"
  git checkout -q -f -B "$BRANCH" "$NEW"
  git branch -q --set-upstream-to="origin/$BRANCH" 2>/dev/null || true
  # 只保留当前版本，旧版本占的空间释放掉
  git reflog expire --expire=now --all
  git gc -q --prune=now 2>/dev/null || true
  echo "✅ 已更新到：$(git log -1 --format='%s（%cd）' --date=format:'%Y-%m-%d %H:%M')"
  echo "   ⚠️ 请先手动彩排一次：./presenter.sh test tomorrow"
  echo "      新版本第一次运行时，系统会再问能否访问“下载”文件夹、麦克风等，都点“允许”；"
  echo "      不先点允许，周日自动启动时会卡在这个询问上。"
}

# ---------- 主程序 ----------
cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  test)
    need_app
    args=(--test)
    case "${1:-}" in
      tomorrow|明天) args+=(--date "$(date -v+1d +%Y%m%d)"); shift ;;
      today|今天) shift ;;
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) args+=(--date "$1"); shift ;;
    esac
    stop_app
    echo "▶ 彩排：open Presenter.app --args ${args[*]} $*"
    /usr/bin/open "$APP" --args "${args[@]}" "$@"
    ;;
  start)
    need_app; stop_app; /usr/bin/open -g "$APP"; echo "✅ 已启动" ;;
  stop)
    stop_app; echo "✅ 已退出" ;;
  autostart)
    autostart "$@" ;;
  update)
    update ;;
  review)
    need_app; /usr/bin/open "$APP" --args --review "$@" ;;
  log)
    touch "$DIR/presenter.log"; tail -n 50 -f "$DIR/presenter.log" ;;
  *)
    usage; [ -z "$cmd" ] || exit 1 ;;
esac
