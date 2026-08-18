// Host half of @dsh-nas/restart-dsh
// 「服务控制」：
//  1) 重启能力：向容器 PID 1 发送 SIGTERM（tini 转发，容器 restart 策略自动拉起）。
//  2) 升级能力（/dsh-upgrade RPC，authority loopback）：
//     - latest：查 npm registry 的 @deepseek-ai/dsh latest 版本
//     - status：读当前版本（挂载的 Dockerfile）+ 升级进度（data/upgrade-run.*）
//     - start ：启动一次性升级容器 dsh-upgrader（复用本地 dsh:local 镜像，
//       root + host 网络，挂 docker.sock；宿主项目目录按原宿主路径挂载，
//       AutoRemove）。容器内把新版本写进 Dockerfile 的 ARG DSH_VERSION 与
//       docker-compose.yml 的 build arg（sed 后恢复原属主），并在 deploy.sh
//       前后把 data/dsh 属主修正为 1000:1000，然后完整执行一次 deploy.sh：
//       配置已就绪时 deploy.sh 自动跳过向导（Caddy/Authelia 配置不受影响），
//       只重建 dsh 镜像；构建失败时 up -d 不执行，现有服务保持运行。
//       进度落在宿主项目目录 data/upgrade-run.{log,exit}，本插件只读展示。
import { readFileSync, accessSync, constants } from 'node:fs'
import { request as httpRequest } from 'node:http'
import { dirname } from 'node:path'

const name = 'restart-dsh'

// 服务依赖：插件进入等待，connection/shell 物化后才激活（官方 api-gateway 同款）
const inject = ['connection', 'shell']

// compose 固定挂载点（见 docker-compose.yml 的 dsh 服务）
// Dockerfile 与 docker-compose.yml 为只读窄挂载，data 为只读目录挂载；
// 升级容器通过 Docker API 解析这些挂载对应的宿主项目根目录。
const MOUNT_DIR = '/opt/dsh-nas'
const DOCKER_SOCK = '/var/run/docker.sock'
const DATA_DIR = MOUNT_DIR + '/data'
const FILES = {
  dockerfile: MOUNT_DIR + '/Dockerfile',
  compose: MOUNT_DIR + '/docker-compose.yml',
  log: DATA_DIR + '/upgrade-run.log',
  exit: DATA_DIR + '/upgrade-run.exit',
  target: DATA_DIR + '/upgrade-version.txt',
}
const HELPER_NAME = 'dsh-upgrader'
const HELPER_IMAGE = 'dsh:local'
const DOCKER_API_VERSION = 'v1.43'
const NPM_LATEST_URL = 'https://registry.npmjs.org/@deepseek-ai%2Fdsh/latest'
// npm 版本号白名单：x.y.z / x.y.z-rc.n；同时是升级入参的注入防线
const VERSION_RE = /^\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?$/

// ---------- 小工具 ----------
function readTextTail(path, tailBytes) {
  const buf = readFileSync(path)
  const start = buf.length > tailBytes ? buf.length - tailBytes : 0
  return buf.subarray(start).toString('utf8')
}
function tryRead(path, tailBytes) {
  try {
    return { ok: true, text: readTextTail(path, tailBytes) }
  } catch (err) {
    return { ok: false, code: err && err.code ? err.code : 'ERR' }
  }
}
function fileExists(path) {
  try { accessSync(path); return true } catch { return false }
}
function sockWritable() {
  try { accessSync(DOCKER_SOCK, constants.W_OK); return true } catch { return false }
}
function currentVersion() {
  const r = tryRead(FILES.dockerfile, 64 * 1024)
  if (!r.ok) return null
  const m = r.text.match(/^ARG[ \t]+DSH_VERSION=([^\r\n\s]+)/m)
  return m ? m[1] : null
}

