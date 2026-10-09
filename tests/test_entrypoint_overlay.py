"""Regression tests at entrypoint.sh's --patch overlay boundary.

Run: python3 -m unittest discover -s tests -v
No root, Docker, network or production data required.

The complete entrypoint runs in an isolated fixture with an allowlisted PATH and a
stub `dsh` that records its argv. The stub answers the `--dump-config` capability
probe and the final `dsh web` exec, so the generated overlay and the argument
order are asserted without booting a real server.
"""
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

STUB_DSH = """#!/bin/sh
line=""
for arg in "$@"; do
  line="$line|$arg"
done
printf '%s\\n' "$line" >> "$FAKE_DSH_LOG"
exit 0
"""


class EntrypointOverlayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dsh-entrypoint-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for tool in ('sh', 'mkdir', 'id'):
            executable = shutil.which(tool)
            if not executable:
                self.skipTest(f'Required test tool unavailable: {tool}')
            (self.bin / tool).symlink_to(executable)
        self.log = self.root / 'dsh-argv.log'
        stub = self.bin / 'dsh'
        stub.write_text(STUB_DSH)
        stub.chmod(0o755)
        self.script = self.root / 'entrypoint.sh'
        shutil.copyfile(REPO / 'entrypoint.sh', self.script)
        self.home = self.root / 'dsh-home'
        self.env = {
            'PATH': str(self.bin), 'HOME': str(self.root), 'TMPDIR': str(self.root),
            'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8',
            'DSH_HOME': str(self.home), 'FAKE_DSH_LOG': str(self.log),
        }

    def run_entrypoint(self, *args, cookie='365'):
        env = dict(self.env)
        if cookie is None:
            env.pop('DSH_COOKIE_MAX_AGE_DAYS', None)
        else:
            env['DSH_COOKIE_MAX_AGE_DAYS'] = cookie
        return subprocess.run(['sh', str(self.script), *args], env=env,
                              capture_output=True, text=True, timeout=30)

    def invocations(self):
        return [line.split('|')[1:] for line in self.log.read_text().splitlines()]

    def test_overlay_trusted_hosts_expression_is_version_agnostic(self):
        """The overlay must not dereference a service directly.

        A `--patch` row replaces the connection row's `config` but not its `inject`,
        so `ctx.webRuntime...` throws `cannot get property "webRuntime" without
        inject` on a dsh whose row injects webStartup (and vice versa). That error
        fails the required `connection` plugin and aborts `dsh web` startup.
        """
        proc = self.run_entrypoint('--port', '3999')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        overlay = (self.home / 'web-cookie-max-age.yml').read_text()
        self.assertIn('cookieMaxAgeDays: 365', overlay)
        self.assertNotRegex(overlay, r'ctx\.(webRuntime|webStartup)\b',
                            'overlay dereferences a service that may not be injected')
        self.assertIn('ctx.get(', overlay)
        self.assertIn("'webStartup'", overlay)
        self.assertIn("'webRuntime'", overlay)

    def test_generated_expression_tolerates_every_service_layout(self):
        """Evaluate the generated expression the way cordis does.

        The loader evaluates `!!js` as `with (ctx) { return eval(expr) }`, so the
        expression must return a list for every service layout a supported dsh can
        present: neither service, webStartup only (0.2.1-alpha.2+), or webRuntime
        only (0.1.0-rc.8 … 0.2.0). It must not throw when a service is missing.
        """
        node = shutil.which('node')
        if not node:
            self.skipTest('node unavailable: cannot evaluate the generated !!js expression')
        proc = self.run_entrypoint('--port', '3999')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        overlay = (self.home / 'web-cookie-max-age.yml').read_text()
        line = next(l for l in overlay.splitlines() if 'trustedHosts' in l)
        expression = line.split('!!js', 1)[1].strip()
        script = (
            "const expr = process.argv[1];"
            "const evaluate = new Function('ctx', 'expr', 'with (ctx) { return eval(expr) }');"
            "const cases = ["
            "  { get: () => undefined },"
            "  { get: (n) => n === 'webStartup' ? { trustedHosts: ['newer'] } : undefined },"
            "  { get: (n) => n === 'webRuntime' ? { trustedHosts: ['legacy'] } : undefined },"
            "];"
            "console.log(JSON.stringify(cases.map((c) => {"
            "  try { return evaluate(c, expr) } catch (err) { return 'THREW: ' + err.message }"
            "})));"
        )
        result = subprocess.run([node, '-e', script, expression],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [[], ['newer'], ['legacy']])

    def test_launcher_flag_precedes_app_args_and_probe_gates_it(self):
        proc = self.run_entrypoint('--port', '3999')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        calls = self.invocations()
        self.assertEqual(len(calls), 2, calls)
        overlay = str(self.home / 'web-cookie-max-age.yml')
        self.assertEqual(calls[0], ['web', '--dump-config', '--patch', overlay])
        self.assertEqual(calls[1][:3], ['web', '--patch', overlay])
        self.assertEqual(calls[1][3:5], ['--host', '127.0.0.1'])
        self.assertEqual(calls[1][-2:], ['--port', '3999'])

    def test_no_overlay_without_cookie_max_age(self):
        proc = self.run_entrypoint(cookie=None)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse((self.home / 'web-cookie-max-age.yml').exists())
        self.assertEqual(self.invocations(), [['web', '--host', '127.0.0.1']])

    def test_invalid_cookie_max_age_fails_before_starting_dsh(self):
        proc = self.run_entrypoint(cookie='0')
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('FATAL', proc.stderr)
        self.assertFalse(self.log.exists(), 'dsh must not be invoked')


if __name__ == '__main__':
    unittest.main()
