# dsh 通用 NAS 部署（Docker + Caddy 反代 + Authelia 双因素鉴权）

任何支持 Docker 和 SSH 的机器都能用（NAS、迷你主机、普通 Linux 服务器均可）。
（系统 UI 不提供 compose 编排入口时，SSH 下用 Docker Compose V2 插件即可；确实无法使用 compose 的环境，见文末「UI 手动创建」对照表。）

## 架构

```
浏览器 ── https://dsh.example.com ──> Caddy (host 网络)
              ├── forward_auth ──> Authelia 127.0.0.1:9091   ← 未登录 → 302 跳登录页（2FA）
              └── reverse_proxy ──> dsh 127.0.0.1:3080
   dsh 出站（LLM API / 联网搜索）──> 宿主代理 127.0.0.1:7890
```

- 三个容器都用 **host 网络**：容器里的 `127.0.0.1` 就是 NAS 宿主本身——dsh 直通宿主代理、Caddy 直连 dsh、Authelia 只监听回环；
- **Caddy 自动 HTTPS**：有域名时自动申请/续期 Let's Encrypt 证书，WebSocket/SSE 无需任何额外配置；
- **Authelia 双因素**：未登录访问 DSH → 自动跳转登录页 → 用户名密码 + TOTP 验证码；
- dsh 由 entrypoint.sh 显式 `--host 127.0.0.1` 绑定回环（host 网络下的安全前提），`deploy.sh` 启动后自动验证实际绑定地址，一旦发现监听非回环立即报错；对外暴露完全交给 Caddy + 鉴权；
- **容器设计**：非 root（官方 `node` 用户，UID 1000）+ **tini**（PID 1：信号转发与子进程收割）；`pnpm@11.20.0` 固定版本供 `dsh plugin` 运行时管理插件；数据与工作区分离——`/home/node/.dsh`（配置/凭据/会话/存储）与 `/workspace`（交互主目录，Web 目录选择器新建落点）；
- **固化插件「服务控制」**：设置面板提供一键「重启 dsh web」与「升级 dsh」（获取 npm 最新版或手动输入版本号 → 后台改版本号并执行 `deploy.sh`，保留 Caddy/Authelia 配置与数据）。插件随镜像固化（`plugins/restart-dsh`），entrypoint 启动时按版本号自动安装/更新进 web profile（`dsh plugin --profile web add file:...`，首次自动初始化 profile，无需网络）；pnpm 缓存重定向到 `/tmp`，不污染 `/workspace`；容器内含 Docker CLI/Compose 并挂载 `docker.sock`（详见「固化插件」一节）。

## 目录结构

```
dsh-nas/
├── Dockerfile              # dsh 镜像（node:22-bookworm + tini + pnpm 固定版）
├── deploy.sh               # 一键部署：配置向导 + 检查 + 构建启动
├── entrypoint.sh           # 代理环境变量 + 启动 dsh + 自动安装固化插件
├── docker-compose.yml      # dsh + authelia + caddy 三容器（authelia 挂 profile，主方案才启动）
├── plugins/
│   └── restart-dsh/        # 固化插件：设置页「服务控制」（一键重启 / 升级 dsh web）
│       ├── package.json    #   dsh.bundle + dsh.client 声明
│       ├── cordis.patch.yml#   bundle patch（一行插入）
│       ├── index.js        #   host 半：/restart-dsh + /dsh-upgrade RPC
│       └── client.js       #   client 半：设置页「服务控制」面板（重启 + 升级）
├── caddy/
│   └── Caddyfile           # 反代 + 鉴权接入（向导自动生成）
├── authelia/
│   ├── configuration.yml   # Authelia 配置（固定 v4.39）
│   └── users_database.yml  # 用户库（argon2id 密码哈希）
├── data/                   # 运行时生成（挂载进容器持久化）
│   ├── dsh/                #   → /home/node/.dsh  配置/凭据/会话/存储/插件
│   └── workspace/          #   → /workspace       工作区（agent 文件、项目）
└── .env                    # 运行时生成：DSH_PROXY（--proxy-host 写入，compose 自动读取）
```

