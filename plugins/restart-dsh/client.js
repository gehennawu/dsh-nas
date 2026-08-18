// Browser half of @dsh-nas/restart-dsh
// 设置面板只提供本地重启能力。
// 网页升级已关闭：当前 dsh 容器不挂载 Docker socket，升级请在 NAS 宿主机执行。
window.__ModuleLoader__.load({
  id: '@dsh-nas/restart-dsh',
  factory: (require) => {
    var module = { exports: {} }
    var exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })
    const React = require('react')
    const inject = ['slots', 'connection']

    function apply(ctx) {
      const { useState } = React
      const S = {
        row: { display: 'flex', alignItems: 'center', gap: '8px', marginTop: '12px', flexWrap: 'wrap' },
        btn: { padding: '6px 14px', borderRadius: '6px', border: '1px solid rgba(128,128,128,0.3)', cursor: 'pointer', fontSize: '13px' },
        hint: { color: '#888', fontSize: '12px', marginTop: '8px', lineHeight: 1.6 },
        divider: { height: 1, background: 'rgba(128,128,128,0.2)', margin: '18px 0 2px' },
      }
      const danger = Object.assign({}, S.btn, { background: '#d33', color: '#fff', borderColor: '#d33' })
      const plain = Object.assign({}, S.btn, { background: 'transparent' })

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
              '页面连接即将断开，容器会自动重新拉起（约 10-30 秒），就绪后请刷新页面。'))
        }

        return React.createElement('div', null,
          React.createElement('p', { style: { margin: '8px 0 0', fontSize: '13px' } },
            '重启 dsh web 服务进程：运行中的任务会中断，持久化的会话可恢复。'),
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

      function ServicePanel() {
        return React.createElement('div', null,
          React.createElement(RestartPanel, null),
          React.createElement('div', { style: S.divider }),
          React.createElement('p', { style: S.hint },
            '网页升级暂未启用。当前 dsh 容器不挂载 Docker socket；如需升级，请在 NAS 宿主机进入项目目录后执行 ./deploy.sh --upgrade 或 ./deploy.sh --latest。'))
      }

      ctx.slots.inject('settings.section', () => ctx.slots.register(
        { name: 'settings.section', id: 'restart-dsh', order: 99, label: () => '服务控制' },
        () => React.createElement(ServicePanel, null),
      ))
    }

    exports.inject = inject
    exports.apply = apply
    return module.exports
  },
})
