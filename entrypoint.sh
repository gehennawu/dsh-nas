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
# 4) 固化插件：确保「服务控制」（仅安全重启 dsh web）已装进 web profile。
#    首次启动时自动初始化 profile 并安装；镜像内插件版本变化时重新安装，
#    让升级后的插件代码覆盖持久化 profile 中的旧版本。
#    file: 本地包无需网络；失败不阻塞启动（日志可见，报错细节落
#    /tmp/plugin-add.log 并回显前 30 行）。pnpm 对 file: 依赖可能复用旧副本
#    不更新内容，安装后校验版本，仍不一致时删除副本手工同步镜像内版本。
set -e

export NODE_USE_ENV_PROXY=1
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7890}"
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7890}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"

# 启动前自检：DSH_HOME 目录必须可写，否则插件安装、profile 管理等都会 EACCES。
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

RESTART_PLUGIN_DIR="$DSH_HOME/profiles/web/node_modules/@dsh-nas/restart-dsh"
plugin_version() {
  node -e 'try { const fs = require("node:fs"); const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(p.version || "") } catch (_) {}' "$1/package.json" 2>/dev/null || true
}
WANT_PLUGIN_VERSION=$(plugin_version /opt/dsh-plugins/restart-dsh)
HAVE_PLUGIN_VERSION=$(plugin_version "$RESTART_PLUGIN_DIR")
if [ ! -d "$RESTART_PLUGIN_DIR" ] || [ "$WANT_PLUGIN_VERSION" != "$HAVE_PLUGIN_VERSION" ]; then
  echo "dsh-entrypoint: installing @dsh-nas/restart-dsh plugin (v${WANT_PLUGIN_VERSION:-unknown})..."
  if dsh plugin --profile web add "file:/opt/dsh-plugins/restart-dsh" >/tmp/plugin-add.log 2>&1; then
    echo "dsh-entrypoint: plugin installed"
  else
    echo "dsh-entrypoint: WARNING plugin install/update failed; starting with the existing version if available"
    echo "dsh-entrypoint: install error details:"
    head -30 /tmp/plugin-add.log
  fi
  # pnpm 对 file: 依赖会复用旧副本（added 0），add 成功不代表内容已更新；
  # 版本仍不一致时删除副本手工同步，确保镜像内插件版本真正落进 profile
  if [ "$(plugin_version "$RESTART_PLUGIN_DIR")" != "$WANT_PLUGIN_VERSION" ]; then
    rm -rf "$RESTART_PLUGIN_DIR" 2>/dev/null || true
    if cp -a /opt/dsh-plugins/restart-dsh "$RESTART_PLUGIN_DIR" 2>/dev/null; then
      echo "dsh-entrypoint: plugin synced manually (v$(plugin_version "$RESTART_PLUGIN_DIR"))"
    else
      echo "dsh-entrypoint: WARNING manual sync failed"
    fi
  fi
fi

exec dsh web --host 127.0.0.1 $trusted_args "$@"