## 前置条件

1. **代理**：NAS 宿主上有代理（Clash 等）监听 7890 端口（HTTP/mixed）。SSH 验证：
   ```sh
   curl -x http://127.0.0.1:7890 -sI https://api.deepseek.com | head -n 1   # 期望 HTTP/2 200
   ```
2. **域名**（主方案必需）：`dsh.example.com` 和 `auth.example.com` 的 DNS 记录指向本 NAS。两种入口方式二选一（配置向导会问）：
   - **Caddy 直连**（有公网 IP 或公网 IPv6 + DDNS）：域名 A/AAAA 记录指向 NAS，防火墙放行 **443**（443-only 设计，不依赖 80——NAS 系统组件占用 80 不影响）；
   - **lucky / CF Tunnel 反代入口**（无公网 IPv4，走 IPv6 或隧道）：前置反代终结 TLS，Caddy 只监听内部 13080 且仅绑回环（`default_bind 127.0.0.1`），局域网无法绕过 lucky 直连；若 lucky/CF 运行在其它机器上，需把 Caddyfile 全局块的 `default_bind` 改成 `0.0.0.0` 或 NAS 局域网 IP。lucky 用户：在 lucky 里把 `dsh.` 和 `auth.` 两个域名都转发到 `http://127.0.0.1:13080`，开启 WebSocket，加请求头 `X-Forwarded-Proto: https`，绑定你已配置的证书。
3. **SSH**：能登进 NAS 执行 docker 命令。

## 快速部署

```sh
# 1. 上传本目录到 NAS，SSH 进入
cd dsh-nas

# 2. 修改配置（见下节「Authelia 首次配置」）
# 3. 数据目录权限（容器内以 UID 1000 运行）
mkdir -p data/dsh data/workspace && chown -R 1000:1000 data

# 4. 构建并启动（主方案 Authelia 鉴权；首次构建约 10 分钟：native 依赖编译）
docker compose --profile auth up -d --build
```

构建网络说明：

- **apt 与 npm、Docker CLI 静态包下载统一走构建时注入的代理**（`--build-arg HTTP_PROXY/HTTPS_PROXY`，由 deploy.sh 自动传入；apt 用 Debian 默认源）。**在 NAS 上构建**时，`127.0.0.1:7890` 是构建容器自身、不是宿主——必须用宿主可达地址：
  ```sh
  ./deploy.sh --proxy-host 192.168.1.10    # 换成 NAS 局域网 IP
  ```
  并确认 Clash 允许局域网访问（`allow-lan: true`，监听 `0.0.0.0:7890`）。deploy.sh 构建失败时也会打印这条提示。

## 一键部署脚本（推荐）

```sh
cd dsh-nas
chmod +x deploy.sh
./deploy.sh
```

**配置向导（自动）**：首次运行检测到占位配置（`example.com` 域名、`CHANGE_ME_*` 密钥、占位密码哈希）时，脚本自动进入交互向导，你只需要回答几个问题，其余全部自动完成：

