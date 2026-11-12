"""Exercise the real patch CLI against isolated browser/Node bundle fixtures."""
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BASES = (
    '/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-client-connection/lib',
    '/usr/local/lib/node_modules/@deepseek-ai/dsh-client-connection/lib',
)
MODERN = ('client.browser.js', 'client.node.js', 'index.js')
LEGACY = ('client.js', 'index.js')
SOURCE = ('(()=>{function isLoopbackHostname(hostname){'
          'if(hostname==="localhost")return true;return false;}'
          'globalThis.patchProbe=isLoopbackHostname;'
          'globalThis.bundleRegistered=true;})();')


class TrustedDomainPatchTests(unittest.TestCase):
    def setUp(self):
        self.node = shutil.which('node')
        if not self.node:
            self.skipTest('node is required for patch syntax checks')
        self.temp = tempfile.TemporaryDirectory(prefix='dsh-trusted-domain-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bases = [self.root / 'nested', self.root / 'hoisted']
        # Relocate only the installation roots; execute all production patch logic.
        script = (REPO / 'patch-trusted-domain.mjs').read_text()
        for original, relocated in zip(BASES, self.bases):
            script = script.replace(original, str(relocated))
        self.script = self.root / 'patch.mjs'
        self.script.write_text(script)

    def fixture(self, names=MODERN, base=0, source=SOURCE):
        directory = self.bases[base]
        directory.mkdir(exist_ok=True)
        files = [directory / name for name in names]
        for file in files:
            file.write_text(source)
        return files

    def patch(self, domain='nas.example.com'):
        return subprocess.run([self.node, str(self.script), domain],
                              capture_output=True, text=True, timeout=15)

    def test_single_line_and_multiline_bundles_remain_valid_and_register(self):
        for names, base, multiline in ((MODERN, 0, False), (LEGACY, 1, True)):
            with self.subTest(names=names, multiline=multiline):
                source = SOURCE.replace(';', ';\n') if multiline else SOURCE
                files = self.fixture(names, base, source)
                # Keep the other candidate empty for the legacy resolution case.
                if base:
                    for old in self.bases[0].iterdir():
                        old.unlink()
                for file in files:
                    before = subprocess.run([self.node, '--check', str(file)],
                                            capture_output=True, text=True)
                    self.assertEqual(before.returncode, 0, before.stderr)
                proc = self.patch('NAS.Example.Com')
                self.assertEqual(proc.returncode, 0, proc.stderr)
                for file in files:
                    checked = subprocess.run([self.node, '--check', str(file)],
                                             capture_output=True, text=True)
                    self.assertEqual(checked.returncode, 0, checked.stderr)
                    probe = subprocess.run(
                        [self.node, '--input-type=module', '-e',
                         file.read_text() + '\nconsole.log(JSON.stringify(['
                         'bundleRegistered,patchProbe("nas.example.com"),'
                         'patchProbe("localhost"),patchProbe("evil.example.com")]));'],
                        capture_output=True, text=True)
                    self.assertEqual(probe.returncode, 0, probe.stderr)
                    self.assertEqual(json.loads(probe.stdout), [True, True, True, False])

    def test_syntax_error_in_last_bundle_rejects_without_writing_any_file(self):
        files = self.fixture()
        files[-1].write_text(SOURCE + '\nconst broken = ;')
        originals = [file.read_bytes() for file in files]
        proc = self.patch()
        self.assertNotEqual(proc.returncode, 0, 'invalid bundle must fail the build')
        self.assertIn('语法校验失败', proc.stderr)
        self.assertIn(str(files[-1]), proc.stderr)
        self.assertEqual([file.read_bytes() for file in files], originals)

    def test_duplicate_patch_is_rejected_without_changes(self):
        files = self.fixture()
        proc = self.patch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        originals = [file.read_bytes() for file in files]
        proc = self.patch()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('拒绝重复 patch', proc.stderr)
        self.assertEqual([file.read_bytes() for file in files], originals)

    def test_missing_declaration_rejects_without_partial_patch(self):
        files = self.fixture()
        files[-1].write_text('globalThis.bundleRegistered = true;')
        originals = [file.read_bytes() for file in files]
        proc = self.patch()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('实际找到 0 个', proc.stderr)
        self.assertEqual([file.read_bytes() for file in files], originals)

    def test_invalid_domain_is_rejected(self):
        files = self.fixture()
        originals = [file.read_bytes() for file in files]
        proc = self.patch('https://nas.example.com')
        self.assertEqual(proc.returncode, 2)
        self.assertEqual([file.read_bytes() for file in files], originals)
