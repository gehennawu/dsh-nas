#!/usr/bin/env bash
# ============================================================
# dsh-nas Linux NAS 一键部署脚本
# 检查：环境 / 文件完整性 / 密钥与域名占位符 / 数据目录权限
#       / 端口冲突 / 代理连通性，然后构建并启动、等待健康，
#       最后验证 dsh 仅监听回环（host 网络下的安全前提）。
# 用法:
#   ./deploy.sh                     # 完整检查 + 构建 + 启动
#   ./deploy.sh --skip-build        # 跳过构建，直接用现有镜像启动
#   ./deploy.sh --proxy-host 192.168.1.5:7890   # 代理不在本机时指定（构建+运行时，写入 .env）
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTHELIA_CONF="$SCRIPT_DIR/authelia/configuration.yml"
USERS_DB="$SCRIPT_DIR/authelia/users_database.yml"
CADDYFILE="$SCRIPT_DIR/caddy/Caddyfile"
DATA_DIR="$SCRIPT_DIR/data/dsh"
WORKSPACE_DIR="$SCRIPT_DIR/data/workspace"
PROXY="http://127.0.0.1:7890"
SKIP_BUILD=0
SETUP_FORCE=0
SETUP_WIZARD_RAN=0
DSH_TRUSTED_DOMAIN_CHANGED=0
UPGRADE_MODE=0
LATEST_MODE=0
UPGRADE_ROLLBACK_ARMED=0
UPGRADE_COMMITTED=0
UPGRADE_SWITCHED=0
UPGRADE_SWITCH_ATTEMPTED=0
UPGRADE_LOCK_FD=9
UPGRADE_TXN_DIR=""
# 升级快照和锁放在 root-only 状态目录，脱离一切 UID 1000 可写/可改名的项目路径
# （README 的 chown 只覆盖 data/dsh 与 data/workspace），避免回滚时被容器篡改。
# 升级只能由宿主机 CLI 以 root（sudo）执行。
UPGRADE_STATE_ROOT="/var/lib/dsh-nas-upgrade"
UPGRADE_BACKUP_ROOT="$UPGRADE_STATE_ROOT/config-backup"
UPGRADE_ENV_EARLY_DIR=""
COMPOSE=""
UPGRADE_OLD_DSH_EXISTS=0
UPGRADE_OLD_AUTHELIA_EXISTS=0
UPGRADE_OLD_CADDY_EXISTS=0
UPGRADE_OLD_DSH_RUNNING=0
UPGRADE_OLD_AUTHELIA_RUNNING=0
UPGRADE_OLD_CADDY_RUNNING=0
UPGRADE_OLD_STACK_RUNNING=0
UPGRADE_OLD_DSH_CONTAINER_ID=""
UPGRADE_OLD_AUTHELIA_CONTAINER_ID=""
UPGRADE_OLD_CADDY_CONTAINER_ID=""
UPGRADE_OLD_DSH_IMAGE_REF=""
UPGRADE_OLD_AUTHELIA_IMAGE_REF=""
UPGRADE_OLD_CADDY_IMAGE_REF=""
UPGRADE_ENV_SNAPSHOT_READY=0
UPGRADE_ENV_ROLLBACK_ARMED=0
UPGRADE_FULL_SNAPSHOT_READY=0
INTERNAL_PORT=13080     # 反代入口模式（lucky/CF）Caddy 内部 http 监听端口
MODE_DIRECT_80_443='direct-80-443'
MODE_DIRECT_443_ONLY='direct-443-only'
MODE_FRONT_PROXY='front-proxy'
ENTRY_MODE="$MODE_DIRECT_443_ONLY"  # 向导生成并写入 Caddyfile 标记；旧配置兼容回退为 443-only
PUBLIC_PORT=443         # 公网访问 HTTPS 端口（前置反代监听端口；443 则 URL 不带端口）

# 公网 URL 辅助：443 端口省略，非标端口带上 :PORT
pub_url() { # $1=host
  if [ "$PUBLIC_PORT" = "443" ]; then echo "https://$1"; else echo "https://$1:$PUBLIC_PORT"; fi
}
SET_PROXY_ARG=0
PROFILE_ARGS=""

# ---------- 输出样式 ----------
if [ -t 1 ]; then
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=""; C_Y=""; C_R=""; C_B=""; C_0=""
fi
PASS=0; FAIL=0; WARN=0
ok()   { PASS=$((PASS+1)); echo "  ${C_G}✓${C_0} $1"; }
warn() { WARN=$((WARN+1)); echo "  ${C_Y}⚠${C_0} $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ${C_R}✗${C_0} $1"; }
section() { echo; echo "${C_B}== $1 ==${C_0}"; }

usage() {
  echo "用法: $0 [--skip-build] [--proxy-host HOST:PORT] [--setup] [--upgrade] [--latest]"
  echo "  --skip-build        跳过镜像构建，直接用现有镜像"
  echo "  --proxy-host ADDR   代理地址（如 192.168.1.5:7890）；构建与运行时都生效，"
  echo "                      写入 .env 的 DSH_PROXY（compose 自动读取）"
  echo "  --setup             强制重跑配置向导（可换域名/入口/密码；原文件备份为 .bak，Authelia 密钥保留）"
  echo "                      向导还会选择是否启用反代域名 patch，并保存 DSH_TRUSTED_DOMAIN"
  echo "  --upgrade           升级模式：跳过 Caddy/Authelia 向导，但仍询问是否启用/更新 dsh 域名 patch"
  echo "  --latest            自动升级到 npm 最新版：查询 @deepseek-ai/dsh latest，更新版本号后"
  echo "                      构建（隐含 --upgrade；需已完成一次正常部署；仍询问 patch）"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    --setup) SETUP_FORCE=1 ;;
    --upgrade) UPGRADE_MODE=1 ;;
    --latest) LATEST_MODE=1; UPGRADE_MODE=1 ;;
    --proxy-host)
      [ $# -ge 2 ] || { echo "错误: --proxy-host 需要一个地址（如 192.168.1.5:7890）"; exit 1; }
      PROXY="http://$2"; SET_PROXY_ARG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
  shift
done

if [ "$UPGRADE_MODE" -eq 1 ] && [ "$SKIP_BUILD" -eq 1 ]; then
  echo "错误: --upgrade/--latest 不能与 --skip-build 同时使用；升级必须重新构建 dsh 镜像"
  exit 1
fi

# ---------- .env 幂等写入（保留其它配置行） ----------
# 升级模式必须先锁定并保存原始 .env，再允许 --proxy-host/patch 选择写入新值。
# 该早期快照只负责恢复 .env；完整配置快照在环境检查阶段继续建立。
capture_upgrade_env_before_mutation() {
  [ "$UPGRADE_MODE" -eq 1 ] || return 0
  [ "$UPGRADE_ENV_SNAPSHOT_READY" -eq 1 ] && return 0
  mkdir -p "$UPGRADE_ENV_EARLY_DIR" || return 1
  chmod 700 "$UPGRADE_ENV_EARLY_DIR" 2>/dev/null || return 1
  rm -f "$UPGRADE_ENV_EARLY_DIR/.env.before" "$UPGRADE_ENV_EARLY_DIR/.env.absent" 2>/dev/null || true
  if [ -f "$ENV_FILE" ]; then
    cp -p "$ENV_FILE" "$UPGRADE_ENV_EARLY_DIR/.env.before" || return 1
    chmod 600 "$UPGRADE_ENV_EARLY_DIR/.env.before" 2>/dev/null || return 1
    UPGRADE_ENV_EXISTED=1
  else
    : > "$UPGRADE_ENV_EARLY_DIR/.env.absent" || return 1
    chmod 600 "$UPGRADE_ENV_EARLY_DIR/.env.absent" 2>/dev/null || return 1
    UPGRADE_ENV_EXISTED=0
  fi
  UPGRADE_ENV_SNAPSHOT_READY=1
  UPGRADE_ENV_ROLLBACK_ARMED=1
}
env_upsert() { # $1=key $2=value
  local key="$1" value="$2" tmp
  touch "$ENV_FILE" 2>/dev/null || return 1
  tmp=$(mktemp "${ENV_FILE}.tmp.XXXXXX") || return 1
  if ! awk -v key="$key" -v value="$value" '
    BEGIN { prefix = key "="; found = 0 }
    index($0, prefix) == 1 {
      if (!found) { print prefix value; found = 1 }
      next
    }
    { print }
    END { if (!found) print prefix value }
  ' "$ENV_FILE" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! atomic_replace_file "$tmp" "$ENV_FILE"; then
    rm -f "$tmp"
    return 1
  fi
}

# ---------- DSH 反代域名 patch 选择 ----------
# DSH_TRUSTED_DOMAIN 只保存 hostname，不含协议、端口或路径。
# 空值表示保持原始 loopback-only 行为；非空值由 Compose 作为 Docker build arg
# 传给 Dockerfile，在 root 构建阶段 patch 两个 dsh-client-connection bundle。
valid_trusted_domain() { # $1=hostname
  local domain="$1"
  [ -n "$domain" ] || return 0
  [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

configure_trusted_domain() { # $1=已保存 hostname $2=当前 Caddy dsh hostname（可选）
  local saved_domain="$1" suggested_domain="${2:-}" answer="" domain="" confirm=""
  if [ ! -t 0 ]; then
    fail "DSH patch 选择需要交互终端；请在 SSH 终端运行升级，不能通过非交互管道跳过选择"
    return 1
  fi

  saved_domain="${saved_domain,,}"
  suggested_domain="${suggested_domain,,}"
  if [ -n "$saved_domain" ] && ! valid_trusted_domain "$saved_domain"; then
    fail ".env 中的 DSH_TRUSTED_DOMAIN 无效: $saved_domain（只允许 hostname，不含协议、端口、路径或空格）"
    return 1
  fi
  if [ -n "$suggested_domain" ] && ! valid_trusted_domain "$suggested_domain"; then
    fail "Caddyfile 中的 dsh hostname 无效: $suggested_domain"
    return 1
  fi

  DSH_TRUSTED_DOMAIN_CHANGED=0
  echo
  echo "  DSH 反代域名 patch（可选）"
  echo "  作用：让反向代理域名访问时也能使用 rc8+ 的 settings/credentials 等特权 RPC。"
  echo "  安全前提：必须已有 HTTPS + Authelia/其它独立认证层。"
  if [ -n "$saved_domain" ]; then
    echo "  .env 当前 hostname: $saved_domain"
    if [ -n "$suggested_domain" ] && [ "$saved_domain" != "$suggested_domain" ]; then
      echo "  Caddy 当前 dsh hostname: $suggested_domain"
      printf "  回车使用 Caddy 当前 hostname，输入 n 关闭，或输入新的 hostname: "
      read_line answer || return 1
      case "$answer" in
        "") domain="$suggested_domain" ;;
        n|N|no|NO|否) domain="" ;;
        *) domain="$answer" ;;
      esac
    else
      printf "  回车保留，输入 n 关闭，或输入新的 hostname 更换: "
      read_line answer || return 1
      case "$answer" in
        "") domain="$saved_domain" ;;
        n|N|no|NO|否) domain="" ;;
        *) domain="$answer" ;;
      esac
    fi
  else
    printf "  是否启用 patch？[y/N]: "
    read_line answer || return 1
    case "$answer" in
      y|Y|yes|YES|是)
        if [ -n "$suggested_domain" ]; then
          printf "  输入 DSH 公网 hostname [%s]（不含协议/端口）: " "$suggested_domain"
        else
          printf "  输入 DSH 公网 hostname（如 dsh.example.com，不含协议/端口）: "
        fi
        read_line domain || return 1
        [ -n "$domain" ] || domain="$suggested_domain"
        ;;
      *)
        domain=""
        ;;
    esac
  fi

  domain="${domain,,}"
  if [ -n "$domain" ] && ! valid_trusted_domain "$domain"; then
    fail "无效 DSH patch hostname: $domain（只允许 hostname，不含协议、端口、路径或空格）"
    return 1
  fi
  if [ -n "$domain" ]; then
    printf "  确认启用 patch，hostname = %s？[Y/n]: " "$domain"
    read_line confirm || return 1
    case "$confirm" in
      n|N|no|NO|否) domain="" ;;
    esac
  fi

  DSH_TRUSTED_DOMAIN="$domain"
  [ "$saved_domain" = "$DSH_TRUSTED_DOMAIN" ] || DSH_TRUSTED_DOMAIN_CHANGED=1
  if [ -n "$DSH_TRUSTED_DOMAIN" ]; then
    ok "已启用 DSH 反代域名 patch: $DSH_TRUSTED_DOMAIN"
  else
    ok "不启用 DSH 反代域名 patch，保持原始 loopback-only 行为"
  fi
}