- **方案选择**：`1)` 域名 + Authelia 双因素（推荐） / `2)` 纯内网 IP + Basic Auth
- **代理输入**：输入出站代理地址（构建 + 运行时统一；NAS 上构建容器内 `127.0.0.1` 是容器自身，须填宿主可达 IP，如 `http://192.168.1.10:7890`，并确认 Clash `allow-lan`）→ 写入 `.env`
- **域名方案**：输入根域（如 `example.com`）→ 自动生成 `auth.`/`dsh.` 子域、证书邮箱（默认 `admin@<根域>`）、自动生成两个随机密钥（`openssl rand`）、自动生成 admin 密码哈希（argon2id，`docker run authelia`）、整体生成 Caddyfile
- **入口方式**（域名方案内）：`1)` **Caddy 直连公网**（DDNS 解析到 NAS，防火墙放行 443，443-only + TLS-ALPN-01 证书，不依赖 80） / `2)` **lucky / CF Tunnel 反代入口**（前置反代终结 TLS，Caddy 只监听内部 13080，自动加 `X-Forwarded-Proto: https`）；**选 2 后输入公网 HTTPS 端口**（=lucky/CF 监听端口，如 16666），该端口会写进所有公网 URL（`authelia_url`、`default_redirection_url`），浏览器访问形如 `https://dsh.example.com:16666`
- **内网方案**：输入 Basic Auth 密码 → 自动生成 bcrypt 哈希（`docker run caddy`）、生成 `:13080` + Basic Auth 的 Caddyfile
- 所有被改写文件先备份为 `.bak`；改完后再进入检查流程

之后脚本自动完成：环境检查（docker/compose）→ 文件完整性 → 配置检查 → 数据目录权限（自动创建并 chown，需要时自动调 sudo）→ 端口检查（3080、按入口模式查 443 或内部 13080、7890 代理连通性）→ 构建启动（主方案自动带 `--profile auth`，**置于 `up` 之前**：`docker compose --profile auth up -d`）→ 等待健康检查 → **验证 dsh 仅监听 127.0.0.1:3080**（host 网络下的安全前提，发现绑定非回环立即报错）→ 打印访问地址。**任何检查未通过会中止并列出修复项**，已配置完成后反复重跑安全（向导自动跳过）。

参数：

```sh
./deploy.sh --skip-build                              # 跳过构建，用现有镜像启动
./deploy.sh --proxy-host 192.168.1.5:7890             # 代理不在本机 127.0.0.1 时指定；构建与运行时都生效，写入 .env 持久化
./deploy.sh --setup                                   # 强制重跑配置向导（可换域名/入口/密码；原文件备份为 .bak，Authelia 密钥保留）
./deploy.sh --latest                                  # 自动升级到 npm 最新版（查询 registry 更新版本号后构建；隐含 --upgrade）
```

端口冲突时自动交互：备选方案（Basic Auth）的监听端口被占用时，脚本会提示输入新端口（1-65535），校验合法且空闲后**自动改写 Caddyfile** 并继续部署；直接回车则中止。主方案的 443 冲突（直连模式）或 13080 冲突（反代入口模式）需手动处理（多为 NAS 管理界面或其他服务占用；改 `deploy.sh` 顶部 `INTERNAL_PORT` 后可整体换端口）。

注意：`deploy.sh` 必须在 **NAS 的 Linux shell**（SSH）里运行，不要在 Windows Git Bash 里跑——Git Bash 的端口检测、属主检测、chown 语义与 Linux 不同，结果不可靠（可用 `bash -n deploy.sh` 做语法校验）。

## lucky / CF Tunnel 反代入口（无公网 IPv4 场景）

NAS 没有公网 IPv4 时（家庭宽带常见），有两种入口；本方案已内置「反代入口」模式（配置向导选入口方式 2，生成内部 http 版 Caddyfile）。

### lucky 入口端到端流程（14 步）

前置：域名 `dsh.example.com` / `auth.example.com` 已解析到 NAS（IPv6 DDNS 等），lucky 已绑定可用证书。

1. **lucky 反代**：新建反代，监听公网 HTTPS 端口（如 16666），绑定证书；添加两条规则 `dsh.example.com` 和 `auth.example.com`，都转发到 `http://127.0.0.1:13080`，开启 **WebSocket**，每条规则加请求头 **`X-Forwarded-Proto: https`**（详细说明见下节「lucky 用户」）；
2. **上传部署**：把 `dsh-nas` 目录上传到 NAS，SSH 进入并运行：
   ```sh
   cd 上传路径/dsh-nas && bash deploy.sh
   ```
