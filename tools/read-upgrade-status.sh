#!/usr/bin/env bash
# dsh-nas 受限升级状态读取器
# 供已认证管理页通过精确 sudo 白名单读取；不接受参数，不执行 Docker。
set -uo pipefail
umask 077

CONTROL_DIR=/var/lib/dsh-nas-upgrade
STATE_FILE="$CONTROL_DIR/upgrade-status.json"

[ "$(id -u)" -eq 0 ] || {
  printf '{"version":1,"status":"error","message":"root required"}\n'
  exit 1
}
[ "$#" -eq 0 ] || {
  printf '{"version":1,"status":"error","message":"arguments not allowed"}\n'
  exit 2
}
[ -d "$CONTROL_DIR" ] && [ ! -L "$CONTROL_DIR" ] || {
  printf '{"version":1,"status":"unknown","message":"status directory unavailable"}\n'
  exit 0
}
[ "$(stat -c '%u:%a' "$CONTROL_DIR" 2>/dev/null || echo invalid)" = "0:700" ] || {
  printf '{"version":1,"status":"error","message":"status directory permissions invalid"}\n'
  exit 1
}
if [ ! -e "$STATE_FILE" ]; then
  printf '{"version":1,"status":"unknown","message":"no upgrade has run"}\n'
  exit 0
fi
[ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] \
  && [ "$(stat -c '%u:%a' "$STATE_FILE" 2>/dev/null || echo invalid)" = "0:600" ] || {
  printf '{"version":1,"status":"error","message":"status file permissions invalid"}\n'
  exit 1
}
cat "$STATE_FILE"
