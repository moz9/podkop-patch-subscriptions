import pathlib
import subprocess
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'openwrt/podkop-subscription-probe.sh'


class Readiness(unittest.TestCase):
    def run_probe(self, ready, alive=True, fractional=True):
        script = f'''
. '{SOURCE}'
tries=0
netstat() {{ [ "$tries" -ge {ready} ] && echo '127.0.0.1:43000 '; }}
kill() {{ {'return 0' if alive else 'return 1'}; }}
sleep() {{
    [ "$1" != 0 ] || return 0
    {'return 0' if fractional else '[ "$1" != 0.0 ]'}
}}
subscription_probe_wait_listener 123 43000
rc=$?
echo "$rc:$tries:$SUBSCRIPTION_PROBE_ERROR"
'''
        return subprocess.run(['sh', '-c', script], capture_output=True, text=True).stdout.strip()

    def test_ready_immediately(self):
        self.assertEqual(self.run_probe(0), '0:0:')

    def test_ready_on_second_poll(self):
        self.assertEqual(self.run_probe(1), '0:1:')

    def test_dead_child(self):
        self.assertEqual(self.run_probe(1, alive=False), '1:0:probe_start_failed')

    def test_bounded_timeout(self):
        self.assertEqual(self.run_probe(51), '1:50:probe_listener_timeout')

    def test_integer_sleep_fallback(self):
        self.assertEqual(self.run_probe(6, fractional=False), '1:5:probe_listener_timeout')


if __name__ == '__main__':
    unittest.main()
