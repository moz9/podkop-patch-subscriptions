import pathlib
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'openwrt/podkop-dns-apply'


class DnsContinuation(unittest.TestCase):
    def run_shell(self, script, *args):
        return subprocess.run(['sh', '-c', 'PODKOP_DNS_APPLY_LIBRARY_ONLY=1; . "$1"; shift; ' + script,
                               'test', str(SOURCE), *map(str, args)], capture_output=True, text=True)

    def test_drift_uses_exact_graph_for_new_pair(self):
        r = self.run_shell('''
DA_SAVED=0; DA_EXPLICIT=0
uci() { return 0; }
podkop_section_context_matches() { return 1; }
dns_apply_saved_requested() { return 1; }
dns_apply_select_context || exit 1
printf '%s:%s' "$DA_SAVED" "$DA_EXPLICIT"
''')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, '1:1')

    def test_pending_draft_is_not_committed(self):
        r = self.run_shell('''
DA_SAVED=0; DA_EXPLICIT=0
uci() { echo 'podkop.settings.dns_server=draft'; }
podkop_section_context_matches() { return 1; }
dns_apply_saved_requested() { return 1; }
dns_apply_select_context
''')
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('not found', r.stderr)

    def test_matching_context_keeps_normal_transaction(self):
        r = self.run_shell('''
DA_SAVED=0; DA_EXPLICIT=0
uci() { return 0; }
podkop_section_context_matches() { return 0; }
dns_apply_select_context || exit 1
printf '%s:%s' "$DA_SAVED" "$DA_EXPLICIT"
''')
        self.assertEqual((r.returncode, r.stdout), (0, '0:0'), r.stderr)

    def test_saved_tuple_keeps_journal_preserving_mode(self):
        r = self.run_shell('''
DA_SAVED=0; DA_EXPLICIT=0
uci() { echo 'podkop.main.draft=1'; }
dns_apply_saved_requested() { return 0; }
dns_apply_select_context || exit 1
printf '%s:%s' "$DA_SAVED" "$DA_EXPLICIT"
''')
        self.assertEqual((r.returncode, r.stdout), (0, '1:0'), r.stderr)

    def test_patch_rejects_injection_and_ambiguous_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / 'podkop'
            output = pathlib.Path(directory) / 'out'
            source.write_text("config settings 'settings'\n")
            for value in ("bad'host", 'bad\\host', 'bad\nhost'):
                r = self.run_shell('dns_apply_patch_primary "$1" doh "$3" udp 77.88.8.1 "$2"', source, output, value)
                self.assertNotEqual(r.returncode, 0, value)
            source.write_text("config settings 'settings'\n" * 2)
            r = self.run_shell('dns_apply_patch_primary "$1" doh dns.google udp 77.88.8.1 "$2"', source, output)
            self.assertNotEqual(r.returncode, 0)

    def test_explicit_write_is_atomic_and_never_calls_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            p = pathlib.Path(directory)
            (p / 'config').write_text('old\n')
            (p / 'primary.new').write_text('verified candidate\n')
            r = self.run_shell('''
DA_WORK="$1"; DA_UCI="$1/config"; DA_EXPLICIT=1
uci() { exit 98; }
dns_apply_pending_unchanged() { return 0; }
dns_apply_saved_requested() { return 0; }
config_load() { return 0; }
dns_apply_uci_set
''', p)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual((p / 'config').read_text(), 'verified candidate\n')
            self.assertTrue((p / 'committed-uci.sha').read_text().strip())

    def test_changed_input_prevents_explicit_write(self):
        with tempfile.TemporaryDirectory() as directory:
            p = pathlib.Path(directory)
            (p / 'config').write_text('old\n')
            (p / 'primary.new').write_text('candidate\n')
            r = self.run_shell('''
DA_WORK="$1"; DA_UCI="$1/config"; DA_EXPLICIT=1
dns_apply_pending_unchanged() { return 1; }
dns_apply_uci_set
''', p)
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual((p / 'config').read_text(), 'old\n')

    def test_primary_patch_preserves_all_unrelated_text(self):
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / 'podkop'
            output = pathlib.Path(directory) / 'out'
            original = "config settings 'settings'\n\toption dns_type 'udp'\n\toption dns_server '1.1.1.1'\n\toption bootstrap_dns_server '77.88.8.8'\n\toption log_level 'warn'\nconfig section 'main'\n\tlist subscription_required_services 'gemini'\n"
            source.write_text(original)
            r = self.run_shell('dns_apply_patch_primary "$1" doh dns.google udp 77.88.8.1 "$2"', source, output)
            self.assertEqual(r.returncode, 0, r.stderr)
            changed = output.read_text()
            self.assertIn("option dns_server 'dns.google'", changed)
            self.assertIn("option bootstrap_dns_server '77.88.8.1'", changed)
            self.assertIn("option log_level 'warn'", changed)
            self.assertIn("config section 'main'\n\tlist subscription_required_services 'gemini'\n", changed)
            self.assertEqual(changed.count('option dns_type'), 1)

    def test_explicit_continuation_restore_restores_uci_not_context(self):
        with tempfile.TemporaryDirectory() as directory:
            p = pathlib.Path(directory)
            (p / 'before.1').write_text('old dns and filters\n')
            (p / 'config').write_text('new dns and filters\n')
            (p / 'before.2').write_text('old context\n')
            (p / 'context').write_text('unchanged context\n')
            (p / 'files').write_text(f'1|uci|{p / "config"}\n2|context|{p / "context"}\n')
            r = self.run_shell('''
DA_WORK="$1"; DA_UCI="$1/config"; DA_SAVED=1; DA_EXPLICIT=1
dns_apply_uci_clear_staged() { return 0; }
config_load() { return 0; }
dns_apply_activate() { return 0; }
dns_apply_live_ready() { return 0; }
dns_apply_continuity_validate() { return 0; }
dns_apply_pending_unchanged() { return 0; }
dns_apply_restore
''', p)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual((p / 'config').read_text(), 'old dns and filters\n')
            self.assertEqual((p / 'context').read_text(), 'unchanged context\n')

