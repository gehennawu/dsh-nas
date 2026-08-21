# dsh-nas：特定 Linux NAS 部署模板

这是一个面向 **Linux NAS** 的 dsh 部署模板：使用 Docker Engine、Docker Compose V2、Bash/GNU 工具和 host 网络，在 NAS 本地可写目录中运行 dsh、Authelia 与 Caddy。

它不是通用 NAS 方案。支持边界见[支持范围](#支持范围)。

## 与常见 Basic Auth 方案的差别

多数 NAS 反代教程的做法是「容器监听 0.0.0.0 + 反代挂 Basic Auth」。对本项目不够，原因：

| 维度 | Basic Auth 方案 | 本方案 |
|---|---|---|
| 认证因子 | 单因子密码，浏览器常驻保存，每个请求都携带明文凭据 | Authelia 双因素（TOTP）；会话 1 小时上限、5 分钟无操作失效，勾选「记住我」延长为 1 个月（可配置收紧） |
| 凭据泄露后果 | 密码即全部权限，无法按设备撤销 | 单个会话可单独登出；连续失败 5 次锁定 5 分钟 |
| 应用暴露面 | 容器监听 0.0.0.0，局域网可绕过反代直连应用 | dsh 只监听 `127.0.0.1`，绕过认证无路径；部署后硬校验实际 listener |
| AI Agent 风险 | 常见网页升级教程给容器挂 Docker socket，等价于交出宿主 root | 主容器无 socket、无 Docker CLI；升级走宿主机命令行，带快照与自动回滚 |

dsh 是能执行任意命令的 AI Agent，凭据一旦被拿走就是整台 NAS。所以这个模板的安全边界按「应用本身必然会被攻破」设计：认证是独立的双因素层，应用本体只绑回环，宿主控制权不出 NAS 命令行。

## 支持范围

### 支持

- Linux 主机、rootful Docker Engine、Docker Compose V2（`docker compose` 插件或 V2 独立版）
- Bash 与 GNU `sed`/`grep`/`awk`/`stat`
- x86_64 和 ARM64
- `network_mode: host`
- 项目目录、`data/`、`authelia/data/`、`caddy/` 位于本地可写文件系统
- 容器内 dsh 以 UID 1000 运行，相关目录必须允许 UID 1000 写入

### 不支持

- TrueNAS CORE、非 Linux Docker 主机
- rootless Docker、不支持 host 网络的容器平台
- 仅提供 BusyBox、缺少 Bash/GNU 工具的环境
- 不能使用 Docker Compose V2 的 NAS 管理界面
- 没有域名且没有可用前置 TLS 代理的部署

## 架构与安全边界

```text
公网浏览器
    │
    ├─ 直连 80/443 或 443-only ──> Caddy ──> Authelia 127.0.0.1:9091
    │                                      └─> dsh 127.0.0.1:3080
    │
    └─ 同机前置反代/Tunnel ──> Caddy 127.0.0.1:13080
                                         ├─> Authelia 127.0.0.1:9091
                                         └─> dsh 127.0.0.1:3080

 dsh 出站请求 ──> NAS 宿主代理（默认 127.0.0.1:7890）
```

- 三个容器都用 host 网络；容器内 `127.0.0.1` 就是 NAS 宿主机。
- dsh 由 `entrypoint.sh` 强制绑定 `127.0.0.1`，局域网无法绕过 Caddy + Authelia 直连 3080。
- `deploy.sh` 启动后校验 dsh/Authelia/Caddy 的实际 listener，关键安全检查失败即非零退出。
- dsh 容器不挂载 Docker socket，运行镜像不含 Docker CLI/Compose。
- 重启与升级都在 NAS 命令行执行：`docker compose restart dsh`、`sudo ./deploy.sh --upgrade`。
- 必须使用域名 + Authelia 双因素，或同机已终结公网 TLS 的前置反代/Tunnel。

## 三种 Caddy 入口模式

三个模式的内部链路完全相同：Caddy → Authelia（双因素）→ dsh，都只在宿主回环上互联。**唯一的区别是：谁来当公网入口、TLS 在哪里终结。**

| | 1. 直连 80/443 | 2. 直连 443-only | 3. 前置反代/Tunnel |
|---|---|---|---|
| 公网入口 | NAS 上的 Caddy | NAS 上的 Caddy | lucky / CF Tunnel 等 |
| 需要 NAS 有公网 IP | 是（IPv4 或 IPv6） | 是（IPv4 或 IPv6） | 否 |
| 需要开放入站端口 | 80 + 443 | 仅 443 | 前置入口的端口（如 16666） |
| 证书由谁管 | Caddy 自动（ACME） | Caddy 自动（TLS-ALPN-01） | 前置入口 |
| 访问地址 | `https://dsh.<domain>` | `https://dsh.<domain>` | `https://dsh.<domain>[:端口]` |

配置向导会写入 `# dsh-nas-entry-mode: ...` 标记，部署脚本据此恢复模式并执行对应的端口与 listener 校验。

### 1. 直连 80/443：`direct-80-443`

流量路径：`浏览器 →（公网）→ NAS:80/443 → Caddy → Authelia/dsh`

- Caddy 自己就是公网入口：域名 A/AAAA 记录指向 NAS 的公网地址（动态 IP 配 DDNS），路由器把 80、443 转发进 NAS
- 80 用于 HTTP→HTTPS 自动跳转和 ACME HTTP-01 证书验证
- 国内家宽 80 端口大多被运营商封禁，此模式在国内家庭网络经常实际退化为模式 2
- 部署后 Caddy 必须只报告 `:80`、`:443`

### 2. 直连 443-only：`direct-443-only`

流量路径：`浏览器 →（公网）→ NAS:443 → Caddy → Authelia/dsh`

- 同样需要公网 IP（IPv4 或 IPv6 都行——没有公网 v4 时用 AAAA 记录走 IPv6 也算直连），但只要求 443 可达，80 被占用或被封也能用
- Caddy 只监听 443；不提供 HTTP→HTTPS 跳转，浏览器必须显式输入 `https://`
- 证书走 TLS-ALPN-01（只需 443 可达）；只能 DNS-01 的环境需自行配置 Caddy DNS provider
- 部署后 Caddy 必须只报告 `:443`

### 3. 前置反代/Tunnel：`front-proxy`

流量路径：`浏览器 →（公网）→ lucky/CF 等前置入口（在这里终结 TLS）→ NAS 内部 127.0.0.1:13080 → Caddy → Authelia/dsh`

- Caddy 不接触公网：`auto_https off`，只监听 `127.0.0.1:13080`；公网入口是 lucky、OpenResty、Cloudflare Tunnel 等
- **NAS 不需要公网 IP，也不需要开放入站端口**（CF Tunnel 是纯出站连接；lucky 按自己的穿透/DDNS 方式工作）
- 前置入口把 `dsh.<domain>` 和 `auth.<domain>` 都转发到 `http://127.0.0.1:13080`——后端地址必须是 127.0.0.1，不能填 NAS 局域网 IP；并设置 `X-Forwarded-Proto: https`
- 前置入口必须与 Caddy 同机且能访问宿主回环（host 网络；bridge 容器里的 `127.0.0.1` 不是宿主机）；非回环 listener 会硬失败
- 前置监听的非标端口（如 16666）会写进 Authelia URL 和访问地址

选择顺序：有公网 IP 且 80/443 都空闲 → 模式 1；有公网 IP 但 80 不可用 → 模式 2；没有公网 IP，或 NAS 上已经有 lucky/CF 入口 → 模式 3。

## 前置条件

1. **出站代理**：NAS 宿主上有 HTTP/mixed 代理，默认 `127.0.0.1:7890`。验证：

   ```sh
   curl -x http://127.0.0.1:7890 -sI https://api.deepseek.com | head -n 1
   ```

   代理不在 NAS 本机时用 `./deploy.sh --proxy-host 192.168.1.10:7890`，并确保代理允许局域网访问。

2. **域名和 DNS**：需要 `dsh.<domain>` 与 `auth.<domain>` 两个主机名。直连模式解析到 NAS；前置反代模式解析到公网 TLS 入口。

3. **本地目录**：项目目录和运行数据须位于本地可写文件系统（非只读挂载、可 `chown`）。容器内 UID 1000 需要写入：

   ```sh
   mkdir -p data/dsh data/workspace \
     caddy/data caddy/config
   sudo chown -R 1000:1000 data/dsh data/workspace
   ```

   不要对整个 `data/` 做 `chown -R`：`data/` 本身保持部署用户所有，容器只需要写入上面两个子目录。

   往 `data/workspace` 放入文件（SSH/SMB/文件管理器拷贝）后，属主通常不是 UID 1000，agent 只读不可写；拷贝完成后执行 `sudo chown -R 1000:1000 data/workspace` 修正（该目录为容器专属，整目录递归 chown 安全）。在 dsh 网页里新建的目录以 UID 1000 创建，无此问题。

   Authelia/Caddy 配置文件只读挂载；`authelia/data/`、`caddy/data/`、`caddy/config/` 由对应容器写入，`deploy.sh` 会做实际写入测试。

4. **SSH 和 Docker 权限**：能在 NAS 上执行 Docker 命令。

## 快速部署

推荐只用部署脚本：启动前执行 Compose、Authelia 配置和 Caddyfile 语法校验，再执行目录、端口、健康和 listener 检查。

```sh
cd dsh-nas
chmod +x deploy.sh
./deploy.sh
```

首次运行时向导会：

1. 写出站代理地址到 `.env`；
2. 询问根域名、证书邮箱和 Authelia admin 密码；
3. 选择三种 Caddy 入口模式；
4. 自动生成 Authelia 密钥、用户密码哈希和 Caddyfile（被改写文件备份 `.bak`）；
5. 询问是否启用 DSH 反代域名 patch；启用时将 hostname 保存到 `.env`，构建阶段以 root patch DSH bundle；不启用则保持原始 loopback-only 行为；
6. 检查文件、目录、端口、代理连通性；
7. 构建前交互选择 dsh 版本：展示 Dockerfile 锁定版、npm `latest` 正式版、npm `next` 预览版三个选项（各带版本号），选择后写回 `Dockerfile` 的 `ARG DSH_VERSION`；回车默认保持锁定版，非交互或 registry 不可达时自动按锁定版继续；
8. 构建并启动，等待健康检查并校验 listener；全部通过后按 Docker 引用关系清理 dangling 旧镜像。

## 升级

```sh
sudo ./deploy.sh --upgrade    # 交互选择 dsh 版本（锁定版/latest/next）后重建
sudo ./deploy.sh --latest     # 不询问，直接查询 npm latest，更新版本号后重建
```

- 升级需 root（事务快照与升级锁在 root-only 的 `/var/lib/dsh-nas-upgrade`）。
- 跳过 Caddy/Authelia 配置向导，但仍交互询问是否启用/更新 DSH 反代域名 patch；构建前还会交互选择 dsh 版本（`--latest` 则跳过选择，直接用 npm latest）；构建前保存配置、`.env`、旧镜像 ID 和容器状态，版本选择发生在快照之后，失败回滚仍恢复旧版本号。
- `flock` 防并发；版本文件原子替换。
- 构建、启动、健康或 listener 校验失败时自动恢复旧版本文件、旧镜像和旧 dsh 服务；恢复失败仍非零退出。这是单机回滚保护，不是蓝绿发布。
- 运行数据在 `data/`，不会因重建丢失。

## 常用参数

```sh
./deploy.sh --skip-build                    # 使用已有 dsh 镜像启动
./deploy.sh --proxy-host 192.168.1.10:7890  # 设置构建和运行时代理
./deploy.sh --setup                          # 重新选择域名、入口或密码
```

## 构建和版本

- dsh 版本唯一来源是 `Dockerfile` 的 `ARG DSH_VERSION`。
- 交互部署在构建前从 npm dist-tags 端点拉取 `latest`（正式版）与 `next`（预览版）版本号，连同 Dockerfile 锁定版一起列出供选择（直连失败自动走代理重试）；选定后原子写回 `Dockerfile`。`--skip-build` 不构建故不询问，`--latest` 已自动选定 latest 不再询问。
- 版本号查询不受缓存影响：脚本不经 npm 本地缓存（纯 HTTP 直读 registry），每次请求追加唯一时间戳参数并携带 `Cache-Control: no-cache` 请求头，穿透转发代理/CDN 等中间层可能按 URL 缓存的旧响应。
- 构建阶段的 apt/npm 下载走部署脚本传入的代理；构建容器内 `127.0.0.1` 不是宿主机，代理须填 NAS 局域网地址。
- 运行时代理来自 `.env` 的 `DSH_PROXY`；`NO_PROXY` 至少含 `127.0.0.1,localhost`。
- 可选的 `.env` 键 `DSH_TRUSTED_DOMAIN` 只接受纯 hostname（如 `dsh.example.com`），不含协议、端口或路径；非空时 Dockerfile 在 root 构建阶段 patch DSH 的浏览器与 Host API loopback 判定。修改此值必须重新构建 dsh 镜像；执行 `--upgrade`/`--latest` 时脚本会再次询问并保留或修改选择。
- patch 过程可见性：patch 在构建的 RUN 步骤内执行，BuildKit 进度 UI 会折叠其输出；构建完成后（以及 `--skip-build` 启动前）脚本会进入镜像实测核验并在部署日志打印结论——两个 bundle 是否接受反代域名、镜像内 dsh 版本是否与 Dockerfile 锁定一致，不一致则拒绝启动。需逐行查看 patch 原始输出可运行 `BUILDKIT_PROGRESS=plain docker compose build dsh`。
- 首次构建需编译 native 依赖，耗时取决于 NAS CPU 和代理速度。
- `.dockerignore` 保证构建上下文不含运行数据、密钥和部署脚本；构建还需要 `patch-trusted-domain.mjs`。

## Authelia 首次配置

向导会自动完成；手动配置时参考：

1. 替换 `authelia/configuration.yml`、`authelia/users_database.yml` 和 Caddyfile 中的域名为真实域名；
2. 用随机值替换 `CHANGE_ME_*` 密钥；
3. 生成 argon2id 密码哈希：

   ```sh
   docker run --rm authelia/authelia:4.39 \
     authelia crypto hash generate argon2 --password '你的密码'
   ```

4. `docker compose --profile auth up -d` 启动；
5. 首次登录后按提示注册 TOTP；初始验证码在 `authelia/data/notifications.txt`，读取后妥善保护或清理。

## 前置反代配置要点

以同机 lucky 为例：

1. 配置公网 HTTPS listener 和证书；
2. `dsh.<domain>` 和 `auth.<domain>` 都转发到 `http://127.0.0.1:13080`；后端地址必须是 `127.0.0.1`，不能填 NAS 局域网 IP——Caddy 只监听回环，这是防止局域网绕过认证直连的边界。lucky 需以 host 网络运行才能访问宿主回环；
3. dsh 规则开启 WebSocket；
4. 两条规则都设置 `X-Forwarded-Proto: https`；
5. 向导中的公网端口与 lucky 实际监听端口一致。

Cloudflare Tunnel 等容器化前置入口需使用 host 网络或明确的宿主访问方式；bridge 网络中的 `127.0.0.1:13080` 指向前置容器自身。

## 使用与运维

```sh
docker compose ps
docker compose logs -f dsh
docker compose restart dsh
```

社区插件用 dsh CLI 管理：

```sh
docker exec -it dsh dsh plugin --profile web add <插件包名>
docker exec -it dsh dsh plugin --profile web remove <插件名>
docker compose restart dsh
```

## 常见问题

| 现象 | 处理 |
|---|---|
| 配置向导拒绝继续 | 检查域名、密钥、用户哈希和 Caddyfile 模式标记；必要时 `./deploy.sh --setup`。 |
| 80 被占用 | 443 空闲选 443-only；443 也被占用选前置反代模式。 |
| 443-only 证书申请失败 | 检查 A/AAAA、IPv6 防火墙和 443 可达性；看 `docker compose logs caddy`。 |
| 前置反代 502 /「后端访问被拒绝」 | lucky/CF 的后端地址必须填 `http://127.0.0.1:13080`，**不能填 NAS 局域网 IP**——Caddy 只监听回环（旧版绑 0.0.0.0，局域网 IP 曾经可用，从旧版升级后必须改）。dsh 和 auth 两条规则都要指到这个地址。 |
| 部署报告 Caddy 非回环 listener | 检查 Caddyfile 的 `default_bind 127.0.0.1`。 |
| 未登录 401 或跳转循环 | 检查 Authelia URL、cookie domain、`X-Forwarded-Proto` 和 `forward_auth` 块。 |
| dsh 反复重启或 profiles 不可写 | `sudo chown -R 1000:1000 data/dsh data/workspace`，确认挂载在可写本地目录。 |
| 模型请求超时 | 检查 `DSH_PROXY`、代理监听地址和 `docker compose logs dsh`。 |
| 流式输出或 WebSocket 异常 | 检查前置代理的 WebSocket 设置。 |
| CLI 升级失败 | 脚本会尝试恢复快照、旧镜像和 dsh 服务；若恢复失败，按提示检查 `Dockerfile`、`dsh:local` 和 Compose 状态。 |

## 安全要求

- 不要把 3080 暴露到局域网或公网；dsh 没有独立认证层。
- 不要给 dsh 容器挂载 Docker socket。
- 公网 TLS 必须由 Caddy 直连模式或同机前置代理/Tunnel 终结。
- 443-only 不会自动把 HTTP 跳转到 HTTPS；使用正确的 `https://` URL。

## 目录结构

```text
dsh-nas/
├── Dockerfile               # 构建 dsh 镜像；唯一版本来源 ARG DSH_VERSION
├── deploy.sh                # 部署/升级/回滚脚本
├── entrypoint.sh            # 容器入口：代理、DSH_HOME 自检、回环绑定启动
├── patch-trusted-domain.mjs # 可选：构建阶段 patch DSH loopback 判定
├── docker-compose.yml       # 三容器 host-network 编排与健康检查
├── .dockerignore            # 构建上下文排除运行数据、密钥和部署配置
├── caddy/
│   ├── Caddyfile            # 向导按入口模式生成
│   ├── data/                # 证书与运行数据
│   └── config/              # 配置状态
├── authelia/
│   ├── configuration.yml    # 宿主维护，容器只读挂载
│   ├── users_database.yml   # 用户库与 argon2id 哈希，容器只读挂载
│   └── data/                # SQLite 与通知文件，容器写入
├── data/
│   ├── dsh/                 # → /home/node/.dsh，UID 1000
│   └── workspace/           # → /workspace，UID 1000
└── .env                     # deploy.sh 生成的 DSH_PROXY
```

升级事务快照与锁位于 `/var/lib/dsh-nas-upgrade`（root-only）。

## 许可证

MIT（见 [LICENSE](LICENSE)）。