persist_trusted_domain() {
  if [ "$DSH_TRUSTED_DOMAIN_CHANGED" -eq 1 ] || ! grep -q '^DSH_TRUSTED_DOMAIN=' "$ENV_FILE" 2>/dev/null; then
    env_upsert DSH_TRUSTED_DOMAIN "$DSH_TRUSTED_DOMAIN" || return 1
    ok "已保存 DSH_TRUSTED_DOMAIN=${DSH_TRUSTED_DOMAIN:-（未启用 patch）}"
  fi
}

# 同目录临时文件 + fsync + rename，避免版本/状态文件半写入。
atomic_replace_file() { # $1=temporary file $2=target file
  local tmp="$1" target="$2" dir
  [ -f "$tmp" ] || return 1
  if [ -e "$target" ]; then
    chmod --reference="$target" "$tmp" 2>/dev/null || return 1
    chown --reference="$target" "$tmp" 2>/dev/null || true
  fi
  sync -d "$tmp" 2>/dev/null || sync
  mv -f "$tmp" "$target" || return 1
  dir=$(dirname "$target")
  sync -d "$dir" 2>/dev/null || true
}
update_dsh_version_atomic() { # $1=validated version
  local version="$1" file="$SCRIPT_DIR/Dockerfile" tmp count
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || return 1
  count=$(grep -cE '^ARG DSH_VERSION=' "$file" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
  if ! cp -p "$file" "$tmp" \
     || ! sed -i -E "s/^ARG DSH_VERSION=.*/ARG DSH_VERSION=$version/" "$tmp" \
     || ! atomic_replace_file "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
}

# 升级模式只允许改版本并构建 dsh；配置文件由调用方完整保留。
# 升级快照包含版本文件、配置文件、.env、旧镜像 ID 和运行容器配置。
upgrade_lock() {
  [ "$UPGRADE_MODE" -eq 1 ] || return 0
  mkdir -p "$UPGRADE_STATE_ROOT" "$UPGRADE_BACKUP_ROOT" \
    || { echo "错误: 无法创建宿主机升级状态目录: $UPGRADE_STATE_ROOT（升级需要 root，请使用 sudo 运行）"; exit 1; }
  chmod 700 "$UPGRADE_STATE_ROOT" "$UPGRADE_BACKUP_ROOT" 2>/dev/null \
    || { echo "错误: 无法限制宿主机升级状态目录权限"; exit 1; }
  if [ "$(id -u)" -eq 0 ]; then
    chown root:root "$UPGRADE_STATE_ROOT" "$UPGRADE_BACKUP_ROOT" 2>/dev/null \
      || { echo "错误: 宿主机升级状态目录必须属于 root"; exit 1; }
  fi
  local state_mode state_owner
  state_mode=$(stat -c '%a' "$UPGRADE_STATE_ROOT" 2>/dev/null || echo 0)
  state_owner=$(stat -c '%u' "$UPGRADE_STATE_ROOT" 2>/dev/null || echo -1)
  [ "$state_mode" = 700 ] && [ "$state_owner" = 0 ] \
    || { echo "错误: 宿主机升级状态目录必须为 root:root 0700: $UPGRADE_STATE_ROOT"; exit 1; }
  if [ ! -f "$UPGRADE_STATE_ROOT/.upgrade.lock" ]; then
    : > "$UPGRADE_STATE_ROOT/.upgrade.lock" || { echo "错误: 无法创建升级锁文件"; exit 1; }
    chmod 600 "$UPGRADE_STATE_ROOT/.upgrade.lock" 2>/dev/null || exit 1
    [ "$(id -u)" -ne 0 ] || chown root:root "$UPGRADE_STATE_ROOT/.upgrade.lock" 2>/dev/null || exit 1
  fi
  if ! eval "exec $UPGRADE_LOCK_FD>\"$UPGRADE_STATE_ROOT/.upgrade.lock\""; then
    echo "错误: 无法打开升级锁文件（升级需要 root，请使用 sudo 运行）" >&2
    exit 1
  fi
  if command -v flock >/dev/null 2>&1; then
    flock -n "$UPGRADE_LOCK_FD" || { echo "错误: 已有另一个升级/部署事务运行；请等待其完成"; exit 1; }
  else
    echo "错误: 升级需要 GNU flock 以防止并发覆盖版本和镜像"
    exit 1
  fi
  local suffix="$(date +%Y%m%d-%H%M%S)-$$"
  UPGRADE_TXN_DIR="$UPGRADE_BACKUP_ROOT/$suffix"
  while ! mkdir -m 700 "$UPGRADE_TXN_DIR" 2>/dev/null; do
    suffix="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
    UPGRADE_TXN_DIR="$UPGRADE_BACKUP_ROOT/$suffix"
  done
  # 事务快照只保留最近 5 次，避免长期升级无限累积
  ls -1dt "$UPGRADE_BACKUP_ROOT"/*/ 2>/dev/null | tail -n +6 | xargs -r rm -rf --
  UPGRADE_BACKUP_DIR="$UPGRADE_TXN_DIR"
  UPGRADE_ENV_EARLY_DIR="$UPGRADE_BACKUP_DIR/.env-before"
  mkdir -m 700 "$UPGRADE_ENV_EARLY_DIR" || { echo "错误: 无法创建 .env 早期快照目录"; exit 1; }
}
UPGRADE_BACKUP_DIR=""
UPGRADE_OLD_VERSION=""
UPGRADE_OLD_IMAGE_ID=""
UPGRADE_OLD_CONTAINER_CONFIG=""
UPGRADE_ENV_EXISTED=0
backup_upgrade_configs() {
  local backup_dir="$UPGRADE_BACKUP_DIR"
  mkdir -p "$backup_dir" || return 1
  if [ "$UPGRADE_ENV_SNAPSHOT_READY" -eq 0 ]; then
    capture_upgrade_env_before_mutation || return 1
  fi
  [ -n "$UPGRADE_OLD_VERSION" ] || true
  local version_count
  version_count=$(grep -cE '^ARG DSH_VERSION=' "$SCRIPT_DIR/Dockerfile" 2>/dev/null || true)
  [ "$version_count" -eq 1 ] || { echo "升级快照失败: Dockerfile 必须恰好有一处 DSH_VERSION"; return 1; }
  for f in "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR/docker-compose.yml" "$CADDYFILE" "$AUTHELIA_CONF" "$USERS_DB" "$ENV_FILE"; do
    [ -f "$f" ] || continue
    cp -p "$f" "$backup_dir/$(basename "$f").before" || return 1
    chmod 600 "$backup_dir/$(basename "$f").before" 2>/dev/null || return 1
  done
  UPGRADE_OLD_VERSION=$(sed -n 's/^ARG DSH_VERSION=//p' "$SCRIPT_DIR/Dockerfile")
  UPGRADE_OLD_IMAGE_ID=$(docker image inspect dsh:local --format '{{.Id}}' 2>/dev/null || true)
  if [ -z "$UPGRADE_OLD_IMAGE_ID" ]; then
    echo "升级快照失败: dsh:local 旧镜像不存在，无法提供可恢复升级"
    return 1
  fi
  [ -n "$UPGRADE_OLD_VERSION" ] || { echo "升级快照失败: Dockerfile DSH_VERSION 为空"; return 1; }
  if docker inspect dsh >"$backup_dir/dsh.inspect.before" 2>/dev/null; then
    UPGRADE_OLD_DSH_EXISTS=1
    [ "$(docker inspect -f '{{.State.Running}}' dsh 2>/dev/null || echo false)" = true ] && UPGRADE_OLD_DSH_RUNNING=1
    UPGRADE_OLD_DSH_CONTAINER_ID=$(docker inspect -f '{{.Id}}' dsh 2>/dev/null || true)
    UPGRADE_OLD_DSH_IMAGE_REF=$(docker inspect -f '{{.Config.Image}}' dsh 2>/dev/null || true)
  fi
  if docker inspect dsh-caddy >"$backup_dir/dsh-caddy.inspect.before" 2>/dev/null; then
    UPGRADE_OLD_CADDY_EXISTS=1
    [ "$(docker inspect -f '{{.State.Running}}' dsh-caddy 2>/dev/null || echo false)" = true ] && UPGRADE_OLD_CADDY_RUNNING=1
    UPGRADE_OLD_CADDY_CONTAINER_ID=$(docker inspect -f '{{.Id}}' dsh-caddy 2>/dev/null || true)
    UPGRADE_OLD_CADDY_IMAGE_REF=$(docker inspect -f '{{.Config.Image}}' dsh-caddy 2>/dev/null || true)
  fi
  if docker inspect authelia >"$backup_dir/authelia.inspect.before" 2>/dev/null; then
    UPGRADE_OLD_AUTHELIA_EXISTS=1
    [ "$(docker inspect -f '{{.State.Running}}' authelia 2>/dev/null || echo false)" = true ] && UPGRADE_OLD_AUTHELIA_RUNNING=1
    UPGRADE_OLD_AUTHELIA_CONTAINER_ID=$(docker inspect -f '{{.Id}}' authelia 2>/dev/null || true)
    UPGRADE_OLD_AUTHELIA_IMAGE_REF=$(docker inspect -f '{{.Config.Image}}' authelia 2>/dev/null || true)
  fi
  if [ "$UPGRADE_OLD_DSH_RUNNING" -eq 1 ] || [ "$UPGRADE_OLD_AUTHELIA_RUNNING" -eq 1 ] || [ "$UPGRADE_OLD_CADDY_RUNNING" -eq 1 ]; then
    UPGRADE_OLD_STACK_RUNNING=1
  fi
  printf '%s\n' "$UPGRADE_OLD_VERSION" > "$backup_dir/old-version"
  printf '%s\n' "$UPGRADE_OLD_IMAGE_ID" > "$backup_dir/old-image-id"
  chmod 600 "$backup_dir"/* 2>/dev/null || true
  chmod 700 "$backup_dir" 2>/dev/null || true
  UPGRADE_ROLLBACK_ARMED=1
}
restore_upgrade_version() {
  local restore_ok=1 target f
  if [ -n "$UPGRADE_OLD_VERSION" ] && [ -f "$SCRIPT_DIR/Dockerfile" ]; then
    update_dsh_version_atomic "$UPGRADE_OLD_VERSION" || restore_ok=0
  fi
  # .env 不使用完整快照中的副本：完整快照可能在 --proxy-host 写入之后建立，
  # 必须使用升级锁建立的最早副本恢复升级前状态。
  for f in Dockerfile docker-compose.yml Caddyfile configuration.yml users_database.yml; do
    if [ -f "$UPGRADE_BACKUP_DIR/$f.before" ]; then
      case "$f" in
        Caddyfile) target="$CADDYFILE" ;;
        configuration.yml) target="$AUTHELIA_CONF" ;;
        users_database.yml) target="$USERS_DB" ;;
        *) target="$SCRIPT_DIR/$f" ;;
      esac
      cp -p "$UPGRADE_BACKUP_DIR/$f.before" "$target" 2>/dev/null || restore_ok=0
    fi
  done
  if [ "$UPGRADE_ENV_ROLLBACK_ARMED" -eq 1 ]; then
    if [ "$UPGRADE_ENV_EXISTED" -eq 1 ] && [ -f "$UPGRADE_ENV_EARLY_DIR/.env.before" ]; then
      cp -p "$UPGRADE_ENV_EARLY_DIR/.env.before" "$ENV_FILE" 2>/dev/null || restore_ok=0
    elif [ "$UPGRADE_ENV_EXISTED" -eq 0 ]; then
      rm -f "$ENV_FILE" 2>/dev/null || restore_ok=0
      [ ! -e "$ENV_FILE" ] || restore_ok=0
    else
      echo "  ${C_R}回滚: 缺少升级前 .env 快照${C_0}"
      restore_ok=0
    fi
    UPGRADE_ENV_ROLLBACK_ARMED=0
  fi
  return "$restore_ok"
}
restore_upgrade_image() {
  [ -n "$UPGRADE_OLD_IMAGE_ID" ] || return 1
  docker tag "$UPGRADE_OLD_IMAGE_ID" dsh:local >/dev/null 2>&1 || return 1
  [ "$(docker image inspect dsh:local --format '{{.Id}}' 2>/dev/null)" = "$UPGRADE_OLD_IMAGE_ID" ]
}
wait_for_stack_healthy() {
  local i status authelia_status caddy_status
  for i in $(seq 1 40); do
    status=$(docker inspect -f '{{.State.Health.Status}}' dsh 2>/dev/null || echo missing)
    authelia_status=$(docker inspect -f '{{.State.Health.Status}}' authelia 2>/dev/null || echo missing)
    caddy_status=$(docker inspect -f '{{.State.Health.Status}}' dsh-caddy 2>/dev/null || echo missing)
    if [ "$status" = healthy ] && [ "$authelia_status" = healthy ] && [ "$caddy_status" = healthy ]; then
      return 0
    fi
    sleep 3
  done
  echo "  ${C_R}回滚健康状态: dsh=${status:-unknown}, authelia=${authelia_status:-unknown}, caddy=${caddy_status:-unknown}${C_0}"
  return 1
}
upgrade_stack_changed() {
  local current running
  if [ "$UPGRADE_OLD_DSH_EXISTS" -eq 1 ]; then
    current=$(docker inspect -f '{{.Id}}' dsh 2>/dev/null || true)
    [ -n "$current" ] || return 0
    [ "$current" = "$UPGRADE_OLD_DSH_CONTAINER_ID" ] || return 0
    running=$(docker inspect -f '{{.State.Running}}' dsh 2>/dev/null || true)
    if [ "$UPGRADE_OLD_DSH_RUNNING" -eq 1 ]; then
      [ "$running" = true ] || return 0
    else
      [ "$running" != true ] || return 0
    fi
  elif docker inspect dsh >/dev/null 2>&1; then
    return 0
  fi
  if [ "$UPGRADE_OLD_AUTHELIA_EXISTS" -eq 1 ]; then
    current=$(docker inspect -f '{{.Id}}' authelia 2>/dev/null || true)
    [ -n "$current" ] || return 0
    [ "$current" = "$UPGRADE_OLD_AUTHELIA_CONTAINER_ID" ] || return 0
    running=$(docker inspect -f '{{.State.Running}}' authelia 2>/dev/null || true)
    if [ "$UPGRADE_OLD_AUTHELIA_RUNNING" -eq 1 ]; then
      [ "$running" = true ] || return 0
    else
      [ "$running" != true ] || return 0
    fi
  elif docker inspect authelia >/dev/null 2>&1; then
    return 0
  fi
  if [ "$UPGRADE_OLD_CADDY_EXISTS" -eq 1 ]; then
    current=$(docker inspect -f '{{.Id}}' dsh-caddy 2>/dev/null || true)
    [ -n "$current" ] || return 0
    [ "$current" = "$UPGRADE_OLD_CADDY_CONTAINER_ID" ] || return 0
    running=$(docker inspect -f '{{.State.Running}}' dsh-caddy 2>/dev/null || true)
    if [ "$UPGRADE_OLD_CADDY_RUNNING" -eq 1 ]; then
      [ "$running" = true ] || return 0
    else
      [ "$running" != true ] || return 0
    fi
  elif docker inspect dsh-caddy >/dev/null 2>&1; then
    return 0
  fi
  return 1
}
validate_restored_stack() {
  local listeners
  wait_for_stack_healthy || return 1
  listeners=$(listener_addresses 3080 2>/dev/null || true)
  if [ "$listeners" != "127.0.0.1:3080" ]; then
    echo "  ${C_R}回滚 listener: dsh 实际为 $(printf '%s ' "$listeners")${C_0}"
    return 1
  fi
  listeners=$(listener_addresses 9091 2>/dev/null || true)
  if [ "$listeners" != "127.0.0.1:9091" ]; then
    echo "  ${C_R}回滚 listener: Authelia 实际为 $(printf '%s ' "$listeners")${C_0}"
    return 1
  fi
  if ! http_get 5 "http://127.0.0.1:9091/api/health" | grep -q '"status":"OK"'; then
    echo "  ${C_R}回滚 API: Authelia /api/health 未通过${C_0}"
    return 1
  fi
  CADDY_LISTENERS=$(caddy_listeners 2>/dev/null || true)
  if [ -z "$CADDY_LISTENERS" ] || ! caddy_listener_set_ok; then
    echo "  ${C_R}回滚 listener: Caddy 实际为 $(printf '%s ' "$CADDY_LISTENERS")${C_0}"
    return 1
  fi
  return 0
}
rollback_upgrade() {
  [ "$UPGRADE_MODE" -eq 1 ] || return 0
  [ "$UPGRADE_ROLLBACK_ARMED" -eq 1 ] || return 0
  local rollback_ok=1 stack_changed=0
  echo "  ${C_Y}升级验证失败，恢复旧版本和旧 dsh 镜像...${C_0}"
  if [ "$UPGRADE_SWITCHED" -eq 1 ]; then
    stack_changed=1
  elif [ "$UPGRADE_SWITCH_ATTEMPTED" -eq 1 ] && upgrade_stack_changed; then
    stack_changed=1
  fi
  restore_upgrade_version || rollback_ok=0
  if ! restore_upgrade_image; then
    echo "  ${C_R}回滚: 旧 dsh 镜像不可用或无法恢复 tag${C_0}"
    rollback_ok=0
  fi
  if [ "$stack_changed" -eq 1 ] && [ -n "$COMPOSE" ]; then
    echo "  ${C_Y}回滚: 停止当前 Compose 栈...${C_0}"
    if ! compose_down_current; then
      echo "  ${C_R}回滚: 无法停止当前 Compose 栈；请查看 docker compose ps${C_0}"
      rollback_ok=0
    fi
    if [ "$UPGRADE_OLD_STACK_RUNNING" -eq 1 ]; then
      if ! restore_upgrade_image; then
        echo "  ${C_R}回滚: 无法重新标记旧 dsh 镜像${C_0}"
        rollback_ok=0
      fi
      echo "  ${C_Y}回滚: 启动旧 Compose 栈...${C_0}"
      if ! $COMPOSE $PROFILE_ARGS up -d; then
        echo "  ${C_R}回滚: 无法重新启动旧 Compose 栈；请查看上方 Compose 输出${C_0}"
        rollback_ok=0
      elif ! validate_restored_stack; then
        rollback_ok=0
      fi
    else
      echo "  ${C_Y}回滚: 升级前没有运行中的完整栈，已清理失败的新栈，不重新启动服务${C_0}"
    fi
  fi
  if [ "$rollback_ok" -eq 1 ]; then
    echo "  ${C_G}旧版本恢复完成${C_0}"
  else
    echo "  ${C_R}旧版本恢复失败；请立即检查 Dockerfile、dsh:local 和 Compose 状态${C_0}"
  fi
  UPGRADE_ROLLBACK_ARMED=0
  [ "$rollback_ok" -eq 1 ]
}
upgrade_exit_trap() {
  local rc=$?
  trap - EXIT INT TERM
  if [ "$rc" -ne 0 ] && [ "$UPGRADE_COMMITTED" -eq 0 ]; then
    if [ "$UPGRADE_ROLLBACK_ARMED" -eq 1 ]; then
      rollback_upgrade || rc=1
    elif [ "$UPGRADE_ENV_ROLLBACK_ARMED" -eq 1 ]; then
      echo "  ${C_Y}升级尚未完成，恢复升级前 .env...${C_0}"
      restore_upgrade_version || rc=1
    fi
  fi
  exit "$rc"
}
upgrade_signal_trap() {
  local signal="$1" code=130
  [ "$signal" = TERM ] && code=143
  trap - INT TERM
  # 显式以 130/143 退出，让 EXIT trap 必然执行 rollback_upgrade；不依赖信号到达时的 `$?`。
  exit "$code"
}

# 升级必须在任何 .env 修改前取得锁并创建事务目录；同时安装失败 trap。
if [ "$UPGRADE_MODE" -eq 1 ]; then
  upgrade_lock
  trap upgrade_exit_trap EXIT
  trap 'upgrade_signal_trap INT' INT
  trap 'upgrade_signal_trap TERM' TERM
fi

# ---------- 运行时代理地址（.env 的 DSH_PROXY，compose 自动读取插值） ----------
# --proxy-host 显式传入 → 写入 .env 持久化；未传入但 .env 有保存值 → 沿用
# 代理地址必须带 scheme：Node/undici 运行时代理只认完整 URL，curl 却容忍裸 host:port，
# 不规范化会出现「部署期连通性检查通过、运行时静默失败」。
normalize_proxy() { # $1=addr
  case "$1" in
    http://*|https://*) printf '%s' "$1" ;;
    *) printf 'http://%s' "$1" ;;
  esac
}
ENV_FILE="$SCRIPT_DIR/.env"
SAVED_PROXY=""
SAVED_TRUSTED_DOMAIN=""
TRUSTED_DOMAIN_COUNT=0
if [ -f "$ENV_FILE" ]; then
  SAVED_PROXY=$(sed -n 's/^DSH_PROXY=//p' "$ENV_FILE" | head -n 1)
  TRUSTED_DOMAIN_COUNT=$(grep -c '^DSH_TRUSTED_DOMAIN=' "$ENV_FILE" 2>/dev/null || true)
  if [ "$TRUSTED_DOMAIN_COUNT" -gt 1 ]; then
    echo "错误: $ENV_FILE 中存在多个 DSH_TRUSTED_DOMAIN，无法安全判断 patch 状态"
    exit 1
  fi
  SAVED_TRUSTED_DOMAIN=$(sed -n 's/^DSH_TRUSTED_DOMAIN=//p' "$ENV_FILE" | head -n 1)
fi
SAVED_PROXY="${SAVED_PROXY%$'\r'}"   # .env 被 Windows 编辑器存成 CRLF 时剥掉回车
SAVED_TRUSTED_DOMAIN="${SAVED_TRUSTED_DOMAIN%$'\r'}"
if ! valid_trusted_domain "$SAVED_TRUSTED_DOMAIN"; then
  echo "错误: $ENV_FILE 中的 DSH_TRUSTED_DOMAIN 无效: $SAVED_TRUSTED_DOMAIN（只允许 hostname，不含协议、端口或路径）"
  exit 1
fi
DSH_TRUSTED_DOMAIN="$SAVED_TRUSTED_DOMAIN"
if [ "$UPGRADE_MODE" -eq 1 ] && ! capture_upgrade_env_before_mutation; then
  echo "错误: 无法在升级前保存原始 .env，拒绝继续升级"
  exit 1
fi
if [ "$SET_PROXY_ARG" -eq 1 ]; then
  if [ "$UPGRADE_MODE" -eq 1 ] && ! capture_upgrade_env_before_mutation; then
    echo "错误: 无法在升级前保存原始 .env，拒绝修改代理配置"
    exit 1
  fi
  if [ "$PROXY" != "$SAVED_PROXY" ]; then
    env_upsert DSH_PROXY "$PROXY" || return 1
    ok "运行时代理已写入 $ENV_FILE：DSH_PROXY=$PROXY"
  fi
elif [ -n "$SAVED_PROXY" ]; then
  PROXY="$(normalize_proxy "$SAVED_PROXY")"
  echo "  沿用 .env 保存的代理: $PROXY（--proxy-host 可覆盖）"
fi

# ---------- 升级模式 ----------
# 升级只允许由 NAS 宿主机上的命令行执行；网页升级和 Docker socket 路径已关闭。
# ---------- HTTP 辅助（curl 优先，wget 兜底） ----------
# 用法: http_get <timeout秒> <url> [可选代理URL]
http_get() {
  if command -v curl >/dev/null 2>&1; then
    if [ $# -ge 3 ]; then curl -s -m "$1" -x "$3" "$2"
    else curl -s -m "$1" "$2"; fi
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- -T "$1" "$2"
  else
    return 1
  fi
}

# ---------- 端口监听检测 ----------
port_listening() { # $1=port
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"
  else
    (echo > "/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1
  fi
}

# 读取本机 listener 地址；ss/netstat 不可用时返回失败，安全校验不能猜测。
listener_addresses() { # $1=port
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk -v p="$1" '$4 ~ (":" p "$" ) {print $4}'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk -v p="$1" '$4 ~ (":" p "$" ) {print $4}'
  else
    return 1
  fi
}

# Caddy admin API 中的实际 HTTP listener（按行输出，如 :443 或 127.0.0.1:13080）。
caddy_listeners() {
  local config
  config=$(docker exec dsh-caddy wget -qO- http://127.0.0.1:2019/config/ 2>/dev/null) || return 1
  printf '%s' "$config" \
    | grep -oE '"listen"[[:space:]]*:[[:space:]]*\[[^]]*\]' \
    | sed -E 's/.*\[(.*)\].*/\1/' \
    | tr ',' '\n' \
    | tr -d '"[:space:]'
}

listener_tool_available() {
  command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1
}

caddy_container_owns_port() { # $1=port；admin API 不可读时保守返回失败
  local port="$1"
  [ -n "${CADDY_CURRENT_LISTENERS:-}" ] \
    && printf '%s\n' "$CADDY_CURRENT_LISTENERS" | grep -qE "(^|:)${port}$"
}

# 检查 Caddy admin API 返回的 listener 是否与入口模式完全一致。
caddy_listener_set_ok() {
  case "$ENTRY_MODE" in
    "$MODE_FRONT_PROXY")
      printf '%s\n' "$CADDY_LISTENERS" | grep -Fxq "127.0.0.1:$INTERNAL_PORT" \
        && [ "$(printf '%s\n' "$CADDY_LISTENERS" | sort -u | wc -l)" -eq 1 ]
      ;;
    "$MODE_DIRECT_80_443")
      printf '%s\n' "$CADDY_LISTENERS" | grep -Fxq ':80' \
        && printf '%s\n' "$CADDY_LISTENERS" | grep -Fxq ':443' \
        && [ "$(printf '%s\n' "$CADDY_LISTENERS" | sort -u | wc -l)" -eq 2 ]
      ;;
    "$MODE_DIRECT_443_ONLY")
      printf '%s\n' "$CADDY_LISTENERS" | grep -Fxq ':443' \
        && [ "$(printf '%s\n' "$CADDY_LISTENERS" | sort -u | wc -l)" -eq 1 ]
      ;;
    *) return 1 ;;
  esac
}

