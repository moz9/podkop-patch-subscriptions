import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const source = fs.readFileSync(new URL('../openwrt/settings.js', import.meta.url), 'utf8');
function render(features) {
  let api;
  const options = new Map();
  const context = vm.createContext({
    form: { Value: 1, ListValue: 2, MultiValue: 3, Flag: 4, DummyValue: 5, DynamicList: 6 },
    widgets: { DeviceSelect: 7, NetworkSelect: 8 }, _: value => value,
    uci: { get() {}, set() { throw new Error('render mutated UCI'); } },
    baseclass: { extend(value) { api = value; } },
    document: { getElementById() { return null; }, createElement() { return {}; }, head: { appendChild() {} } },
    main: { DNS_SERVER_OPTIONS: {}, BOOTSTRAP_DNS_SERVER_OPTIONS: {}, UPDATE_INTERVAL_OPTIONS: {},
      getDnsServerOptionsForType() { return {}; }, DNS_SUPPORTED_PROTOCOLS: ['udp', 'tcp', 'doh', 'dot'],
      getClashUIUrl() { return 'http://example.test'; } },
    dnsBenchmark: { renderOpenButton() {} },
  });
  vm.runInContext('(function(){' + source + '\n})()', context);
  const section = { tab() {}, taboption(tab, type, name) {
    const option = { tab, type, value() {}, depends() {} };
    options.set(name, option);
    return option;
  } };
  api.createSettingsContent(section, features);
  return options;
}
test('uTLS fallback toggle appears only with exact engine capability and defaults off', () => {
  for (const features of [undefined, [], ['tls.utls']]) {
    assert.equal(render(features).has('enable_utls_fallback'), false);
  }
  const flag = render(['tls.utls-fallback']).get('enable_utls_fallback');
  assert.ok(flag, 'supported engine must expose toggle');
  assert.equal(flag.type, 4);
  assert.equal(flag.tab, 'service');
  assert.equal(flag.default, '0');
  assert.equal(flag.rmempty, false);
});