3. **代理地址**：按提示输入出站代理。注意：NAS 上构建容器内的 `127.0.0.1` 是容器自身、不是宿主——必须填宿主可达地址（如 `http://192.168.1.10:7890`），并确认 Clash 开了 `allow-lan`；
4. **访问方案**：选 `1) 域名 + Authelia 双因素`；
5. **根域**：输入反代的根域（如 `example.com`；不带 `http://`、不带端口号，脚本会校验）；
6. **证书邮箱**：Let's Encrypt 证书邮箱，直接回车用默认 `admin@<根域>`；
7. **公网入口方式**：选 `2) lucky / CF Tunnel 等反代入口（前置反代终结 TLS，Caddy 只监听内部端口）`；
8. **公网端口**：输入 lucky 反代监听的端口（浏览器访问时带 `:端口` 的那个，提示默认 443，lucky 常用 16666）；
9. **admin 密码**：输入 Authelia 的 admin 登录密码（不回显，需输入两次确认，脚本自动生成 argon2id 哈希）。首次配置时终端还会打印三个自动生成的 Authelia 密钥（session/reset/storage），注意保存；
10. **等待部署完成**：首次构建约 10 分钟（native 依赖编译）。脚本自动完成检查 → 构建 → 启动 dsh/Authelia/Caddy 三个容器 → 健康检查，任何检查未通过会中止并列出修复项；
11. **访问**：浏览器输入 `https://dsh.example.com:16666`（端口按第 8 步的实际值）。**第一次必须带 `https://`**——只输 `dsh.example.com:16666` 会被浏览器按 http 访问而失败；
12. **登录**：页面自动跳转 `auth.example.com`，输入 admin 密码；
13. **注册 2FA**：按提示开启一次性密码——验证码不会真的发到邮箱，而是写在 NAS 的 `dsh-nas/authelia/notifications.txt`（`cat authelia/notifications.txt` 查看），输入验证码后出现 TOTP 二维码，用手机 Authenticator 扫码添加；
14. **完成**：重新访问 `https://dsh.example.com:16666`，登录后即可使用。

### lucky 用户（推荐，你已有 DDNS + 证书）

lucky 继续负责：DDNS（域名 AAAA 记录 → NAS 公网 IPv6）、TLS 终结（你的证书）、公网 443 监听。Caddy 退居内部：

```
浏览器 → https://dsh.example.com → lucky（443，证书）→ http://127.0.0.1:13080
       → Caddy（内部 http，按域名路由）→ Authelia → dsh
```

lucky 配置（3 步）：

1. **反代 → 新建**：监听你的**公网 HTTPS 端口**（如 16666；监听地址留空 = 全部接口，含 IPv6）；证书选你已配置的那个；这个端口就是向导里输入的"公网 HTTPS 端口"，浏览器访问 `https://dsh.example.com:16666` 时用；
2. **两条转发规则**：
   - `dsh.example.com` → `http://127.0.0.1:13080`（**WebSocket 开启**）
   - `auth.example.com` → `http://127.0.0.1:13080`
3. **每条规则加请求头**：`X-Forwarded-Proto: https`（lucky 的"修改请求头"；否则 Authelia 会误判协议为 http，产生错误的 http 重定向）。

> IPv6 防火墙放行你 lucky 反代监听的公网端口（如 16666），而不是 443。

> lucky 的 DDNS 若尚未配置：DDNS → 新建 → 选你的 DNS 服务商 → 域名 `dsh.example.com` / `auth.example.com` → 记录类型 **AAAA** → 地址来源"自动检测 IPv6"。

### CF Tunnel 用户（备选）

Zero Trust → Tunnels → 创建隧道（token 模式）→ Public Hostnames 添加两条：`dsh.example.com` 和 `auth.example.com` → 服务都填 `http://127.0.0.1:13080`。隧道容器需出站走代理（`HTTPS_PROXY` 指向 7890）。

## Authelia 首次配置（5 步）

> 以下步骤 `./deploy.sh` 的配置向导会自动完成；手动配置时参考。

