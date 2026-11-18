#!/bin/bash
# 旧的入口，保留以兼容以前的说明。现在请用：./presenter.sh autostart on|off|status
exec "$(cd "$(dirname "$0")" && pwd)/presenter.sh" autostart "$@"
