# dsh-nas 升级与维护手册

本文档覆盖 dsh 升级到 **v0.1.2-alpha.1+（浏览器一次性 token 认证）** 前后的全部流程与日常维护。文中网址均为示例（`dsh.example.com` / `auth.example.com`），使用时替换为你的真实域名。

## 背景：新版一次性 token 认证是什么

v0.1.2-alpha.1 起，dsh 在应用层加了浏览器会话认证（官方发布说明：「网络访问 Web 界面时启用链接中的一次性 token 认证鉴权」）：

- 每个 dsh 进程生成随机启动令牌；`dsh web` 启动时打印一次带 `?token=…` 的 URL。
- 首次打开该 URL 会签发一个签名 cookie（默认 30 天，可配）并 303 跳回干净地址；此后所有 Web 会话（含 `/api` RPC）都要求该 cookie，缺失/过期一律 401。
- 认证**无条件生效**（本地访问同样走交换，只是 `dsh web` 会自动带 token 打开）；不存在 loopback 豁免，也没有为反向代理做特殊处理。
- Authelia 双因素层不受影响，仍在其前端；Caddy/Authelia 配置无需为此改动。

配套仓库改动（已合入本仓库，升级前后均安全）：

| 文件 | 改动 |
|---|---|
| `docker-compose.yml` | 健康检查改为「任何 HTTP 响应都算存活」（未带 cookie 的 `/` 返回 401 是正常行为，不再导致 unhealthy）；透传 `DSH_COOKIE_MAX_AGE_DAYS` 环境变量 |
| `entrypoint.sh` | `DSH_COOKIE_MAX_AGE_DAYS` 非空时生成 `--patch` overlay 覆盖 connection 行 `cookieMaxAgeDays`，**改有效期无需重建镜像** |
| `deploy.sh` | `--cookie-max-age DAYS` 参数 + 首次部署向导询问，持久化到 `.env`；新增 `./deploy.sh url` 子命令打印最新启动 URL |
| `README.md` | 补充「v0.1.2+ 浏览器一次性 token 认证与维护」章节 |

> 兼容性说明：当前 rc.2 的 connection schema 没有 `cookieMaxAgeDays` 键，schemastery 对未知键保留但不报错——升级前配置了也安全（被忽略，仍默认 30 天），升级后自动生效。

---

## 阶段 0：现在就做（无需等新版）

### 拉包与配置保护（老用户必读）

```sh
# 首次拿包（还没有仓库副本时）：
git clone https://github.com/gehennawu/dsh-nas.git /path/to/dsh-nas

# 老用户拉包（已有部署）：一键升级本脚本，自动保护本地配置——
sudo ./deploy.sh update-script
```

`update-script` 内部自动完成：保护 `caddy/Caddyfile`、`authelia/*.yml`（skip-worktree，幂等）→ 快进拉取远端 main → 保留 Dockerfile 锁定的 dsh 版本选择。**只手动替换 deploy.sh 也可以**（脚本会把整个包按远端更新，受保护配置不受影响）；但 NAS 上的项目目录必须是用 `git clone` 部署的（有 `.git`）。脚本版本过旧（无 `update-script` 命令）时，手动执行一次 `git pull`，之后就能用自升级。

要点：

- `.env`、`data/`、`caddy/data/`、`authelia/data/` 本来就在 `.gitignore`（未跟踪），`git pull` 碰不到；
- `update-script` 保护的「向导/部署生成、每台 NAS 都不同的本地配置」——Caddyfile 与 Authelia 域名/密码等永久归你所有；
- Dockerfile 由 `deploy.sh` 管理（每次部署写回你选的 dsh 版本）。若未来 `git pull` 提示 Dockerfile 本地冲突，先接受上游版本再重跑升级（会自动写回所选版本）：
  `git checkout -- Dockerfile && sudo ./deploy.sh --upgrade`

```sh
# 可选：调整会话 cookie 有效期（正整数天；空 = dsh 默认 30 天）
sudo ./deploy.sh --cookie-max-age 90
docker compose up -d dsh          # 重建容器生效，不用重新构建镜像

# 也可在 --setup 向导中回答；或直接改 .env 的 DSH_COOKIE_MAX_AGE_DAYS
```

不调整就跳过，默认 30 天完全够用（见「日常维护」的续期节奏）。

## 阶段 1：升级到 v0.1.2+

**alpha 预览版已经发布到 npm 的 `alpha` dist-tag。** 当前不要用 `--latest` 期待得到 alpha 版本：`--latest` 只读取 npm `latest` 正式版。升级前请先备份 `data/dsh/`，并确认目标 alpha 版本的会话/插件兼容性。

```sh
# 老用户完整命令（保护配置/自升级在阶段 0；脚本旧则先手动 git pull 一次）
cd /path/to/dsh-nas && sudo ./deploy.sh update-script
sudo ./deploy.sh --upgrade                 # 交互选择 dsh 版本（锁定版/latest/next/alpha）后重建
# 或直接升级到 npm alpha 预览版：
sudo ./deploy.sh --alpha
# 或带设置一次到位：alpha 升级 + cookie 有效期 365 天
sudo ./deploy.sh --alpha --cookie-max-age 365
# 正式版升级仍使用：
sudo ./deploy.sh --latest --cookie-max-age 365   # 直接取 npm latest
```

升级机制（仓库原有能力）：root-only 事务快照 + 升级锁；构建/启动/健康/listener 校验失败自动恢复旧版本文件、旧镜像和旧 dsh 服务；`--latest`/`--alpha` 在快照后查询对应 dist-tag 并写入版本；构建前会再次询问 trusted-domain patch、`--cookie-max-age` 沿用 `.env` 已保存值不重复打扰。