# ---------- 配置向导：域名 / 邮箱 / 密钥 / 鉴权密码 自动写入 ----------
backup_file() { # $1=path
  if [ -f "$1" ]; then
    cp "$1" "$1.bak"
    chmod 600 "$1.bak" 2>/dev/null || true
  fi
}

# 随机密钥（openssl 优先，/dev/urandom 兜底）
gen_secret() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32
  else head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}

# Authelia argon2id 密码哈希（需要 docker 拉取 authelia 镜像）
authelia_hash() { # $1=password；成功输出哈希到 stdout
  local out
  out=$(docker run --rm authelia/authelia:4.39 authelia crypto hash generate argon2 --password "$1" 2>/dev/null) || return 1
  printf '%s' "$out" | grep -o '\$argon2id\$[^[:space:]]*' | head -n 1
}

# 读取一行输入（IFS 含 \r：剥离 Windows 管道可能注入的回车符，保留内部空格）
read_line() { # $1=变量名
  local name="$1" rc
  IFS=$'\t\n\r' read -r "$name"; rc=$?
  return "$rc"
}

# 读取隐藏密码（不回显；\r 同样剥离）
read_secret() { # $1=变量名
  local name="$1" rc
  IFS=$'\n\r' read -s -r "$name"; rc=$?
  echo
  return "$rc"
}

