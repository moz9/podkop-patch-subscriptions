import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'openwrt/podkop-dns-benchmark').read_text()
FUNCTION = SOURCE.split('db_fast_context() {', 1)[1].split('\n}\n', 1)[0]


class ContextTest(unittest.TestCase):
    def check_context(self, native, expected):
        script = '''
db_runtime_safe() { return 0; }
db_busy() { return 1; }
db_fingerprint() { printf '%%s' "${1:-full}"; }
DB_DIR=/nonexistent
db_deadline=9999999999
db_native_mode=%s
db_fast_context() {%s
}
db_fast_context %s
''' % (native, FUNCTION, expected)
        return subprocess.run(['sh', '-c', script], capture_output=True).returncode

    def test_native_uses_ordering_identity(self):
        self.assertEqual(self.check_context(1, 'ordering'), 0)

    def test_pair_uses_full_identity(self):
        self.assertEqual(self.check_context(0, 'full'), 0)

    def test_real_change_still_rejected(self):
        self.assertNotEqual(self.check_context(1, 'changed'), 0)
        self.assertNotEqual(self.check_context(0, 'changed'), 0)


if __name__ == '__main__':
    unittest.main()
