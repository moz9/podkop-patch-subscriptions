import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const source = fs.readFileSync(new URL('../openwrt/section.js', import.meta.url), 'utf8');
const originals = new Map();
const section = {
  tab() {},
  option() { return {modalonly: false}; },
  taboption(_tab, _type, name, title) {
    const option = {option:name, title, parse() { return Promise.resolve('parsed'); },
      value() {}, depends() {}, formvalue() { return undefined; }, cfgvalue() { return undefined; },
      isActive() { return true; }, stripTags(value) { return value; }};
    originals.set(name, option);
    return option;
  },
};
let exported;
const notifications = [];
const context = vm.createContext({
  baseclass: {extend: value => (exported = value)},
  form: Object.fromEntries(['ListValue','DynamicList','TextValue','Value','Flag','DummyValue'].map(x => [x,x])),
  widgets: {DeviceSelect:'DeviceSelect'},
  main: {URLTEST_DOWNLOAD_URL_OPTIONS:{}, DNS_SERVER_OPTIONS:{}, DOMAIN_LIST_OPTIONS:{},
    REGIONAL_OPTIONS:[], validateProxyUrl:()=>({valid:true}), validateUrl:()=>({valid:true})},
  uci: {get:()=>null}, _: text => text,
  E: (tag, attrs, children) => ({tag, attrs, children}),
  ui: {addNotification: (...args) => notifications.push(args)},
});
vm.runInContext('String.prototype.format = function(value) { return this.replace("%s", value); }', context);
vm.runInContext(`(function(){${source}\n})()`, context);
exported.createSectionContent(section, []);

// LuCI GridSection.cloneOptions copies parse() to a NamedSection option, but
// its original option has no rendered form value. Only the clone has a widget.
const originalType = originals.get('proxy_config_type');
const originalUrl = originals.get('subscription_url');
originalType.cfgvalue = () => 'subscription_urltest';
originalType.formvalue = () => undefined;
originalUrl.formvalue = () => undefined;
const cloned = (name, value) => ({...originals.get(name), formvalue: () => value,
  cfgvalue: () => value, isActive: () => true});
const mode = cloned('proxy_config_type', 'subscription_urltest');
const subscription = cloned('subscription_url', ['https://example.invalid/list']);
const links = cloned('urltest_proxy_links', []);
const widgets = new Map([['proxy_config_type',mode],['subscription_url',subscription],['urltest_proxy_links',links]]);
const modalMap = {lookupOption(name, sectionId) {
  assert.equal(sectionId, 'main');
  const option = widgets.get(name);
  return option ? [option, sectionId] : null;
}};
links.map = modalMap;
assert.equal(await links.parse('main'), 'parsed', 'populated cloned subscription URL permits Mix without manual links');
mode.formvalue = () => 'urltest';
await assert.rejects(links.parse('main'), /must not be empty|не.*пуст/i,
  'switching modal mode to URLTest requires manual links');
mode.formvalue = () => 'subscription_urltest';
subscription.formvalue = () => [];
await assert.rejects(links.parse('main'), /Подпис|подпис|URL/i,
  'empty Mix rejects when both cloned URL and manual links are empty');

const root = {children:[], prepend(node) { this.children.unshift(node); },
  querySelector() { return this.children.find(node => node.attrs?.class === 'pdk-section-save-error') || null; }};
let closed = false, reloaded = false, draft = 'https://example.invalid/list';
const parent = {load:async()=>{reloaded=true}, reset:async()=>{reloaded=true}};
const failingMap = {root, parent, save:async()=>{throw new Error('rpc_failed')}};
section.handleModalCancel = () => {closed=true};
await section.handleModalSave(failingMap, {});
assert.equal(closed, false, 'failed Save must not close modal');
assert.equal(reloaded, false, 'failed Save must not reset draft');
assert.equal(draft, 'https://example.invalid/list');
assert.ok(root.children.some(node => JSON.stringify(node).includes('Не удалось сохранить')),
  'failed Save shows visible Russian error inside current modal');
const successfulMap = {root, parent, save:async()=>{}};
await section.handleModalSave(successfulMap, {});
assert.equal(closed, true, 'successful Save retains native modal close behavior');
assert.equal(reloaded, true, 'successful Save refreshes the parent map');
console.log('PASS: cloned modal validation and visible non-destructive Save failure');