**① 替换域名占位符**：把 `caddy/Caddyfile` 和 `authelia/configuration.yml` 里的 `example.com` 全部换成你的域名（cookie 挂父域，所以必须是"可注册域"，如 `example.com`、`duckdns.org`）。

**② 生成两个随机密钥**，填进 `authelia/configuration.yml` 的 `CHANGE_ME_*`：

```sh
openssl rand -hex 32
```

**③ 生成用户密码哈希**，填进 `authelia/users_database.yml` 的 `password` 字段：

```sh
docker run --rm authelia/authelia:4.39 authelia crypto hash generate argon2 --password '你的密码'
```

**④ 启动**：

```sh
docker compose --profile auth up -d --build
```

**⑤ 注册 TOTP**（只需一次）：浏览器打开 `https://auth.example.com` → 用 admin 和密码登录 → 按提示用手机 Authenticator（Google/Microsoft/Aegis 等）扫码并输入一次性码。验证码会先写入 NAS 上的 `authelia/notifications.txt`，从那里读取：

```sh
cat authelia/notifications.txt
```

之后访问 `https://dsh.example.com`，未登录会自动跳转登录页。

## 使用与运维

```sh
docker compose ps                 # 查看状态
docker compose logs -f dsh        # dsh 日志
docker compose logs -f authelia   # 鉴权日志
docker compose restart dsh        # 重启 dsh（装插件后必须）
```

升级 dsh（推荐）：设置 → 服务控制 → 升级 dsh——点击「获取最新版本」或手动输入版本号，再点击升级。后台自动完成：改 `Dockerfile` 的 `ARG DSH_VERSION`（与 `docker-compose.yml` 的 build arg 保持同步）→ 执行一次 `deploy.sh`（重建镜像 + 重启容器）。Caddy/Authelia 配置、证书与 `data/` 数据不受影响；构建失败时现有服务保持运行。

> 首次使用网页端升级前，需在 NAS 上手动重跑一次 `./deploy.sh` 应用新版部署配置（镜像内 Docker CLI、`docker.sock`/项目文件挂载与属组）。命令行升级：`./deploy.sh --latest` 自动查询 npm 最新版、更新 `Dockerfile`/`docker-compose.yml` 版本号后构建（隐含 `--upgrade`）；或手动改 `Dockerfile` 的 `DSH_VERSION` → `docker compose up -d --build`。数据在 `data/`，不丢。`--upgrade`/`--latest` 模式显式跳过配置向导并在构建前保存 Caddy/Authelia/.env 快照。

安装社区插件（容器内已带 pnpm）：

```sh
docker exec -it dsh dsh plugin --profile web add <插件包名>
docker compose restart dsh        # 插件启动时组合进配置树，必须重启
```

插件管理注意事项（违规会导致容器起不来或升级失效）：

- **删除插件必须用 CLI**：`docker exec -it dsh dsh plugin --profile web remove <插件名>`。profile 的 `package.json` 里有**两处**记录——`dependencies` 依赖与 `dsh.profile.bundles` 注册表，手工只清一处会留下死引用：轻则升级时 pnpm 安装报 ENOENT（固化插件更新被阻断，升级功能失效），重则启动报 `cannot resolve profile bundle`（容器崩溃循环）；
- **`file:/workspace/...` 方式安装的插件，源目录不能删/移**：下次容器重启时 pnpm 解析会 ENOENT。要删这类插件：先 `remove`，再删源目录，顺序不能反；
- **升级/重建镜像不影响已装插件**：社区插件存放在 `data/dsh/profiles/web/`（持久卷），不在镜像内；entrypoint 的固化安装逻辑只管 `restart-dsh` 一个插件。

## 固化插件「服务控制」（重启 / 升级 dsh）

镜像内置 `plugins/restart-dsh`：设置面板新增「服务控制」页，提供一键重启与升级 dsh 两项能力。

