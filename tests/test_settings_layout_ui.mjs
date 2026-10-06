import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const source = fs.readFileSync(new URL('../openwrt/settings.js', import.meta.url), 'utf8');

// Minimal DOM boundary reproducing LuCI Dropdown: transformItem() creates
// unchecked inputs; openDropdown() checks the selected ones only on opening.
// Selection markers, not those initially stale inputs, are the native value.
class Item {
  constructor(value, selected) {
    this.value = value;
    this.selected = selected;
    this.input = { checked: false, defaultChecked: false };
  }
  hasAttribute(name) { return name === 'selected' && this.selected; }
  getAttribute(name) { return name === 'data-value' ? this.value : null; }
  querySelector() { return this.input; }
}
class Dropdown {
  constructor(values, choices, options) {
    this.items = Object.keys(choices).map(key => new Item(key, values.includes(key)));
    this.options = options;
    this.listeners = {};
    this.classes = new Set();
    this.classList = { add: value => this.classes.add(value) };
    this.list = { querySelectorAll: () => this.items };
    this.firstChild = this.list;
  }
  render() { return this; }
  querySelectorAll() { return this.items; }
  querySelector() { return this.list; }
  insertBefore(child, before) { assert.equal(before, this.firstChild); this.summary = child; }
  addEventListener(name, callback) { (this.listeners[name] ||= []).push(callback); }
  emit(name) { for (const callback of this.listeners[name] || []) callback({ target: this }); }
  open() {
    for (const item of this.items) if (item.selected) item.input.checked = true;
    this.emit('cbi-dropdown-open');
  }
  select(value, checked) {
    const item = this.items.find(item => item.value === value);
    item.selected = item.input.checked = checked;
    this.emit('cbi-dropdown-change');
  }
  clickCheckbox(value) {
    const item = this.items.find(item => item.value === value);
    const beforeClick = item.input.checked;
    // HTML checkbox pre-activation flips checked before listeners run. LuCI
    // toggles li[selected] but prevents the input click's default action.
    item.input.checked = !beforeClick;
    this.select(value, !item.selected);
    // HTML cancelled activation runs AFTER cbi-dropdown-change listeners and
    // restores the original checkbox property, not the native selected marker.
    item.input.checked = beforeClick;
  }
  getValue() { return this.items.filter(item => item.selected).map(item => item.value); }
}
const toArray = value => Array.isArray(value) ? Array.from(value) : String(value || '').split(/\s+/).filter(Boolean);
class Option {
  constructor(type, name, title, description) {
    Object.assign(this, { type, option: name, title, description, keylist: [], vallist: [], map: {} });
  }
  value(key, label) { this.keylist.push(key); this.vallist.push(label); }
  depends() {}
  cbid(section) { return `cbid.podkop.${section}.${this.option}`; }
  transformChoices() { return Object.fromEntries(this.keylist.map((key, index) => [key, this.vallist[index]])); }
  getValidator() { return null; }
  // LuCI form.MultiValue.renderWidget(), preserving its selection/default and
  // dropdown display-size contract while isolating the browser DOM dependency.
  renderWidget(section_id, option_index, cfgvalue) {
    const value = cfgvalue != null ? cfgvalue : this.default;
    return new Dropdown(toArray(value), this.transformChoices(), {
      id: this.cbid(section_id), sort: this.keylist, multiple: true,
      optional: this.optional || this.rmempty, select_placeholder: this.placeholder,
      create: this.create, display_items: this.display_size ?? this.size ?? 3,
      dropdown_items: this.dropdown_size ?? this.size ?? -1,
      validate: this.getValidator(section_id), disabled: this.readonly ?? this.map.readonly,
    }).render();
  }
}
function setup(config = {}) {
  let exported;
  const options = new Map(), tabs = [], styles = [], writes = [], deferred = [];
  const doc = {
    getElementById: () => styles.length ? styles[0] : null,
    createElement: () => ({}), head: { appendChild: node => styles.push(node) },
  };
  const context = vm.createContext({
    form: { Value: 1, ListValue: 2, MultiValue: 3, Flag: 4, DummyValue: 5, DynamicList: 6 },
    widgets: { DeviceSelect: 7, NetworkSelect: 8 }, _: value => value,
    uci: { get: (_package, _section, name) => config[name], set: (...args) => writes.push(args) },
    baseclass: { extend: value => (exported = value) }, document: doc,
    window: { setTimeout: callback => { deferred.push(callback); return deferred.length; } },
    main: { DNS_SERVER_OPTIONS: {}, BOOTSTRAP_DNS_SERVER_OPTIONS: {}, UPDATE_INTERVAL_OPTIONS: {},
      getClashUIUrl: () => 'http://example.test', validateDNS: () => ({ valid: true }) },
    dnsBenchmark: { renderOpenButton() {} },
  });
  vm.runInContext('(function(){' + source + '\n})()', context);
  const option = (type, name, title, description) => {
    const record = new Option(type, name, title, description);
    record.cfgvalue = () => config[name] ?? record.default;
    options.set(name, record);
    return record;
  };
  exported.createSettingsContent({ option, tab: (...args) => tabs.push(args),
    taboption(tab, ...args) { const record = option(...args); record.tab = tab; return record; } });
  return { options, tabs, styles, writes, flushDeferred() { while (deferred.length) deferred.shift()(); } };
}
const multiKeys = ['dns_optimizer_protocols', 'dns_optimizer_candidates', 'dns_optimizer_bootstrap_candidates'];
test('configured and default DNS MultiValues have true checked state on initial render and opening', () => {
  for (const config of [{}, { dns_optimizer_protocols: 'udp dot', dns_optimizer_candidates: ['google', 'quad9'],
    dns_optimizer_bootstrap_candidates: ['yandex_1', 'google_1'] }]) {
    const state = setup(config);
    for (const key of multiKeys) {
      const option = state.options.get(key), configured = option.cfgvalue('settings');
      const widget = option.renderWidget('settings', 0, configured);
      const values = toArray(configured);
      assert.deepEqual(widget.getValue().sort(), [...values].sort(), key + ' preserves values');
      for (const item of widget.items) assert.equal(item.input.checked, values.includes(item.value), key + ' initial ' + item.value);
      widget.open();
      for (const item of widget.items) assert.equal(item.input.checked, values.includes(item.value), key + ' open ' + item.value);
      widget.select(values[0], false);
      assert.equal(widget.items.find(item => item.value === values[0]).input.checked, false, 'native change is not reverted to cfgvalue');
      assert.ok(!widget.getValue().includes(values[0]));
      assert.equal(widget.options.display_items, 1, 'collapsed selection is compact');
    }
    assert.deepEqual(state.writes, [], 'rendering does not mutate UCI');
  }
});
test('settings use separate Russian DNS, benchmark and service tabs with unchanged defaults', () => {
  const state = setup();
  assert.deepEqual(state.tabs, [['dns', 'DNS'], ['benchmark', 'Проверка DNS'], ['service', 'Дополнительно']]);
  for (const key of ['dns_type', 'dns_server', 'bootstrap_dns_server', 'secondary_dns_type', 'dns_failover_enabled', 'dns_rewrite_ttl'])
    assert.equal(state.options.get(key).tab, 'dns', key);
  for (const [key, option] of state.options) {
    if (key.startsWith('dns_optimizer_') || key === '_dns_benchmark') assert.equal(option.tab, 'benchmark', key);
  }
  for (const key of ['source_network_interfaces', 'enable_yacd', 'config_path', 'cache_path', 'log_level'])
    assert.equal(state.options.get(key).tab, 'service', key);
  assert.equal(state.options.get('dns_type').default, 'udp');
  assert.equal(state.options.get('dns_server').default, '8.8.8.8');
  assert.equal(state.options.get('bootstrap_dns_server').default, '77.88.8.8');
  assert.equal(state.options.get('dns_failover_enabled').default, '0');
  assert.equal(state.options.get('dns_optimizer_include_wan').default, '0');
});
test('multivalue containment styles are injected even without rendering the legacy optimizer', () => {
  const state = setup();
  assert.equal(state.styles.length, 1, 'styles are available on settings page');
  const css = state.styles[0].textContent;
  assert.match(css, /\.pdk-settings-multivalue[\s\S]*?max-width:\s*min\(100%,\s*30rem\)\s*!important/);
  assert.match(css, /\.pdk-settings-multivalue\[open\]\s*>\s*ul\.dropdown/);
  assert.match(css, /overflow-wrap:\s*anywhere/);
  assert.match(css, /\.pdk-settings-multivalue:not\(\[open\]\)[\s\S]*?display:\s*none/);
});
test('compact Russian summaries replace selected chips and follow native selection changes', () => {
  const state = setup();
  for (const [key, initialText] of [
    ['dns_optimizer_protocols', 'UDP, DoH, DoT'],
    ['dns_optimizer_candidates', 'Выбрано: 3 из 7'],
    ['dns_optimizer_bootstrap_candidates', 'Выбрано: 7 из 10'],
  ]) {
    const option = state.options.get(key);
    const widget = option.renderWidget('settings', 0, option.cfgvalue('settings'));
    assert.ok(widget.summary, key + ' has an explicit compact summary');
    assert.equal(widget.summary.textContent, initialText);
    widget.open();
    assert.equal(widget.summary.textContent, initialText, 'opening does not change the selection');
    widget.select(widget.getValue()[0], false);
    assert.equal(widget.summary.textContent, key === 'dns_optimizer_protocols' ? 'DoH, DoT' :
      key === 'dns_optimizer_candidates' ? 'Выбрано: 2 из 7' : 'Выбрано: 6 из 10');
    const css = state.styles[0].textContent;
    assert.match(css, /\.pdk-settings-multivalue\s*>\s*ul:not\(\.dropdown\)[\s\S]*?display:\s*none\s*!important/,
      'native selected-chip list and preview must remain hidden regardless of theme');
    assert.match(css, /\.pdk-settings-multivalue\s*>\s*\.more[\s\S]*?display:\s*none\s*!important/);
  }
  assert.deepEqual(state.writes, []);
});
test('checkbox state settles after native cancelled click default action for deselect AND reselect', () => {
  const state = setup();
  const option = state.options.get('dns_optimizer_protocols');
  const widget = option.renderWidget('settings', 0, option.cfgvalue('settings'));
  widget.open();
  state.flushDeferred();
  const dot = widget.items.find(item => item.value === 'dot');
  widget.clickCheckbox('dot');
  assert.equal(dot.selected, false, 'native value changes during click');
  assert.equal(dot.input.checked, true, 'browser cancelled activation restores old checked after synchronous listeners');
  assert.equal(widget.summary.textContent, 'UDP, DoH');
  state.flushDeferred();
  assert.equal(dot.input.checked, false, 'deferred sync repairs native cancelled-click reversion');
  assert.ok(!widget.getValue().includes('dot'));
  widget.clickCheckbox('dot');
  assert.equal(dot.selected, true);
  assert.equal(dot.input.checked, false, 'browser reverts reselect too');
  state.flushDeferred();
  assert.equal(dot.input.checked, true, 'reselect is also synchronized after default action');
  assert.equal(widget.summary.textContent, 'UDP, DoH, DoT');
  assert.deepEqual(state.writes, [], 'checkbox display repair does not write UCI');
});
