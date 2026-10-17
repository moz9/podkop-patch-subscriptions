"""Bounded Linux fixture tests; no package binaries/installers are executed."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FreshCandidateTests(unittest.TestCase):
    def run_function(self, body):
        source = (ROOT / 'i').read_text().split('# CANDIDATE_MAIN')[0]
        with tempfile.TemporaryDirectory() as td:
            lib = Path(td) / 'lib.sh'
            lib.write_text(source)
            return subprocess.run(['sh', '-c', '. "$LIB"; ' + body], text=True,
                                  capture_output=True, env=dict(os.environ, LIB=str(lib), CASE_TMP=td))

    def test_fresh_and_exact_existing_only(self):
        for values, wanted in [('"" "" ""', 'fresh'),
                               ('0.7.24-r1 0.7.24-r1 1.14.2-r14', 'existing')]:
            r = self.run_function('candidate_mode ' + values)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.strip(), wanted)

    def test_partial_or_legacy_rejected(self):
        for values in ['0.7.22-r1 0.7.22-r1 ""', '0.7.24-r1 "" ""',
                       '"" "" 1.14.2-r14', '0.7.24-r1 0.7.24-r1 1.14.2-r13']:
            self.assertNotEqual(self.run_function('candidate_mode ' + values).returncode, 0)

    def test_platform_exact(self):
        good = '25.12.5 aarch64_cortex-a53 aarch64 redmi,ax6'
        self.assertEqual(self.run_function('candidate_platform ' + good).returncode, 0)
        for bad in ['25.12.4 aarch64_cortex-a53 aarch64 redmi,ax6',
                    '25.12.5 x86_64 x86_64 redmi,ax6',
                    '25.12.5 aarch64_cortex-a53 aarch64 other,router']:
            self.assertNotEqual(self.run_function('candidate_platform ' + bad).returncode, 0)

    def test_hash_failure_blocks_next_step(self):
        r = self.run_function('printf changed > "$CASE_TMP/file"; candidate_hash "' + 'a'*64 +
                              '" "$CASE_TMP/file"; printf MUTATED')
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('MUTATED', r.stdout)

    def test_dependency_simulation_failure_blocks_add(self):
        r = self.run_function('apk() { return 42; }; candidate_simulate "$CASE_TMP/plan" jq; printf MUTATED')
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('MUTATED', r.stdout)

    def test_upgrade_plan_is_rejected(self):
        r = self.run_function('apk() { printf "(1/2) Upgrading libc (1 to 2)\\n"; }; '
                              'candidate_simulate "$CASE_TMP/plan" jq; printf MUTATED')
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('MUTATED', r.stdout)

    def test_fresh_install_plan_allowed(self):
        r = self.run_function('apk() { printf "(1/2) Installing jq (1.8.1-r2)\\nOK: 80 packages\\n"; }; '
                              'candidate_simulate "$CASE_TMP/plan" jq; printf ACCEPTED')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('ACCEPTED', r.stdout)

    def test_service_uid_conflict_rejected(self):
        r = self.run_function('printf "someone:x:5566:5566::/:/bin/false\\n" > "$CASE_TMP/passwd"; '
                              'printf "sing-box:x:5566:\\n" > "$CASE_TMP/group"; '
                              'candidate_account_check "$CASE_TMP/passwd" "$CASE_TMP/group"; printf MUTATED')
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('MUTATED', r.stdout)

    def test_exact_service_account_accepted(self):
        r = self.run_function('printf "sing-box:x:5566:5566::/:/bin/false\\n" > "$CASE_TMP/passwd"; '
                              'printf "sing-box:x:5566:\\n" > "$CASE_TMP/group"; '
                              'candidate_account_check "$CASE_TMP/passwd" "$CASE_TMP/group"; printf ACCEPTED')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('ACCEPTED', r.stdout)

    def test_database_query_failure_is_not_fresh(self):
        r = self.run_function('apk() { return 33; }; candidate_package_version podkop; printf MUTATED')
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('MUTATED', r.stdout)

    def test_duplicate_package_record_rejected(self):
        r = self.run_function('apk() { printf "podkop 0.7.24-r1\\npodkop 0.7.22-r1\\n"; }; '
                              'candidate_package_version podkop; printf MUTATED')
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('MUTATED', r.stdout)


if __name__ == '__main__':
    unittest.main()
