import json
import pathlib
import subprocess
import unittest
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'openwrt/podkop-service-checks.sh'


class GeminiMinimum(unittest.TestCase):
    def cache_case(self, action):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(['sh', '-c', '''
. "$1"
PODKOP_SERVICE_CACHE_DIR="$2"
subscription_services_context() { echo fixed; }
validate_subscription_section_name() { return 0; }
validate_subscription_link_id() { return 0; }
validate_subscription_urltest_section() { return 0; }
subscription_services_mark_pending() { return 0; }
subscription_runtime_busy() { return 1; }
subscription_action_lock_acquire() { return 0; }
subscription_action_lock_release() { return 0; }
get_subscription_items_cache_path() { echo "$PODKOP_SERVICE_CACHE_DIR/items"; }
printf '[{"id":"abc","supported":true}]' > "$2/items"
''' + action, 'test', str(SOURCE), tmp], capture_output=True, text=True)
            return result

    def test_captcha_opt_in_does_not_claim_chat_or_extend_expiry(self):
        r = self.cache_case('''
subscription_services_store main abc '{"gemini":{"state":"unknown","network":"pass","category":"captcha","reason":"captcha_required","manual":false}}'
before=$(jq '.results[0].services.gemini.expiresAt' "$2/main.json")
subscription_services_confirm main abc gemini captcha >/dev/null || exit 1
jq --argjson before "$before" '.results[0].services.gemini | {state,manual,reason,sameExpiry:(.expiresAt==$before)}' "$2/main.json"
''')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), dict(state='pass',manual=False,reason='captcha_allowed',sameExpiry=True))

    def test_generic_unknown_cannot_be_allowed_as_captcha(self):
        r = self.cache_case('''
subscription_services_store main abc '{"gemini":{"state":"unknown","network":"pass","category":"unknown","reason":"region_marker_missing"}}'
subscription_services_confirm main abc gemini captcha
''')
        self.assertNotEqual(r.returncode, 0)

    def test_latest_error_retains_history_without_admitting(self):
        r = self.cache_case('''
subscription_services_store main abc '{"gemini":{"state":"pass","network":"pass","reason":"region_precheck_passed"}}'
subscription_services_store main abc '{"gemini":{"state":"unknown","network":"fail","category":"node_error"}}'
subscription_services_read main
''')
        self.assertEqual(r.returncode, 0, r.stderr)
        proof=json.loads(r.stdout)[0]['services']['gemini']
        self.assertEqual(proof['state'], 'unknown')
        self.assertEqual(proof['lastSuccess']['reason'], 'region_precheck_passed')
        self.assertEqual(proof['expiresAt']-proof['checkedAt'], 300)

    def classify(self, rc, code, body, control='unknown'):
        result = subprocess.run(['sh', '-c', '. "$1"; subscription_services_classify gemini "$2" "$3" "$4" "$5"',
            'test', str(SOURCE), str(rc), str(code), body, control], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_captcha_is_unknown_not_denied(self):
        r = self.classify(0, 429, '<html>unusual traffic</html>')
        self.assertEqual((r['state'], r['category']), ('unknown', 'captcha'))

    def test_generic_forbidden_is_not_captcha(self):
        self.assertEqual(self.classify(0, 403, 'access denied')['category'], 'service_error')

    def test_control_distinguishes_service_from_node_failure(self):
        self.assertEqual(self.classify(28, 0, '', 'pass')['category'], 'service_error')
        self.assertEqual(self.classify(28, 0, '', 'fail')['category'], 'node_error')

    def test_plain_200_not_chat_proof(self):
        self.assertEqual(self.classify(0, 200, '<html>Gemini login</html>')['state'], 'unknown')

    def test_supported_marker_only_preliminary(self):
        r = self.classify(0, 200, '<html>Gemini ,2,1,200,"DEU"</html>')
        self.assertEqual((r['state'], r['category'], r['manual']), ('pass', 'preliminary', False))

    def test_cooldown_returns_cached_without_engine(self):
        result = subprocess.run(['sh', '-c', '''
. "$1"
validate_subscription_section_name() { return 0; }
validate_subscription_urltest_section() { return 0; }
validate_subscription_link_id() { return 0; }
subscription_services_read() { echo '[{"id":"abc","services":{"gemini":{"state":"unknown","category":"captcha","retryAfter":4102444800}}}]'; }
subscription_isolated_test() { echo engine_started; return 77; }
subscription_services_check main abc '["gemini"]'
''', 'test', str(SOURCE)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(json.loads(result.stdout)['cached'])


if __name__ == '__main__':
    unittest.main()