run_setup_wizard() {
  # 已配置且未强制 --setup → 跳过
  if [ "$SETUP_FORCE" -eq 0 ]; then
    local need=0
    # 主方案（Authelia）：密钥、密码、域名都要就绪。
    # Basic Auth 已删除；旧的 :PORT 配置在后面的配置检查中明确拒绝。
    grep -q 'CHANGE_ME_' "$AUTHELIA_CONF" && need=1
    grep -q 'p=8\$\.\.\.' "$USERS_DB" && need=1
    grep -vE '^\s*#' "$CADDYFILE" | grep -q 'example\.com' && need=1
    grep -vE '^\s*#' "$AUTHELIA_CONF" | grep -q 'example\.com' && need=1
    # 模板 Caddyfile 的 example.com 全在注释里，活跃检查发现不了；
    # 若 Caddyfile 活跃配置行太少（无任何站点块/http_port），视为未配置。
    active_lines=$(grep -cE '^\s*[^#[:space:]]' "$CADDYFILE" 2>/dev/null) || active_lines=0
    [ "$active_lines" -lt 3 ] && need=1
    if [ "$need" -eq 0 ]; then
      ok "配置已就绪，跳过向导（用 --setup 可强制重跑）"
      return 0
    fi
  fi
  if [ ! -t 0 ]; then
    fail "检测到配置未完成，但当前不是交互终端；请 SSH 交互运行本脚本，或按 README 手动修改配置"
    return 1
  fi
  SETUP_WIZARD_RAN=1
  echo
  echo "  ${C_B}== 配置向导 ==${C_0}（检测到占位配置，将自动写入；原文件备份为 .bak）"
  # 代理地址（构建 + 运行时统一）。注意：NAS 上构建容器内的 127.0.0.1 是容器自身、
  # 不是宿主——在 NAS 上构建必须填宿主可达地址（如 http://192.168.1.10:7890），
  # 并确认 Clash 允许局域网访问（allow-lan）。回车沿用当前值。
  if [ -n "${SAVED_PROXY:-}" ]; then
    echo "  当前代理: $PROXY（.env 保存，回车沿用，或输入新值）"
  fi
  printf "  输入代理地址（构建/运行出站用）[%s]: " "$PROXY"
  read_line NEW_PROXY || return 1
  if [ -n "$NEW_PROXY" ]; then
    PROXY="$(normalize_proxy "$NEW_PROXY")"
  fi
  if [ "$PROXY" != "$SAVED_PROXY" ]; then
    env_upsert DSH_PROXY "$PROXY" || return 1
    ok "代理已写入 $ENV_FILE：DSH_PROXY=$PROXY"
  fi

  echo "  访问方案：域名 + Authelia 双因素（需要可用域名，如 example.com）"
  MODE_SEL=1
  # ---------- 域名 + Authelia ----------
    printf "  输入根域（如 example.com，不要带 http://）: "
    read_line ROOT || return 1
    ROOT="${ROOT#http://}"; ROOT="${ROOT#https://}"
    case "$ROOT" in
      ""|*" "*|*"/"*|*":"*) fail "无效根域: $ROOT（应为 example.com 形式，不带端口/路径）"; return 1 ;;
    esac
    printf "  Let's Encrypt 证书邮箱 [默认 admin@%s]: " "$ROOT"
    read_line EMAIL || return 1
    [ -z "$EMAIL" ] && EMAIL="admin@$ROOT"
    case "$EMAIL" in
      ""|*" "*) fail "无效邮箱: $EMAIL"; return 1 ;;
    esac

    # 公网入口方式：Caddy 直连 443-only、直连 80/443，或由 lucky/CF 反代终结 TLS。
    echo "  选择公网入口方式："
    echo "    1) Caddy 直连 443-only（仅需空闲 443；不提供 HTTP 自动跳转）"
    echo "    2) Caddy 直连 80/443（80 用于 HTTP→HTTPS 跳转/ACME HTTP-01）"
    echo "    3) lucky / CF Tunnel 等前置反代（公网 TLS 终结，Caddy 只监听内部端口）"
    printf "  请输入 1、2 或 3 [1]: "
    read_line ENTRY_SEL || return 1
    [ -z "$ENTRY_SEL" ] && ENTRY_SEL=1
    case "$ENTRY_SEL" in
      1) ENTRY_MODE="$MODE_DIRECT_443_ONLY" ;;
      2) ENTRY_MODE="$MODE_DIRECT_80_443" ;;
      3)
        ENTRY_MODE="$MODE_FRONT_PROXY"
        # 公网 HTTPS 端口 = lucky/CF 反代监听的端口（浏览器访问时带 :端口）
        printf "  公网 HTTPS 端口（lucky/CF 监听端口，浏览器访问用）[443]: "
        read_line NEW_PUBLIC_PORT || return 1
        if [ -n "$NEW_PUBLIC_PORT" ]; then
          case "$NEW_PUBLIC_PORT" in
            *[!0-9]*) fail "无效端口: $NEW_PUBLIC_PORT（应为 1-65535 的数字）"; return 1 ;;
          esac
          if [ "$NEW_PUBLIC_PORT" -lt 1 ] || [ "$NEW_PUBLIC_PORT" -gt 65535 ]; then
            fail "端口超出范围: $NEW_PUBLIC_PORT（应为 1-65535）"; return 1
          fi
          PUBLIC_PORT="$NEW_PUBLIC_PORT"
        fi
        if [ "$PUBLIC_PORT" != "443" ]; then
          echo "  ${C_Y}  公网访问将是 https://dsh.$ROOT:$PUBLIC_PORT / https://auth.$ROOT:$PUBLIC_PORT（记得防火墙放行 $PUBLIC_PORT）${C_0}"
        fi
        ;;
      *) fail "无效入口方式: $ENTRY_SEL（应为 1、2 或 3）"; return 1 ;;
    esac

    # 修改 authelia 配置前先备份（与 usage 承诺的 .bak 一致）
    backup_file "$AUTHELIA_CONF"
    backup_file "$USERS_DB"

    # 密钥：自动生成并替换 CHANGE_ME_*（已生成过的保留，避免作废现有会话/2FA）
    if grep -q 'CHANGE_ME_' "$AUTHELIA_CONF"; then
      SESSION_SECRET=$(gen_secret); RESET_SECRET=$(gen_secret); STORAGE_SECRET=$(gen_secret)
      if [ -z "$SESSION_SECRET" ] || [ -z "$RESET_SECRET" ] || [ -z "$STORAGE_SECRET" ]; then
        fail "密钥生成失败"; return 1
      fi
      sed -i "s|CHANGE_ME_session_secret|$SESSION_SECRET|" "$AUTHELIA_CONF"
      sed -i "s|CHANGE_ME_reset_password_jwt_secret|$RESET_SECRET|" "$AUTHELIA_CONF"
      sed -i "s|CHANGE_ME_storage_encryption_key|$STORAGE_SECRET|" "$AUTHELIA_CONF"
      ok "已自动生成 Authelia 密钥"
      echo "  ${C_Y}  请保存以下密钥（忘记只能重置配置）:${C_0}"
      echo "    session: $SESSION_SECRET"
      echo "    reset:   $RESET_SECRET"
      echo "    storage: $STORAGE_SECRET"
    fi

    # 域名：先读出配置里当前生效的域名（模板占位 example.com 或上次配置的域名），
    # 再统一替换为本次输入——--setup 换域名时旧域名不是 example.com，只认占位符会漏替换。
    CUR_DOMAIN=$(sed -n "s#^.*authelia_url: 'https://auth\.\([^':]*\).*#\1#p" "$AUTHELIA_CONF" | head -n 1)
    sed -i "s/example\.com/$ROOT/g" "$AUTHELIA_CONF" "$USERS_DB"
    if [ -n "$CUR_DOMAIN" ] && [ "$CUR_DOMAIN" != "example.com" ] && [ "$CUR_DOMAIN" != "$ROOT" ]; then
      sed -i "s/$CUR_DOMAIN/$ROOT/g" "$AUTHELIA_CONF" "$USERS_DB"
      ok "域名已从 $CUR_DOMAIN 改为 $ROOT"
    fi
    # 公网端口：先清掉 URL 里历史残留的 :端口，再按本次入口模式统一追加（幂等，支持换端口）
    sed -i -E "s#(auth\.$ROOT|dsh\.$ROOT):[0-9]+#\1#g" "$AUTHELIA_CONF"
    if [ "$ENTRY_MODE" = "$MODE_FRONT_PROXY" ] && [ "$PUBLIC_PORT" != "443" ]; then
      sed -i "s#https://auth\.$ROOT'#https://auth.$ROOT:$PUBLIC_PORT'#g" "$AUTHELIA_CONF"
      sed -i "s#https://dsh\.$ROOT'#https://dsh.$ROOT:$PUBLIC_PORT'#g" "$AUTHELIA_CONF"
    fi
    ok "已写入域名: auth.$ROOT / dsh.$ROOT"

    # Authelia 登录密码 → argon2id 哈希（--setup 重跑时直接回车可保留现有密码）
    PW_PLACEHOLDER=0
    grep -q 'p=8\$\.\.\.' "$USERS_DB" && PW_PLACEHOLDER=1
    if [ "$PW_PLACEHOLDER" -eq 1 ] || [ "$SETUP_FORCE" -eq 1 ]; then
      if [ "$PW_PLACEHOLDER" -eq 1 ]; then
        printf "  输入 admin 登录密码（Authelia 用，不回显）: "
      else
        printf "  输入新的 admin 登录密码（不回显；直接回车 = 保留现有密码）: "
      fi
      read_secret PW1 || return 1
      if [ -z "$PW1" ] && [ "$PW_PLACEHOLDER" -eq 1 ]; then
        fail "密码不能为空"; return 1
      fi
      if [ -n "$PW1" ]; then
        printf "  再次输入确认: "
        read_secret PW2 || return 1
        if [ "$PW1" != "$PW2" ]; then fail "两次密码不一致"; return 1; fi
        echo "  正在生成 argon2id 哈希（首次需拉取 authelia 镜像，请稍候）..."
        AUTH_HASH=$(authelia_hash "$PW1")
        if [ -z "$AUTH_HASH" ]; then
          fail "密码哈希生成失败（docker 或网络问题）；请手动运行: docker run --rm authelia/authelia:4.39 authelia crypto hash generate argon2 --password '你的密码' 后填入 users_database.yml"
          return 1
        fi
        # 整行替换 password（占位符有公共前缀，片段替换会残留）
        sed -i "s|^\(\s*password: \).*|\1'$AUTH_HASH'|" "$USERS_DB"
        ok "admin 密码已写入（argon2id）"
      else
        ok "保留现有 admin 密码"
      fi
    fi

    # 生成 Caddyfile（主方案，按三种入口模式生成）
    backup_file "$CADDYFILE"
    if [ "$ENTRY_MODE" = "$MODE_FRONT_PROXY" ]; then
      # lucky / CF Tunnel 反代入口：TLS 由前置终结，Caddy 内部 http（$INTERNAL_PORT）
      # authelia_url 用公网 URL（含 lucky 监听端口，如 https://auth.example.com:16666）
      AUTH_URL=$(pub_url "auth.$ROOT")
      cat > "$CADDYFILE" <<EOF