// ---------- Docker Engine API（unix socket 直连） ----------
function docker(method, apiPath, body) {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? null : JSON.stringify(body)
    const headers = {}
    if (payload !== null) {
      headers['Content-Type'] = 'application/json'
      headers['Content-Length'] = Buffer.byteLength(payload)
    }
    const req = httpRequest(
      {
        socketPath: DOCKER_SOCK,
        method,
        path: apiPath,
        headers,
        timeout: 20000,
      },
      (res) => {
        let data = ''
        res.setEncoding('utf8')
        res.on('data', (c) => { data += c })
        res.on('end', () => {
          let json = null
          try { json = data ? JSON.parse(data) : null } catch { json = null }
          resolve({ status: res.statusCode, json, text: data })
        })
      },
    )
    req.on('timeout', () => req.destroy(new Error('docker api timeout')))
    req.on('error', reject)
    if (payload !== null) req.write(payload)
    req.end()
  })
}

// 通过 Docker API 查找自身容器（镜像 dsh:local + 运行中），返回容器 ID。
// cgroup v2 + host 网络下 /proc/self/cgroup 不含容器 ID，hostname 返回宿主机名，
// 常规方法全部失效，只能靠镜像名过滤。
async function selfContainerId() {
  const res = await docker('GET', '/' + DOCKER_API_VERSION + '/containers/json?filters={"status":["running"],"ancestor":["dsh:local"]}')
  if (res.status !== 200 || !Array.isArray(res.json)) return null
  return res.json.length > 0 ? res.json[0].Id : null
}

// 从自身容器的 Binds 里解析宿主项目目录（升级容器挂载要用宿主路径）
async function resolveHostProjectDir() {
  const id = await selfContainerId()
  if (!id) throw new Error('无法通过 Docker API 找到自身容器（镜像 dsh:local）')
  const res = await docker('GET', '/' + DOCKER_API_VERSION + '/containers/' + id + '/json')
  if (res.status !== 200 || !res.json) {
    throw new Error('读取自身容器信息失败（HTTP ' + res.status + '）')
  }
  const binds = (res.json.HostConfig && res.json.HostConfig.Binds) || []
  for (const bind of binds) {
    // dsh 容器只挂载 Dockerfile/data 的窄路径；从其中任一宿主源路径反推项目根目录。
    let match = bind.match(/^(.+):\/opt\/dsh-nas\/Dockerfile(?::(?:rw|ro))?$/)
    if (match) return dirname(match[1])
    match = bind.match(/^(.+):\/opt\/dsh-nas\/data(?::(?:rw|ro))?$/)
    if (match) return dirname(match[1])
  }
  throw new Error('未在容器挂载中找到 /opt/dsh-nas/Dockerfile 或 data 对应的宿主项目目录（需按新版 docker-compose.yml 重新部署）')
}

// ---------- 升级动作 ----------
async function fetchLatestVersion() {
  const res = await fetch(NPM_LATEST_URL, {
    signal: AbortSignal.timeout(15000),
    headers: { accept: 'application/json' },
  })
  if (!res.ok) throw new Error('npm registry HTTP ' + res.status + '（网络或代理问题）')
  const data = await res.json()
  const v = data && data.version
  if (typeof v !== 'string' || !VERSION_RE.test(v)) throw new Error('registry 返回的版本号无效')
  return v
}