**一键重启**：Host 半向容器 PID 1（tini）发送 SIGTERM → tini 转发给 dsh → 进程退出 → 容器由 `restart: unless-stopped` 自动拉起；RPC 走 `connection.rpc` 通道（`authority: 'loopback'`，与 `/api` 同款信任栅栏）。

**一键升级**：点击「获取最新版本」查询 npm registry 的 `@deepseek-ai/dsh` latest tag，也可手动输入版本号。确认后，插件启动一次性后台容器 `dsh-upgrader`：

1. 复用本地 `dsh:local` 镜像，以 root + host 网络运行，挂载宿主 `docker.sock`；项目目录**按原宿主路径**挂载——不能用 `/project` 之类的内部别名，`deploy.sh` 里 compose 的相对 bind（`./data/dsh` 等）按宿主路径解析，挂错名字会让 daemon 在宿主根下自动创建空的 `/project/data/dsh`，重建的容器挂到空数据目录直接启动失败；
2. 将版本写入 `Dockerfile` 的 `ARG DSH_VERSION` 和 `docker-compose.yml` 的 build arg，然后以 `--upgrade` 模式执行一次 `deploy.sh`；升级容器以 root 运行，执行前后都会把 `data/dsh` 属主修正为 1000:1000，防止属主漂移导致新容器 entrypoint 的可写检查失败；
3. `--upgrade` 显式跳过配置向导，并在构建前把 Caddyfile、Authelia 配置和 `.env` 快照到 `data/upgrade-config-backup/`；不会重写 Caddyfile / Authelia 配置，只重新构建 dsh 镜像并重新拉取对应 npm 版本，Caddy/Authelia 配置、证书与 `data/` 数据保留；
4. 进度写入 `data/upgrade-run.log` / `data/upgrade-run.exit`，设置页轮询展示日志尾部与结果。容器重建期间页面断开属正常，稍后刷新即可查看最终状态；
5. 构建失败时 `up -d` 不执行，现有服务保持运行，可查看 `data/upgrade-run.log`。

**首次启用网页端升级**：拉取本次代码后，必须先在 NAS 上手动运行一次 `./deploy.sh`，应用以下新配置：

- `dsh` 服务挂载项目版本文件、`data/`、`/var/run/docker.sock`；
- `deploy.sh` 自动检测 socket 属组并写入 `.env` 的 `DOCKER_GID`，Compose 用 `group_add` 授权；
- `Dockerfile` 运行阶段安装 Docker CLI 与 Compose 插件，供升级容器执行 `deploy.sh`。

安全提示：挂载 `docker.sock` 等价于宿主 root 权限；dsh 仍只监听回环，必须保持 Caddy + Authelia 鉴权链路，不要直接暴露 3080。若 NAS 的 socket 是 `root:root` 或属组无读写权限，网页端升级会自动禁用，但命令行升级不受影响。

- **自动安装/更新插件**：`entrypoint.sh` 启动时对比镜像内插件与持久化 profile 中的 `package.json` 版本，不一致则重新执行 `dsh plugin --profile web add file:/opt/dsh-plugins/restart-dsh`；本地包无需网络，失败不阻塞启动（报错细节写入 `/tmp/plugin-add.log` 并在容器日志回显）；pnpm 缓存已重定向到 `/tmp`，不污染 `/workspace`。pnpm 对 `file:` 依赖可能复用旧副本而不更新内容（安装"成功"但版本不变），安装后校验实际版本，仍不一致时删除 profile 副本手工同步镜像内版本；
- **手动重装**（如需）：

  ```sh
  docker exec -it dsh dsh plugin --profile web remove @dsh-nas/restart-dsh
  docker exec -it dsh dsh plugin --profile web add file:/opt/dsh-plugins/restart-dsh
  docker compose restart dsh
  ```

- 插件随镜像固化：重建镜像（`docker compose up -d --build`）后自动生效，不依赖会话级动态插件。

## 无域名、纯内网 IP 的备选方案

