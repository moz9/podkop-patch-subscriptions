import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'openwrt/podkop-dns-benchmark').read_text()
FUNCTION = SOURCE.split('db_fast_context() {', 1)[1].split('\n}\n', 1)[0]
PAIR_FUNCTION = SOURCE.split('db_pair_test() {', 1)[1].split('\n}\n', 1)[0]


class ContextTest(unittest.TestCase):
    def test_engine_identity_does_not_start_engine_or_require_probe_memory(self):
        body = SOURCE.split('db_engine_identity() (', 1)[1].split('\n)\n', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            engine = pathlib.Path(directory) / 'engine'
            engine.write_text('#!/bin/sh\nexit 99\n')
            engine.chmod(0o755)
            script = 'DB_BIN="$1"; db_resource_admit() { return 1; }; db_engine_identity() (' + body + '\n)\ndb_engine_identity'
            first = subprocess.run(['sh', '-c', script, 'test', str(engine)], capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            engine.write_text('#!/bin/sh\nexit 98\n')
            second = subprocess.run(['sh', '-c', script, 'test', str(engine)], capture_output=True, text=True)
            self.assertEqual(second.returncode, 0)
            self.assertNotEqual(first.stdout, second.stdout)

    def check_pair_context(self, busy_at=0, changed=False):
        with tempfile.TemporaryDirectory() as directory:
            script = r'''
DB_DIR="$1"; DB_PROOF="$1/proof"; DB_STATUS="$1/status"; DB_REPORT="$1/report"
busy_count=0
db_pair_object() { printf '{"success":false}'; }
db_state() { printf '%s\n' "$7" > "$DB_STATUS"; }
db_check_pair() { touch "$DB_DIR/checked"; db_pair_json='{"success":true}'; }
db_busy() { busy_count=$((busy_count+1)); [ "$busy_count" -eq "$busy_at" ]; }
db_write_proof() { touch "$DB_PROOF"; }
db_runtime_safe() { return 0; }
busy_at="$2"
changed="$3"
db_fingerprint() { if [ -f "$DB_DIR/checked" ] && [ "$changed" = changed ]; then printf changed; else printf stable; fi; }
db_pair_test() {''' + PAIR_FUNCTION + r'''
}
db_pair_test doh id server bootstrap
cat "$DB_STATUS"
if [ -f "$DB_PROOF" ]; then printf 'proof\n'; fi
'''
            return subprocess.run(['sh', '-c', script, 'test', directory, str(busy_at),
                                   'changed' if changed else 'stable'],
                                  capture_output=True, text=True, check=True).stdout.strip()

    def test_pair_busy_before_proof_is_not_configuration_change(self):
        self.assertEqual(self.check_pair_context(busy_at=1), 'service_busy')

    def test_pair_busy_after_proof_removes_proof(self):
        self.assertEqual(self.check_pair_context(busy_at=2), 'service_busy')

    def test_pair_real_change_rejects_without_proof(self):
        self.assertEqual(self.check_pair_context(changed=True), 'configuration_changed')

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
