#!/usr/bin/env bash
# dsh-nas 宿主机升级请求签发器
# 只负责创建带 HMAC 签名的 upgrade-request.json，不执行 Docker/Compose。
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
CANONICAL_PROJECT_DIR="/opt/dsh-nas"
# 网页/CLI 签发器和 systemd 处理器共享 root-only 状态目录。
CONTROL_DIR="/var/lib/dsh-nas-upgrade"
REQUEST_FILE="$CONTROL_DIR/upgrade-request.json"
KEY_FILE="$CONTROL_DIR/upgrade-request.key"
LOCK_FILE="$CONTROL_DIR/.request.lock"

usage() {
  cat <<'EOF'
用法:
  sudo bash tools/request-upgrade.sh --init-key
  sudo bash tools/request-upgrade.sh --request --action upgrade --source host-cli
  sudo bash tools/request-upgrade.sh --request --action latest --source web-admin

说明:
  --init-key  首次创建 root-only HMAC 密钥；已有密钥不会被覆盖。
  --request   原子创建一个待处理请求；请求文件已存在时拒绝覆盖。
  --action    只能是 upgrade 或 latest。
  --source    只能是 host-cli 或 web-admin。
EOF
}

die() {
  echo "错误: $*" >&2
  exit 1
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "请求签发器必须由 root 执行（网页调用应使用精确 sudo 白名单）"
}