不想搞域名时，用 **Caddy 内置 Basic Auth**：打开 `caddy/Caddyfile` 末尾注释掉的 `:13080` 块、注释掉上面两个站点块，然后**不带** `--profile auth` 启动（authelia 容器不会被拉起，无需从 docker-compose.yml 删除）。密码哈希：

```sh
docker run --rm caddy caddy hash-password --plaintext '你的密码'
```

访问 `http://<NAS IP>:13080`，浏览器弹窗输密码（首次输入后自动缓存，WebSocket/SSE 不受影响）。这个方案适合纯内网；出公网请务必用上面的 Authelia 方案或 Tailscale。

## 常见问题

| 现象 | 处理 |
|---|---|
| 访问 dsh 显示 401 而不是登录页 | Caddyfile 的 `@authfail`/`handle_response` 块被改过或 Caddyfile 没生效（`docker compose restart caddy`）；确认 `authelia_url` 参数与 `session.cookies[].authelia_url` 一致 |
| 登录后跳回登录页（循环） | Authelia 日志里的 session domain 警告：`configuration.yml` 的 `cookies[].domain` 必须是你域名的公共父域（如 `example.com`），且与访问域名匹配 |
| Authelia 提示 configuration invalid | 检查 CHANGE_ME 是否都替换了；`docker compose logs authelia` 看具体报错 |
| TOTP 注册码在哪 | `cat authelia/notifications.txt`（文件通知器写入的） |
| 证书申请失败（直连模式） | 域名 AAAA/A 记录是否指向 NAS；防火墙是否放行 **443**（IPv6 也放行）；`docker compose logs caddy` 看 TLS-ALPN-01 结果 |
| 登录后跳回登录页（循环） | Authelia 配置的 cookie 域与访问域名不匹配；或反代入口模式漏了 `X-Forwarded-Proto: https` |
| 反代入口模式打不开 | lucky/CF 里两条规则是否都指向 `http://127.0.0.1:13080`；Caddy 内部 13080 是否被其他服务占用 |
| 内网用域名访问超时 | NAT hairpin（回流）问题：路由器开 NAT loopback，或改用 hosts 记录 |
| 模型请求超时/连接失败 | 确认宿主 `127.0.0.1:7890` 可达（见前置条件）；`docker compose logs dsh` 看有无 `TRANSPORT` 错 |
| 页面能开但流式输出卡住 | 确认没动 Caddyfile 的 `reverse_proxy` 块（Caddy 默认流式，无需额外配置） |
| 网页端升级失败 | 查看 `data/upgrade-run.log` 和 `data/upgrade-config-backup/`；常见原因是 npm 版本不存在、构建代理不通（`.env` 的 `DSH_PROXY`）或 `docker.sock` 无权限（重跑 `./deploy.sh` 检测 `DOCKER_GID`）。失败时现有服务保持运行 |
| 升级后 dsh 反复重启报 `profiles 不可写` | 旧版升级逻辑把项目目录挂成内部别名，compose 相对 bind 解析错位，daemon 在宿主根自动创建了空的 `/project/data/dsh`（root 属主）。`docker inspect dsh` 看 Mounts：出现 `/project` 即中招——从真实项目目录重跑 `./deploy.sh`，再删除宿主残留的 `/project` 目录 |
| 插件装不上 / 报 `cannot resolve profile bundle` | profile 里残留失效的 `file:` 依赖（源目录已删）：清理 `data/dsh/profiles/web/package.json` 的 `dependencies` 死引用及 `dsh.profile.bundles` 数组对应条目；`dsh plugin add` 的报错细节看容器日志的 `install error details` 段 |
| 升级后 dsh 起不来 | SSH 把 `Dockerfile` 的 `DSH_VERSION` 改回旧版本，再运行 `./deploy.sh` 回滚；`data/` 数据不受影响 |
| 数据目录权限错误 | `chown -R 1000:1000 data`（或 `data/dsh data/workspace`） |
| 连局域网 Ollama/本地模型 | 把它加进 `NO_PROXY`：`NO_PROXY=127.0.0.1,localhost,192.168.x.x` |
| 插件装完不生效 | 装完必须 `docker compose restart dsh` |

