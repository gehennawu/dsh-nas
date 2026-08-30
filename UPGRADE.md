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

```sh
# 可选：调整会话 cookie 有效期（正整数天；空 = dsh 默认 30 天）
sudo ./deploy.sh --cookie-max-age 90
docker compose up -d dsh          # 重建容器生效，不用重新构建镜像

# 也可在 --setup 向导中回答；或直接改 .env 的 DSH_COOKIE_MAX_AGE_DAYS
```

不调整就跳过，默认 30 天完全够用（见「日常维护」的续期节奏）。

## 阶段 1：升级到 v0.1.2+

**前置确认：版本必须已在 npm 发布。** `dsh-v0.1.2-alpha.1` 目前只有 GitHub release，npm `latest` 仍是 `0.1.1-rc.2`（Dockerfile 从 npm 安装，发布前升级引导里选不到）。等到 npm 发布后再执行：

```sh
sudo ./deploy.sh --upgrade    # 交互选择 dsh 版本后重建
sudo ./deploy.sh --latest     # 不询问，直接取 npm latest
```

升级机制（仓库原有能力）：root-only 事务快照 + 升级锁；构建/启动/健康/listener 校验失败自动恢复旧版本文件、旧镜像和旧 dsh 服务；构建前会再次询问 trusted-domain patch、`--cookie-max-age` 沿用 `.env` 已保存值不重复打扰。

升级当天三件事：

1. **健康检查**——已适配（见上表），无需手动处理。
2. **trusted-domain patch**——继续保留。客户端 `connection.isLoopback` 依旧只看页面 hostname，设置页持久化与「在 NAS 上打开文件」等特权面仍依赖 `DSH_TRUSTED_DOMAIN` patch；patch 与一次性 token 认证互不冲突（认证全域生效，patch 只影响浏览器权限面判定）。升级时照常回答向导即可。
3. **首次 401 交换**——升级后第一次访问 `https://dsh.example.com/`（即使 Authelia 已登录）会看到 401。SSH 到 NAS：

```sh
./deploy.sh url
# 输出形如: dsh web: http://127.0.0.1:3080/?token=xxxx (LAN: ...)
```

把 `https://dsh.example.com/?token=xxxx` 粘到浏览器打开 → 自动 303 跳回干净地址并签发 cookie → 之后正常使用。

**升级后只需做这一次浏览器交换**：cookie 的 HMAC 密钥持久化在 `data/dsh/.credentials.yaml`（已挂载），重启/重建容器不影响已签发 cookie。

## 阶段 2：日常维护

### 会话续期（每月约一次）

| 场景 | 操作 |
|---|---|
| cookie 过期（默认 30 天） | `./deploy.sh url` → 打开输出中的 token URL → 自动续期，cookie 从当刻重新起算 |
| 提前续期 | 同一操作，任何时候都行；令牌在进程生命周期内可反复使用（「一次性」指只接受交换路径，不是单次消费） |
| dsh 重启/重建后 | **什么都不用做**（cookie 有效则继续用）；如需续期必须用重启后的新 token——旧 token URL 已失效（`./deploy.sh url` 取的是日志里最新一行） |
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