check_root_nonsymlink_dir() {
  local path="$1" owner mode
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  owner=$(stat -c '%u' "$path" 2>/dev/null || echo -1)
  mode=$(stat -c '%a' "$path" 2>/dev/null || echo 0)
  [ "$owner" = 0 ] || return 1
  [ $((8#$mode & 0022)) -eq 0 ]
}

check_root_code_file() {
  local path="$1" owner mode
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  owner=$(stat -c '%u' "$path" 2>/dev/null || echo -1)
  mode=$(stat -c '%a' "$path" 2>/dev/null || echo 0)
  [ "$owner" = 0 ] || return 1
  [ $((8#$mode & 0022)) -eq 0 ]
}

ensure_project_path() {
  local path rel
  [ "$PROJECT_DIR" = "$CANONICAL_PROJECT_DIR" ] \
    || die "项目必须安装在 $CANONICAL_PROJECT_DIR（当前: $PROJECT_DIR）"
  [ -d "$PROJECT_DIR" ] && [ ! -L "$PROJECT_DIR" ] \
    || die "项目目录不存在或是符号链接"
  path="$PROJECT_DIR"
  while [ "$path" != "/" ]; do
    check_root_nonsymlink_dir "$path" \
      || die "项目目录及父目录必须 root-owned 且不可被 group/other 写入: $path"
    path=$(dirname "$path")
  done
  for rel in tools/request-upgrade.sh tools/process-upgrade-request.sh; do
    check_root_code_file "$PROJECT_DIR/$rel" \
      || die "请求工具必须 root-owned 且不可被 group/other 写入: $rel"
  done
}

ensure_control_dirs() {
  ensure_project_path
  mkdir -p "$CONTROL_DIR" "$CONTROL_DIR/processed" "$CONTROL_DIR/failed" \
    "$CONTROL_DIR/rejected" "$CONTROL_DIR/seen" "$CONTROL_DIR/logs" \
    || die "无法创建升级控制目录"
  chmod 700 "$CONTROL_DIR" "$CONTROL_DIR/processed" "$CONTROL_DIR/failed" \
    "$CONTROL_DIR/rejected" "$CONTROL_DIR/seen" "$CONTROL_DIR/logs" \
    || die "无法限制升级控制目录权限"
  for dir in "$CONTROL_DIR" "$CONTROL_DIR/processed" "$CONTROL_DIR/failed" \
             "$CONTROL_DIR/rejected" "$CONTROL_DIR/seen" "$CONTROL_DIR/logs"; do
    [ "$(stat -c '%u' "$dir" 2>/dev/null || echo -1)" = 0 ] \
      || die "升级控制目录必须属于 root: $dir"
    [ "$(stat -c '%a' "$dir" 2>/dev/null || echo 0)" = 700 ] \
      || die "升级控制目录必须是 0700: $dir"
  done
}

ensure_key() {
  [ -L "$KEY_FILE" ] && die "HMAC 密钥不能是符号链接"
  [ -f "$KEY_FILE" ] || die "HMAC 密钥不存在；先运行: sudo bash tools/request-upgrade.sh --init-key"
  [ "$(stat -c '%u' "$KEY_FILE" 2>/dev/null || echo -1)" = 0 ] \
    || die "HMAC 密钥必须属于 root"
  [ "$(stat -c '%a' "$KEY_FILE" 2>/dev/null || echo 0)" = 600 ] \
    || die "HMAC 密钥权限必须是 0600"
  SECRET="$(<"$KEY_FILE")"
  [[ "$SECRET" =~ ^[0-9a-f]{64}$ ]] || die "HMAC 密钥格式无效（需要 64 位十六进制）"
}

atomic_write() {
  local target="$1" tmp
  tmp=$(mktemp "$CONTROL_DIR/.request.tmp.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! cat >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  sync -d "$tmp" 2>/dev/null || sync
  mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
  sync -d "$CONTROL_DIR" 2>/dev/null || true
}

hmac_sha256() {
  # SECRET 固定为 64 位 hex；只使用 hexkey 语义，避免 OpenSSL fallback 改变 HMAC。
  local result
  result=$(printf '%s' "$1" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$SECRET" -binary 2>/dev/null \
    | od -An -tx1 | tr -d ' \n') || return 1
  [[ "$result" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$result"
}

init_key() {
  ensure_control_dirs
  if [ -e "$KEY_FILE" ]; then
    ensure_key
    echo "HMAC 密钥已存在，未覆盖: $KEY_FILE"
    return 0
  fi
  local tmp
  tmp=$(mktemp "$CONTROL_DIR/.key.tmp.XXXXXX") || die "无法创建临时密钥文件"
  chmod 600 "$tmp" || { rm -f "$tmp"; die "无法设置密钥权限"; }
  if ! openssl rand -hex 32 >"$tmp"; then
    rm -f "$tmp"
    die "无法生成 HMAC 密钥"
  fi
  sync -d "$tmp" 2>/dev/null || sync
  mv -f "$tmp" "$KEY_FILE" || { rm -f "$tmp"; die "无法安装 HMAC 密钥"; }
  chmod 600 "$KEY_FILE"
  echo "已创建 root-only HMAC 密钥: $KEY_FILE"
}

create_request() {
  local action="$1" source="$2" requested_at request_id payload signature hex
  case "$action" in upgrade|latest) ;; *) die "action 只能是 upgrade 或 latest" ;; esac
  case "$source" in host-cli|web-admin) ;; *) die "source 只能是 host-cli 或 web-admin" ;; esac
  ensure_control_dirs
  ensure_key
  exec 9>"$LOCK_FILE" || die "无法打开请求锁"
  chmod 600 "$LOCK_FILE" || die "无法限制请求锁权限"
  flock -n 9 || die "已有请求正在处理；请稍后重试"
  [ ! -L "$REQUEST_FILE" ] || die "待处理请求不能是符号链接"
  [ ! -e "$REQUEST_FILE" ] || die "已有待处理请求；请等待宿主机处理完成"
  for seen_id in "$CONTROL_DIR/seen"/*; do
    [ -e "$seen_id" ] || continue
    [ -f "$seen_id" ] && [ ! -L "$seen_id" ] \
      || die "seen 记录必须是普通 root-only 文件: $seen_id"
    [ "$(stat -c '%u:%a' "$seen_id" 2>/dev/null || echo invalid)" = "0:600" ] \
      || die "seen 记录权限异常: $seen_id"
  done

  requested_at="$(date +%s)"
  hex="$(openssl rand -hex 16)" || die "无法生成 request_id"
  request_id="${hex:0:8}-${hex:8:4}-${hex:12:4}-${hex:16:4}-${hex:20:12}"
  payload=$(printf 'version=1\naction=%s\nrequested_at=%s\nrequest_id=%s\nsource=%s' \
    "$action" "$requested_at" "$request_id" "$source")
  signature=$(hmac_sha256 "$payload")
  [[ "$signature" =~ ^[0-9a-f]{64}$ ]] || die "无法生成 HMAC 签名"

  atomic_write "$REQUEST_FILE" <<EOF || die "无法原子写入升级请求"
{"version":1,"action":"$action","requested_at":$requested_at,"request_id":"$request_id","source":"$source","signature":"$signature"}
EOF
  chmod 600 "$REQUEST_FILE"
  echo "已创建升级请求: $REQUEST_FILE"
  echo "  action=$action source=$source request_id=$request_id"
}

[ $# -gt 0 ] || { usage; exit 1; }
case "$1" in
  -h|--help) usage; exit 0 ;;
esac
require_root
MODE=""
ACTION=""
SOURCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --init-key) MODE="init-key" ;;
    --request) MODE="request" ;;
    --action)
      [ $# -ge 2 ] || die "--action 需要 upgrade 或 latest"; ACTION="$2"; shift ;;
    --source)
      [ $# -ge 2 ] || die "--source 需要 host-cli 或 web-admin"; SOURCE="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知参数: $1" ;;
  esac
  shift
done

case "$MODE" in
  init-key) init_key ;;
  request)
    [ -n "$ACTION" ] || die "请求缺少 --action"
    [ -n "$SOURCE" ] || die "请求缺少 --source"
    create_request "$ACTION" "$SOURCE"
    ;;
  *) usage; die "必须指定 --init-key 或 --request" ;;
esac
