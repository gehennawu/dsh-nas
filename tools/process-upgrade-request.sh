#!/usr/bin/env bash
# dsh-nas 宿主机受限升级请求处理器
# 由 root systemd service/timer 或 cron 调用；不接受任意 shell/Docker 参数。
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
CONTROL_DIR="/var/lib/dsh-nas-upgrade"
REQUEST_FILE="$CONTROL_DIR/upgrade-request.json"
KEY_FILE="$CONTROL_DIR/upgrade-request.key"
STATE_FILE="$CONTROL_DIR/upgrade-status.json"
RUN_LOCK="$CONTROL_DIR/.processor.lock"
REQUEST_LOCK="$CONTROL_DIR/.request.lock"
DEPLOY_SCRIPT="$PROJECT_DIR/deploy.sh"
MAX_AGE=900
CANONICAL_PROJECT_DIR="/opt/dsh-nas"
# systemd 处理器固定使用 root-only 状态目录；不要从请求文件或网页覆盖。
REQUEST_RE="^\\{\\\"version\\\":1,\\\"action\\\":\\\"(upgrade|latest)\\\",\\\"requested_at\\\":([1-9][0-9]*),\\\"request_id\\\":\\\"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\\\",\\\"source\\\":\\\"(host-cli|web-admin)\\\",\\\"signature\\\":\\\"([0-9a-f]{64})\\\"\\}$"

log() {
  local line
  line="$(date -Is) $*"
  printf '%s\n' "$line" >&2
  if [ -d "$CONTROL_DIR/logs" ]; then
    printf '%s\n' "$line" >> "$CONTROL_DIR/logs/processor.log" 2>/dev/null || true
    chmod 600 "$CONTROL_DIR/logs/processor.log" 2>/dev/null || true
  fi
}

die() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "请求处理器必须由 root 执行"
}

