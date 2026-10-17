import pathlib
import os
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'pe-migrate').read_text().split('# MIGRATION_MAIN')[0]

class Plans(unittest.TestCase):
    def test_failover_upgrade_preserves_bounded_diagnostic_fallback(self):
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / 'podkop'
            target.write_bytes((ROOT / 'openwrt/runtime-0.7.24/usr/bin/podkop').read_bytes())
            env = dict(os.environ, PODKOP_DNS_FAILOVER_TARGET=str(target), PODKOP_DNS_FAILOVER_SHELL='sh')
            script = str(ROOT / 'openwrt/podkop-dns-failover-upgrade.sh')
            subprocess.run(['sh', script], env=env, check=True)
            subprocess.run(['sh', '-n', str(target)], check=True)
            content = target.read_bytes()
            subprocess.run(['sh', script], env=env, check=True)
            self.assertEqual(content, target.read_bytes())
            self.assertIn(b'config_get dns_type "settings" "dns_type"', content)

    def check(self, text):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / 'plan'
            p.write_text(text)
            return subprocess.run(['sh', '-c', SOURCE + '\nplan_check "$1" sing-box podkop-engine', 'test', str(p)], capture_output=True).returncode

    def test_real_apk_advisory_is_not_an_upgrade_action(self):
        self.assertEqual(self.check('NOTE: Consider running apk upgrade with --prune and/or --available.\n(1/2) Purging sing-box (1.13.21-r1)\n(2/2) Installing podkop-engine (1.14.2-r14)\n'), 0)

    def test_no_dependency_removal(self):
        self.assertNotEqual(self.check('(1/3) Purging sing-box (1.13.21-r1)\n(2/3) Purging kmod-inet-diag (6.12.94-r1)\n(3/3) Installing podkop-engine (1.14.2-r14)\n'), 0)

    def test_no_podkop_removal(self):
        self.assertNotEqual(self.check('(1/3) Purging sing-box (1.13.21-r1)\n(2/3) Purging podkop (0.7.24-r1)\n(3/3) Installing podkop-engine (1.14.2-r14)\n'), 0)

    def test_no_unrelated_upgrade(self):
        self.assertNotEqual(self.check('(1/3) Purging sing-box (1.13.21-r1)\n(2/3) Upgrading libc (1 -> 2)\n(3/3) Installing podkop-engine (1.14.2-r14)\n'), 0)

    def test_no_empty_or_failed_plan(self):
        for text in ['', 'ERROR: conflict\n', '(1/2) Purging sing-box (1.13.21-r1)\n']:
            self.assertNotEqual(self.check(text), 0)

if __name__ == '__main__':
    unittest.main()
