"""Run deploy.sh's actual embedded image probe without Docker or network."""
import json
import re
import subprocess
import unittest

import test_trusted_domain_patch as fixtures
from test_trusted_domain_patch import MODERN, LEGACY, SOURCE, BASES, REPO


class ImageProbeTests(unittest.TestCase):
    # Reuse fixture helpers, not the patch CLI test cases.
    setUp = fixtures.TrustedDomainPatchTests.setUp
    fixture = fixtures.TrustedDomainPatchTests.fixture
    patch = fixtures.TrustedDomainPatchTests.patch
    def probe(self, domain='nas.example.com'):
        deploy = (REPO / 'deploy.sh').read_text()
        match = re.search(r'probe=\$\(docker run --rm --entrypoint node "\$image" -e \'\n(.*?)\n  \' "\$domain"\)',
                          deploy, re.S)
        self.assertIsNotNone(match, 'production embedded probe boundary changed')
        script = match.group(1)
        for original, relocated in zip(BASES, self.bases):
            script = script.replace(original, str(relocated))
        pkg = self.root / 'package.json'
        pkg.write_text(json.dumps({'version': '0.2.2-rc.2'}))
        script = script.replace('/usr/local/lib/node_modules/@deepseek-ai/dsh/package.json', str(pkg))
        script = script.replace('/usr/local/bin/dsh-entrypoint', str(self.script))
        self.script.chmod(0o755)
        return subprocess.run([self.node, '-e', script, domain], capture_output=True,
                              text=True, timeout=15)

    def test_probe_accepts_patched_modern_and_legacy_layouts(self):
        for names, base in ((MODERN, 0), (LEGACY, 1)):
            with self.subTest(names=names):
                files = self.fixture(names, base)
                if base:
                    for old in self.bases[0].iterdir():
                        old.unlink()
                patched = self.patch()
                self.assertEqual(patched.returncode, 0, patched.stderr)
                result = self.probe('NAS.Example.Com')
                self.assertEqual(result.returncode, 0, result.stderr)
                for file in files:
                    self.assertIn(file.name + '=patched,domain-ok', result.stdout)

    def test_probe_checks_syntax_even_when_patch_disabled(self):
        files = self.fixture()
        self.assertEqual(self.probe('').returncode, 0)
        files[-1].write_text(SOURCE + '\nconst broken = ;')
        result = self.probe('')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('语法校验失败', result.stderr)
        self.assertIn(str(files[-1]), result.stderr)

    def test_probe_refuses_cross_directory_bundle_set(self):
        self.fixture(('client.browser.js',), 0)
        self.fixture(('client.node.js', 'index.js'), 1)
        result = self.probe('')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('拒绝跨目录拼接', result.stderr)

    def test_probe_uses_complete_hoisted_set_after_partial_nested_set(self):
        self.fixture(('client.browser.js',), 0, 'const broken = ;')
        self.fixture(MODERN, 1)
        result = self.probe('')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('bundle-base=' + str(self.bases[1]), result.stdout)

    def test_probe_rejects_old_comment_and_false_positive_markers(self):
        safe = ' if (hostname === "nas.example.com") return true; /* dsh-nas: trusted-domain patch */\n'
        sources = {
            'old-line-comment': SOURCE.replace('{if', '{ if (hostname === "nas.example.com") return true; // dsh-nas: trusted-domain patch\nif'),
            'marker-outside-function': SOURCE + '\n/* dsh-nas: trusted-domain patch nas.example.com */',
            'wrong-domain': SOURCE.replace('{if', '{' + safe.replace('nas.example.com', 'wrong.example.com') + 'if'),
            'duplicate-marker': SOURCE.replace('{if', '{' + safe + 'if') + '\n/* dsh-nas: trusted-domain patch */',
            'missing-patch': SOURCE,
        }
        for label, source in sources.items():
            with self.subTest(label=label):
                self.fixture(source=source)
                result = self.probe()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('补丁结构校验失败', result.stderr)

    def test_probe_rejects_patch_when_disabled(self):
        self.fixture()
        patched = self.patch()
        self.assertEqual(patched.returncode, 0, patched.stderr)
        result = self.probe('')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('未启用 patch 但发现补丁标记', result.stderr)
