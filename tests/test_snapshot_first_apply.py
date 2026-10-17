import pathlib
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'openwrt/podkop-service-snapshot.sh'


class FirstApply(unittest.TestCase):
    def stage(self, peers='main', valid=1):
        with tempfile.TemporaryDirectory() as tmp:
            script = f'''
. '{SOURCE}'
PODKOP_SERVICE_SNAPSHOT_DIR='{tmp}/saved'
mkdir '{tmp}/work'
config_foreach() {{ for s in {peers}; do "$1" "$s"; done; }}
validate_subscription_urltest_section() {{ return 0; }}
subscription_required_services_json() {{ echo '["gemini"]'; }}
subscription_services_preflight_section() {{ [ {valid} = 1 ] || SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED=1; }}
subscription_services_snapshot_section() {{ echo '{{"section":"main","admittedIds":["one"]}}' >> "$SNAPSHOT_SECTIONS"; }}
subscription_services_snapshot_section_stage main '{tmp}/work'
'''
            return subprocess.run(['sh', '-c', script], capture_output=True).returncode

    def test_first_target_with_valid_evidence(self):
        self.assertEqual(self.stage(), 0)

    def test_unknown_peer_not_blessed(self):
        self.assertNotEqual(self.stage('main peer'), 0)

    def test_failed_evidence_rejected(self):
        self.assertNotEqual(self.stage(valid=0), 0)

    def test_initial_commit_rejects_changed_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = f'''
. '{SOURCE}'
PODKOP_SERVICE_SNAPSHOT_DIR='{tmp}/saved'
mkdir '{tmp}/work'
: > '{tmp}/work/snapshot-initial'
echo '{{"section":"main","admittedIds":["one"]}}' > '{tmp}/work/snapshot-target.jsonl'
subscription_services_snapshot_section() {{ echo '{{"section":"main","admittedIds":["two"]}}' >> "$SNAPSHOT_SECTIONS"; }}
subscription_services_snapshot_save() {{ touch '{tmp}/unsafe-save'; }}
subscription_services_snapshot_section_commit main '{tmp}/work'
'''
            self.assertNotEqual(subprocess.run(['sh', '-c', script]).returncode, 0)
            self.assertFalse(pathlib.Path(tmp, 'unsafe-save').exists())

if __name__ == '__main__':
    unittest.main()
