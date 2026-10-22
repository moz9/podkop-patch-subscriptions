import hashlib
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'u').read_text().split('# DISPATCH_MAIN')[0]

class Dispatch(unittest.TestCase):
    def test_routes(self):
        for version, engine, expected in [('', 'none', 'fresh'), ('0.7.22', 'stock', 'legacy'), ('0.7.23', 'pe', 'pe023'), ('0.7.24', 'stock', 'migrate'), ('0.7.24', 'pe', 'pe')]:
            p = subprocess.run(['sh', '-c', SOURCE + '\nselect_route "$1" "$2"', 'test', version, engine], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stdout.strip(), expected)

    def test_unknown_combinations_are_not_migrated(self):
        for version, engine in [('0.7.23', 'stock'), ('0.8.0', 'stock'), ('0.7.22', 'pe'), ('', 'pe')]:
            p = subprocess.run(['sh', '-c', SOURCE + '\nselect_route "$1" "$2"', 'test', version, engine], capture_output=True)
            self.assertNotEqual(p.returncode, 0)

    def test_patch_only_cannot_install_or_migrate(self):
        self.assertIn('require_patch_route "$route" "${PODKOP_PATCH_UPDATE_PODKOP:-1}"', SOURCE)
        for route in ['legacy', 'pe023', 'pe', 'fresh', 'migrate']:
            for mode in ['0', '1']:
                p = subprocess.run(['sh', '-c', SOURCE + '\nrequire_patch_route "$1" "$2"', 'test', route, mode], capture_output=True, text=True)
                allowed = mode != '0' or route in ['legacy', 'pe023', 'pe']
                self.assertEqual(p.returncode == 0, allowed, f'{route}, mode {mode}: {p.stderr}')

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
        self.assertTrue(hashlib.sha256((ROOT / 'u').read_bytes()).hexdigest() in (ROOT / 'i').read_text(), 'public entry does not pin the exact dispatcher bytes')

    def test_existing_pe24_requires_confirmed_transaction(self):
        branch = SOURCE.split('      pe)')[1].split('        ;;')[0]
        self.assertIn('RouterDesk', branch)
        self.assertNotIn('download_run', branch)

    def test_pe23_keeps_its_base(self):
        self.assertIn('      pe023)', SOURCE, 'PE23 route is missing')
        branch = SOURCE.split('      pe023)')[1].split('        ;;')[0]
        self.assertIn('PODKOP_PATCH_UPDATE_PODKOP=0', branch)
        self.assertIn('PODKOP_PATCH_FORCE_PODKOP_UPDATE=0', branch)
        self.assertIn('download_run "$PODKOP_PATCH_VERSION" i ', branch)

    def test_public_entry_uses_requested_revision(self):
        entry = (ROOT / 'i').read_text()
        self.assertTrue('bootstrap_ref="${PODKOP_PATCH_VERSION:-main}"' in entry, 'public entry ignores the requested immutable revision')
        self.assertTrue('/$bootstrap_ref/u' in entry, 'dispatcher download is not revision-bound')

if __name__ == '__main__':
    unittest.main()