# dsh-nas-entry-mode: front-proxy
# 由 deploy.sh 配置向导生成（模式：lucky/CF 反代入口，Caddy 内部 http）（原始文件备份于同目录 .bak）
{
    auto_https off
    http_port $INTERNAL_PORT
    default_bind 127.0.0.1
}

http://auth.$ROOT {
    reverse_proxy 127.0.0.1:9091 {
        header_up X-Forwarded-Proto https
    }
}

http://dsh.$ROOT {
    forward_auth 127.0.0.1:9091 {
        uri /api/authz/forward-auth?authelia_url=$AUTH_URL
        copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
        header_up X-Forwarded-Proto https
        # Caddy 响应匹配器必须是命名 matcher（@ 开头），不能直接写状态码
        @authfail {
            status 401
        }
        handle_response @authfail {
            redir {http.response.header.Location} 302
        }
    }
    reverse_proxy 127.0.0.1:3080 {
        header_up Host 127.0.0.1:3080
        header_up Origin http://127.0.0.1:3080
        header_up X-Forwarded-Proto https
    }
}
EOF
      ok "已生成 Caddyfile（反代入口模式，内部 http://127.0.0.1:$INTERNAL_PORT，域名 $ROOT）"
      echo "  ${C_Y}  提示: 在 lucky/CF 中把 dsh.$ROOT 和 auth.$ROOT 都转发到 http://127.0.0.1:$INTERNAL_PORT，并设 X-Forwarded-Proto: https。"
      echo "  后端地址必须填 127.0.0.1，不能填 NAS 局域网 IP——Caddy 只监听回环，局域网无法绕过认证直连。"
      echo "  前置反代必须与本机 Caddy 同网络命名空间（host 网络）或能访问 NAS 回环地址，否则转发不通${C_0}"
    else
      if [ "$ENTRY_MODE" = "$MODE_DIRECT_80_443" ]; then
        # Caddy 直连公网：80/443，保留 HTTP→HTTPS 跳转并允许 ACME HTTP-01。
        cat > "$CADDYFILE" <<EOF
# dsh-nas-entry-mode: direct-80-443
# 由 deploy.sh 配置向导生成（模式：Caddy 直连公网，80/443）（原始文件备份于同目录 .bak）
{
    email $EMAIL
}

https://auth.$ROOT {
    reverse_proxy 127.0.0.1:9091
}

https://dsh.$ROOT {
    forward_auth 127.0.0.1:9091 {
        uri /api/authz/forward-auth?authelia_url=https://auth.$ROOT
        copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
        @authfail {
            status 401
        }
        handle_response @authfail {
            redir {http.response.header.Location} 302
        }
    }
    reverse_proxy 127.0.0.1:3080 {
        header_up Host 127.0.0.1:3080
        header_up Origin http://127.0.0.1:3080
    }
}
EOF
        ok "已生成 Caddyfile（直连模式，80/443 + HTTP→HTTPS，域名 $ROOT）"
        echo "  ${C_Y}  提示: 确保域名解析到 NAS，防火墙放行 80 和 443${C_0}"
      else
        # Caddy 直连公网：443-only，证书默认使用 ACME TLS-ALPN-01（不依赖 80，
        # NAS 系统占用 80 无碍）。disable_redirects 只关闭自动 HTTP 跳转，保留证书自动化。
        cat > "$CADDYFILE" <<EOF
# dsh-nas-entry-mode: direct-443-only
# 由 deploy.sh 配置向导生成（模式：Caddy 直连公网，443-only）（原始文件备份于同目录 .bak）
{
    email $EMAIL
    auto_https disable_redirects
}

https://auth.$ROOT {
    reverse_proxy 127.0.0.1:9091
}

https://dsh.$ROOT {
    forward_auth 127.0.0.1:9091 {
        uri /api/authz/forward-auth?authelia_url=https://auth.$ROOT
        copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
        # Caddy 响应匹配器必须是命名 matcher（@ 开头），不能直接写状态码
        @authfail {
            status 401
        }
        handle_response @authfail {
            redir {http.response.header.Location} 302
        }
    }
    reverse_proxy 127.0.0.1:3080 {
        header_up Host 127.0.0.1:3080
        header_up Origin http://127.0.0.1:3080
    }
}
EOF
        ok "已生成 Caddyfile（直连模式，443-only + TLS-ALPN-01，域名 $ROOT）"
        echo "  ${C_Y}  提示: 确保域名解析到 NAS（DDNS/lucky），防火墙放行 443${C_0}"
      fi
    fi

  echo "  ${C_G}配置向导完成，继续检查...${C_0}"
}

# ============================================================
section "1. 环境检查"
# ---------- docker / compose ----------
COMPOSE=""
if command -v docker >/dev/null 2>&1; then
  if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"; ok "docker 与 docker compose 可用"
  elif command -v docker-compose >/dev/null 2>&1 \
       && docker-compose version 2>/dev/null | head -n 1 | grep -q 'version v2'; then
    # 独立版二进制也叫 docker-compose，但必须是 V2：compose 文件用了 profiles 和
    # depends_on condition，V1（python 版）解析不了，兜底接受它只会在 up 时才报错。
    COMPOSE="docker-compose"; ok "docker-compose（Compose V2 独立版）可用"
  elif command -v docker-compose >/dev/null 2>&1; then
    fail "docker-compose 是旧版 V1，不支持本项目 compose 文件（profiles / depends_on condition）；请安装 Compose V2（docker compose 插件或 v2 独立版）"
  else
    fail "docker 已安装但没有 compose 插件"
  fi
else
  fail "docker 未安装"
fi

