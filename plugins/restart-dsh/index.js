// Host half of @dsh-nas/restart-dsh
// 当前版本只提供安全的本地重启能力。
// 网页升级已关闭：dsh 主容器不挂载 Docker socket；升级只能由 NAS 宿主机命令行执行。

const name = 'restart-dsh'
const inject = ['connection', 'shell', 'timer']

const badRequest = (message) => ({
  ok: false,
  error: { code: 'bad-request', message, details: { issues: [] } },
})

function apply(ctx) {
  // 向 PID 1（tini）发送 SIGTERM，容器由 restart: unless-stopped 自动拉起。
  ctx.connection.rpc.handle('/restart-dsh', async (endpoint) => {
    if (endpoint !== 'web') return badRequest('unknown endpoint: ' + String(endpoint))

    const doKill = () => {
      try {
        const spec = ctx.shell.resolve({ command: 'kill -TERM 1' })
        ctx.shell.run(spec).catch(() => {})
      } catch (err) {
        console.error('restart-dsh: kill failed', err && err.message ? err.message : err)
      }
    }

    // 先返回 RPC 响应，再退出进程，避免浏览器把已发送的重启误报成失败。
    ctx.timer.timeout(doKill, 500)

    return { ok: true, value: '重启指令已发出，进程将在 0.5 秒后退出（容器自动拉起）' }
  }, { authority: 'loopback' })

  // 保留旧 endpoint，但明确拒绝，避免旧客户端或缓存继续尝试高权限升级流程。
  ctx.connection.rpc.handle('/dsh-upgrade', async (endpoint) => {
    if (endpoint !== 'web') return badRequest('unknown endpoint: ' + String(endpoint))
    return {
      ok: false,
      error: {
        code: 'command-error',
        message: '网页升级暂未启用：当前版本不挂载 Docker socket，请在 NAS 宿主机上使用命令行升级。',
        details: {},
      },
    }
  }, { authority: 'loopback' })
}

export { apply, inject, name }
export default { apply, inject, name }
