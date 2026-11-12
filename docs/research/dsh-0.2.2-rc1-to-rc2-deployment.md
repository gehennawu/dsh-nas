# DSH 0.2.2-rc.1 → 0.2.2-rc.2：dsh-nas 部署与启动专项调查

调查日期：2026-11-12（Asia/Shanghai；API 发布时刻保留 UTC）。范围仅限本项目镜像安装、入口、可信域名补丁、Web 启动与部署核验；不评述第三方插件功能。本文是调查记录，不是已完成容器升级的证明。

> 后续修订：调查之后，v1.7.6 已将镜像核验加固为逐 bundle 语法检查、同目录完整布局解析及严格注入识别，`--skip-build` 同样执行；下文关于 marker-only 核验的描述是修复前基线，不再代表当前部署脚本。HTTP 存活探针的边界不变。

## 结论摘要

1. **确认存在直接影响：浏览器 bundle 开始压缩排版。** `dsh-client-connection/lib/client.browser.js` 从 rc.1 的 1,523 行变为 rc.2 的 3 行，`isLoopbackHostname` 的语义及函数名未变。历史上在 `{` 后插入 `//` 行注释的补丁会吞掉 rc.2 同行的剩余代码，实际复现 `SyntaxError: Unexpected end of input`；rc.1 同样注入则语法通过。这不是“rc.1 已经单行”的既有问题。
2. **没有证据要求更换 Node 基础镜像、CLI 调用或 cookie overlay。** 主包 Node engines 两版均为 `>=24.9.0`；`lib/bin.js` 入口不变；`--patch` 必须先于 `--host` 的规则、`webStartup`、`connection.config.trustedHosts`、`cookieMaxAgeDays`、认证实现及 Web 启动源码均未变。
3. **其他确认变化：** npm 发布物新增源码/文档/source maps，安装体积增加；连接层 Zod 从 `4.4.3` 升到 `4.6.6`；主包直接依赖集合有增减；`$DSH_HOME/.env` 新允许精确大写的两个 DeepSeek endpoint 变量；profile 启动新增出站 User-Agent 后缀。这些不是入口参数不兼容。
4. **部署核验边界必须保留：** 本项目 marker/domain 检查不能证明 JS 可解析；HTTP 探针任意 HTTP 状态都成功，只证明监听进程响应，不证明浏览器脚本正常或认证可用。这是本地既有探针覆盖不足，被此次压缩变化放大，不是上游新增健康接口回归。

## 一手证据与方法