**升级前的插件兼容性检查（alpha/新版本必做）**：alpha.2 移除了 `@deepseek-ai/dsh-settings` 的 `settingsNamespace`、`installSettingsSection` 等导出，并重构了插件清单/Remote 契约。第三方插件若仍 import 这些旧导出，会在启动时抛 `The requested module '@deepseek-ai/dsh-settings' does not provide an export named ...`，导致 dsh 容器崩溃循环。升级前：

```sh
# 在宿主查看 web profile 启用了哪些第三方插件
ls data/dsh/profiles/web/node_modules/ | grep -v '^\.' | grep '^[a-z]'
# 逐个核对插件 dist-tag 是否声明兼容目标版本（npm 页面或：）
npm view dsh-better-sidebar@alpha peerDependencies.@deepseek-ai/dsh-settings
npm view dshmarket dist-tags
```

- 有适配版（如 `dsh-better-sidebar@0.18.0-alpha.0` 声明 `^0.1.2-alpha.2`）→ 先升级插件再升 dsh；
- 无适配版 → 移除插件（`dsh plugin --profile web remove <pkg>`）或等作者更新后再升 dsh，避免容器启动失败。

升级当天三件事：

1. **健康检查**——已适配（见上表），无需手动处理。
2. **trusted-domain patch**——继续保留。客户端 `connection.isLoopback` 依旧只看页面 hostname，设置页持久化与「在 NAS 上打开文件」等特权面仍依赖 `DSH_TRUSTED_DOMAIN` patch；patch 与一次性 token 认证互不冲突（认证全域生效，patch 只影响浏览器权限面判定）。升级时照常回答向导即可。
3. **首次 401 交换**——升级后第一次访问 `https://dsh.example.com/`（即使 Authelia 已登录）会看到 401。取令牌两种方式任选：

```sh
./deploy.sh url                                     # SSH 到 NAS 执行；自动拼好公网地址（https://dsh.example.com[:公网端口]/?token=xxxx），直接复制打开
# 或：NAS 官方 Docker 管理界面查看 dsh 容器日志，找最新的 "dsh web: ..." 行
# 输出形如: dsh web: http://127.0.0.1:3080/?token=xxxx (LAN: ...)
# 手动方式下复制 ?token= 段拼到反代地址：https://dsh.example.com/?token=xxxx
```

粘到浏览器打开 → 自动 303 跳回干净地址并签发 cookie → 之后正常使用。**token 与打印出来的 host 无关**，直接取 `?token=` 段即可；`./deploy.sh url` 已自动完成拼接（公网域名/端口从 Caddyfile 读取，反代入口模式的内部端口 13080 不会混入）。

**升级后只需做这一次浏览器交换**：cookie 的 HMAC 密钥持久化在 `data/dsh/.credentials.yaml`（已挂载），重启/重建容器不影响已签发 cookie。

## 阶段 2：日常维护

### 会话续期（每月约一次）

| 场景 | 操作 |
|---|---|
| cookie 过期 | `./deploy.sh url`（自动拼好公网 token URL，直接复制打开），或 NAS 官方 Docker 界面看 dsh 容器日志里的 `dsh web:` 行手动拼 → 打开 → 自动续期，cookie 从当刻重新起算 |
| 提前续期 | 同一操作，任何时候都行；令牌在进程生命周期内可反复使用（「一次性」指只接受交换路径，不是单次消费） |
| dsh 重启/重建后 | **什么都不用做**（cookie 有效则继续用）；如需续期必须用重启后的新 token——旧 token URL 已失效（日志里取最新一行） |
| 过期 token + 有效 cookie | 无害：会直接 303 回干净地址（只是没有续期效果） |
| 换浏览器 / 新设备 | 每个浏览器各打开一次 token URL，各持独立 cookie、独立 30 天，互不影响 |
| 无痕/隐私窗口 | 可用，但关窗即销毁 cookie，下次重新交换 |
| 全局吊销 | 删 `data/dsh/.credentials.yaml` + 重启 dsh ⇒ 所有浏览器会话全部失效，各自重新交换 |

### 调整有效期

三种等价方式（保存到 `.env` 的 `DSH_COOKIE_MAX_AGE_DAYS`）：

```sh
sudo ./deploy.sh --setup --cookie-max-age 120    # 向导后生效
sudo ./deploy.sh --cookie-max-age 120            # 直接设置
# 或手动编辑 .env 后: docker compose up -d dsh
```

留空 = dsh 默认 30 天。cookie 是 bearer 凭证，有效期越长被盗后的暴露窗口越大，建议够用即可。

**注意：改时长只对新签发的 cookie 生效。** 已持有的 cookie 保持原到期时间不变——改完配置后，每个浏览器需重新打开一次 token URL（重新交换）才能拿到新时长。

### 日常升级（与以前相同）

```sh
sudo ./deploy.sh --upgrade
```

数据都在 `data/`，不会因重建丢失；`./deploy.sh url` 与 `--cookie-max-age` 在每次部署总结末尾都有提示。

## 安全提醒

- **token URL 是进程凭据**：拿到它就能换出完整 API 权限的 cookie。`./deploy.sh url` 的输出、`docker logs dsh` 中的 `dsh web:` 行都属于敏感信息，勿外传。
- `data/dsh/`（含 `.credentials.yaml`）与 `docker logs` 保持 NAS 本地私有；不要在非受信终端粘贴 token URL。
- 部署后 dsh 仍只监听 `127.0.0.1:3080`（`deploy.sh` 会硬校验 listener），局域网无法绕过 Caddy + Authelia 直连。
- 一次性 token 认证补齐了「Host 头可伪造」这一旧缺陷：新版 `/api` 栅栏（loopback / trustedHosts）只决定 403 与 401 之分，真正的门禁是签名 cookie。