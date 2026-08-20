# syntax=docker/dockerfile:1
#
# DeepSeek Harness (dsh) — Linux NAS Docker 镜像模板
#
# 约束与设计：
# 1. 基础镜像必须用完整版 node:22-bookworm（不能用 slim）——
#    DSH 的 native 依赖（landlock-run 等）npm 安装时要走 node-gyp 编译。
# 2. 官方没有发布 Docker 镜像，这里用官方 npm 包安装，版本用 ARG 锁定。
# 3. 运行身份：node:22 官方镜像自带的 node 用户（UID 1000，非 root）；
#    tini 作为 PID 1，负责信号转发（docker stop → SIGTERM → dsh）
#    与子进程收割（Agent 启动的 bash/后台任务不残留僵尸进程）。
# 4. 数据与工作区分离：
#    /home/node/.dsh — DSH_HOME（配置/凭据/会话/存储，挂载持久化）
#    /workspace     — 交互主目录 + 启动工作目录（Web 目录选择器的新建
#                      操作落在该可写目录，挂载持久化）

# ---------- 构建阶段：装编译工具链 + 安装 dsh ----------
FROM node:22-bookworm AS build

ARG DSH_VERSION=0.1.0-rc.8

# node-gyp 编译工具链 + CA 证书（编译一次约 10 分钟，正常现象）
# apt 与 npm 都使用构建时注入的 HTTP_PROXY/HTTPS_PROXY（--build-arg）。
# 注意 NAS 上构建容器内的 127.0.0.1 是容器自身，不是宿主——代理地址须为宿主可达，
# 由 deploy.sh 配置向导输入的代理地址提供（如 http://192.168.1.10:7890）。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 make g++ ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @deepseek-ai/dsh@${DSH_VERSION}

# ---------- 运行阶段：干净的运行时镜像 ----------
FROM node:22-bookworm

# node:22-bookworm 为完整版镜像；当前网页升级不直接驱动宿主 Docker，
# 因此运行镜像不再内置 Docker CLI/Compose，也不挂载 docker.sock。

ARG PNPM_VERSION=11.20.0
# 可选：把一个由 HTTPS + Authelia 保护的反向代理 hostname 纳入 DSH 的
# loopback-only 浏览器权限面。只接受纯 hostname，不含协议、端口或路径。
ARG DSH_TRUSTED_DOMAIN=""

# tini（PID 1 init）+ git（git 源插件）+ CA 证书（同样走构建代理）
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git tini \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/lib/node_modules /usr/local/lib/node_modules

# rc8+ 把 settings/credentials/directory-picker 等特权 RPC 固定为 loopback-only。
# 运行容器以 node(1000) 启动，无权改 /usr/local/lib/node_modules；因此可选 patch
# 必须在此处以构建用户 root 应用，并同时修改浏览器 bundle 与 Host API 栅栏。
COPY patch-trusted-domain.mjs /tmp/patch-trusted-domain.mjs
RUN if [ -n "$DSH_TRUSTED_DOMAIN" ]; then \
      node /tmp/patch-trusted-domain.mjs "$DSH_TRUSTED_DOMAIN"; \
    fi \
 && rm -f /tmp/patch-trusted-domain.mjs

# pnpm 固定版本：`dsh plugin` 运行时管理社区插件依赖它（转发 pnpm 命令），
# 固定版本保证 lockfile 与插件安装行为稳定；升级时改 ARG 重建。
# npm 全局 bin 是符号链接，跨阶段 COPY 行为不确定，dsh 的 bin 显式重建。
RUN npm install -g pnpm@${PNPM_VERSION} \
 && ln -s /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js /usr/local/bin/dsh \
 && chmod +x /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js

# 数据主目录与可写工作区分离（DSH_HOME 显式固定，不随 HOME 漂移）
# pnpm 缓存重定向到 /tmp：避免 `dsh plugin` 的 store/cache 污染 /workspace
ENV DSH_HOME=/home/node/.dsh \
    HOME=/workspace \
    PNPM_HOME=/tmp/pnpm-home \
    XDG_CACHE_HOME=/tmp/xdg-cache \
    XDG_DATA_HOME=/tmp/xdg-data
RUN mkdir -p /workspace /home/node/.dsh \
 && chown -R node:node /workspace /home/node \
 && usermod -d /workspace node
WORKDIR /workspace

# 容器入口脚本（代理环境变量、显式绑定回环启动 dsh web）
# tini 会 exec 至该路径，缺失则容器启动即失败（exit 127: No such file）
COPY entrypoint.sh /usr/local/bin/dsh-entrypoint
RUN chmod +x /usr/local/bin/dsh-entrypoint

USER node

EXPOSE 3080

# tini 作为 PID 1：信号转发 + 僵尸收割
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/dsh-entrypoint"]