# ---------- 必要文件 ----------
section "2. 文件完整性"
for f in Dockerfile entrypoint.sh patch-trusted-domain.mjs docker-compose.yml \
          caddy/Caddyfile authelia/configuration.yml authelia/users_database.yml; do
  if [ -f "$SCRIPT_DIR/$f" ]; then ok "$f"; else fail "$f 缺失"; fi
done

# ---------- 配置向导（检测到占位符时自动交互配置） ----------
section "3. 配置向导"
if [ "$UPGRADE_MODE" -eq 1 ]; then
  ok "升级模式：跳过 Caddy/Authelia 配置向导（dsh patch 仍会单独询问）"
  backup_upgrade_configs || {
    fail "无法创建升级前配置快照；为保护版本和 Caddy/Authelia，停止升级"
    exit 1
  }
  # --latest：从 npm registry 取 @deepseek-ai/dsh 最新版写入版本文件（与网页端升级同一数据源）
  if [ "$LATEST_MODE" -eq 1 ]; then
    REG_URL="https://registry.npmjs.org/@deepseek-ai%2fdsh/latest"
    LATEST_JSON=$(http_get 10 "$REG_URL")
    [ -z "$LATEST_JSON" ] && LATEST_JSON=$(http_get 15 "$REG_URL" "$PROXY")
    LATEST_V=$(printf '%s' "$LATEST_JSON" | grep -o '"version": *"[^"]*"' | head -n 1 | cut -d'"' -f4)
    if ! [[ "$LATEST_V" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
      fail "获取 npm 最新版本失败（registry 直连与代理均不可达，或返回异常）"
      echo "  可手动改 Dockerfile 的 DSH_VERSION 后，不带 --latest 重跑"
      exit 1
    fi
    OLD_V=$(sed -n 's/^ARG DSH_VERSION=//p' "$SCRIPT_DIR/Dockerfile" | head -n 1)
    if [ -z "$OLD_V" ]; then
      fail "Dockerfile 中缺少唯一的 DSH_VERSION 版本来源"
      exit 1
    fi
    if ! update_dsh_version_atomic "$LATEST_V"; then
      fail "无法原子更新 Dockerfile 的 DSH_VERSION"
      exit 1
    fi
    if [ "$OLD_V" = "$LATEST_V" ]; then
      ok "npm 最新版 $LATEST_V 与当前一致（构建走缓存）"
    else
      ok "dsh 版本已更新: ${OLD_V:-?} → $LATEST_V（npm latest）"
    fi
  fi
else
  run_setup_wizard || exit 1
fi

# 首次部署/--setup 与 --upgrade/--latest 都独立询问 patch；升级时必须在
# backup_upgrade_configs() 之后进行，这样 .env 的最早快照已经就绪，可以安全回滚。
ACTIVE_CADDY=$(sed '/^[[:space:]]*#/d' "$CADDYFILE")
CURRENT_DSH_HOST=""
CURRENT_DSH_HOST=$(printf '%s\n' "$ACTIVE_CADDY" \
  | grep -oE '^(https?://)dsh\.[^ {]+' \
  | head -n 1 \
  | sed -E 's#^https?://##; s#:[0-9]+$##')
if [ "$UPGRADE_MODE" -eq 1 ] || [ "$SETUP_WIZARD_RAN" -eq 1 ]; then
  configure_trusted_domain "$SAVED_TRUSTED_DOMAIN" "$CURRENT_DSH_HOST" || exit 1
  if [ "$DSH_TRUSTED_DOMAIN_CHANGED" -eq 1 ] && [ "$SKIP_BUILD" -eq 1 ]; then
    fail "DSH_TRUSTED_DOMAIN 已改变，但 --skip-build 不会重建镜像；请去掉 --skip-build"
    exit 1
  fi
  persist_trusted_domain || {
    fail "无法保存 DSH_TRUSTED_DOMAIN 到 $ENV_FILE"
    exit 1
  }
fi

# Basic Auth 已删除：过滤注释后，发现旧的裸端口站点或 basic_auth 指令时直接要求迁移。
if printf '%s\n' "$ACTIVE_CADDY" | grep -qE '(^|[[:space:]])(:[0-9]+|basic_auth|basicauth)([[:space:]]|\{|$)'; then
  fail "检测到已删除的 Basic Auth/裸端口 Caddy 配置（$CADDYFILE）；请先保留备份，再运行 ./deploy.sh --setup 迁移到域名 + Authelia 或前置反代/Tunnel。旧 Basic Auth 密码不会自动迁移。"
  exit 1
fi

# 入口模式通过向导写入的显式标记恢复；无标记的旧手工配置只做兼容性探测，
# 探测失败时拒绝继续，避免错误检查 443/13080 和输出错误访问地址。
MODE_MARKER=$(sed -n 's/^# dsh-nas-entry-mode: //p' "$CADDYFILE" | head -n 1)
if [ -n "$MODE_MARKER" ]; then
  case "$MODE_MARKER" in
    "$MODE_DIRECT_80_443"|"$MODE_DIRECT_443_ONLY"|"$MODE_FRONT_PROXY") ENTRY_MODE="$MODE_MARKER" ;;
    *) fail "Caddyfile 的入口模式标记无效: $MODE_MARKER"; exit 1 ;;
  esac
else
  if printf '%s\n' "$ACTIVE_CADDY" | grep -qE '(^|[[:space:]])http://'; then
    ENTRY_MODE="$MODE_FRONT_PROXY"
  elif printf '%s\n' "$ACTIVE_CADDY" | grep -qE '(^|[[:space:]])https://'; then
    ENTRY_MODE="$MODE_DIRECT_443_ONLY"
  else
    fail "无法确定 Caddy 入口模式；请运行 ./deploy.sh --setup 重新生成带模式标记的配置"
    exit 1
  fi
  warn "Caddyfile 缺少入口模式标记，已根据活跃站点兼容探测为 $ENTRY_MODE；这是兼容回退，建议运行 ./deploy.sh --setup 固化模式"
fi

# 主方案始终启动 Authelia；Basic Auth 已删除。
PROFILE_ARGS="--profile auth"

# Authelia 配置必须先通过官方镜像校验，避免错误配置进入 Compose。
validate_authelia_config() {
  if ! docker run --rm --entrypoint authelia \
       -v "$SCRIPT_DIR/authelia:/config:ro" \
       -v "$SCRIPT_DIR/authelia/data:/config/data:ro" \
       authelia/authelia:4.39 --config /config/configuration.yml config validate >/dev/null 2>&1; then
    fail "Authelia 配置校验失败；请运行 docker run --rm --entrypoint authelia -v \"$SCRIPT_DIR/authelia:/config:ro\" -v \"$SCRIPT_DIR/authelia/data:/config/data:ro\" authelia/authelia:4.39 --config /config/configuration.yml config validate 查看详情"
    return 1
  fi
  ok "Authelia 4.39 配置校验通过"
}
validate_compose_config() {
  if ! $COMPOSE config --quiet >/dev/null 2>&1; then
    fail "$COMPOSE config 校验失败；请修复 Compose 文件或变量后重试"
    return 1
  fi
  ok "Docker Compose 配置校验通过"
}
validate_caddy_config() {
  if ! docker run --rm -i caddy:2-alpine caddy validate --config - --adapter caddyfile <"$CADDYFILE" >/dev/null 2>&1; then
    fail "Caddyfile 语法校验失败；请运行 docker run --rm -i caddy:2-alpine caddy validate --config - --adapter caddyfile < \"$CADDYFILE\" 查看详情"
    return 1
  fi
  ok "Caddyfile 语法校验通过"
}
if [ "$UPGRADE_MODE" -eq 0 ]; then
  validate_authelia_config || exit 1
fi
if [ -n "$COMPOSE" ]; then
  validate_compose_config || exit 1
fi
validate_caddy_config || exit 1

# 反代入口模式下从 authelia_url 还原公网端口；缺失或非法时不静默回退。
if [ "$ENTRY_MODE" = "$MODE_FRONT_PROXY" ]; then
  CADDY_PUBLIC_PORT=$(printf '%s\n' "$ACTIVE_CADDY" | grep -oE 'authelia_url=https?://[^[:space:]{}]+' | head -n 1 | sed -n 's#.*:\([0-9][0-9]*\)$#\1#p')
  if [ -n "$CADDY_PUBLIC_PORT" ]; then
    if [ "$CADDY_PUBLIC_PORT" -lt 1 ] || [ "$CADDY_PUBLIC_PORT" -gt 65535 ]; then
      fail "Caddyfile 的公网端口无效: $CADDY_PUBLIC_PORT"; exit 1
    fi
    PUBLIC_PORT="$CADDY_PUBLIC_PORT"
  else
    warn "反代 Caddyfile 未在 authelia_url 中声明公网端口，按 443 处理；请确认前置代理实际监听 443"
  fi
fi

# ---------- 配置占位符 ----------
section "4. 配置检查（密钥 / 密码 / 域名）"
  if grep -q 'CHANGE_ME_' "$AUTHELIA_CONF"; then
    fail "authelia/configuration.yml 仍有 CHANGE_ME_* 占位密钥（用 openssl rand -hex 32 生成后替换）"
  else
    ok "Authelia 密钥已配置"
  fi
  if grep -q 'p=8\$\.\.\.' "$USERS_DB"; then
    fail "users_database.yml 仍是占位密码哈希（运行: docker run --rm authelia/authelia:4.39 authelia crypto hash generate argon2 --password '你的密码'）"
  else
    ok "用户密码哈希已配置"
  fi
  # 只检查活跃配置（过滤注释行）；Caddyfile 全局 email 也会被捕获，一并提示
  if grep -vE '^\s*#' "$CADDYFILE" | grep -q 'example\.com' \
     || grep -vE '^\s*#' "$AUTHELIA_CONF" | grep -q 'example\.com'; then
    warn "活跃配置中仍有 example.com（域名或证书邮箱）"
  else
    ok "域名占位符已替换"
  fi
  # Authelia 配置含会话/JWT/存储密钥和密码哈希，宿主上必须 0600，防止同机其它用户读取
  for f in "$AUTHELIA_CONF" "$USERS_DB" "$AUTHELIA_CONF.bak" "$USERS_DB.bak"; do
    [ -f "$f" ] || continue
    if [ "$(stat -c '%a' "$f" 2>/dev/null)" = "600" ]; then
      ok "$(basename "$f") 权限为 0600"
    elif chmod 600 "$f" 2>/dev/null; then
      ok "已收紧 $(basename "$f") 权限为 0600"
    else
      fail "$(basename "$f") 含密钥/密码哈希但无法收紧到 0600；请手动执行 chmod 600"
    fi
  done