## 安全提醒（重要）

- **dsh Web 没有认证层**，靠 Caddy + Authelia 补；**不要**绕过 Caddy 直接暴露 3080 端口。
- Authelia 默认 `two_factor`：登录需密码 + TOTP。手机 Authenticator 请备份（丢失需重配，Authelia 提供一次性备份码）。
- `authelia/notifications.txt` 含验证码，部署完可删除内容（Authelia 会继续追加）。
- 代理端口 7890 只监听内网；公网端口只开 80/443。
- 网页端升级挂载了 `docker.sock`（等价宿主 root 权限），务必保持 Caddy + Authelia 鉴权链路完整，不要把 3080 直接暴露到局域网/公网。

## UI 手动创建（不支持 compose 的 NAS）

镜像：先在有 Docker 的机器执行 `docker build -t dsh:local .` 后用 `docker save/load` 导入（authelia/caddy 直接拉官方镜像），然后创建三个容器，网络模式全部选 **host**：

| 容器 | 镜像 | 卷映射 | 环境变量 |
|---|---|---|---|
| dsh | `dsh:local` | `data/dsh` → `/home/node/.dsh`、`data/workspace` → `/workspace`；网页端升级还需挂载 `Dockerfile`、`docker-compose.yml`、`data/` 和 `/var/run/docker.sock` | `NODE_USE_ENV_PROXY=1`、`HTTP_PROXY=http://127.0.0.1:7890`、`HTTPS_PROXY=http://127.0.0.1:7890`、`NO_PROXY=127.0.0.1,localhost`（代理不在本机时把 127.0.0.1 换成代理地址） |
| authelia | `authelia/authelia:4.39`（固定版，配置按此编写，仅主方案需要） | `authelia/` → `/config` | 无 |
| caddy | `caddy:2-alpine` | `caddy/Caddyfile` → `/etc/caddy/Caddyfile`（只读）、`caddy/data` → `/data`、`caddy/config` → `/config` | 无 |

重启策略全部选"退出时重启"；dsh 的健康检查命令：`node -e "fetch('http://127.0.0.1:3080').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"`（间隔 30s、超时 5s、重试 3 次）。

## 文件说明

| 文件 | 作用 |
|---|---|
| `Dockerfile` | dsh 镜像：node:22-bookworm + tini（PID 1）+ 固定版本 pnpm@11.20.0 + Docker CLI/Compose + node 用户（UID 1000）；`/home/node/.dsh` 与 `/workspace` 分离 |
| `entrypoint.sh` | 设置代理环境变量（`NODE_USE_ENV_PROXY=1` 是 Node fetch 走代理的总开关）；显式 `dsh web --host 127.0.0.1` 绑定回环；启动前按版本号自动安装/更新固化插件 |
| `docker-compose.yml` | 三容器编排，host 网络，健康检查，自动重启；dsh 挂载 docker.sock、版本文件和升级日志，使用 `.env` 的 `DOCKER_GID` 授权；authelia 挂 `auth` profile |
| `plugins/restart-dsh/` | 固化插件「服务控制」：host 半注册 `/restart-dsh` 与 `/dsh-upgrade` RPC（重启或启动一次性升级容器执行 `deploy.sh`）；client 半注册设置页面板（重启确认 + 版本/日志/结果） |
| `caddy/Caddyfile` | 反代 + forward_auth + Host/Origin 改写 + 内网 Basic Auth 备选 |
| `authelia/configuration.yml` | Authelia v4.39 配置（SQLite 单实例、文件通知器） |
| `authelia/users_database.yml` | 用户库（argon2id 密码哈希） |

## 许可证

MIT（见 [LICENSE](LICENSE)）
