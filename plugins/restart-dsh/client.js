// Browser half of @dsh-nas/restart-dsh
// 设置面板新增「服务控制」页：
//  1) 重启：一键重启 dsh web（两段式确认）
//  2) 升级：获取 npm 最新版 / 手动输入版本号 → 后台容器执行
//     （改 Dockerfile 的 ARG DSH_VERSION → 跑一次 deploy.sh），
//     实时展示日志尾部与结果；容器重建期间页面断开属正常。
window.__ModuleLoader__.load({
  id: '@dsh-nas/restart-dsh',
  factory: (require) => {
    var module = { exports: {} }
    var exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })
    const React = require('react')

    // 服务依赖：apply 前等待这些服务物化，避免插件先于服务激活而静默失效。
    // timer：升级进度轮询（每 3 秒读取宿主项目目录下的进度文件）。
    const inject = ['slots', 'connection', 'timer']

    // 版本号白名单（与 host 半一致）：x.y.z 或 x.y.z-rc.n
    const VERSION_RE = /^\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?$/

    function apply(ctx) {
      const { useState, useEffect } = React

      const S = {
        row: { display: 'flex', alignItems: 'center', gap: '8px', marginTop: '12px', flexWrap: 'wrap' },
        btn: { padding: '6px 14px', borderRadius: '6px', border: '1px solid rgba(128,128,128,0.3)', cursor: 'pointer', fontSize: '13px' },
        hint: { color: '#888', fontSize: '12px', marginTop: '8px', lineHeight: 1.6 },
        title: { margin: '22px 0 0', fontSize: '13px', fontWeight: 600 },
        divider: { height: 1, background: 'rgba(128,128,128,0.2)', margin: '18px 0 2px' },
        input: { padding: '6px 10px', borderRadius: '6px', border: '1px solid rgba(128,128,128,0.4)', fontSize: '13px', width: '170px' },
        log: {
          marginTop: '10px', padding: '10px', borderRadius: '6px', background: 'rgba(128,128,128,0.08)',
          maxHeight: '260px', overflow: 'auto', fontSize: '11px', lineHeight: 1.5, whiteSpace: 'pre-wrap',
          wordBreak: 'break-all', fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
        },
        ok: { color: '#2a9d4a', fontSize: '12px', margin: '10px 0 0' },
        bad: { color: '#d33', fontSize: '12px', margin: '10px 0 0' },
        warn: { color: '#b8860b', fontSize: '12px', margin: '10px 0 0' },
      }
      const danger = Object.assign({}, S.btn, { background: '#d33', color: '#fff', borderColor: '#d33' })
      const plain = Object.assign({}, S.btn, { background: 'transparent' })
      const primary = Object.assign({}, S.btn, { background: '#2563eb', color: '#fff', borderColor: '#2563eb' })

      function RestartPanel() {
        const [stage, setStage] = useState(0) // 0 初始 / 1 确认 / 2 已发送
        const [busy, setBusy] = useState(false)
        const [error, setError] = useState(null)

        const restart = async () => {
          setBusy(true)
          setError(null)
          try {
            const res = await ctx.connection.rpc.call('/restart-dsh', 'web', {})
            if (res && res.ok === false) throw new Error(res.error && res.error.message || '重启失败')
            setStage(2)
          } catch (err) {
            setError(err && err.message ? String(err.message) : String(err))
            setStage(0)
          } finally {
            setBusy(false)
          }
        }

        if (stage === 2) {
          return React.createElement('div', null,
            React.createElement('p', { style: { margin: 0 } }, '重启指令已发出。'),
            React.createElement('p', { style: S.hint },
              '页面连接即将断开，容器会自动重新拉起（约 10-30 秒），就绪后请刷新页面。若 1 分钟后页面仍可用，说明重启未生效（非容器部署或权限不足）。'))
        }

        return React.createElement('div', null,
          React.createElement('p', { style: { margin: '8px 0 0', fontSize: '13px' } },
            '重启 dsh web 服务进程：运行中的任务会中断，持久化的会话可恢复（数据在持久化卷中）。'),
          React.createElement('div', { style: S.row },
            stage === 0
              ? React.createElement('button', { style: danger, onClick: () => setStage(1) }, '重启 dsh web')
              : [
                  React.createElement('button', { key: 'confirm', style: danger, onClick: restart, disabled: busy }, busy ? '发送中…' : '确认重启'),
                  React.createElement('button', { key: 'cancel', style: plain, onClick: () => setStage(0), disabled: busy }, '取消'),
                ]),
          stage === 1 ? React.createElement('p', { style: S.hint }, '确认后将立即断开当前连接，等待容器自动重启。') : null,
          error ? React.createElement('p', { style: Object.assign({}, S.hint, { color: '#d33' }) }, String(error)) : null)
      }

      function UpgradePanel() {
        const [info, setInfo] = useState(null)
        const [latest, setLatest] = useState(null) // null | {version} | {error}
        const [fetching, setFetching] = useState(false)
        const [version, setVersion] = useState('')
        const [stage, setStage] = useState(0) // 0 输入 / 1 确认
        const [starting, setStarting] = useState(false)
        const [offline, setOffline] = useState(false)
        const [error, setError] = useState(null)

        const call = (payload) => ctx.connection.rpc.call('/dsh-upgrade', 'web', payload)

        useEffect(() => {
          let stopped = false
          const tick = () => {
            call({ action: 'status' }).then((res) => {
              if (stopped) return
              setOffline(false)
              if (res && res.ok === false) setInfo(null)
              else setInfo(res ? res.value : null)
            }).catch(() => {
              if (!stopped) setOffline(true) // 升级重建容器中或连接断开
            })
          }
          tick()
          const stop = ctx.interval(tick, 3000)
          return () => { stopped = true; stop() }
        }, [])

        const fetchLatest = () => {
          setFetching(true)
          setLatest(null)
          call({ action: 'latest' })
            .then((res) => {
              if (res && res.ok !== false && res.value) setLatest({ version: res.value.latest })
              else setLatest({ error: (res && res.error && res.error.message) || '获取失败（网络或代理问题）' })
            })
            .catch(() => setLatest({ error: '获取失败（网络或代理问题）' }))
            .finally(() => setFetching(false))
        }

        const doStart = () => {
          const v = (version || '').trim()
          if (!VERSION_RE.test(v)) {
            setError('版本号格式无效（应为 x.y.z 或 x.y.z-rc.n，如 0.1.0-rc.7）')
            return
          }
          setStarting(true)
          setError(null)
          call({ action: 'start', version: v })
            .then((res) => {
              if (res && res.ok === false) throw new Error(res.error && res.error.message || '启动升级失败')
              setStage(0)
            })
            .catch((err) => setError(err && err.message ? String(err.message) : String(err)))
            .finally(() => setStarting(false))
        }

        const current = info ? info.current : null
        const target = info ? info.target : null
        const exit = info ? info.exit : null
        const inProgressFiles = target !== null && exit === null
        const running = !!info && (info.helperRunning === true || (info.helperRunning === null && inProgressFiles))
        const done = exit !== null && exit !== undefined
        const success = done && exit === 0
        const ready = !info || !info.capable || (info.capable.dockerfile && info.capable.compose && info.capable.sock && info.capable.sockWritable)

        return React.createElement('div', null,
          React.createElement('p', { style: S.title }, '升级 dsh'),
          React.createElement('p', { style: { margin: '8px 0 0', fontSize: '13px' } },
            '当前版本：' + (current || '—'),
            latest && latest.version
              ? '　·　npm 最新：' + latest.version + (current && current === latest.version ? '（已是最新）' : '')
              : ''),
          React.createElement('div', { style: S.row },
            React.createElement('button', { style: plain, onClick: fetchLatest, disabled: fetching || running }, fetching ? '查询中…' : '获取最新版本'),
            latest && latest.version && latest.version !== current && !running
              ? React.createElement('button', { key: 'fill', style: plain, onClick: () => setVersion(latest.version) }, '填入 ' + latest.version)
              : null,
            latest && latest.error ? React.createElement('span', { style: S.bad }, String(latest.error)) : null),

          !ready
            ? React.createElement('p', { style: S.warn },
              '⚠ 升级功能未就绪（缺少 docker.sock / 项目文件挂载或属组权限）。请在 NAS 上重新运行一次 ./deploy.sh 应用新版部署配置后再使用；命令行升级不受影响。')
            : null,

          !running
            ? React.createElement('div', { style: S.row },
              React.createElement('input', {
                style: S.input,
                value: version,
                placeholder: '版本号，如 0.1.0-rc.7',
                onChange: (e) => setVersion(e.target.value),
              }),
              stage === 0
                ? React.createElement('button', {
                  style: primary,
                  onClick: () => { setError(null); setStage(1) },
                  disabled: !(version || '').trim(),
                }, '升级 dsh')
                : [
                    React.createElement('button', { key: 'go', style: primary, onClick: doStart, disabled: starting }, starting ? '启动中…' : '确认升级'),
                    React.createElement('button', { key: 'no', style: plain, onClick: () => setStage(0), disabled: starting }, '取消'),
                  ])
            : null,
          stage === 1 && !running
            ? React.createElement('p', { style: S.hint },
              '升级将在后台执行：改 Dockerfile 的 ARG DSH_VERSION → 重建镜像（首次依赖编译约 10 分钟）→ 重启容器。期间页面会断开属正常；Caddy/Authelia 配置与数据不受影响；构建失败时现有服务保持运行。')
            : null,

          running
            ? React.createElement('p', { style: S.hint },
              '⏳ 升级进行中（后台执行，可关闭此页面）：' + (current || '?') + ' → ' + (target || '…'))
            : null,
          offline
            ? React.createElement('p', { style: S.warn },
              '连接已断开——多为容器正在重建，升级仍在后台进行；请 1-3 分钟后刷新本页查看结果。')
            : null,
          done
            ? (success
              ? React.createElement('p', { style: S.ok },
                '✓ 升级完成' + (target ? '：' + target : '') + '（当前版本 ' + (current || '?') + '）——刷新页面即可使用新版本。')
              : React.createElement('p', { style: S.bad },
                '✗ 升级失败（退出码 ' + exit + '）：请查看下方日志。常见原因：版本号不存在、构建代理不通。现有服务保持运行。'))
            : null,
          info && info.logTail ? React.createElement('pre', { style: S.log }, String(info.logTail)) : null,
          error ? React.createElement('p', { style: Object.assign({}, S.hint, { color: '#d33' }) }, String(error)) : null)
      }

      function ServicePanel() {
        return React.createElement('div', null,
          React.createElement(RestartPanel, null),
          React.createElement('div', { style: S.divider }),
          React.createElement(UpgradePanel, null))
      }

      ctx.slots.inject('settings.section', () => ctx.slots.register(
        { name: 'settings.section', id: 'restart-dsh', order: 99, label: () => '服务控制' },
        () => React.createElement(ServicePanel, null),
      ))
    }

    exports.inject = inject
    exports.apply = apply
    // 物化后的模块导出 = factory 返回值（官方所有 client bundle 同款结尾）
    return module.exports
  },
})