# ---------- 数据目录权限 ----------
section "5. 数据目录权限（容器内以 UID 1000 运行）"
chown_dir() { # $1=path
  if [ "$(id -u)" -eq 0 ]; then chown -R 1000:1000 "$1"
  elif command -v sudo >/dev/null 2>&1; then sudo chown -R 1000:1000 "$1"
  else return 1; fi
}
check_dir_perm() { # $1=path $2=用途说明
  local dir="$1" label="$2"
  local OWNER
  if [ ! -d "$dir" ]; then
    if mkdir -p "$dir" 2>/dev/null; then
      if chown_dir "$dir" 2>/dev/null; then ok "已创建 $dir 并 chown 1000:1000（$label）"
      else fail "已创建 $dir 但无法 chown 1000:1000（$label）；请手动修复权限"; fi
    else
      fail "无法创建 $dir（$label）；请手动创建并确保 UID 1000 可写"
    fi
  else
    OWNER=$(stat -c %u "$dir" 2>/dev/null || echo "?")
    if [ "$OWNER" = "1000" ]; then
      ok "$dir 属主 = 1000（$label）"
    elif [ "$OWNER" = "?" ]; then
      fail "无法读取 $dir 属主（$label）；请确认 NAS 支持 GNU stat 并手动检查权限"
    elif chown_dir "$dir" 2>/dev/null; then
      ok "已 chown -R 1000:1000（$label，原属主 $OWNER）"
    else
      fail "$dir 属主为 $OWNER 且无法修复（应为 1000，$label）"
    fi
  fi
}
check_container_dir_perm() { # $1=path $2=用途说明
  local dir="$1" label="$2"
  if [ ! -d "$dir" ]; then
    if mkdir -p "$dir" 2>/dev/null; then
      ok "已创建 $dir（$label）"
    else
      fail "无法创建 $dir（$label）；请手动创建并确保容器可写"
    fi
  elif [ -L "$dir" ]; then
    fail "$dir 不能是符号链接（$label）"
  else
    ok "$dir 已存在（$label；由对应容器用户写入）"
  fi
}
write_test_as_container_root() { # $1=directory $2=用途说明 $3=image
  # 注意：local 一行内的赋值是先展开后赋值，probe 引用 probe_name 必须拆成第二条 local
  local dir="$1" label="$2" image="$3" probe_name=".dsh-nas-root-write-test.$$"
  local probe="$dir/$probe_name"
  if [ "$(id -u)" -eq 0 ] \
     && sh -c 'p="$1"; printf "ok\\n" >"$p" && rm -f "$p"' sh "$probe" >/dev/null 2>&1 \
     && [ ! -e "$probe" ]; then
    ok "$dir 实际写入和删除测试通过（$label，宿主 root/容器 root）"
  elif command -v docker >/dev/null 2>&1 \
       && docker run --rm --entrypoint sh -v "$dir:/probe" "$image" \
            -c 'p="/probe/$1"; printf "ok\\n" >"$p" && rm -f "$p"' sh "$probe_name" >/dev/null 2>&1 \
       && [ ! -e "$probe" ]; then
    ok "$dir 实际写入和删除测试通过（$label，容器 root）"
  else
    rm -f "$probe" 2>/dev/null || true
    fail "$dir 实际写入测试失败（$label）；请确认对应容器用户可以创建、写入和删除文件"
  fi
}
write_test_as_uid1000() { # $1=directory $2=用途说明
  # 注意：local 一行内的赋值是先展开后赋值，probe 引用 probe_name 必须拆成第二条 local
  local dir="$1" label="$2" probe_name=".dsh-nas-write-test.$$"
  local probe="$dir/$probe_name"
  # 首次部署时镜像尚未构建，优先用真实 UID 1000 做宿主文件系统测试。
  if [ "$(id -u)" -eq 1000 ] \
     && sh -c 'p="$1"; printf "ok\\n" >"$p" && rm -f "$p"' sh "$probe" >/dev/null 2>&1 \
     && [ ! -e "$probe" ]; then
    ok "$dir 实际写入和删除测试通过（$label，当前 UID 1000）"
  elif [ "$(id -u)" -eq 0 ] && command -v setpriv >/dev/null 2>&1 \
       && setpriv --reuid=1000 --regid=1000 --init-groups \
            sh -c 'p="$1"; printf "ok\\n" >"$p" && rm -f "$p"' sh "$probe" >/dev/null 2>&1 \
       && [ ! -e "$probe" ]; then
    ok "$dir 实际写入和删除测试通过（$label，宿主 UID 1000）"
  elif command -v docker >/dev/null 2>&1 && docker image inspect dsh:local >/dev/null 2>&1 \
       && docker run --rm --entrypoint node -v "$dir:/probe" dsh:local \
            -e 'const fs=require("node:fs"); const p="/probe/"+process.argv[1]; fs.writeFileSync(p,"ok\\n"); fs.unlinkSync(p)' "$probe_name" >/dev/null 2>&1 \
       && [ ! -e "$probe" ]; then
    ok "$dir 实际写入和删除测试通过（$label，dsh node UID 1000）"
  else
    rm -f "$probe" 2>/dev/null || true
    fail "$dir 实际写入测试失败（$label）；请确认本地文件系统允许 UID 1000 创建、写入和删除文件"
  fi
}
check_dir_perm "$DATA_DIR" "DSH 数据目录（配置/凭据/会话/存储）"
check_dir_perm "$WORKSPACE_DIR" "工作区目录（Web 目录选择器新建落点）"
check_dir_perm "$DATA_DIR/profiles" "插件 profile 目录（node 用户必须可写）"
check_dir_perm "$DATA_DIR/profiles/node_modules" "插件 node_modules 目录（node 用户必须可写）"
check_container_dir_perm "$SCRIPT_DIR/caddy/data" "Caddy 证书和运行数据"
check_container_dir_perm "$SCRIPT_DIR/caddy/config" "Caddy 配置状态"
check_container_dir_perm "$SCRIPT_DIR/authelia/data" "Authelia SQLite 和通知文件"
if [ "$FAIL" -eq 0 ]; then
  write_test_as_uid1000 "$DATA_DIR" "DSH 数据目录"
  write_test_as_uid1000 "$WORKSPACE_DIR" "工作区目录"
  write_test_as_uid1000 "$DATA_DIR/profiles" "插件 profile 目录"
  write_test_as_uid1000 "$DATA_DIR/profiles/node_modules" "插件 node_modules 目录"
  write_test_as_container_root "$SCRIPT_DIR/caddy/data" "Caddy 数据目录" caddy:2-alpine
  write_test_as_container_root "$SCRIPT_DIR/caddy/config" "Caddy 配置目录" caddy:2-alpine
  write_test_as_container_root "$SCRIPT_DIR/authelia/data" "Authelia 数据目录" authelia/authelia:4.39
fi

# ---------- 端口与代理 ----------
section "6. 端口与代理检查"
# 只对实际持有目标端口的同名服务容器跳过冲突检查；不能因任一旧容器运行
# 就跳过其它服务的端口检查。
container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$1"
}

# 代理监听检测：从 $PROXY 解析目标（本机才检测监听，远程代理只测连通性）
PROXY_HOSTPORT="${PROXY#http://}"; PROXY_HOSTPORT="${PROXY_HOSTPORT#https://}"
PROXY_HOST="${PROXY_HOSTPORT%%:*}"
PROXY_PORT="${PROXY_HOSTPORT##*:}"
if [ "$PROXY_HOST" = "127.0.0.1" ] || [ "$PROXY_HOST" = "localhost" ]; then
  case "$PROXY_PORT" in
    *[!0-9]*|'') warn "代理地址缺端口: $PROXY；dsh 出站可能失败" ;;
    *)
      if port_listening "$PROXY_PORT"; then
        ok "宿主代理端口 $PROXY_PORT 在监听"
      else
        warn "宿主 $PROXY_PORT 端口未监听（代理未运行？部署可继续但 dsh 出站会失败）"
      fi ;;
  esac
else
  echo "  代理在远程主机 $PROXY_HOSTPORT（跳过本机监听检测，仅测连通性）"
fi
if http_get 8 "https://api.deepseek.com" >/dev/null 2>&1; then
  ok "直连出站正常"
elif http_get 8 "https://api.deepseek.com" "$PROXY" >/dev/null 2>&1; then
  ok "经代理 $PROXY 出站正常"
else
  warn "经代理 $PROXY 访问 api.deepseek.com 失败（代理可能未就绪，部署可继续但模型请求会失败）"
fi

CADDY_CURRENT_LISTENERS=""
if container_running dsh-caddy; then
  CADDY_CURRENT_LISTENERS=$(caddy_listeners 2>/dev/null || true)
fi

if ! listener_tool_available; then
  fail "无法读取宿主 listener 地址（需要 ss 或 netstat）；拒绝继续部署"
elif [ -n "$(listener_addresses 3080 2>/dev/null || true)" ]; then
  DSH_CURRENT_LISTENERS=$(listener_addresses 3080 2>/dev/null || true)
  if container_running dsh \
     && printf '%s\n' "$DSH_CURRENT_LISTENERS" | grep -Fxq '127.0.0.1:3080' \
     && [ "$(printf '%s\n' "$DSH_CURRENT_LISTENERS" | sort -u | wc -l)" -eq 1 ]; then
    ok "dsh 容器已运行，确认仅占用 127.0.0.1:3080"
  elif container_running dsh; then
    fail "现有 dsh listener 不符合回环安全预期（实际：$(printf '%s ' "$DSH_CURRENT_LISTENERS")）"
  else
    fail "宿主 3080 端口已被占用（实际 listener: $(printf '%s ' "$DSH_CURRENT_LISTENERS")；host 网络下 dsh 无法绑定）"
  fi
else
  ok "dsh 端口 3080 空闲"
fi

if [ "$ENTRY_MODE" = "$MODE_FRONT_PROXY" ]; then
  # 反代入口（lucky/CF）：Caddy 只监听内部 $INTERNAL_PORT，公网端口由前置反代负责。
  FRONT_LISTENERS=$(listener_addresses "$INTERNAL_PORT" 2>/dev/null || true)
  if [ -n "$FRONT_LISTENERS" ]; then
    if container_running dsh-caddy \
       && printf '%s\n' "$CADDY_CURRENT_LISTENERS" | grep -Fxq "127.0.0.1:$INTERNAL_PORT" \
       && [ "$(printf '%s\n' "$CADDY_CURRENT_LISTENERS" | sort -u | wc -l)" -eq 1 ]; then
      ok "dsh-caddy 容器已运行，确认占用回环内部端口 127.0.0.1:$INTERNAL_PORT"
    elif container_running dsh-caddy && [ -n "$CADDY_CURRENT_LISTENERS" ]; then
      fail "现有 dsh-caddy listener 不符合回环内部模式（实际：$(printf '%s ' "$CADDY_CURRENT_LISTENERS")）"
    elif container_running dsh-caddy; then
      fail "现有 dsh-caddy 已运行但无法读取 admin API listener；拒绝假定其占用端口安全"
    else
      fail "宿主 $INTERNAL_PORT 端口已被占用（实际 listener: $(printf '%s ' "$FRONT_LISTENERS")；Caddy 需绑定回环内部端口）"
    fi
  else
    ok "Caddy 内部端口 $INTERNAL_PORT 空闲"
  fi
elif [ "$ENTRY_MODE" = "$MODE_DIRECT_80_443" ]; then
  for required_port in 80 443; do
    REQUIRED_LISTENERS=$(listener_addresses "$required_port" 2>/dev/null || true)
    if [ -n "$REQUIRED_LISTENERS" ]; then
      if container_running dsh-caddy && caddy_container_owns_port "$required_port"; then
        ok "dsh-caddy 容器已运行，保留端口 $required_port；启动后仍会校验完整 80/443 listener"
      elif container_running dsh-caddy; then
        fail "现有 dsh-caddy 未在 admin API 中声明端口 $required_port；拒绝假定端口冲突可复用"
      else
        fail "宿主 $required_port 端口已被占用（实际 listener: $(printf '%s ' "$REQUIRED_LISTENERS")；直连 80/443 模式需要该端口）"
      fi
    else
      ok "Caddy 端口 $required_port 空闲（直连 80/443 模式）"
    fi
  done
