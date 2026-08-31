# DSH v0.1.2-alpha.2 对 dsh-nas 的影响评估

> 调研对象：本仓库 `dsh-nas` Linux NAS Docker 部署模板（下文将它称为“本插件/本项目”）。
>
> 评估版本：`@deepseek-ai/dsh@0.1.2-alpha.2`，Git tag `dsh-v0.1.2-alpha.2`，tag commit [`0a53fb55`](https://github.com/deepseek-ai/deepseek-harness/commit/0a53fb55bea101816fa226bb964ae2bed71c343b)。
>
> 资料来源：DSH 官方 GitHub Release、官方仓库源码/差异、npm 官方 registry；未以社区文章作为结论依据。

## 结论摘要

**结论：alpha.2 对本项目是“有条件兼容”，不是需要立即重写 Caddy/认证链路的破坏性升级；版本选择已增加专用 `--alpha` 通道，但预览版仍需备份和验收。**

最重要的事实有三条：

1. `0.1.2-alpha.2` 已经发布到 npm，但当前 npm `latest` 和 `next` 仍是 `0.1.1-rc.2`，alpha.2 位于 `alpha` dist-tag。官方 registry 元数据可见 [`@deepseek-ai/dsh` package metadata](https://registry.npmjs.org/@deepseek-ai/dsh) 和 [`@deepseek-ai/dsh@0.1.2-alpha.2`](https://registry.npmjs.org/@deepseek-ai/dsh/0.1.2-alpha.2)。
2. 本项目当前 `Dockerfile` 锁定的是 `0.1.0-rc.8`；`deploy.sh` 的 `--latest` 只取正式版，新增的 `--alpha` 专门读取 npm `alpha` dist-tag。因此，**现在执行 `sudo ./deploy.sh --latest` 仍不会安装 alpha.2**，而 `sudo ./deploy.sh --alpha` 会按 alpha 通道升级。
3. alpha.2 保留了本项目依赖的浏览器 token 认证、`cookieMaxAgeDays`、`trustedHosts`、`dsh web --host` 和 `dsh-client-connection` 两个 bundle 的基本结构；本仓库的 Caddy Host/Origin 回写、健康检查、trusted-domain patch 设计原则仍然成立。但升级仍应先备份 `data/dsh`，因为官方 session 格式仍标为 `0`，明确“不承诺兼容、不提供迁移”。

建议使用专用的 `--alpha` 升级通道，不要用 `--latest` 代替 alpha.2 升级。脚本会查询 npm `alpha` dist-tag，并在升级快照后原子写入目标版本，再走现有事务升级流程。

## 本项目当前基线

| 位置 | 当前行为 | 对 alpha.2 的判断 |
|---|---|---|
| `Dockerfile:20` | `ARG DSH_VERSION=0.1.0-rc.8` | 可被改成 alpha.2；当前默认不会自动升级 |
| `Dockerfile:38` | 容器固定安装 `pnpm@11.20.0` | 高于 alpha.2 根 manifest 声明的 pnpm 11.7.0；通常不构成阻塞，但插件解析异常时应优先核对版本 |
| `deploy.sh:613-696` | 查询并展示 npm `latest`、`next`、`alpha`；`--alpha` 直接选择 alpha 通道 | 可明确升级预览版 |
| `deploy.sh:1880-1907` | `--latest` 写入 npm `latest`，`--alpha` 写入 npm `alpha` | 两个通道语义明确，不能同时使用 |
| `patch-trusted-domain.mjs:32-35` | patch `dsh-client-connection/lib/client.js` 与 `lib/index.js` | alpha.2 npm 包仍提供这两个文件，结构检查通过；预计兼容，但构建时必须继续实测 |
| `entrypoint.sh:59-86` | 通过 `--patch` overlay 设置 `cookieMaxAgeDays`，启动 `dsh web --host 127.0.0.1` | alpha.2 的 Connection schema 仍有 `cookieMaxAgeDays`；设计继续适用 |
| `docker-compose.yml:57-59` | dsh 健康检查接受任意 HTTP 响应 | 继续正确；未认证根请求返回 401 不应判 unhealthy |
| `caddy/Caddyfile:50-53` 等 | 反代到 `127.0.0.1:3080`，回写 Host/Origin 为 loopback | 与 alpha.2 Host/Origin trust fence 相容；无需因 alpha.2 改 Caddy |
| `data/dsh` | 持久化凭据、会话、preset 等 | 升级前应额外快照；现有升级回滚不覆盖运行数据 |

## 官方 alpha.2 变更与影响

### 1. Web Connection 自动恢复、立即重连

Release 新增“连接异常状态、自动重试和立即重连”。官方 [`Web connection recovery control` 设计记录](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.1.2-alpha.2/.agents/notes/implemented/feature/2026-08-28-web-connection-recovery-control.zh.md)说明：重试由 `ConnectionController` 统一调度，浏览器 offline/online 事件、手动 `ctx.connection.reconnect()` 和 `$events` ready frame 都参与连接状态机；Gateway mux 不再额外维护一套重试计时器。

alpha.2 的官方 [`dsh-client-connection` README](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.2-alpha.2/packages/client/connection/README.zh.md)还明确了：

- HTTP RPC 和 `/api/remote.mux` WebSocket 都经过同一个浏览器认证和 Host/Origin trust fence；
- `500ms、1s、2s、4s、8s、10s` 退避并带抖动，成功由 ready frame 证明；
- 用户手动重连会立即开始新尝试；
- 当前 logical stream 在物理连接代际断开时结束，重连后按原有 baseline/cursor/replay 语义恢复。

**对本项目的影响：**

- **不需要新增 Caddy 指令。** Caddy `reverse_proxy` 默认支持 WebSocket，现有文档已经要求前置反代开启 WebSocket；如果跨机 Lucky/其他前置层剥掉 Upgrade，alpha.2 只会表现为连接失败/重试，不能解决前置代理配置问题。
- 这是本项目最应该做的升级后冒烟测试：通过外部 HTTPS 域名登录，确认会话加载；临时断开前置代理或 dsh，再恢复，确认页面出现连接状态并可自动/手动恢复。
- 未认证根请求仍是 401，不能把“连接异常 UI”与浏览器 token 认证混为一谈。

相关官方提交：[`ccfbbb4`](https://github.com/deepseek-ai/deepseek-harness/commit/ccfbbb4)、[`e14d354`](https://github.com/deepseek-ai/deepseek-harness/commit/e14d354)、[`e036aae`](https://github.com/deepseek-ai/deepseek-harness/commit/e036aae)。这些提交支持“当前配置大概率兼容”的工程判断，但不是针对本项目 Caddy 拓扑的官方 ABI 承诺。

### 2. 会话标题显示活动定时计划

Release 新增会话标题区域查看活动定时计划，功能提交为 [`2a9b940e`](https://github.com/deepseek-ai/deepseek-harness/commit/2a9b940ef578ba1bda91d81547895e531788ae3a)。alpha.2 的差异还说明，`ui-schedule` 是 Web bundle 中默认关闭、通过显式 overlay 才启用的能力；默认 Web 启动图并不会因为升级自动激活 Schedule runtime。

**对本项目的影响：**

- 本仓库没有 Schedule overlay 或自定义 `cordis.yml`，因此默认部署不会多出新的守护进程、端口或宿主定时任务。
- 如果用户在 profile/preset 中显式启用了 `@deepseek-ai/dsh-schedule`、`@deepseek-ai/dsh-time-context` 和 `ui-schedule`，升级后应验证活动计划展示、重启后的计划恢复及会话标题 Remote 调用。
- 本项目现有 `network_mode: host` 不会与该 UI 功能产生新的端口冲突。

### 3. 插件清单、全局/会话插件分组与 Agent Preset 切换

Release 新增：插件按会话/全局分组、Agent Preset 切换和跨预设搜索。官方 [`agent-presets README`](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.2-alpha.2/packages/preset/agent-presets/README.zh.md)确认 alpha.2 的 preset 模型包括：

- 每个会话从一个 preset 组装工具、提示词和 skill；
- preset 可来自随包目录、配置根目录和 `$DSH_HOME/.agent-presets`；
- preset 选择在会话尚未产生内容时才允许切换；
- 会话 header 和 `agent-preset/selected` 事件记录实际使用的 preset；
- broken preset 会被列出并带原因，而不是静默隐藏。

本项目将 `DSH_HOME` 固定为 `/home/node/.dsh`，并将 `./data/dsh` 持久化挂载到该目录，因此用户 preset 若放在 `data/dsh/.agent-presets`，理论上会随容器重建保留。`HOME=/workspace` 不应误解为 DSH preset 根目录；DSH 使用的是显式 `DSH_HOME`。

**对本项目的影响：**

- **正向兼容：** 容器持久化卷覆盖了 preset/配置的预期存储位置，升级不会因镜像重建丢失该目录。
- **需要测试：** alpha.2 的清单会显示更多全局/会话/preset 信息；应检查自定义 preset 是否能发现、切换和恢复，且 `data/dsh` 的属主仍为 UID 1000。
- **安全边界不变：** preset 的权限等于其引用插件的权限；不能因为 UI 能搜索/切换 preset 就放宽 Authelia、Caddy 或容器权限。
- **不要把 preset 文件当作普通运行时配置自动改写。** 官方说明 preset 文件是输入，挂载后的 loader 写回被抑制；应通过 DSH 的 preset 创作/删除路径管理。

相关官方提交：[`e5f36cc`](https://github.com/deepseek-ai/deepseek-harness/commit/e5f36cc)、[`8349cc6`](https://github.com/deepseek-ai/deepseek-harness/commit/8349cc6)。

### 4. Remote 网关统一 `RemoteError`

alpha.2 将 Remote 调用的失败统一为 `RemoteError`，使用域前缀 code 和结构化 details；Gateway 自身使用 `gateway/*` 错误码，resolver 可保留如 `session/not-found`、`session/agent-busy` 等领域错误。官方 [`adding-a-remote-api` cookbook](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.2-alpha.2/docs/cookbook/adding-a-remote-api.zh.md)规定：Client 侧应按 `error.code` 分支，而不是依赖 `instanceof`；Remote 端点应通过 `@Remote` 和生成的 codec 接入。

**对本项目的影响：**

- `dsh-nas` 本身没有 TypeScript Remote owner、Client plugin 或自定义 Gateway 代码，因此**没有直接源码迁移工作**。
- 这是对 profile 中第三方插件的**条件影响**：如果插件直接使用 DSH 内部旧 API Proxy、手写 RPC response、或依赖旧异常类/`instanceof`，需按 alpha.2 的 Remote 契约重新构建和验证。不能仅凭插件能被 pnpm 安装就认为运行时兼容。
- 如果插件只通过公开工具、标准 `ctx.remote` 和官方包入口工作，风险较低；仍建议对每个已安装插件执行一次加载、Remote 调用和错误路径测试。

相关官方提交：[`804b1ff`](https://github.com/deepseek-ai/deepseek-harness/commit/804b1ff)、[`674a1e9`](https://github.com/deepseek-ai/deepseek-harness/commit/674a1e9)、[`9135a13`](https://github.com/deepseek-ai/deepseek-harness/commit/9135a13)。这些是插件 API 兼容性需要重点关注的内部实现证据，不应解读为“所有历史插件均保证兼容”。

### 5. `SessionEvent.ignorable` 恢复与会话日志风险

Release 明确恢复了 alpha.1 移除的 `SessionEvent.ignorable`。alpha.2 官方 [`packages/core/session/src/types.ts`](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.2-alpha.2/packages/core/session/src/types.ts)同时明确：

- `SESSION_FORMAT_VERSION = 0`；
- 未发布阶段不承诺兼容；
- 不兼容日志会被拒绝，当前没有迁移；
- 未知事件只有明确带 `ignorable: true` 才能被读取端安全忽略。

alpha.2 的官方 release 及其差异范围为 [`alpha.1 → alpha.2 compare`](https://github.com/deepseek-ai/deepseek-harness/compare/dsh-v0.1.2-alpha.1...dsh-v0.1.2-alpha.2)。差异并不只是 UI：还包含 session projection/cache、SQLite 物理存储、Remote、preset 和 schedule 等大量内部重构。

**对本项目的影响：**

- 现有升级回滚会保存旧镜像、配置和 `.env`，但**不会回滚 `data/dsh` 中升级后新写入的会话数据**。因此在从 `0.1.0-rc.8` 或其他旧版本直接跨到 alpha.2 前，必须由运维者另做 `data/dsh` 快照。
- 不应继续在文档中写“数据不会因重建丢失”并将其等同于“所有旧会话语义保证可恢复”。前者是 Docker 卷事实，后者不是 alpha.2 官方承诺。
- 升级后的验收至少包括：旧会话列表、打开旧会话、加载历史、继续对话、fork/subagent（如启用）、新建会话和重启后再次打开。
- 如果旧会话无法恢复，应优先保留原快照并回滚镜像；不要在没有副本的情况下让新版本继续改写同一份 session store。

### 6. Node.js 运行时、NPM peer dependency 与 HMR

alpha.2 根 manifest 的官方约束是 `node: ^22.19.0 || >=24.0.0`，package manager 为 pnpm 11.7.0；官方 [`package.json`](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.2-alpha.2/package.json)和 [`apps/cli/package.json`](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.2-alpha.2/apps/cli/package.json)可核对。Release 还说明修复了 Node.js 24.0–24.11.1 的启动失败与 HMR 失效，并优化了 npm peer dependency。

本项目当前使用 `node:22-bookworm`，而不是 Node 24；alpha.2 的 Node 24/HMR 修复对生产镜像不是直接收益，但有两个注意点：

- `node:22-bookworm` 是浮动 tag，构建时应确认实际版本至少满足 alpha.2 的 `^22.19.0`；同时本项目代理方案依赖 `NODE_USE_ENV_PROXY=1`，注释要求 Node 22 至少达到 22.21。
- alpha.2 的 peer dependency 变化主要影响 DSH 包和外部插件的解析，不改变 Docker host 网络、UID 1000 或容器权限模型；插件若锁定旧的 `@deepseek-ai/*` 精确版本，仍可能在 profile 安装/加载时出现依赖冲突。

## 本项目现存的升级阻塞点

### 版本通道：`--latest` 与 `--alpha` 语义分离

当前脚本查询 `latest`、`next`、`alpha`；官方 npm metadata 当前为：

```text
latest = 0.1.1-rc.2
next   = 0.1.1-rc.2
alpha  = 0.1.2-alpha.2
```

因此：

- `sudo ./deploy.sh --latest`：仍然得到 npm `latest` 正式版，不保证是 alpha.2；
- 普通 `sudo ./deploy.sh --upgrade`：交互列表现在包含 alpha 预览版；
- `sudo ./deploy.sh --alpha`：直接读取 npm `alpha` dist-tag，明确安装当前 alpha 版本。

`--latest` 与 `--alpha` 不能同时使用，也不能与 `--skip-build` 同时使用；两个参数都会隐含 `--upgrade`，并保留现有事务快照、失败回滚和构建后镜像核验。

### 文档与通道说明

README 与 UPGRADE 已同步说明：alpha 版本通过 `--alpha` 获取，正式版通过 `--latest` 获取；`--latest` 不会因为 alpha 发布而自动切换到预览版本。

### 阻塞点 C：当前 patch 是按内部 bundle 文本结构实现的

本项目的 `patch-trusted-domain.mjs` 不是稳定公开 API，而是针对两个已安装 bundle 的源码文本做结构校验和插入。我们核对了 alpha.2 的官方 `@deepseek-ai/dsh-client-connection@0.1.2-alpha.2` npm 包：它仍包含 `lib/client.js`、`lib/index.js`，且两处仍可找到 `isLoopbackHostname`；因此当前 patch **预计**可用。

不过它仍属于内部结构 patch，不能只依赖推断。现有 `verify_dsh_image()` 已经会在构建后验证版本号、两个 bundle 的 marker/domain 和入口脚本权限，应继续把它作为硬门槛；若 alpha.2 后续改变 bundle，宁可构建失败，不要静默跳过 patch。

## 推荐升级与验收顺序

### 升级前

1. 先运行 `sudo ./deploy.sh update-script`，确认脚本和文档为最新仓库版本。
2. 单独快照：
   - `data/dsh/`，尤其是 `.credentials.yaml`、session store、`.agent-presets`；
   - 如自定义 profile/plugin 在 `data/dsh/profiles` 下，也一并快照；
   - 当前 `dsh:local` 镜像和 Docker 容器 inspect 信息。
3. 使用 `sudo ./deploy.sh --alpha` 获取 npm `alpha` 通道的当前版本；不要执行 `--latest` 期待得到 alpha.2。
4. 确认构建实际 Node 版本满足 `^22.19.0`，并且 Node 代理功能满足项目所需的 22.21+ 条件。

### 升级后

按以下顺序验收，任何一项失败都不要删除旧数据快照：

1. `docker compose ps`：dsh、Authelia、Caddy 健康状态正常；dsh 根请求未带 cookie 返回 401 属预期。
2. `sudo ./deploy.sh url`：取得新进程 token URL；通过公网 HTTPS 域名打开一次，确认 token 交换、cookie 签发和 Authelia 认证均正常。
3. 确认 dsh 仍只监听 `127.0.0.1:3080`，Caddy 入口仍只暴露预期 listener。
4. 登录后打开一个旧会话并继续对话；重启 dsh 后再次打开；检查新建会话。
5. 在前置代理链路下验证 WebSocket/Remote：断开再恢复网络或 dsh，观察自动重试和“立即重连”。
6. 检查插件清单的会话/全局分组；若使用自定义 Agent Preset，验证发现、切换、恢复和 broken preset 报错。
7. 若使用 schedule 或第三方插件，分别验证定时计划 UI、Remote 调用和错误路径。
8. 最后才清理 dangling image；保留 `data/dsh` 升级前快照至少一个回滚周期。

## 最终判定

| 范围 | 判定 | 动作 |
|---|---|---|
| Docker host 网络、UID 1000、Caddy/Authelia 拓扑 | 兼容 | 不需要因 alpha.2 改架构 |
| 浏览器 token/cookie、`cookieMaxAgeDays` overlay | 兼容 | 保留现有 entrypoint 与健康检查；做一次实际 token 验收 |
| trusted-domain patch | 条件兼容 | alpha.2 bundle 结构仍匹配；保留构建后硬核验 |
| WebSocket/Remote 连接 | 条件兼容 | 检查前置代理 Upgrade，并做断线恢复测试 |
| preset/plugin inventory | 低风险但需验收 | 检查 `data/dsh/.agent-presets` 与第三方插件 |
| RemoteError / 旧 API 使用方 | 条件兼容 | 重新构建并测试外部插件；不要依赖旧异常 ABI |
| 已有 session 数据 | 未承诺兼容 | 升级前独立快照，验收失败时从旧镜像和快照恢复 |
| `deploy.sh --latest` / `--alpha` | 语义分离 | `--latest` 取正式版，`--alpha` 取 alpha 预览版；升级前仍需备份并验收 |

**一句话建议：**本项目的部署安全边界可以承载 alpha.2，现可使用 `--alpha` 明确跟随 npm alpha 通道；预览版仍不应跳过 `data/dsh` 快照和升级后验收。

## 参考资料

- [v0.1.2-alpha.2 官方 Release](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.1.2-alpha.2)
- [Release API JSON（含完整正文、tag commit 与发布时间）](https://api.github.com/repos/deepseek-ai/deepseek-harness/releases/tags/dsh-v0.1.2-alpha.2)
- [alpha.1 → alpha.2 官方差异](https://github.com/deepseek-ai/deepseek-harness/compare/dsh-v0.1.2-alpha.1...dsh-v0.1.2-alpha.2)
- [alpha.2 官方 package.json](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.2-alpha.2/package.json)
- [alpha.2 `@deepseek-ai/dsh` npm metadata](https://registry.npmjs.org/@deepseek-ai/dsh/0.1.2-alpha.2)
- [alpha.2 `dsh-client-connection` package manifest](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.2-alpha.2/packages/client/connection/package.json)
- [alpha.2 Connection README](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.2-alpha.2/packages/client/connection/README.zh.md)
- [alpha.2 Agent Presets README](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.2-alpha.2/packages/preset/agent-presets/README.zh.md)
- [alpha.2 Remote API cookbook](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.2-alpha.2/docs/cookbook/adding-a-remote-api.zh.md)
- [alpha.2 Session 类型与日志版本](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.2-alpha.2/packages/core/session/src/types.ts)