// 升级容器内执行的脚本。version 已通过 VERSION_RE 白名单校验（仅 [0-9A-Za-z.-]），无注入风险。
function helperCommand(version, hostDir) {
  const v = version
  const dir = hostDir.replace(/'/g, `'\\''`)
  return `set -o pipefail
cd '${dir}' || { echo 9 > data/upgrade-run.exit; exit 9; }
printf '%s\\n' '${v}' > data/upgrade-version.txt
rm -f data/upgrade-run.exit
printf '== dsh 升级 ${v} ==\\n开始: %s\\n' "$(date '+%F %T')" > data/upgrade-run.log
# sed -i 会把文件属主改为 root：先记录原属主，改完恢复，保证宿主用户仍可编辑
own_df="$(stat -c '%u:%g' Dockerfile 2>/dev/null || true)"
own_dc="$(stat -c '%u:%g' docker-compose.yml 2>/dev/null || true)"
sed -i -E 's/^ARG DSH_VERSION=.*/ARG DSH_VERSION=${v}/' Dockerfile
sed -i -E 's#^ *DSH_VERSION:.*$#        DSH_VERSION: "${v}"#' docker-compose.yml
[ -n "$own_df" ] && chown "$own_df" Dockerfile || true
[ -n "$own_dc" ] && chown "$own_dc" docker-compose.yml || true
if ! grep -q '^ARG DSH_VERSION=${v}$' Dockerfile; then
  echo '✗ 版本号写入 Dockerfile 失败' >> data/upgrade-run.log
  echo 2 > data/upgrade-run.exit
  exit 2
fi
grep -q 'DSH_VERSION: "${v}"' docker-compose.yml || {
  echo '✗ 版本号写入 docker-compose.yml 失败' >> data/upgrade-run.log
  echo 2 > data/upgrade-run.exit
  exit 2
}
echo "== 宿主项目目录: $(pwd) ==" >> data/upgrade-run.log
# 升级容器按原路径挂载宿主项目目录、cwd 即原始部署目录：compose 文件里的相对
# bind（./data/dsh 等）才能被 daemon 解析回真实宿主路径。若挂到 /project 之类
# 的内部路径，daemon 会在宿主上自动创建空的 /project/data/dsh（root 属主），
# 重建的容器挂到空目录，entrypoint 直接 FATAL。
# COMPOSE_PROJECT_NAME 显式对齐原部署项目名（防 -p 自定义过项目名的场景）。
COMPOSE_PROJECT_NAME=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' dsh 2>/dev/null) && export COMPOSE_PROJECT_NAME
echo "== COMPOSE_PROJECT_NAME: \${COMPOSE_PROJECT_NAME:-\$PWD} ==" >> data/upgrade-run.log
# 必须在 deploy.sh 之前修复属主：up -d 启动的新容器 entrypoint 在 deploy.sh 内部
# 就做可写检查，事后 chown 来不及；且 deploy.sh 只检查目录本身属主，子树被
# root 化时漏检，这里无条件递归修复
chown -R 1000:1000 data/dsh 2>>data/upgrade-run.log || true
bash ./deploy.sh --upgrade >> data/upgrade-run.log 2>&1
rc=$?
echo "$rc" > data/upgrade-run.exit
printf '== 升级结束（退出码 %s）: %s ==\\n' "$rc" "$(date '+%F %T')" >> data/upgrade-run.log
chmod 666 data/upgrade-run.log data/upgrade-run.exit data/upgrade-version.txt 2>/dev/null || true
[ -f .env ] && chmod 666 .env 2>/dev/null || true
chown -R 1000:1000 data/dsh 2>/dev/null || true
exit "$rc"`
}

async function startUpgrade(version) {
  const v = typeof version === 'string' ? version.trim() : ''
  if (!VERSION_RE.test(v)) throw new Error('版本号格式无效（应为 x.y.z 或 x.y.z-rc.n）')
  if (!fileExists(FILES.dockerfile)) {
    throw new Error('未找到 ' + FILES.dockerfile + '：需按新版 docker-compose.yml 挂载项目文件后重新部署')
  }
  if (!fileExists(DOCKER_SOCK)) {
    throw new Error('未找到 /var/run/docker.sock：需按新版 docker-compose.yml 挂载后重新部署')
  }
  if (!sockWritable()) {
    throw new Error('docker.sock 无写权限：请在 NAS 上重跑一次 ./deploy.sh（自动检测并写入 DOCKER_GID 属组）')
  }
  // 并发防护：已有升级容器在跑则拒绝
  const existing = await docker('GET', '/' + DOCKER_API_VERSION + '/containers/' + HELPER_NAME + '/json').catch(() => null)
  if (existing && existing.status === 200 && existing.json && existing.json.State && existing.json.State.Running) {
    throw new Error('已有升级任务在运行中，请稍候')
  }
  const hostDir = await resolveHostProjectDir()
  // 清理可能残留的同名容器（上次启动失败未 AutoRemove 的场景）
  await docker('DELETE', '/' + DOCKER_API_VERSION + '/containers/' + HELPER_NAME + '?force=1&v=1').catch(() => {})
  const create = await docker('POST', '/' + DOCKER_API_VERSION + '/containers/create?name=' + HELPER_NAME, {
    Image: HELPER_IMAGE,
    Entrypoint: ['/bin/bash', '-c', helperCommand(v, hostDir)],
    WorkingDir: hostDir,
    User: '0:0',
    Labels: { 'dsh-nas.upgrade': 'true' },
    HostConfig: {
      NetworkMode: 'host',
      AutoRemove: true,
      Binds: [DOCKER_SOCK + ':' + DOCKER_SOCK, hostDir + ':' + hostDir],
    },
  })
  if (create.status !== 201) {
    const msg = (create.json && create.json.message) || create.text || ('HTTP ' + create.status)
    throw new Error('创建升级容器失败: ' + msg)
  }
  const id = create.json.Id
  const start = await docker('POST', '/' + DOCKER_API_VERSION + '/containers/' + id + '/start')
  if (start.status !== 204) {
    await docker('DELETE', '/' + DOCKER_API_VERSION + '/containers/' + id + '?force=1&v=1').catch(() => {})
    const msg = (start.json && start.json.message) || start.text || ('HTTP ' + start.status)
    throw new Error('启动升级容器失败: ' + msg)
  }
  return { started: true, helper: HELPER_NAME, target: v }
}

async function upgradeStatus() {
  const exitR = tryRead(FILES.exit, 16)
  const targetR = tryRead(FILES.target, 256)
  const logR = tryRead(FILES.log, 6000)
  let helperRunning = null
  try {
    const res = await docker('GET', '/' + DOCKER_API_VERSION + '/containers/' + HELPER_NAME + '/json')
    helperRunning = !!(res.status === 200 && res.json && res.json.State && res.json.State.Running)
  } catch { helperRunning = null }
  const exitParsed = exitR.ok ? parseInt(exitR.text.trim(), 10) : NaN
  return {
    current: currentVersion(),
    target: targetR.ok ? targetR.text.trim() : null,
    exit: Number.isFinite(exitParsed) ? exitParsed : null,
    logTail: logR.ok ? logR.text : '',
    helperRunning,
    capable: {
      dockerfile: fileExists(FILES.dockerfile),
      compose: fileExists(FILES.compose),
      sock: fileExists(DOCKER_SOCK),
      sockWritable: sockWritable(),
    },
  }
}

function apply(ctx) {
  // ---- 重启：向 PID 1（tini）发 SIGTERM，容器由 restart 策略自动拉起 ----
  ctx.connection.rpc.handle('/restart-dsh', async (endpoint, payload) => {
    if (endpoint !== 'web') return { ok: false, error: { code: 'bad-request', message: 'unknown endpoint: ' + String(endpoint), details: {} } }
    // 时序：先返回成功响应，再延迟发送 SIGTERM。
    // Node 收到 SIGTERM 会立即退出、不等事件循环——若先 kill 再返回，
    // RPC 响应可能在进程退出时被截断，浏览器会误报「失败」。
    const doKill = () => {
      try {
        const spec = ctx.shell.resolve({ command: 'kill -TERM 1' })
        ctx.shell.run(spec).catch(() => {})
      } catch (err) {
        console.error('restart-dsh: kill failed', err && err.message ? err.message : err)
      }
    }
    const timer = ctx.get('timer')
    if (timer !== undefined) timer.timeout(doKill, 500)
    else doKill()
    return { ok: true, value: '重启指令已发出，进程将在 0.5 秒后退出（容器自动拉起）' }
  }, { authority: 'loopback' })

  // ---- 升级：latest / status / start ----
  ctx.connection.rpc.handle('/dsh-upgrade', async (endpoint, payload) => {
    if (endpoint !== 'web') return { ok: false, error: { code: 'bad-request', message: 'unknown endpoint: ' + String(endpoint), details: {} } }
    const action = payload && typeof payload === 'object' ? payload.action : null
    try {
      if (action === 'latest') return { ok: true, value: { latest: await fetchLatestVersion() } }
      if (action === 'status') return { ok: true, value: await upgradeStatus() }
      if (action === 'start') return { ok: true, value: await startUpgrade(payload && payload.version) }
      return { ok: false, error: { code: 'bad-request', message: 'unknown action: ' + String(action), details: {} } }
    } catch (err) {
      return { ok: false, error: { code: 'internal', message: err && err.message ? String(err.message) : String(err), details: {} } }
    }
  }, { authority: 'loopback' })
}

export { apply, inject, name, helperCommand }
export default { apply, inject, name }