check_path() {
  local path="$1" mode owner
  [ -e "$path" ] || return 1
  [ ! -L "$path" ] || return 1
  owner=$(stat -c '%u' "$path" 2>/dev/null || echo -1)
  mode=$(stat -c '%a' "$path" 2>/dev/null || echo 0)
  [ "$owner" = 0 ] && [ "$mode" = 600 ]
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

ensure_project_trust() {
  local path rel
  [ "$PROJECT_DIR" = "$CANONICAL_PROJECT_DIR" ] \
    || die "升级项目路径必须固定为 $CANONICAL_PROJECT_DIR（当前: $PROJECT_DIR）"
  [ -d "$PROJECT_DIR" ] && [ ! -L "$PROJECT_DIR" ] \
    || die "升级项目目录不存在或是符号链接"
  path="$PROJECT_DIR"
  while [ "$path" != "/" ]; do
    check_root_nonsymlink_dir "$path" \
      || die "升级项目目录及父目录必须 root-owned 且不可被 group/other 写入: $path"
    path=$(dirname "$path")
  done
  for rel in caddy authelia plugins tools plugins/restart-dsh; do
    check_root_nonsymlink_dir "$PROJECT_DIR/$rel" \
      || die "升级代码目录必须 root-owned 且不可被 group/other 写入: $rel"
  done
  for rel in deploy.sh Dockerfile docker-compose.yml entrypoint.sh \
      caddy/Caddyfile authelia/configuration.yml authelia/users_database.yml \
      plugins/restart-dsh/package.json plugins/restart-dsh/index.js \
      plugins/restart-dsh/client.js plugins/restart-dsh/cordis.patch.yml \
      tools/process-upgrade-request.sh; do
    check_root_code_file "$PROJECT_DIR/$rel" \
      || die "升级代码文件必须 root-owned 且不可被 group/other 写入: $rel"
  done
}

ensure_control_dir() {
  local dir
  [ -d "$CONTROL_DIR" ] || die "升级控制目录不存在；先运行 request-upgrade.sh --init-key"
  [ ! -L "$CONTROL_DIR" ] || die "升级控制目录不能是符号链接"
  [ "$(stat -c '%u' "$CONTROL_DIR" 2>/dev/null || echo -1)" = 0 ] \
    || die "升级控制目录必须属于 root"
  [ "$(stat -c '%a' "$CONTROL_DIR" 2>/dev/null || echo 0)" = 700 ] \
    || die "升级控制目录必须是 0700"
  for dir in processed failed rejected seen logs; do
    check_root_nonsymlink_dir "$CONTROL_DIR/$dir" \
      || die "升级控制子目录必须是 root-owned 0700 且不能是符号链接: $dir"
  done
}

ensure_key() {
  check_path "$KEY_FILE" || die "HMAC 密钥不存在或权限不是 root:0600"
  SECRET="$(<"$KEY_FILE")"
  [[ "$SECRET" =~ ^[0-9a-f]{64}$ ]] || die "HMAC 密钥格式无效"
}

write_status() {
  local status="$1" message="$2" request_id="${3:-}" action="${4:-}" now tmp
  now="$(date +%s)"
  tmp=$(mktemp "$CONTROL_DIR/.status.tmp.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  message=${message//\\/\\\\}
  message=${message//\"/\\\"}
  printf '{"version":1,"status":"%s","message":"%s","request_id":"%s","action":"%s","updated_at":%s}\n' \
    "$status" "$message" "$request_id" "$action" "$now" >"$tmp"
  sync -d "$tmp" 2>/dev/null || sync
  mv -f "$tmp" "$STATE_FILE" || { rm -f "$tmp"; return 1; }
  chmod 600 "$STATE_FILE" 2>/dev/null || true
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

archive_request_file() {
  local bucket="$1" request_id="$2" target="$CONTROL_DIR/$bucket/$request_id.json"
  [ -e "$REQUEST_FILE" ] && [ ! -L "$REQUEST_FILE" ] || return 1
  [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
  mv "$REQUEST_FILE" "$target"
}

archive_rejected_request() {
  local request_id="${1:-unknown}" archive="$CONTROL_DIR/rejected" suffix target
  [ -f "$REQUEST_FILE" ] && [ ! -L "$REQUEST_FILE" ] || return 1
  for suffix in "$(date +%s)-$$" "$(date +%s)-$$-$RANDOM" "$(date +%s)-$$-$RANDOM-$RANDOM"; do
    target="$archive/${suffix}-${request_id}.json"
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
      mv "$REQUEST_FILE" "$target" && return 0
    fi
  done
  return 1
}

claim_request_id() {
  local request_id="$1" action="$2" marker="$CONTROL_DIR/seen/$1"
  [ ! -L "$marker" ] || reject_request "request_id ledger 不能是符号链接" "$request_id" "$action"
  [ ! -e "$marker" ] || reject_request "request_id 已处理，拒绝重放" "$request_id" "$action"
  ( set -o noclobber; : >"$marker" ) 2>/dev/null \
    || reject_request "无法原子占用 request_id" "$request_id" "$action"
  if ! chmod 600 "$marker"; then
    rm -f "$marker" 2>/dev/null || true
    reject_request "无法限制 request_id ledger 权限" "$request_id" "$action"
  fi
}

reject_request() {
  local reason="$1" request_id="${2:-}" action="${3:-}"
  write_status rejected "$reason" "$request_id" "$action" || true
  archive_rejected_request "${request_id:-unknown}" || true
  log "拒绝升级请求: $reason"
  exit 1
}

process_request() {
  local raw version action requested_at request_id source signature payload now age expected
  [ -e "$REQUEST_FILE" ] || return 0
  [ ! -L "$REQUEST_FILE" ] || reject_request "请求文件不能是符号链接"
  check_path "$REQUEST_FILE" || reject_request "请求文件必须属于 root 且权限为 0600"
  for seen_id in "$CONTROL_DIR/seen"/*; do
    [ -e "$seen_id" ] || continue
    [ -f "$seen_id" ] && [ ! -L "$seen_id" ] \
      || die "seen 记录必须是普通 root-only 文件: $seen_id"
    [ "$(stat -c '%u:%a' "$seen_id" 2>/dev/null || echo invalid)" = "0:600" ] \
      || die "seen 记录权限异常: $seen_id"
    case "$(basename "$seen_id")" in
      ''|*[!0-9a-f-]*) die "seen 记录文件名非法: $seen_id" ;;
    esac
  done
  raw="$(<"$REQUEST_FILE")" || reject_request "无法读取请求文件"
  if [[ ! "$raw" =~ $REQUEST_RE ]] || [[ "$raw" == *$'\n'* ]] || [[ "$raw" == *$'\r'* ]]; then
    reject_request "请求必须是单行 canonical JSON，不能包含额外字段或尾随内容"
  fi
  version=1
  action="${BASH_REMATCH[1]}"
  requested_at="${BASH_REMATCH[2]}"
  request_id="${BASH_REMATCH[3]}"
  source="${BASH_REMATCH[4]}"
  signature="${BASH_REMATCH[5]}"
  now="$(date +%s)"
  age=$((now - requested_at))
  [ "$age" -ge 0 ] && [ "$age" -le "$MAX_AGE" ] \
    || reject_request "请求已过期或来自未来" "$request_id" "$action"
  payload=$(printf 'version=1\naction=%s\nrequested_at=%s\nrequest_id=%s\nsource=%s' \
    "$action" "$requested_at" "$request_id" "$source")
  expected=$(hmac_sha256 "$payload") || reject_request "无法计算 HMAC 签名" "$request_id" "$action"
  [ "$expected" = "$signature" ] || reject_request "HMAC 签名不匹配" "$request_id" "$action"
  claim_request_id "$request_id" "$action"
  [ -x "$DEPLOY_SCRIPT" ] || reject_request "deploy.sh 不存在或不可执行" "$request_id" "$action"
  [ -f "$PROJECT_DIR/docker-compose.yml" ] || reject_request "Compose 文件缺失" "$request_id" "$action"

  write_status running "正在执行受限宿主机升级" "$request_id" "$action" || true
  log "接受升级请求: action=$action request_id=$request_id source=$source"
  if [ "$action" = latest ]; then
    DSH_NAS_RESTRICTED_UPGRADE=1 DSH_NAS_UPGRADE_STATE_DIR="$CONTROL_DIR" \
      "$DEPLOY_SCRIPT" --latest >>"$CONTROL_DIR/logs/deploy-$request_id.log" 2>&1
  else
    DSH_NAS_RESTRICTED_UPGRADE=1 DSH_NAS_UPGRADE_STATE_DIR="$CONTROL_DIR" \
      "$DEPLOY_SCRIPT" --upgrade >>"$CONTROL_DIR/logs/deploy-$request_id.log" 2>&1
  fi
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    chmod 600 "$CONTROL_DIR/logs/deploy-$request_id.log" 2>/dev/null || true
    archive_request_file processed "$request_id" \
      || { log "无法安全归档已处理请求 $request_id"; return 1; }
    write_status succeeded "升级完成" "$request_id" "$action" || return 1
    log "升级完成: request_id=$request_id"
    return 0
  fi
  write_status failed "升级失败；请检查受限升级日志和事务快照" "$request_id" "$action" || true
  chmod 600 "$CONTROL_DIR/logs/deploy-$request_id.log" 2>/dev/null || true
  archive_request_file failed "$request_id" \
    || log "WARNING: 无法安全归档失败请求 $request_id"
  log "升级失败: request_id=$request_id rc=$rc"
  return "$rc"
}

require_root
ensure_control_dir
ensure_key
ensure_project_trust
exec 8>"$RUN_LOCK" || die "无法打开处理器锁"
chmod 600 "$RUN_LOCK" 2>/dev/null || true
flock -n 8 || { log "已有升级请求处理器运行，退出"; exit 0; }
exec 9>"$REQUEST_LOCK" || die "无法打开请求锁"
chmod 600 "$REQUEST_LOCK" 2>/dev/null || true
flock -n 9 || { log "请求签发器正在写入请求，稍后重试"; exit 0; }
process_request
