import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const read = name => fs.readFileSync(new URL('../openwrt/' + name, import.meta.url), 'utf8');
const entry = read('podkop.js');
assert.match(entry, /podkopMap\.section\(\s*form\.GridSection,\s*"section"/, 'legacy sections use a compact GridSection');
assert.doesNotMatch(entry, /sectionsSection\.template\s*=\s*"cbi\/simpleform"/);
assert.doesNotMatch(entry, /getSingBoxFeatures|Podkop Enhanced|Podkop PE/, 'legacy branding and RPC contract stay unchanged');
const pageScope = entry.indexOf('document.body.classList.add("pdk-page")');
assert.ok(pageScope >= 0 && pageScope < entry.indexOf('main.injectGlobalStyles()'), 'page scope is installed before styles');

const configs = {
  alpha: {connection_type: 'proxy', proxy_config_type: 'subscription_urltest',
    subscription_url: ['https://user:password@secret.example/list'],
    urltest_proxy_links: ['vless://secret@node.example:443'],
    subscription_selection_mode: 'selected', subscription_selected_link_ids: ['one', 'two'],
    community_lists: ['youtube', 'telegram'], remote_domain_lists: ['https://secret.example/domains']},
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
  main: {DNS_SERVER_OPTIONS: {}, DOMAIN_LIST_OPTIONS: {}, REGIONAL_OPTIONS: [],
    validateProxyUrl: () => ({valid:true}), validateUrl: () => ({valid:true})},
  _: text => text,
});
vm.runInContext(`(function(){${read('section.js')}\n})()`, context);
exported.createSectionContent(section);
assert.deepEqual(tabs, [
  {id:'connection', title:'Подключение'}, {id:'checking', title:'Проверка узлов'},
  {id:'lists', title:'Списки'}, {id:'advanced', title:'Дополнительно'},
], 'all four editor tabs match PE');
const table = records.filter(row => row.placement === 'table');
const modal = records.filter(row => row.placement === 'modal');
assert.equal(table.length, 3, 'exactly three compact summary columns');
assert.deepEqual(table.map(row => row.key), ['_overview_type','_overview_sources','_overview_lists']);
assert.ok(table.every(row => row.type === 'DummyValue' && row.modalonly === false));
assert.ok(modal.every(row => row.modalonly === true), 'all editable fields are modal-only');
const groups = {
  connection: ['connection_type','proxy_config_type','proxy_string','subscription_url','subscription_update_interval',
    'outbound_json','selector_proxy_links','urltest_proxy_links','enable_udp_over_tcp','interface',
    'domain_resolver_enabled','domain_resolver_dns_type','domain_resolver_dns_server'],
  checking: ['urltest_check_interval','urltest_tolerance','urltest_testing_url'],
  lists: ['community_lists','user_domain_list_type','user_domains','user_domains_text','user_subnet_list_type',
    'user_subnets','user_subnets_text','local_domain_lists','local_subnet_lists','remote_domain_lists','remote_subnet_lists'],
  advanced: ['fully_routed_ips','mixed_proxy_enabled','mixed_proxy_port','resolve_real_ip_for_routing'],
};
assert.equal(modal.length, Object.values(groups).flat().length, 'no legacy option is lost or engine-only field added');
for (const [tab, keys] of Object.entries(groups)) for (const key of keys)
  assert.equal(modal.find(row => row.key === key)?.tab, tab, `${key} remains editable in the expected tab`);
const type = table.find(row => row.key === '_overview_type');
assert.equal(type.cfgvalue('beta'), 'VPN');
assert.equal(table.find(row => row.key === '_overview_sources').cfgvalue('beta'), 'Интерфейс: wg0');
const summary = table.map(row => row.cfgvalue('alpha')).join(' ');
assert.match(summary, /выбрано: 2/);
assert.doesNotMatch(summary, /secret|password|vless:\/\//, 'summary never leaks credentials');
const tolerance = modal.find(row => row.key === 'urltest_tolerance');
assert.equal(tolerance.validate('alpha','50'), true);
assert.equal(tolerance.validate('alpha','1000'), true);
assert.notEqual(tolerance.validate('alpha','49'), true);
assert.notEqual(tolerance.validate('alpha','50.5'), true);
assert.ok(modal.find(row => row.key === 'urltest_proxy_links').dependencies.some(args => args[1] === 'subscription_urltest'));
console.log('PASS: legacy compact safe GridSection and complete four-tab editor');
