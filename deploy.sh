#!/usr/bin/env bash
# ============================================================
# dsh-nas 一键部署脚本
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
UPGRADE_MODE=0
LATEST_MODE=0
ALT_MODE=0
ALT_PORT=13080          # 备选方案（内网 Basic Auth）监听端口
INTERNAL_PORT=13080     # 反代入口模式（lucky/CF）Caddy 内部 http 监听端口
ENTRY_MODE=1   # 主方案公网入口：1=Caddy 直连（443-only） / 2=lucky 等反代入口（内部 http）
PUBLIC_PORT=443         # 公网访问 HTTPS 端口（lucky/CF 监听端口；443 则 URL 不带端口）

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
  echo "  --upgrade           升级模式：跳过配置向导，只构建并启动 dsh（不改 Caddy/Authelia）"
  echo "  --latest            自动升级到 npm 最新版：查询 @deepseek-ai/dsh latest，更新版本号后"
  echo "                      构建（隐含 --upgrade；需已完成一次正常部署）"
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

# ---------- .env 幂等写入（保留其它配置行） ----------
env_upsert() { # $1=key $2=value
  touch "$ENV_FILE" 2>/dev/null || return 1
  if grep -q "^$1=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >>"$ENV_FILE"
  fi
}

# 升级模式只允许改版本并构建 dsh；配置文件由调用方完整保留。
# 升级容器以 root 运行，不能依赖宿主用户权限来创建快照。
backup_upgrade_configs() {
  local backup_dir="$SCRIPT_DIR/data/upgrade-config-backup"
  mkdir -p "$backup_dir" || return 1
  for f in "$CADDYFILE" "$AUTHELIA_CONF" "$USERS_DB" "$ENV_FILE"; do
    [ -f "$f" ] || continue
    cp -p "$f" "$backup_dir/$(basename "$f").before" || return 1
  done
  printf '%s\n' "$backup_dir" > "$SCRIPT_DIR/data/upgrade-config-backup.path"
}

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
[ -f "$ENV_FILE" ] && SAVED_PROXY=$(sed -n 's/^DSH_PROXY=//p' "$ENV_FILE" | head -n 1)
SAVED_PROXY="${SAVED_PROXY%$'\r'}"   # .env 被 Windows 编辑器存成 CRLF 时剥掉回车
if [ "$SET_PROXY_ARG" -eq 1 ]; then
  if [ "$PROXY" != "$SAVED_PROXY" ]; then
    env_upsert DSH_PROXY "$PROXY"
    ok "运行时代理已写入 $ENV_FILE：DSH_PROXY=$PROXY"
  fi
elif [ -n "$SAVED_PROXY" ]; then
  PROXY="$(normalize_proxy "$SAVED_PROXY")"
  echo "  沿用 .env 保存的代理: $PROXY（--proxy-host 可覆盖）"
fi

