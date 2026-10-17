import pathlib
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'openwrt/podkop-service-checks.sh'


class ServiceContext(unittest.TestCase):
    def context(self, setting='udp', dns='1.1.1.1', udp='0'):
        with tempfile.TemporaryDirectory() as tmp:
            config = pathlib.Path(tmp) / 'runtime.json'
            config.write_text('{"dns":{"servers":[{"type":"udp","server":"' + dns + '"}]}}')
            r = subprocess.run(['sh', '-c', '''
. "$1"
config_get() { eval "$1=\\\"$UDP\\\""; }
podkop_section_logical_path() { printf '%s' "$CONFIG"; }
jq() { if [ "$3" = /etc/sing-box/config.json ]; then command jq "$1" "$2" "$CONFIG"; else command jq "$@"; fi; }
uci() { printf "podkop.settings.dns_type='%s'\\n" "$SETTING"; }
CONFIG="$2"; SETTING="$3"; UDP="$4"
subscription_services_context main
''', 'test', str(SOURCE), str(config), setting, udp], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            return r.stdout.strip()

    def test_saved_dns_choice_does_not_invalidate_actual_probe(self):
        self.assertEqual(self.context('udp'), self.context('doh'))

    def test_actual_dns_change_preserves_node_observation(self):
        self.assertEqual(self.context(dns='1.1.1.1'), self.context(dns='8.8.8.8'))

    def test_probe_transport_change_invalidates(self):
        self.assertNotEqual(self.context(udp='0'), self.context(udp='1'))

