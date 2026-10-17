import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class UpdateTest(unittest.TestCase):
    def run_helper(self, code, *args):
        return subprocess.run(['sh', '-c',
            'PE_UPDATE_LIBRARY_ONLY=1; . "$1"; shift; ' + code,
            'test', str(ROOT / 'pe-update'), *map(str, args)],
            capture_output=True, text=True)

    def test_replace_only_unique_complete_block(self):
        with tempfile.TemporaryDirectory() as directory:
            old = pathlib.Path(directory) / 'old'
            new = pathlib.Path(directory) / 'new'
            old.write_text('before\n# marker begin\nold\n# marker end\nafter\n')
            new.write_text('# marker begin\nnew\n# marker end\n')
            result = self.run_helper('pe_replace_block "$1" "$2" marker', old, new)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'before\n# marker begin\nnew\n# marker end\nafter\n')

    def test_refuse_duplicate_missing_or_reversed_markers(self):
        with tempfile.TemporaryDirectory() as directory:
            old = pathlib.Path(directory) / 'old'
            new = pathlib.Path(directory) / 'new'
            block = '# marker begin\nnew\n# marker end\n'
            new.write_text(block)
            for content in ('none\n', block + block, '# marker end\n# marker begin\n'):
                old.write_text(content)
                self.assertNotEqual(self.run_helper('pe_replace_block "$1" "$2" marker', old, new).returncode, 0)

    def test_exact_runtime_identity_only(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = pathlib.Path(directory) / 'podkop'
            runtime.write_text('# PODKOP_SUBSCRIPTIONS_PATCH_VERSION=20261017-pe-fastfix-v1-candidate\n')
            for podkop, engine, expected in (
                ('0.7.24', '1.14.2-pdk-r14', 0),
                ('0.7.23', '1.14.2-pdk-r14', 1),
                ('0.7.24', '1.14.2', 1),
            ):
                result = self.run_helper('pe_identity "$1" "$2" "$3"', runtime, podkop, engine)
                self.assertEqual(result.returncode, expected, result.stderr)
            runtime.write_text('# PODKOP_SUBSCRIPTIONS_PATCH_VERSION=other\n')
            self.assertNotEqual(self.run_helper('pe_identity "$1" 0.7.24 1.14.2-pdk-r14', runtime).returncode, 0)

    def test_rollback_restores_bytes_and_releases_owned_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            backup = root / 'backup'
            backup.mkdir()
            target = root / 'target'
            target.write_text('changed')
            (backup / '1').write_text('original')
            (root / 'targets').write_text(f'1|{target}\n')
            result = self.run_helper('''
pe_work="$1"; pe_backup="$1/backup"; pe_owned=1; pe_mutated=1
podkop_mutation_lock_release() { printf released; }
pe_finish 9
''', root)
            self.assertEqual(result.returncode, 9)
            self.assertEqual(target.read_text(), 'original')
            self.assertIn('released', result.stdout)

    def test_invalid_replacement_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            old = pathlib.Path(directory) / 'old'
            new = pathlib.Path(directory) / 'new'
            old.write_text('# marker begin\nold\n# marker end\n')
            new.write_text('# marker end\nnew\n# marker begin\n')
            self.assertNotEqual(self.run_helper('pe_replace_block "$1" "$2" marker', old, new).returncode, 0)

    def test_noop_requires_every_target_identical(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            target = root / 'target'
            target.write_text('same')
            target.chmod(0o755)
            (root / 'new.1').write_text('same')
            (root / 'targets').write_text(f'1|{target}\n')
            self.assertEqual(self.run_helper('pe_work="$1"; pe_unchanged', root).returncode, 0)
            target.write_text('different')
            self.assertNotEqual(self.run_helper('pe_work="$1"; pe_unchanged', root).returncode, 0)

    def test_noop_refuses_identical_bytes_with_broken_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            target = root / 'target'
            target.write_text('same')
            target.chmod(0o600)
            (root / 'new.1').write_text('same')
            (root / 'targets').write_text(f'1|{target}\n')
            self.assertNotEqual(self.run_helper('pe_work="$1"; pe_unchanged', root).returncode, 0)

    def test_stage_corrects_copy_reset_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / 'source'
            stage = root / 'stage'
            source.write_text('payload')
            source.chmod(0o600)
            stage.write_text('old')
            stage.chmod(0o755)
            result = self.run_helper('''
cp() { command cp "$@" && chmod 600 "$2"; }
pe_stage "$1" "$2" 1 "$(id -u):$(id -g)"
''', source, stage)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(stage.stat().st_mode & 0o7777, 0o755)
            self.assertEqual(stage.read_text(), 'payload')

    @unittest.skipUnless(shutil.which('busybox'), 'BusyBox unavailable')
    def test_busybox_stage_modes_for_executable_and_ui(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / 'source'
            stage = root / 'stage'
            source.write_text('payload')
            source.chmod(0o600)
            for index, mode in ((1, 0o755), (2, 0o755), (3, 0o644), (4, 0o644), (7, 0o755)):
                stage.write_text('old')
                stage.chmod(0o755)
                result = self.run_helper('''
cp() { busybox cp "$@"; }
pe_stage "$1" "$2" "$3" "$(id -u):$(id -g)"
''', source, stage, index)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(stage.stat().st_mode & 0o7777, mode)
                self.assertEqual(stage.read_text(), 'payload')


if __name__ == '__main__':
    unittest.main()
