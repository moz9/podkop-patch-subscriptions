import hashlib
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'u').read_text().split('# DISPATCH_MAIN')[0]

class Dispatch(unittest.TestCase):
    def test_routes(self):
        for version, engine, expected in [('', 'none', 'fresh'), ('0.7.22', 'stock', 'legacy'), ('0.7.24', 'stock', 'migrate'), ('0.7.24', 'pe', 'pe')]:
            p = subprocess.run(['sh', '-c', SOURCE + '\nselect_route "$1" "$2"', 'test', version, engine], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stdout.strip(), expected)

    def test_unknown_combinations_are_not_migrated(self):
        for version, engine in [('0.7.23', 'stock'), ('0.8.0', 'stock'), ('0.7.22', 'pe'), ('', 'pe')]:
            p = subprocess.run(['sh', '-c', SOURCE + '\nselect_route "$1" "$2"', 'test', version, engine], capture_output=True)
            self.assertNotEqual(p.returncode, 0)

    def test_download_tamper_cannot_execute(self):
        with tempfile.TemporaryDirectory() as d:
            marker = pathlib.Path(d) / 'executed'
            # Stub network download only; real sha256sum must reject these bytes.
            body = SOURCE + '\ncurl() { for last; do :; done; printf "touch %s\\n" "$MARKER" > "$last"; }\n'
            body += 'MARKER="$1"; export MARKER; download_run pinned i ' + '0' * 64
            p = subprocess.run(['sh', '-c', body, 'test', str(marker)], capture_output=True)
            self.assertNotEqual(p.returncode, 0)
            self.assertFalse(marker.exists())

    def test_public_entry_pins_dispatcher(self):
        self.assertIn(hashlib.sha256((ROOT / 'u').read_bytes()).hexdigest(), (ROOT / 'i').read_text())

    def test_existing_pe_delivers_verified_hotfix(self):
        branch = SOURCE.split('      pe)')[1].split('        ;;')[0]
        self.assertIn(' pe-update ', branch)
        self.assertNotIn('already installed; no changes', branch)

if __name__ == '__main__':
    unittest.main()