# ---------- 升级功能：记录 docker.sock 属组（.env DOCKER_GID） ----------
# 容器内 node 用户通过 compose 的 group_add 加入该组，才能驱动宿主 Docker。
# 若 NAS 把 socket 设为 root:root 或没有 group rw，网页端升级会自动禁用；命令行不受影响。
if [ -S /var/run/docker.sock ]; then
  SOCK_GID=$(stat -c %g /var/run/docker.sock 2>/dev/null || echo 0)
  SOCK_MODE=$(stat -c %a /var/run/docker.sock 2>/dev/null || echo 0)
  SOCK_MODE_DEC=$((8#$SOCK_MODE))
  if [ "$SOCK_GID" != "0" ] && [ $((SOCK_MODE_DEC & 48)) -eq 48 ]; then
    env_upsert DOCKER_GID "$SOCK_GID"
    ok "docker.sock 属组 GID=$SOCK_GID 已写入 $ENV_FILE（网页端升级功能）"
  elif [ "$SOCK_GID" = "0" ]; then
    warn "docker.sock 属主为 root:root，容器内非 root 无法访问；网页端升级功能不可用（命令行升级不受影响）"
  else
    warn "docker.sock 权限为 $SOCK_MODE，属组无读写权限；网页端升级功能不可用（命令行升级不受影响）"
  fi
else
  warn "未找到 /var/run/docker.sock；网页端升级功能不可用（命令行升级不受影响）"
fi

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

# ---------- 配置向导：域名 / 邮箱 / 密钥 / 鉴权密码 自动写入 ----------
backup_file() { # $1=path
  [ -f "$1" ] && cp "$1" "$1.bak"
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

# Caddy bcrypt 密码哈希（需要 docker 拉取 caddy 镜像）
caddy_hash() { # $1=password；成功输出哈希到 stdout
  local out
  out=$(docker run --rm caddy caddy hash-password --plaintext "$1" 2>/dev/null) || return 1
  printf '%s' "$out" | grep -o '\$2[aby]\$[^[:space:]]*' | head -n 1
}

# 读取一行输入（IFS 含 \r：剥离 Windows 管道可能注入的回车符，保留内部空格）
read_line() { # $1=变量名
  IFS=$'\t\n\r' read -r "$1"
}

# 读取隐藏密码（不回显；\r 同样剥离）
read_secret() { # $1=变量名
  IFS=$'\n\r' read -s -r "$1"
  echo
}

run_setup_wizard() {
  # 已配置且未强制 --setup → 跳过
  if [ "$SETUP_FORCE" -eq 0 ]; then
    local need=0
    if grep -qE '^\s*:[0-9]+\s*\{' "$CADDYFILE"; then
      # 备选方案（Basic Auth）：只需 Caddyfile 就绪
      grep -qE '__CADDY_HASH__' "$CADDYFILE" && need=1
      grep -vE '^\s*#' "$CADDYFILE" | grep -q 'example\.com' && need=1
    else
      # 主方案（Authelia）：密钥、密码、域名都要就绪
      grep -q 'CHANGE_ME_' "$AUTHELIA_CONF" && need=1
      grep -q 'p=8\$\.\.\.' "$USERS_DB" && need=1
      grep -vE '^\s*#' "$CADDYFILE" | grep -q 'example\.com' && need=1
      grep -vE '^\s*#' "$AUTHELIA_CONF" | grep -q 'example\.com' && need=1
      # 盲点修复：模板 Caddyfile 的 example.com 全在注释里，活跃检查发现不了。
      # 若 Caddyfile 活跃配置行太少（无任何站点块/http_port），视为未配置。
      # 注意：grep -c 无匹配时既输出 0 又返回 1，不能写成 $(... || echo 0)（会得到两行）。
      active_lines=$(grep -cE '^\s*[^#[:space:]]' "$CADDYFILE" 2>/dev/null) || active_lines=0
      [ "$active_lines" -lt 3 ] && need=1
    fi
    if [ "$need" -eq 0 ]; then
      ok "配置已就绪，跳过向导（用 --setup 可强制重跑）"
      return 0
    fi
  fi
  if [ ! -t 0 ]; then
    fail "检测到配置未完成，但当前不是交互终端；请 SSH 交互运行本脚本，或按 README 手动修改配置"
    return 1
  fi
  echo
  echo "  ${C_B}== 配置向导 ==${C_0}（检测到占位配置，将自动写入；原文件备份为 .bak）"
  # 代理地址（构建 + 运行时统一）。注意：NAS 上构建容器内的 127.0.0.1 是容器自身、
  # 不是宿主——在 NAS 上构建必须填宿主可达地址（如 http://192.168.1.10:7890），
  # 并确认 Clash 允许局域网访问（allow-lan）。回车沿用当前值。
  if [ -n "${SAVED_PROXY:-}" ]; then
    echo "  当前代理: $PROXY（.env 保存，回车沿用，或输入新值）"
  fi
  printf "  输入代理地址（构建/运行出站用）[%s]: " "$PROXY"
  read_line NEW_PROXY
  if [ -n "$NEW_PROXY" ]; then
    PROXY="$(normalize_proxy "$NEW_PROXY")"
  fi
  if [ "$PROXY" != "$SAVED_PROXY" ]; then
    env_upsert DSH_PROXY "$PROXY"
    ok "代理已写入 $ENV_FILE：DSH_PROXY=$PROXY"
  fi

  echo "  选择访问方案："
  echo "    1) 域名 + Authelia 双因素（推荐；需要域名，如 example.com）"
  echo "    2) 纯内网 IP + Basic Auth（不需要域名）"
  printf "  请输入 1 或 2 [1]: "
  read_line MODE_SEL
  [ -z "$MODE_SEL" ] && MODE_SEL=1

  if [ "$MODE_SEL" = "1" ]; then
    # ---------- 方案 1：域名 + Authelia ----------
    printf "  输入根域（如 example.com，不要带 http://）: "
    read_line ROOT
    ROOT="${ROOT#http://}"; ROOT="${ROOT#https://}"
    case "$ROOT" in
      ""|*" "*|*"/"*|*":"*) fail "无效根域: $ROOT（应为 example.com 形式，不带端口/路径）"; return 1 ;;
    esac
    printf "  Let's Encrypt 证书邮箱 [默认 admin@%s]: " "$ROOT"
    read_line EMAIL
    [ -z "$EMAIL" ] && EMAIL="admin@$ROOT"
    case "$EMAIL" in
      ""|*" "*) fail "无效邮箱: $EMAIL"; return 1 ;;
    esac

    # 公网入口方式：决定 Caddy 是直连公网（443-only）还是由 lucky/CF 反代终结 TLS
    echo "  选择公网入口方式："
    echo "    1) Caddy 直连公网（DDNS 把域名解析到 NAS，IPv6/IPv4 放行 443）"
    echo "    2) lucky / CF Tunnel 等反代入口（前置反代终结 TLS，Caddy 只监听内部端口）"
    printf "  请输入 1 或 2 [1]: "
    read_line ENTRY_SEL
    [ -z "$ENTRY_SEL" ] && ENTRY_SEL=1
    if [ "$ENTRY_SEL" = "2" ]; then
      ENTRY_MODE=2
      # 公网 HTTPS 端口 = lucky/CF 反代监听的端口（浏览器访问时带 :端口）
      printf "  公网 HTTPS 端口（lucky/CF 监听端口，浏览器访问用）[443]: "
      read_line NEW_PUBLIC_PORT
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
        echo "  ${C_Y}  公网访问将是 https://dsh.$ROOT:$PUBLIC_PORT / https://auth.$ROOT:$PUBLIC_PORT（记得 IPv6 放行 $PUBLIC_PORT）${C_0}"
      fi
    elif [ "$ENTRY_SEL" != "1" ]; then
      fail "无效入口方式: $ENTRY_SEL（应为 1 或 2）"; return 1
    fi

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
    if [ "$ENTRY_MODE" -eq 2 ] && [ "$PUBLIC_PORT" != "443" ]; then
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
      read_secret PW1
      if [ -z "$PW1" ] && [ "$PW_PLACEHOLDER" -eq 1 ]; then
        fail "密码不能为空"; return 1
      fi
      if [ -n "$PW1" ]; then
        printf "  再次输入确认: "
        read_secret PW2
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

    # 生成 Caddyfile（主方案，按入口方式分两种形态）
    backup_file "$CADDYFILE"
    if [ "$ENTRY_MODE" -eq 2 ]; then
      # lucky / CF Tunnel 反代入口：TLS 由前置终结，Caddy 内部 http（$INTERNAL_PORT）
      # authelia_url 用公网 URL（含 lucky 监听端口，如 https://auth.example.com:16666）
      AUTH_URL=$(pub_url "auth.$ROOT")
      cat > "$CADDYFILE" <<EOF
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
      echo "  ${C_Y}  提示: 在 lucky/CF 中把 dsh.$ROOT 和 auth.$ROOT 都转发到 http://127.0.0.1:$INTERNAL_PORT，并设 X-Forwarded-Proto: https；"
      echo "  Caddy 内部端口已只绑回环（default_bind 127.0.0.1），局域网无法绕过 lucky 直连；若 lucky/CF 运行在其它机器，需把 default_bind 改成 0.0.0.0 或 NAS 局域网 IP${C_0}"
    else
      # Caddy 直连公网：443-only，证书走 TLS-ALPN-01（不依赖 80，NAS 系统占用 80 无碍）
      cat > "$CADDYFILE" <<EOF
# 由 deploy.sh 配置向导生成（模式：Caddy 直连公网，443-only）（原始文件备份于同目录 .bak）
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

  elif [ "$MODE_SEL" = "2" ]; then
    # ---------- 方案 2：内网 + Basic Auth ----------
    printf "  输入 Basic Auth 密码（访问 Web UI 用，不回显）: "
    read_secret BPW1
    printf "  再次输入确认: "
    read_secret BPW2
    if [ -z "$BPW1" ]; then fail "密码不能为空"; return 1; fi
    if [ "$BPW1" != "$BPW2" ]; then fail "两次密码不一致"; return 1; fi
    echo "  正在生成 bcrypt 哈希（首次需拉取 caddy 镜像，请稍候）..."
    CADDY_HASH=$(caddy_hash "$BPW1")
    if [ -z "$CADDY_HASH" ]; then
      fail "密码哈希生成失败（docker 或网络问题）；请手动运行: docker run --rm caddy caddy hash-password --plaintext '你的密码' 后填入 Caddyfile"
      return 1
    fi
    backup_file "$CADDYFILE"
    cat > "$CADDYFILE" <<EOF
# 由 deploy.sh 配置向导生成（原始文件备份于同目录 .bak）
:$ALT_PORT {
    basic_auth {
        admin __CADDY_HASH__
    }
    reverse_proxy 127.0.0.1:3080 {
        header_up Host 127.0.0.1:3080
        header_up Origin http://127.0.0.1:3080
    }
}
EOF
    sed -i "s|__CADDY_HASH__|$CADDY_HASH|" "$CADDYFILE"
    ok "已生成 Caddyfile（备选方案，:$ALT_PORT + Basic Auth）"
    echo "  ${C_Y}  提示: 备选方案不会启动 authelia 容器（compose profile 控制），无需手动移除${C_0}"
  else
    fail "无效选择: $MODE_SEL（应为 1 或 2）"
    return 1
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
for f in Dockerfile entrypoint.sh docker-compose.yml \
          caddy/Caddyfile authelia/configuration.yml authelia/users_database.yml \
          plugins/restart-dsh/package.json plugins/restart-dsh/index.js \
          plugins/restart-dsh/client.js plugins/restart-dsh/cordis.patch.yml; do
  if [ -f "$SCRIPT_DIR/$f" ]; then ok "$f"; else fail "$f 缺失"; fi
done

# ---------- 配置向导（检测到占位符时自动交互配置） ----------
section "3. 配置向导"
if [ "$UPGRADE_MODE" -eq 1 ]; then
  ok "升级模式：跳过配置向导（Caddy/Authelia 配置保持不变）"
  backup_upgrade_configs || {
    fail "无法创建升级前配置快照；为保护 Caddy/Authelia，停止升级"
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
      echo "  可手动改 Dockerfile 的 DSH_VERSION 与 docker-compose.yml 的 build arg 后，不带 --latest 重跑"
      exit 1
    fi
    OLD_V=$(sed -n 's/^ARG DSH_VERSION=//p' "$SCRIPT_DIR/Dockerfile" | head -n 1)
    sed -i -E "s/^ARG DSH_VERSION=.*/ARG DSH_VERSION=$LATEST_V/" "$SCRIPT_DIR/Dockerfile"
    sed -i -E "s#^ *DSH_VERSION:.*#        DSH_VERSION: \"$LATEST_V\"#" "$SCRIPT_DIR/docker-compose.yml"
    if [ "$OLD_V" = "$LATEST_V" ]; then
      ok "npm 最新版 $LATEST_V 与当前一致（构建走缓存）"
    else
      ok "dsh 版本已更新: ${OLD_V:-?} → $LATEST_V（npm latest）"
    fi
  fi
else
  run_setup_wizard
fi

# 方案检测（向导可能已生成 Caddyfile，需在配置检查前确定模式）
if grep -qE '^\s*:[0-9]+\s*\{' "$CADDYFILE"; then
  ALT_MODE=1
  ALT_PORT=$(grep -oE '^\s*:[0-9]+' "$CADDYFILE" | head -n 1 | tr -dc '0-9')
fi
# 入口模式检测：Caddyfile 含 http:// 站点块 = 反代入口（内部 http）；否则 = 直连
if grep -qE '^http://' "$CADDYFILE"; then ENTRY_MODE=2; fi
# 反代入口模式下从 Caddyfile 的 authelia_url 还原公网端口（向导跳过时结果摘要才有正确 URL）
if [ "$ENTRY_MODE" -eq 2 ]; then
  CADDY_PUBLIC_PORT=$(grep -oE 'authelia_url=https?://[^[:space:]{}]+' "$CADDYFILE" | head -n 1 | grep -oE ':[0-9]+$' | tr -d ':')
  [ -n "$CADDY_PUBLIC_PORT" ] && PUBLIC_PORT="$CADDY_PUBLIC_PORT"
fi

# 主方案（Authelia）启动 authelia 容器；备选方案（Basic Auth）不启动
if [ "$ALT_MODE" -eq 1 ]; then
  PROFILE_ARGS=""
else
  PROFILE_ARGS="--profile auth"
fi

# ---------- 配置占位符 ----------
section "4. 配置检查（密钥 / 密码 / 域名）"
if [ "$ALT_MODE" -eq 1 ]; then
  ok "备选方案模式（Basic Auth）：跳过 Authelia 密钥/密码检查"
  if grep -vE '^\s*#' "$CADDYFILE" | grep -q 'example\.com'; then
    warn "Caddyfile 活跃配置中仍有 example.com（可忽略或清理）"
  else
    ok "域名占位符已替换"
  fi
else
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
    warn "活跃配置中仍有 example.com（域名或证书邮箱）；内网 Basic Auth 备选方案可忽略"
  else
    ok "域名占位符已替换"
  fi
fi

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
      else warn "已创建 $dir 但未能 chown；请手动: sudo chown -R 1000:1000 $dir"; fi
    else
      warn "无法创建 $dir，请手动创建并 chown 1000:1000"
    fi
  else
    OWNER=$(stat -c %u "$dir" 2>/dev/null || echo "?")
    if [ "$OWNER" = "1000" ]; then
      ok "$dir 属主 = 1000（$label）"
    elif [ "$OWNER" = "?" ]; then
      warn "无法读取 $dir 属主；请确认: sudo chown -R 1000:1000 $dir"
    elif chown_dir "$dir" 2>/dev/null; then
      ok "已 chown -R 1000:1000（$label，原属主 $OWNER）"
    else
      warn "$dir 属主为 $OWNER（应为 1000）；请手动: sudo chown -R 1000:1000 $dir"
    fi
  fi
}
check_dir_perm "$DATA_DIR" "DSH 数据目录（配置/凭据/会话/存储）"
check_dir_perm "$WORKSPACE_DIR" "工作区目录（Web 目录选择器新建落点）"
check_dir_perm "$DATA_DIR/profiles" "插件 profile 目录（node 用户必须可写）"

# ---------- 端口与代理 ----------
section "6. 端口与代理检查"
# 本项目容器是否已在运行（升级场景：端口占用不判为冲突）
RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -cE '^(dsh|authelia|dsh-caddy)$' || true)

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

if [ "$RUNNING" -gt 0 ]; then
  ok "检测到已有容器运行，跳过端口冲突检查（升级场景）"
else
  if port_listening 3080; then
    fail "宿主 3080 端口已被占用（host 网络下 dsh 无法绑定）；请停掉占用进程"
  else
    ok "dsh 端口 3080 空闲"
  fi
  if [ "$ALT_MODE" -eq 1 ]; then
    if port_listening "$ALT_PORT"; then
      # 端口被占用：交互式让用户指定新端口
      echo
      echo "  ${C_Y}⚠ 备选方案端口 $ALT_PORT 已被占用。${C_0}"
      printf "  输入新的监听端口 [1-65535]（直接回车 = 中止部署）: "
      read -r NEW_PORT
      NEW_PORT="${NEW_PORT%$'\r'}"   # 防御：去掉 Windows 管道/部分终端注入的回车符
      if [ -n "$NEW_PORT" ]; then
        if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_PORT" -ge 1 ] && [ "$NEW_PORT" -le 65535 ]; then
          if port_listening "$NEW_PORT"; then
            fail "端口 $NEW_PORT 也被占用，请换一个端口后重跑"
          elif sed -i "s/^:$ALT_PORT {/:$NEW_PORT {/" "$CADDYFILE"; then
            ok "已把 Caddyfile 监听端口改为 $NEW_PORT"
            ALT_PORT="$NEW_PORT"
          else
            fail "更新 Caddyfile 失败（$CADDYFILE）"
          fi
        else
          fail "无效端口: $NEW_PORT（应为 1-65535 的数字）"
        fi
      else
        fail "未输入端口，中止部署；可自行修改 Caddyfile 的 :$ALT_PORT 后重跑"
      fi
    else
      ok "备选方案端口 $ALT_PORT 空闲"
    fi
  else
    if [ "$ENTRY_MODE" -eq 2 ]; then
      # 反代入口（lucky/CF）：Caddy 只监听内部 $INTERNAL_PORT，公网端口由前置反代负责
      if port_listening "$INTERNAL_PORT"; then
        fail "宿主 $INTERNAL_PORT 端口已被占用（Caddy 内部 http 监听需要；可用 --setup 重跑或改 deploy.sh 的 INTERNAL_PORT 后重跑）"
      else
        ok "Caddy 内部端口 $INTERNAL_PORT 空闲"
      fi
    else
      # 直连模式：443-only（TLS-ALPN-01 证书），不依赖 80——NAS 系统组件占用 80 无碍
      if port_listening 443; then
        fail "宿主 443 端口已被占用（Caddy 直连模式需要；请停用占用进程，或改走 lucky/CF 反代入口）"
      else
        ok "Caddy 端口 443 空闲（80 不检查：443-only 设计，NAS 系统占用 80 不影响）"
      fi
    fi
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
if [ "$UPGRADE_MODE" -eq 1 ] && [ "$SKIP_BUILD" -eq 1 ]; then
  fail "升级模式不能与 --skip-build 同时使用（必须重新构建 dsh 镜像）"
  exit 1
fi
compose_up() {
  # --profile 是 compose 顶层 flag，必须置于子命令之前：docker compose --profile auth up -d
  if $COMPOSE $PROFILE_ARGS up -d; then
    UP_OK=1; ok "容器已启动"
  else
    fail "$COMPOSE up -d 失败；运行 $COMPOSE logs 排查（常见: Caddyfile 语法错误 / 端口绑定失败）"
  fi
}
UP_OK=0
if [ "$SKIP_BUILD" -eq 1 ]; then
  ok "跳过构建，直接启动"
  compose_up
else
  echo "  构建镜像（首次约 10 分钟，native 依赖编译；npm 走代理 $PROXY）..."
  if $COMPOSE build --build-arg "HTTP_PROXY=$PROXY" --build-arg "HTTPS_PROXY=$PROXY"; then
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
  compose_up
fi

# ---------- 等待健康 ----------
section "8. 等待服务就绪与安全验证"
if [ "$UP_OK" -ne 1 ]; then
  warn "容器未成功启动，跳过健康等待与安全验证"
else
  STATUS="starting"
  for i in $(seq 1 40); do
    STATUS=$(docker inspect -f '{{.State.Health.Status}}' dsh 2>/dev/null || echo "starting")
    [ "$STATUS" = "healthy" ] && break
    sleep 3
  done
  if [ "$STATUS" = "healthy" ]; then
    ok "dsh 健康检查通过"
  else
    warn "dsh 未在 120 秒内 healthy；运行 docker compose logs dsh 排查"
  fi

  # 安全验证：host 网络下 dsh 必须只绑定回环，否则局域网可绕过 Caddy+Authelia 直连
  LISTEN_3080=""
  if command -v ss >/dev/null 2>&1; then
    LISTEN_3080=$(ss -ltn 2>/dev/null | awk '{print $4}' | grep -E '[:.]3080$')
  elif command -v netstat >/dev/null 2>&1; then
    LISTEN_3080=$(netstat -ltn 2>/dev/null | awk '{print $4}' | grep -E '[:.]3080$')
  fi
  if [ -z "$LISTEN_3080" ]; then
    warn "无法读取 3080 绑定地址（ss/netstat 不可用）；请手动确认: ss -ltn | grep 3080 应只有 127.0.0.1:3080"
  elif printf '%s\n' "$LISTEN_3080" | grep -qvE '^127\.0\.0\.1:3080$'; then
    fail "dsh 监听在非回环地址（$(printf '%s' "$LISTEN_3080" | tr '\n' ' ')）——局域网可绕过鉴权直连！立即处理: docker compose stop dsh，确认 entrypoint.sh 的 --host 127.0.0.1 未被改动"
  else
    ok "dsh 仅监听 127.0.0.1:3080（无法绕过 Caddy+Authelia 直连）"
  fi

  if [ "$ALT_MODE" -eq 1 ]; then
    ok "备选方案模式：跳过 Authelia 健康检查（authelia 容器未启动）"
  elif http_get 5 "http://127.0.0.1:9091/api/health" | grep -q '"status":"OK"'; then
    ok "Authelia 健康"
  else
    warn "Authelia 未就绪；运行 docker compose logs authelia 排查（常见: 密钥未替换/配置报错）"
  fi
fi

# ---------- 总结 ----------
section "结果"
echo "  ${C_B}$PASS 项通过 | $WARN 项警告 | $FAIL 项失败${C_0}"
if [ "$FAIL" -eq 0 ]; then
  if [ "$ALT_MODE" -eq 1 ]; then
    echo "  访问: ${C_B}http://<NAS-IP>:${ALT_PORT}${C_0}（Basic Auth 账号密码在 Caddyfile 的 basic_auth 块）"
  else
    # 从 Caddyfile 提取实际域名（直连模式行首 https://，反代入口模式行首 http://，统一剥掉前缀）
    DSH_DOMAIN=$(grep -oE '^https?://dsh\.[^ {]+' "$CADDYFILE" | head -n 1 | sed -E 's#^https?://##')
    AUTH_DOMAIN=$(grep -oE '^https?://auth\.[^ {]+' "$CADDYFILE" | head -n 1 | sed -E 's#^https?://##')
    [ -z "$DSH_DOMAIN" ] && DSH_DOMAIN="dsh.example.com"
    [ -z "$AUTH_DOMAIN" ] && AUTH_DOMAIN="auth.example.com"
    # pub_url：反代入口非 443 端口时自动带 :端口，直连 443 时省略
    echo "  访问: ${C_B}$(pub_url "$DSH_DOMAIN")${C_0}"
    echo "  首次使用: 打开 $(pub_url "$AUTH_DOMAIN") 登录，按提示注册 TOTP（验证码见 authelia/notifications.txt）"
  fi
  echo "  常用: docker compose logs -f dsh | docker compose restart dsh（装插件后）"
fi
if [ "$FAIL" -gt 0 ]; then
  echo "  ${C_R}部署流程结束，但有 $FAIL 项失败（见上）；退出码置为 1，修复后重跑: $0${C_0}"
  exit 1
fi
exit 0