- GitHub 官方 release API：[rc.1](https://api.github.com/repos/deepseek-ai/deepseek-harness/releases/tags/dsh-v0.2.2-rc.1)、[rc.2](https://api.github.com/repos/deepseek-ai/deepseek-harness/releases/tags/dsh-v0.2.2-rc.2)。发布时刻分别为 `2026-11-04T13:07:14Z`、`2026-11-11T11:33:06Z`。
- [官方 compare API](https://api.github.com/repos/deepseek-ai/deepseek-harness/compare/dsh-v0.2.2-rc.1...dsh-v0.2.2-rc.2)、[compare diff](https://github.com/deepseek-ai/deepseek-harness/compare/dsh-v0.2.2-rc.1...dsh-v0.2.2-rc.2.diff)。API 返回 `total_commits=1568`、`files.length=300`，文件列表已到 GitHub 上限，**不能把其中没有某文件当作无变化证据**。另下载两 tag 完整源码 archive，以相同相对路径逐字节比对部署相关目录。
- tag 快照实际 commit：rc.1 `66491b05e3f05ad35bcdd4f6cd7ed26041d9e3db`；rc.2 `ddac96760b6edf8fa0fe17cbdcf0b512f4c12b2c`。archive 来源：[rc.1](https://api.github.com/repos/deepseek-ai/deepseek-harness/tarball/dsh-v0.2.2-rc.1)、[rc.2](https://api.github.com/repos/deepseek-ai/deepseek-harness/tarball/dsh-v0.2.2-rc.2)。
- npm 官方 registry 主包元数据：[rc.1](https://registry.npmjs.org/@deepseek-ai%2fdsh/0.2.2-rc.1)、[rc.2](https://registry.npmjs.org/@deepseek-ai%2fdsh/0.2.2-rc.2)；实际 tarball：[rc.1](https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-0.2.2-rc.1.tgz)、[rc.2](https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-0.2.2-rc.2.tgz)。还下载 connection、web-app、app-boot、launch-environment、bash-sandbox、terminal-bash、fs-local 的两版 tarball；下载字节均与对应 registry `dist.integrity` SHA-512 一致。
- 临时资料置于 `/tmp/dsh-release-research`，未运行包安装脚本、未修改系统安装、未启动或停止任何线上服务。release notes 只作定位，结论来自上述源码和发布实物。

## 1. engines、依赖、安装及 native 构建

### 未变化的安装契约

主包 npm 元数据中，两版均为：

```text
engines.node                    >=24.9.0
bin.dsh                         lib/bin.js
commander                       ^15.0.0
js-yaml                         ^4.3.2
@deepseek-ai/cordis              ~4.1.0
@deepseek-ai/schemastery         ~3.19.0
@deepseek-ai/cordis-plugin-loader ~1.1.0
@deepseek-ai/cordis-plugin-include ~1.1.0
node-addon-require-builtin      ^0.1.9
```

主包两版均没有会执行的 install/postinstall 生命周期脚本（rc.1 未提供 `scripts`，rc.2 为 `{}`）。来源为上述 npm 主包元数据；不是依据当前机器已安装的其他版本推断。

本项目 [Dockerfile](../../Dockerfile#L18-L33) 的 Node 26 完整 Bookworm 与编译工具链，从 engines 看无需为此次升级更换；[跨阶段拷贝与 bin 符号链接](../../Dockerfile#L51-L68) 的目标仍有效。**但 Dockerfile 默认仍锁定 `0.1.0-rc.8`，不能把“本项目当前默认版本”误写成 rc.1；本文比较的是指定的两个官方版本。**

Native 相关定向源码比较：

- [`node-addon-system` entry manifest](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/native/system/packages/entry/package.json) 两 tag 完全相同，版本 `0.1.2`，说明为 prebuilt Landlock/flock，含 Linux arm64/x64 optional 平台包，无 install/postinstall。
- [`sandbox-local` manifest](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/packages/sandbox/sandbox-local/package.json)、[`bash-sandbox` manifest](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/packages/shell/bash-sandbox/package.json) 的非 DSH 依赖、optionalDependencies、engines、生命周期脚本未改变。
- [`subprocess-local` manifest](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/packages/subprocess/subprocess-local/package.json) 继续依赖 `koffi=3.1.1`、`node-pty=1.2.0-beta.15`，`postinstall` 仍是 `node scripts/ensure-spawn-helper.mjs`；[该脚本](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/packages/subprocess/subprocess-local/scripts/ensure-spawn-helper.mjs) 两 tag 字节相同，只恢复现有 spawn-helper 的可执行位。
- [`fs-local` npm 元数据 rc.1](https://registry.npmjs.org/@deepseek-ai%2fdsh-fs-local/0.2.2-rc.1) / [rc.2](https://registry.npmjs.org/@deepseek-ai%2fdsh-fs-local/0.2.2-rc.2) 的 `koffi=3.1.1`、`chokidar=5.0.0` 未变。

因此没有发现**这些核实的安装/native 路径**新增必须 apt 安装的组件；不能由此宣称所有传递依赖、所有 NAS 架构无需编译。尤其不能仅依据本地旧注释“Landlock 一定 node-gyp”来概括官方 rc.1/rc.2 的现状，也不据此建议本次删除编译工具链或改用 slim。

### 确认有变化

- connection npm 依赖 `zod: 4.4.3 → 4.6.6`，见 [rc.1 元数据](https://registry.npmjs.org/@deepseek-ai%2fdsh-client-connection/0.2.2-rc.1) / [rc.2 元数据](https://registry.npmjs.org/@deepseek-ai%2fdsh-client-connection/0.2.2-rc.2)。没有发现由此要求修改 `trustedHosts` / cookie overlay 的源码证据。
- 主包直接依赖新增 `@deepseek-ai/dsh-cua-bundle`，移除 `@deepseek-ai/dsh-experimental-agent-team-profile`；内部 DSH 包版本整体随发布升级。这里只记录 npm 安装图变化，不讨论这些组件功能。来源：两版主包 registry `dependencies` 实际对象，不是 release notes。
- 官方扩大 npm 发布内容。主包 `dist.fileCount: 20 → 532`，`dist.unpackedSize: 76,416 → 6,215,049` bytes；下载 tgz 为 `25,197 → 2,197,456` bytes。实际 rc.2 tar 包含 `docs/`、`src/`、声明 maps 等，`lib/bin.js` 仍在。connection 等包也加入 `src`、JS maps、声明 maps，见 [manifest rc.1](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.1/packages/client/connection/package.json) / [rc.2](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/packages/client/connection/package.json)。影响是下载/镜像内容增加，而非改了全局安装根或可执行入口。

## 2. client-connection bundle 布局与可信域名补丁（直接风险）

官方 tarball：[rc.1](https://registry.npmjs.org/@deepseek-ai/dsh-client-connection/-/dsh-client-connection-0.2.2-rc.1.tgz)、[rc.2](https://registry.npmjs.org/@deepseek-ai/dsh-client-connection/-/dsh-client-connection-0.2.2-rc.2.tgz)。实际比对：

| 文件 | rc.1 bytes / 行数 | rc.2 bytes / 行数 | 结论 |
|---|---:|---:|---|
| `lib/client.browser.js` | 60,601 / 1,523 | 43,991 / 3 | 浏览器 bundle 排版压缩 |
| `lib/client.node.js` | 23,247 / 624 | 23,247 / 624 | SHA-256 完全相同 |
| `lib/index.js` | 44,434 / 1,072 | 44,434 / 1,072 | SHA-256 完全相同 |

三个目标在两版中各有且仅有一个匹配 `function isLoopbackHostname(hostname)\s*\{` 的声明。函数均接受 `localhost`、`[::1]`、合法 `127.*.*.*`；未新增公开域名默认放行，**可信域名扩展仍是本项目自行承担的补丁策略**。源码 [connection/src](https://github.com/deepseek-ai/deepseek-harness/tree/dsh-v0.2.2-rc.2/packages/client/connection/src) 18 个 TS 文件两 tag 全部字节相同；变化来自统一构建器 [`packages/client/tsdown.client.ts`](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/packages/client/tsdown.client.ts#L800-L812) 新增：

```ts
minify: { compress: false, mangle: false }
```

这压缩文本但保留标识符，不是把函数改名。Node 侧保持未压缩。可在完整 [compare diff](https://github.com/deepseek-ai/deepseek-harness/compare/dsh-v0.2.2-rc.1...dsh-v0.2.2-rc.2.diff) 搜索上述配置复核。

### 实物复现与当前工作树兼容验证

在临时副本中、使用 Node `v26.13.1`：

1. 从两版正式 tgz 各复制上述三个文件到独立临时目录；只将当前 [patch 脚本](../../patch-trusted-domain.mjs#L33-L103) 的两个安装路径候选重定位到临时目录，其他代码原样执行。
2. 以测试 hostname `nas.example.test` 运行补丁：rc.1、rc.2 均退出 0；对三份 patched bundle 分别运行 `node --check`，共六项全部退出 0。
3. 另模拟历史注入 `if (...) return true; // dsh-nas: trusted-domain patch`（无追加换行）：rc.1 browser 退出 0；rc.2 browser 退出 1，`SyntaxError: Unexpected end of input`。仅做解析，不执行 bundle。

当前工作树 [补丁注入](../../patch-trusted-domain.mjs#L65-L103) 已采用块注释并补换行，且三文件全量预读、唯一匹配验证、写前 ESM 语法检查，因此**本次读取到的版本已避开该实物复现故障**。这一修改在本调查开始前已存在于工作树，不是本文改动，也不等同于线上镜像已包含它。

安装后的 nested / hoisted 两个候选路径是本地补丁的兼容策略，tarball 的 `package/lib` 布局不能证明 npm 全局安装一定采用哪一个。实际 npm hoist 结果本次未安装验证。

## 3. CLI、Web 启动、配置与认证：核实未变化的接口

完整 tag 对照中，[`apps/cli/src/args.ts`](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/apps/cli/src/args.ts)、[`bin.ts`](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/apps/cli/src/bin.ts) 完全相同；[`web-app/src/startup.ts`](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/packages/bundle/web-app/src/startup.ts)、[`web-app/src/index.ts`](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/packages/bundle/web-app/src/index.ts) 也完全相同。

据此确认：

- `dsh web` / `--profile web`、launcher `--patch` / `--dump-config`、app `--host` / `--port` / `--trusted-host` / `--public-url` 等部署参数没有在这次比较中改变。
- launcher 从首个不识别 token 起将剩余参数透传给 app，故 [entrypoint 参数顺序](../../entrypoint.sh#L99-L114) 仍应为 `dsh web --patch ... --host 127.0.0.1 ...`，不能把 overlay 选项移到 `--host` 后面。
- [`web-app/cordis.patch.yml` connection 行](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/packages/bundle/web-app/cordis.patch.yml#L236-L245) 两版仍是 `inject: [webStartup]`、`trustedHosts: !!js ctx.webStartup.trustedHosts`。`web-startup`、`webserver`、`web-runtime` 的部署结构没有因 rc.2 改名；该文件其他组合内容有变化，不能说整个文件未变。
- [`connection/src/index.ts`](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/packages/client/connection/src/index.ts#L95-L139) 的 `cookieMaxAgeDays` schema/default 仍为正整数、默认 30 天；`trustedHosts` 仍默认空数组，并验证 authority。认证、Host/Origin 栅栏、token/cookie 实现所在 connection 源码没有变化，Node Host bundle 也字节一致。
- [entrypoint cookie overlay](../../entrypoint.sh#L59-L105) 继续重述 `trustedHosts` 并设置 `cookieMaxAgeDays`；`ctx.get('webStartup')?.trustedHosts ?? ctx.get('webRuntime')?.trustedHosts ?? []` 在两版都首先取得 `webStartup`，没有 rc.2 迁移服务名的证据。现有 `--dump-config --patch` 探测只验证 launcher/profile composition 路径，不等于启动所有服务、验证认证或浏览器功能。
- 绑定 `127.0.0.1`、端口 3080、反代仍应保留现有安全边界；没有依据为了升级而改绑 `0.0.0.0` 或取消认证。
- 启动 URL 日志仍为 `dsh web: ${authenticatedUrl}`（[runtime 源码](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/packages/bundle/web-app/src/index.ts#L218-L234)），[认证 URL 生成](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/packages/client/connection/src/browser-auth.ts#L244-L247) 仍向 URL 设置 token query；相关源码两版字节相同。因此 [deploy token 提取](../../deploy.sh#L81-L84) 所依赖的 `dsh web:` / `?token=` 格式没有新增不兼容；这里验证的是当前无额外 query 的默认启动 URL，未覆盖任意自定义 public URL 的既有解析边界。

### 有变化但不要求修改 NAS 启动参数

- [`installed-bin.ts`](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/apps/cli/src/installed-bin.ts) 新增 Windows 8.3 路径 canonicalization，并动态导入实际 CLI。Linux 分支保留 `import.meta.url`，npm `bin` 仍为 `lib/bin.js`；不能把内部新增 chunk 文件当作 NAS bin 路径失效。
- [`profile-boot.ts`](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/apps/cli/src/profile-boot.ts) 新增编码后的 `DSH_USER_AGENT_SUFFIX=dsh-profile/<profile>`（Web 为 `dsh-profile/web`），影响出站请求标识，不增加入口必填参数。

## 4. 启动环境与 `.env` 的实际差异

[`app-boot/src/index.ts`](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/packages/boot/app-boot/src/index.ts) 新增 `HOME_LAYER_ENDPOINT_NAMES`，允许 `$DSH_HOME/.env` 中精确大写的 `DEEPSEEK_BASE_URL` 和 `DEEPSEEK_SEARCH_BASE_URL`。继承的进程环境仍优先。调用目录的 `.env` 仍拒绝这两个 endpoint；`DSH_*`、`XDG_*`、PATH、CA/TLS 等启动敏感变量的限制仍在。代理四变量仅允许从 Harness-home `.env` 提供的规则未变。[官方 app-boot 说明](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/packages/boot/app-boot/README.md) 与源码相符。

对本项目而言：[Compose](../../docker-compose.yml#L37-L53) 读取项目 `.env` 是宿主插值，把 `DSH_PROXY` 映射为容器继承的 `HTTP_PROXY/HTTPS_PROXY`；这不等同于 DSH 在 `/workspace/.env` 加载文件。现有 [entrypoint](../../entrypoint.sh#L20-L36) 代理继承方式无需因为上述 endpoint 放宽而修改。如果用户另外在挂载工作区内放入 `.env`，需要独立遵守 DSH 的项目环境限制；不能把旧有限制误说成 rc.2 新增拒绝。

两版官方 `dsh-launch-environment/lib/index.js` 字节一致（[rc.1 元数据](https://registry.npmjs.org/@deepseek-ai%2fdsh-launch-environment/0.2.2-rc.1) / [rc.2](https://registry.npmjs.org/@deepseek-ai%2fdsh-launch-environment/0.2.2-rc.2)）。出站代理实现新增可选 HTTP/2/route dispatcher 能力，但没有证据显示现有缺省环境代理策略改变；本调查不据此要求移除 `NODE_USE_ENV_PROXY` 或重新定义代理变量。

## 5. 版本输出、构建核验与健康探针

### 版本

[`args.ts`](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/apps/cli/src/args.ts#L146-L155) 两版仍通过 commander `.version(version, '-V, --version', ...)` 输出版本；[`bin.ts`](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.2/apps/cli/src/bin.ts) 版本读取逻辑未变。**没有发现新增版本前缀/输出格式变更**。本项目 [verify_dsh_image](../../deploy.sh#L977-L1023) 实际读安装主包的 `package.json.version`，不是解析 `dsh --version` stdout，所以内部 CLI chunk 的变化不影响该版本比较。

边界：未安装全部依赖，未执行真实完整安装树的 `dsh --version`，以上输出契约结论来自相同源码与两版 npm 主包 version 字段，不冒充端到端 CLI 实测。

### 探针

- [本地镜像核验](../../deploy.sh#L994-L1023) 检查 bundle 是否有 marker 和 JSON 编码域名；即使旧 `//` 补丁吞码，这两者仍可能存在，导致误报成功。尤其 `--skip-build` 会跳过当前补丁的构建阶段语法保护，仍可能接受带 marker 的旧坏镜像。建议后续另加目标 bundle 语法检查；这是本地既有核验缺口，本文不修改部署脚本。
- [Compose 健康检查](../../docker-compose.yml#L56-L63) 只执行 `fetch('http://127.0.0.1:3080')`，200/401/403/500 等有 HTTP 响应都算成功。rc.1、rc.2 相同的认证逻辑意味着 401 并不自动代表进程未就绪；但健康状态绝不证明 browser bundle、WebSocket、token→cookie 或特权 RPC 可用。
- [`packages/host/webserver/src`](https://github.com/deepseek-ai/deepseek-harness/tree/dsh-v0.2.2-rc.2/packages/host/webserver/src) 两个 TS 文件与两版 web-app runtime / connection 认证源码未变；在所查部署链路未发现 rc.2 新增必须迁移到的专用健康接口。

## 验证范围与剩余边界

**已完成：** GitHub API/完整 compare diff/完整 tag archive 定向比对；上述官方 npm 产物下载和 integrity 校验；发布物文件清单、字节及函数匹配检查；两版各三个真实 connection bundle 的当前补丁应用及语法校验；历史行注释在 rc.2 的纯解析失败复现。仅创建本研究文件，未修改部署配置或脚本。

**明确未验证：** 全量 npm 依赖解析及 global hoist、npm 生命周期脚本执行、所有可选 native 平台产物、Linux arm64/x64 NAS 的实际编译与内核 Landlock 行为、Docker 多阶段构建、重建镜像最终大小、容器启动、持久化 profile 升级、Caddy/Authelia 反代、浏览器实际加载及 token/cookie/RPC 回归。未运行线上服务，未更改系统。故“无需改某接口”仅指已核实契约没有变化，**不是保证任意现存 NAS 安装直接升级成功**。
