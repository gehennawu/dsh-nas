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
# 4) rc8+ 的反向代理 trusted-domain 兼容 patch 在 Dockerfile 构建阶段应用；
#    运行容器保持 node(1000)，不修改 /usr/local/lib/node_modules。
set -e

export NODE_USE_ENV_PROXY=1
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7890}"
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7890}"
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

exec dsh web --host 127.0.0.1 $trusted_args "$@"