else
  # 直连 443-only：不需要 80，且启动后必须确认没有 80 listener。
  REQUIRED_LISTENERS=$(listener_addresses 443 2>/dev/null || true)
  if [ -n "$REQUIRED_LISTENERS" ]; then
    if container_running dsh-caddy \
       && printf '%s\n' "$CADDY_CURRENT_LISTENERS" | grep -Fxq ':443' \
       && [ "$(printf '%s\n' "$CADDY_CURRENT_LISTENERS" | sort -u | wc -l)" -eq 1 ]; then
      ok "dsh-caddy 容器已运行，确认占用 443"
    elif container_running dsh-caddy && [ -n "$CADDY_CURRENT_LISTENERS" ]; then
      fail "现有 dsh-caddy listener 不符合 443-only 预期（实际：$(printf '%s ' "$CADDY_CURRENT_LISTENERS")）"
    elif container_running dsh-caddy; then
      fail "现有 dsh-caddy 已运行但无法读取 admin API listener；拒绝假定 443-only 安全"
    else
      fail "宿主 443 端口已被占用（实际 listener: $(printf '%s ' "$REQUIRED_LISTENERS")；Caddy 直连模式需要该端口）"
    fi
  else
    ok "Caddy 端口 443 空闲（443-only 模式）"
  fi
fi

# ============================================================
if [ "$FAIL" -gt 0 ]; then
  echo
  echo "${C_R}${C_B}有 $FAIL 项检查未通过，中止部署。${C_0}"
  echo "修复后重新运行: $0"
  exit 1
fi

# ---------- 构建与启动 ----------
section "7. 构建与启动"
cd "$SCRIPT_DIR"
compose_up() {
  # --profile 是 compose 顶层 flag，必须置于子命令之前：docker compose --profile auth up -d
  if [ "$UPGRADE_MODE" -eq 1 ]; then
    UPGRADE_SWITCH_ATTEMPTED=1
  fi
  if $COMPOSE $PROFILE_ARGS up -d; then
    UP_OK=1
    if [ "$UPGRADE_MODE" -eq 1 ]; then
      if upgrade_stack_changed; then
        UPGRADE_SWITCHED=1
      else
        echo "  ${C_Y}升级: Compose 成功但未确认容器或镜像已切换；后续失败不会停止原栈${C_0}"
      fi
    fi
    ok "容器已启动"
    return 0
  fi
  fail "$COMPOSE up -d 失败；运行 $COMPOSE logs 排查（常见: Caddyfile 语法错误 / 端口绑定失败）"
  return 1
}
compose_down_current() {
  [ -n "$COMPOSE" ] || return 1
  $COMPOSE $PROFILE_ARGS down
}
UP_OK=0
if [ "$SKIP_BUILD" -eq 1 ]; then
  ok "跳过构建，直接启动"
  if ! compose_up; then
    echo "  ${C_R}Compose 启动失败，进入统一失败处理。${C_0}"
  fi
else
  echo "  构建镜像（首次约 10 分钟，native 依赖编译；npm 走代理 $PROXY；DSH patch=${DSH_TRUSTED_DOMAIN:-关闭}）..."
  if $COMPOSE build \
       --build-arg "HTTP_PROXY=$PROXY" \
       --build-arg "HTTPS_PROXY=$PROXY" \
       --build-arg "DSH_TRUSTED_DOMAIN=$DSH_TRUSTED_DOMAIN"; then
    ok "构建完成"
  else
    echo "${C_R}构建失败。${C_0}"
    echo "  ${C_Y}常见原因与处理：${C_0}"
    echo "  1) apt 阶段失败：apt 与 npm 一样走构建代理（默认 Debian 源）——检查代理是否可达（地址正确、Clash 开了 allow-lan）；"
    echo "     可换可用代理重跑: $0 --proxy-host <宿主IP>:7890"
    echo "  2) npm 阶段失败：构建容器内的 127.0.0.1 是容器自身，不是宿主——"
    echo "     必须用宿主可达地址重跑：${C_B}./deploy.sh --proxy-host 192.168.1.10${C_0}（换成 NAS 局域网 IP）"
    echo "     并确认 Clash 允许局域网访问（allow-lan: true，监听 0.0.0.0:7890）。"
    echo "  修复后重跑本脚本即可。"
    exit 1
  fi
  if ! compose_up; then
    echo "  ${C_R}Compose 启动失败，进入统一失败处理。${C_0}"
  fi
fi

# ---------- 等待健康 ----------
section "8. 等待服务就绪与安全验证"
if [ "$UP_OK" -ne 1 ]; then
  fail "容器未成功启动，跳过健康等待与安全验证"
else
  STATUS="starting"
  AUTHELIA_STATUS="starting"
  CADDY_STATUS="starting"
  for i in $(seq 1 40); do
    STATUS=$(docker inspect -f '{{.State.Health.Status}}' dsh 2>/dev/null || echo "starting")
    AUTHELIA_STATUS=$(docker inspect -f '{{.State.Health.Status}}' authelia 2>/dev/null || echo "starting")
    CADDY_STATUS=$(docker inspect -f '{{.State.Health.Status}}' dsh-caddy 2>/dev/null || echo "starting")
    [ "$STATUS" = "healthy" ] && [ "$AUTHELIA_STATUS" = "healthy" ] && [ "$CADDY_STATUS" = "healthy" ] && break
    sleep 3
  done
  if [ "$STATUS" = "healthy" ]; then
    ok "dsh 健康检查通过"
  else
    fail "dsh 未在 120 秒内 healthy；运行 docker compose logs dsh 排查"
  fi
  if [ "$AUTHELIA_STATUS" = "healthy" ]; then
    ok "Authelia 容器健康检查通过"
  else
    fail "Authelia 容器未在 120 秒内 healthy；运行 docker compose logs authelia 排查"
  fi
  if [ "$CADDY_STATUS" = "healthy" ]; then
    ok "Caddy 容器 healthcheck 通过"
  else
    fail "Caddy 容器未在 120 秒内 healthy；运行 docker compose logs caddy 排查"
  fi

  # 安全验证：host 网络下 dsh 必须只绑定回环，否则局域网可绕过 Caddy+Authelia 直连
  LISTEN_3080=""
  if command -v ss >/dev/null 2>&1; then
    LISTEN_3080=$(ss -ltn 2>/dev/null | awk '{print $4}' | grep -E '[:.]3080$')
  elif command -v netstat >/dev/null 2>&1; then
    LISTEN_3080=$(netstat -ltn 2>/dev/null | awk '{print $4}' | grep -E '[:.]3080$')
  fi
  if [ -z "$LISTEN_3080" ]; then
    fail "无法读取 3080 绑定地址（ss/netstat 不可用）；拒绝继续部署，请安装 ss 或 netstat 后重试"
  elif printf '%s\n' "$LISTEN_3080" | grep -qvE '^127\.0\.0\.1:3080$'; then
    fail "dsh 监听在非回环地址（$(printf '%s' "$LISTEN_3080" | tr '\n' ' ')）——局域网可绕过鉴权直连！立即处理: docker compose stop dsh，确认 entrypoint.sh 的 --host 127.0.0.1 未被改动"
  else
    ok "dsh 仅监听 127.0.0.1:3080（无法绕过 Caddy+Authelia 直连）"
  fi

  # Authelia 同样必须只绑定回环；否则可绕过 Caddy 的访问控制接口。
  LISTEN_9091=$(listener_addresses 9091 2>/dev/null || true)
  if [ -z "$LISTEN_9091" ]; then
    fail "无法读取 Authelia 9091 绑定地址（ss/netstat 不可用或服务未监听）；拒绝继续部署"
  elif printf '%s\n' "$LISTEN_9091" | grep -qvE '^127\.0\.0\.1:9091$' \
       || [ "$(printf '%s\n' "$LISTEN_9091" | sort -u | wc -l)" -ne 1 ]; then
    fail "Authelia 监听在非预期地址（$(printf '%s' "$LISTEN_9091" | tr '\n' ' ')）；应仅为 127.0.0.1:9091"
  else
    ok "Authelia 仅监听 127.0.0.1:9091"
  fi

  if [ "$AUTHELIA_STATUS" = "healthy" ] && http_get 5 "http://127.0.0.1:9091/api/health" | grep -q '"status":"OK"'; then
    ok "Authelia 健康"
  else
    fail "Authelia 未通过健康检查；运行 docker compose logs authelia 排查（常见: 密钥未替换/配置报错）"
  fi

  if [ "$CADDY_STATUS" = "healthy" ]; then
    ok "Caddy admin API 健康"
  else
    fail "Caddy 未通过 healthcheck；运行 docker compose logs caddy 排查（常见: Caddyfile 语法错误/端口绑定失败）"
  fi

  CADDY_LISTENERS=$(caddy_listeners 2>/dev/null || true)
  if [ -z "$CADDY_LISTENERS" ]; then
    fail "无法从 Caddy admin API 读取 HTTP listener；拒绝继续部署"
  elif caddy_listener_set_ok; then
    case "$ENTRY_MODE" in
      "$MODE_FRONT_PROXY") ok "Caddy 反代模式仅监听回环内部端口 127.0.0.1:$INTERNAL_PORT" ;;
      "$MODE_DIRECT_80_443") ok "Caddy 直连 80/443 模式仅监听 80 和 443" ;;
      "$MODE_DIRECT_443_ONLY") ok "Caddy 443-only 模式仅监听 443，未发现 80 listener" ;;
    esac
  else
    fail "Caddy listener 不符合入口模式 $ENTRY_MODE 的安全预期（实际：$(printf '%s ' "$CADDY_LISTENERS")）"
  fi
fi

if [ "$FAIL" -gt 0 ] || [ "$UP_OK" -ne 1 ]; then
  # 升级模式的 EXIT trap 会在退出前恢复版本；普通部署停止当前失败栈，避免留下 unhealthy 服务。
  if [ "$UPGRADE_MODE" -eq 1 ]; then
    exit 1
  fi
  compose_down_current || true
fi

# ---------- 总结 ----------
section "结果"
echo "  ${C_B}$PASS 项通过 | $WARN 项警告 | $FAIL 项失败${C_0}"
if [ "$FAIL" -eq 0 ]; then
  # 从 Caddyfile 提取实际域名（直连模式行首 https://，反代入口模式行首 http://，统一剥掉前缀）。
  DSH_DOMAIN=$(grep -oE '^https?://dsh\.[^ {]+' "$CADDYFILE" | head -n 1 | sed -E 's#^https?://##')
  AUTH_DOMAIN=$(grep -oE '^https?://auth\.[^ {]+' "$CADDYFILE" | head -n 1 | sed -E 's#^https?://##')
  [ -z "$DSH_DOMAIN" ] && DSH_DOMAIN="dsh.example.com"
  [ -z "$AUTH_DOMAIN" ] && AUTH_DOMAIN="auth.example.com"
  # pub_url：反代入口非 443 端口时自动带 :端口，直连 443 时省略。
  echo "  访问: ${C_B}$(pub_url "$DSH_DOMAIN")${C_0}"
  echo "  首次使用: 打开 $(pub_url "$AUTH_DOMAIN") 登录，按提示注册 TOTP（验证码见 authelia/data/notifications.txt）"
  echo "  常用: docker compose logs -f dsh | docker compose restart dsh（社区插件增删后同样需要重启）"
fi
if [ "$FAIL" -gt 0 ] || [ "$UP_OK" -ne 1 ]; then
  echo "  ${C_R}部署流程结束，但有检查或启动失败；退出码置为 1，修复后重跑: $0${C_0}"
  exit 1
fi
UPGRADE_COMMITTED=1
UPGRADE_ROLLBACK_ARMED=0
exit 0
