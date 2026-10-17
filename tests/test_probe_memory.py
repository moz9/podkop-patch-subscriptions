import pathlib
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'openwrt/podkop-subscription-probe.sh'


class Memory(unittest.TestCase):
    def budget(self, available, active=0):
        with tempfile.TemporaryDirectory() as tmp:
            info = pathlib.Path(tmp, 'meminfo')
            info.write_text(f'MemTotal: 412196 kB\nMemAvailable: {available} kB\n')
            return subprocess.run(['sh', '-c', f'''
. '{SOURCE}'
PODKOP_SUBSCRIPTION_MEMINFO_FILE='{info}'
subscription_probe_resources services 1 {active}
''']).returncode

    def test_no_private_engine_with_small_reserve(self):
        self.assertNotEqual(self.budget(65536), 0)

    def test_ample_memory_allowed(self):
        self.assertEqual(self.budget(160000), 0)

    def test_active_child_keeps_working_reserve(self):
        self.assertNotEqual(self.budget(32768, 1), 0)

    def test_priority_only_in_private_child(self):
        result = subprocess.run(['sh', '-c', f'''
. '{SOURCE}'
before=$(cat /proc/self/oom_score_adj)
( subscription_probe_private_priority && exec cat /proc/self/oom_score_adj )
after=$(cat /proc/self/oom_score_adj)
[ "$before" = "$after" ]
'''], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), '1000')


if __name__ == '__main__':
    unittest.main()
