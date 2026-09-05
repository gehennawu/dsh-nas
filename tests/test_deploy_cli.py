"""Regression tests at deploy.sh's CLI boundary (Python 3.9+, Bash/GNU tools).

Run: python3 -m unittest discover -s tests -v
No root, Docker, network or production data required. The complete script runs in
an isolated fixture with an allowlisted PATH. Only its hard-coded host upgrade
state directory is relocated in the disposable copy; no functions are replaced.
"""
import errno
import json
import os
import pty
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class DeployCliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dsh-cli-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / 'project'
        self.project.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        # No ambient PATH fallback: an unanticipated command must fail closed.
        for tool in ('bash', 'sh', 'dirname', 'basename', 'pwd', 'grep', 'sed', 'awk', 'head',
                     'tail', 'tr', 'sort', 'wc', 'cut', 'mkdir', 'chmod', 'rm',
                     'mv', 'touch', 'mktemp', 'date', 'flock', 'ls', 'xargs', 'seq'):
            executable = shutil.which(tool)
            if not executable:
                self.skipTest(f'Required test tool unavailable: {tool}')
            (self.bin / tool).symlink_to(executable)
        (self.bin / 'python3').symlink_to(sys.executable)
        fake = self.bin / 'fake-system.py'
        shutil.copyfile(REPO / 'tests/fake-system.py', fake)
        fake.chmod(0o755)
        for tool in ('docker', 'curl', 'wget', 'ip', 'id', 'stat', 'cp', 'chown',
                     'sync', 'sleep', 'ss', 'netstat', 'sudo', 'systemctl',
                     'service', 'apt-get', 'usermod', 'setpriv', 'git'):
            (self.bin / tool).symlink_to(fake)
        for relative in ('deploy.sh', 'Dockerfile', 'entrypoint.sh',
                         'patch-trusted-domain.mjs', 'docker-compose.yml'):
            target = self.project / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / relative, target)
        script = self.project / 'deploy.sh'
        source = script.read_text()
        state_literal = 'UPGRADE_STATE_ROOT="/var/lib/dsh-nas-upgrade"'
        self.assertEqual(source.count(state_literal), 1,
                         'Update fixture relocation if the host-state interface changes')
        script.write_text(source.replace(state_literal,
                          f'UPGRADE_STATE_ROOT="{self.root}/upgrade-state"'))
        # Do not read local Authelia files: deployed checkouts may contain secrets.
        auth = self.project / 'authelia'
        auth.mkdir()
        (auth / 'configuration.yml').write_text(
            "session:\n  secret: fixture-not-a-secret\n  cookies:\n"
            "    - domain: nas.test\n      authelia_url: 'https://auth.nas.test'\n")
        (auth / 'users_database.yml').write_text(
            'users:\n  admin:\n    password: fixture-not-a-real-hash\n')
        for relative in ('data/dsh/profiles/node_modules', 'data/workspace',
                         'caddy/data', 'caddy/config', 'authelia/data'):
            (self.project / relative).mkdir(parents=True, exist_ok=True)
        (self.project / '.env').write_text('DSH_PROXY=\nDSH_TRUSTED_DOMAIN=\n')
        self.env = {
            'PATH': str(self.bin), 'HOME': str(self.root), 'TMPDIR': str(self.root),
            'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8', 'TEST_ROOT': str(self.root),
            'REAL_STAT': shutil.which('stat'), 'REAL_CP': shutil.which('cp'),
        }
        self.configure_entry('direct-443-only', [[':443']])

    def configure_entry(self, mode, listeners):
        if mode == 'front-proxy':
            globals_ = 'auto_https off\n    http_port 13080\n    default_bind 127.0.0.1'
            scheme, suffix = 'http', ':13080'
        else:
            globals_ = 'email admin@nas.test'
            if mode == 'direct-443-only':
                globals_ += '\n    auto_https disable_redirects'
            scheme, suffix = 'https', ''
        (self.project / 'caddy/Caddyfile').write_text(
            f'# dsh-nas-entry-mode: {mode}\n{{\n    {globals_}\n}}\n'
            f'{scheme}://auth.nas.test{suffix} {{\n    reverse_proxy 127.0.0.1:9091\n}}\n'
            f'{scheme}://dsh.nas.test{suffix} {{\n'
            '    forward_auth 127.0.0.1:9091 {\n'
            '        uri /api/authz/forward-auth?authelia_url=https://auth.nas.test\n'
            '    }\n    reverse_proxy 127.0.0.1:3080\n}\n')
        self.env['TEST_CADDY_JSON'] = json.dumps({'apps': {'http': {'servers': {
            f'srv{i}': {'listen': addresses} for i, addresses in enumerate(listeners)
        }}}})

    def run_deploy(self, *args):
        result = subprocess.run([str(self.bin / 'bash'), str(self.project / 'deploy.sh'), *args],
                                cwd=self.project, env=self.env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=30)
        self.assertNotIn('command not found', result.stdout)
        unexpected = self.root / 'unexpected-commands'
        self.assertFalse(unexpected.exists(), unexpected.read_text() if unexpected.exists() else '')
        return result

    def test_upgrade_failure_reports_successful_config_restore(self):
        # Upgrade takes a snapshot, then refuses a non-interactive patch choice.
        # This exercises the real EXIT trap and rollback through the CLI.
        result = self.run_deploy('--upgrade')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('DSH patch 选择需要交互终端', result.stdout)
        self.assertIn('旧版本恢复完成', result.stdout)
        self.assertNotIn('旧版本恢复失败', result.stdout)

    def test_upgrade_failure_does_not_hide_config_restore_failure(self):
        self.env['TEST_RESTORE_FAILURE'] = '1'
        result = self.run_deploy('--upgrade')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('DSH patch 选择需要交互终端', result.stdout)
        self.assertIn('旧版本恢复失败', result.stdout)
        self.assertNotIn('旧版本恢复完成', result.stdout)

    def test_direct_80_443_accepts_two_listeners(self):
        self.configure_entry('direct-80-443', [[':80', ':443']])
        result = self.run_deploy('--skip-build')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('Caddy 直连 80/443 模式仅监听 80 和 443', result.stdout)

    def test_direct_80_443_accepts_separate_server_listeners(self):
        self.configure_entry('direct-80-443', [[':443'], [':80']])
        result = self.run_deploy('--skip-build')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_443_only_accepts_single_listener(self):
        result = self.run_deploy('--skip-build')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('Caddy 443-only 模式仅监听 443', result.stdout)

    def test_front_proxy_accepts_loopback_listener(self):
        self.configure_entry('front-proxy', [['127.0.0.1:13080']])
        result = self.run_deploy('--skip-build')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('Caddy 反代模式仅监听 127.0.0.1:13080', result.stdout)

    def test_443_only_rejects_extra_listener(self):
        self.configure_entry('direct-443-only', [[':443', ':80']])
        result = self.run_deploy('--skip-build')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('Caddy listener 不符合入口模式', result.stdout)

    def test_direct_80_443_rejects_missing_port(self):
        self.configure_entry('direct-80-443', [[':443']])
        result = self.run_deploy('--skip-build')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('Caddy listener 不符合入口模式', result.stdout)

    def test_front_proxy_rejects_wildcard_listener(self):
        self.configure_entry('front-proxy', [['0.0.0.0:13080']])
        result = self.run_deploy('--skip-build')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('Caddy listener 不符合入口模式', result.stdout)

    def test_empty_admin_config_is_not_accepted(self):
        self.env['TEST_CADDY_JSON'] = '{}'
        result = self.run_deploy('--skip-build')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('无法从 Caddy admin API 读取 HTTP listener', result.stdout)

    def test_cleanup_preserves_other_projects_and_unmarked_history(self):
        images = [
            {'id': 'own-unused', 'project': True},
            {'id': 'other-unused'},
            {'id': 'legacy-dsh-unmarked'},
            {'id': 'own-tagged', 'project': True, 'tagged': True},
            {'id': 'own-running', 'project': True, 'referenced': True},
            {'id': 'own-stopped', 'project': True, 'referenced': True},
        ]
        inventory = self.root / 'images.json'
        inventory.write_text(json.dumps(images))
        result = self.run_deploy('--skip-build')
        self.assertEqual(result.returncode, 0, result.stdout)
        remaining = {image['id'] for image in json.loads(inventory.read_text())}
        self.assertEqual(remaining, {'other-unused', 'legacy-dsh-unmarked', 'own-tagged',
                                     'own-running', 'own-stopped'})

    def test_cleanup_failure_only_warns_and_preserves_images(self):
        self.env['TEST_PRUNE_FAILURE'] = '1'
        inventory = self.root / 'images.json'
        images = [{'id': 'own-unused', 'project': True}]
        inventory.write_text(json.dumps(images))
        result = self.run_deploy('--skip-build')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('本项目悬空镜像清理失败', result.stdout)
        self.assertEqual(json.loads(inventory.read_text()), images)

    def test_cleanup_does_not_run_when_inventory_cannot_be_read(self):
        self.env['TEST_IMAGE_LIST_FAILURE'] = '1'
        inventory = self.root / 'images.json'
        images = [{'id': 'own-unused', 'project': True}]
        inventory.write_text(json.dumps(images))
        result = self.run_deploy('--skip-build')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('已跳过清理', result.stdout)
        self.assertEqual(json.loads(inventory.read_text()), images)

    def test_failed_deployment_does_not_clean_images(self):
        self.configure_entry('direct-443-only', [[':443', ':80']])
        inventory = self.root / 'images.json'
        images = [{'id': 'own-unused', 'project': True}]
        inventory.write_text(json.dumps(images))
        result = self.run_deploy('--skip-build')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(json.loads(inventory.read_text()), images)

    def test_final_dsh_image_declares_cleanup_ownership(self):
        final_stage = (self.project / 'Dockerfile').read_text().rsplit('FROM ', 1)[1]
        self.assertIn('LABEL io.github.gehennawu.dsh-nas.cleanup="dsh"', final_stage)

    def test_plain_output_shows_stage_summary_and_separate_commands(self):
        result = self.run_deploy('--skip-build')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('[1/8] 环境检查', result.stdout)
        self.assertIn('[8/8] 等待服务就绪与安全验证', result.stdout)
        self.assertIn('部署完成', result.stdout)
        self.assertIn('总耗时:', result.stdout)
        self.assertIn('查看日志: docker compose logs -f dsh\n', result.stdout)
        self.assertIn('重启服务: docker compose restart dsh', result.stdout)
        self.assertNotIn('logs -f dsh |', result.stdout)
        self.assertNotIn('\x1b[', result.stdout)
        # Sensitive output remains present, as explicitly requested.
        self.assertIn('https://dsh.nas.test/?token=fixture-not-a-secret', result.stdout)

    def test_slow_start_shows_service_status_before_success(self):
        self.env['TEST_HEALTH_STARTING_ONCE'] = '1'
        result = self.run_deploy('--skip-build')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('等待服务就绪 · 已等待', result.stdout)
        self.assertIn('dsh: 启动中 | Authelia: 启动中 | Caddy: 启动中', result.stdout)
        self.assertIn('部署完成', result.stdout)

    def test_tty_url_respects_no_color_and_dumb_terminal(self):
        for term, no_color, colored in [('xterm', '', True), ('xterm', '1', False),
                                        ('dumb', '', False)]:
            with self.subTest(term=term, no_color=no_color):
                # Use `url`, whose output includes the existing bold token URL.
                try:
                    master, slave = pty.openpty()
                except OSError as error:
                    self.skipTest(f'PTY unavailable in this environment: {error}')
                try:
                    env = dict(self.env, TERM=term, NO_COLOR=no_color)
                    process = subprocess.Popen(
                        [str(self.bin / 'bash'), str(self.project / 'deploy.sh'), 'url'],
                        cwd=self.project, env=env, stdin=subprocess.DEVNULL,
                        stdout=slave, stderr=slave)
                    os.close(slave)
                    slave = None
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                        raise
                    chunks = []
                    while True:
                        try:
                            chunk = os.read(master, 4096)
                        except OSError as error:
                            if error.errno == errno.EIO:
                                break
                            raise
                        if not chunk:
                            break
                        chunks.append(chunk)
                    output = b''.join(chunks).decode()
                    self.assertEqual(process.returncode, 0, output)
                    self.assertEqual('\x1b[' in output, colored, output)
                    self.assertIn('?token=fixture-not-a-secret', output)
                finally:
                    os.close(master)
                    if slave is not None:
                        os.close(slave)

    def test_failure_summary_never_claims_success(self):
        self.configure_entry('direct-443-only', [[':443', ':80']])
        result = self.run_deploy('--skip-build')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('部署未完成', result.stdout)
        self.assertNotIn('部署完成', result.stdout)


if __name__ == '__main__':
    unittest.main()
