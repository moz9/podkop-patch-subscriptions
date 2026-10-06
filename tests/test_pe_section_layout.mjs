import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const read = name => fs.readFileSync(new URL('../openwrt/' + name, import.meta.url), 'utf8');
const entry = read('podkop.js');
assert.match(entry, /podkopMap\.section\(\s*form\.GridSection,\s*"section"/, 'sections use LuCI grid with per-row modal');
assert.doesNotMatch(entry, /sectionsSection\.template\s*=\s*"cbi\/simpleform"/, 'grid must not retain full-page section template');

const configs = {
  alpha: {
    connection_type: 'proxy', proxy_config_type: 'subscription_urltest',
    subscription_url: ['https://user:password@secret.example/list'],
    urltest_proxy_links: ['vless://secret@node.example:443'],
    subscription_selection_mode: 'selected', subscription_selected_link_ids: ['one', 'two'],
    community_lists: ['youtube', 'telegram'], remote_domain_lists: ['https://secret.example/domains'],
  },
  beta: {connection_type: 'vpn', interface: 'wg0'},
};
const records = [], tabs = [];
const makeOption = (placement, tab, type, key, title) => {
  const row = {placement, tab, type, key, title, dependencies: [], values: [],
    depends(...args) { this.dependencies.push(args); }, value(...args) { this.values.push(args); }};
  records.push(row);
  return row;
};
const section = {
  tab(id, title) { tabs.push({id, title}); },
  option(type, key, title) { return makeOption('table', null, type, key, title); },
  taboption(tab, type, key, title) { return makeOption('modal', tab, type, key, title); },
};
let exported;
const context = vm.createContext({
  baseclass: {extend: value => (exported = value)},
  form: Object.fromEntries(['ListValue','DynamicList','TextValue','Value','Flag','DummyValue'].map(x => [x, x])),
  widgets: {DeviceSelect: 'DeviceSelect'},
  uci: {get: (_config, id, key) => configs[id]?.[key]},
  main: {URLTEST_DOWNLOAD_URL_OPTIONS: {}, DNS_SERVER_OPTIONS: {}, DOMAIN_LIST_OPTIONS: {},
    REGIONAL_OPTIONS: [], validateProxyUrl: () => ({valid:true}), validateUrl: () => ({valid:true})},
  _: text => text,
});
vm.runInContext(`(function(){${read('section.js')}\n})()`, context);
exported.createSectionContent(section, ['urltest.fallbacks', 'urltest.download_url']);

assert.ok(tabs.length >= 3, 'modal groups fields into several tabs');
assert.ok(tabs.every(tab => /[А-Яа-яЁё]/.test(tab.title)), 'tab labels are Russian');
const table = records.filter(row => row.placement === 'table');
const modal = records.filter(row => row.placement === 'modal');
assert.ok(table.length >= 2 && table.length <= 5, 'table has a small number of summary columns');
assert.ok(!table.some(row => row.key === '_overview_id'), 'native section name is not duplicated');
assert.ok(table.every(row => row.type === 'DummyValue' && row.modalonly === false), 'summary columns are read-only and table-only');
assert.ok(modal.every(row => row.modalonly === true), 'every editable field is hidden from grid table and shown only in modal');
for (const key of ['connection_type','proxy_config_type','subscription_url','urltest_proxy_links',
  'urltest_fallback_links','urltest_download_check','urltest_download_url','community_lists',
  'user_domains','local_domain_lists','remote_domain_lists','fully_routed_ips','mixed_proxy_enabled']) {
  const field = modal.find(row => row.key === key);
  assert.ok(field, `${key} remains editable in modal`);
  assert.ok(tabs.some(tab => tab.id === field.tab), `${key} assigned to a real tab`);
}
const type = table.find(row => row.key === '_overview_type');
const sources = table.find(row => row.key === '_overview_sources');
assert.equal(type.cfgvalue('beta').includes('VPN'), true, 'VPN is summarized by connection type');
const summary = [type.cfgvalue('alpha'), sources.cfgvalue('alpha'), ...table.map(row => row.cfgvalue('alpha'))].join(' ');
assert.match(summary, /2/, 'selection count is visible');
assert.doesNotMatch(summary, /secret|password|vless:\/\//, 'summary never prints subscription or proxy credentials');
const fallback = modal.find(row => row.key === 'urltest_fallback_links');
assert.ok(fallback.dependencies.some(args => args[0] === 'proxy_config_type' && args[1] === 'subscription_urltest'));
assert.ok(modal.find(row => row.key === 'urltest_download_url').dependencies.some(args => args[0]?.urltest_download_check === 'custom'));
console.log('PASS: PE sections render as compact safe grid with tabbed modal fields');
