#!/bin/sh
# dsh 容器入口：
# 1) 所有出站流量（LLM API、联网搜索/抓取）走宿主 NAS 的代理端口。
#    DSH 用 Node 全局 fetch（undici），默认不读代理环境变量，
#    必须显式开启 NODE_USE_ENV_PROXY=1（Node >= 22.21 / >= 24 支持）。
#    容器使用 host 网络，所以 127.0.0.1:7890 就是宿主的代理。
#    如果你的 NAS 不支持 host 网络，把下面的 127.0.0.1 换成宿主局域网 IP。
# 2) dsh 显式绑定 127.0.0.1：host 网络下这是整个方案的安全前提——
#    一旦绑定 0.0.0.0，局域网可绕过 Caddy+Authelia 直连 dsh。
#    deploy.sh 启动后会验证实际绑定地址。
# 3) 可选：DSH_TRUSTED_HOSTS 追加 --trusted-host（默认方案由 Caddy 改写
#    Host 头绕过信任栅栏，不需要；仅在直连 3080 或透传真实 Host 时才需要）。
# 4) 可选：DSH_COOKIE_MAX_AGE_DAYS 为 dsh Web 浏览器会话 cookie 有效期（正整数天数；
#    空值用 dsh 默认 30）。v0.1.2+ 一次性 token 认证签发该 cookie；这里按配置生成
#    --patch overlay 覆盖 connection 行，无需修改镜像。
# 5) rc8+ 的反向代理 trusted-domain 兼容 patch 在 Dockerfile 构建阶段应用；
#    运行容器保持 node(1000)，不修改 /usr/local/lib/node_modules。
set -e

export NODE_USE_ENV_PROXY=1
# 代理变量语义（与 docker-compose.yml 的 "-" 插值配合）：
#   - 未设置 → 回落默认代理 127.0.0.1:7890（裸 docker run 兼容旧行为）
#   - 设置为空（compose 传入 DSH_PROXY= 空值）→ 显式直连，unset 掉避免
#     undici 把空字符串当代理 URL 解析失败
#   - 设置为值 → 原样使用
if [ "${HTTP_PROXY+set}" != "set" ]; then
  export HTTP_PROXY="http://127.0.0.1:7890"
elif [ -z "$HTTP_PROXY" ]; then
  unset HTTP_PROXY
fi
if [ "${HTTPS_PROXY+set}" != "set" ]; then
  export HTTPS_PROXY="http://127.0.0.1:7890"
elif [ -z "$HTTPS_PROXY" ]; then
  unset HTTPS_PROXY
fi
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"

# 启动前自检：DSH_HOME 目录必须可写，否则会话/profile 管理等都会 EACCES。
# entrypoint 以 node(1000) 运行，无法自行 chown，只能提示用户在宿主修复。
for d in "$DSH_HOME/profiles" "$DSH_HOME/profiles/node_modules"; do
  if ! mkdir -p "$d" 2>/dev/null; then
    echo "dsh-entrypoint: FATAL $d 不可写（当前 UID=$(id -u)）。"
    echo "  请在 NAS 宿主上执行: chown -R 1000:1000 <项目目录>/data/dsh"
    echo "  或: docker exec -u root dsh chown -R node:node /home/node/.dsh"
    exit 1
  fi
done

trusted_args=""
if [ -n "${DSH_TRUSTED_HOSTS:-}" ]; then
  old_ifs="$IFS"
  IFS=','
  for h in $DSH_TRUSTED_HOSTS; do
    trusted_args="$trusted_args --trusted-host $h"
  done
  IFS="$old_ifs"
fi

# DSH_COOKIE_MAX_AGE_DAYS → 生成 connection 行 overlay（--patch 只在根 profile 层之后追加，
# 覆盖同名行的 config；必须重述 webRuntime.trustedHosts 表达式，否则该行会回落为空列表）。
patch_args=""
if [ -n "${DSH_COOKIE_MAX_AGE_DAYS:-}" ]; then
  case "$DSH_COOKIE_MAX_AGE_DAYS" in
    ''|*[!0-9]*)
      echo "dsh-entrypoint: FATAL DSH_COOKIE_MAX_AGE_DAYS 必须是正整数天数，实际为: $DSH_COOKIE_MAX_AGE_DAYS" >&2
      exit 1 ;;
  esac
  if [ "$DSH_COOKIE_MAX_AGE_DAYS" -lt 1 ] || [ "$DSH_COOKIE_MAX_AGE_DAYS" -gt 3650 ] 2>/dev/null; then
    echo "dsh-entrypoint: FATAL DSH_COOKIE_MAX_AGE_DAYS 超出范围（1–3650）: $DSH_COOKIE_MAX_AGE_DAYS" >&2
    exit 1
  fi
  patch_file="$DSH_HOME/web-cookie-max-age.yml"
  {
    echo "# dsh-nas: browser-session cookie max age overlay（entrypoint.sh 生成，勿手改）"
    echo "- id: connection"
    echo "  config:"
    echo "    trustedHosts: !!js ctx.webRuntime.trustedHosts"
    echo "    cookieMaxAgeDays: $DSH_COOKIE_MAX_AGE_DAYS"
  } > "$patch_file" || {
    echo "dsh-entrypoint: FATAL 无法写入 $patch_file" >&2
    exit 1
  }
  patch_args="--patch $patch_file"
fi

exec dsh web --host 127.0.0.1 $trusted_args $patch_args "$@"
