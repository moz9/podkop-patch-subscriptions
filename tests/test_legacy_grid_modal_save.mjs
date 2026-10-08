import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const source = fs.readFileSync(new URL('../openwrt/section.js', import.meta.url), 'utf8');
const originals = new Map();
const option = (_type, name, title) => {
  const field = {option:name, title, parse() { return Promise.resolve('parsed'); },
    value() {}, depends() {}, formvalue() { return undefined; }, cfgvalue() { return undefined; },
    isActive() { return true; }, stripTags(value) { return value; }};
  originals.set(name, field);
  return field;
};
const section = {tab() {}, option, taboption: (_tab, ...args) => option(...args)};
let exported;
const context = vm.createContext({
  baseclass: {extend: value => (exported = value)},
  form: Object.fromEntries(['ListValue','DynamicList','TextValue','Value','Flag','DummyValue'].map(x => [x,x])),
  widgets: {DeviceSelect:'DeviceSelect'}, main: {DNS_SERVER_OPTIONS:{}, DOMAIN_LIST_OPTIONS:{},
    REGIONAL_OPTIONS:[], validateProxyUrl:()=>({valid:true}), validateUrl:()=>({valid:true})},
  uci: {get:()=>null}, _: text => text,
  E: (tag, attrs, children) => ({tag, attrs, children}),
});
vm.runInContext('String.prototype.format = function(value) { return this.replace("%s", value); }', context);
vm.runInContext(`(function(){${source}\n})()`, context);
exported.createSectionContent(section);

// LuCI clones options into a NamedSection; only clones have rendered widgets.
originals.get('proxy_config_type').cfgvalue = () => 'subscription_urltest';
const cloned = (name, value) => ({...originals.get(name), formvalue: () => value,
  cfgvalue: () => value, isActive: () => true});
const mode = cloned('proxy_config_type','subscription_urltest');
const subscription = cloned('subscription_url',['https://example.invalid/list']);
const links = cloned('urltest_proxy_links', []);
const widgets = new Map([['proxy_config_type',mode],['subscription_url',subscription],['urltest_proxy_links',links]]);
links.map = {lookupOption(name, id) {
  assert.equal(id,'main');
  return widgets.has(name) ? [widgets.get(name),id] : null;
}};
assert.equal(await links.parse('main'), 'parsed', 'cloned subscription URL permits Mix with no manual links');
mode.formvalue = () => 'urltest';
await assert.rejects(links.parse('main'), /must not be empty|не.*пуст/i, 'modal URLTest requires manual links');
mode.formvalue = () => 'subscription_urltest';
subscription.formvalue = () => [];
await assert.rejects(links.parse('main'), /Подпис|подпис|URL/i, 'empty modal Mix rejects');
links.formvalue = () => ['vless://public@node.invalid:443'];
assert.equal(await links.parse('main'), 'parsed', 'manual links alone permit Mix');

assert.equal(typeof section.handleModalSave, 'function', 'custom Save keeps errors visible');
const root = {children:[], prepend(node) { node.remove = () => this.children.splice(this.children.indexOf(node),1); this.children.unshift(node); },
  querySelector() { return this.children.find(node => node.attrs?.class.includes('pdk-section-save-error')) || null; }};
let closed = false, reloaded = false;
const parent = {load:async()=>{reloaded=true}, reset:async()=>{reloaded=true}};
section.handleModalCancel = (_map,_event,saved) => {assert.equal(saved,true);closed=true};
const failingMap = {root,parent,save:async()=>{throw new Error('rpc_failed')}};
await section.handleModalSave(failingMap, {});
assert.equal(closed,false,'failed Save must not close modal');
assert.equal(reloaded,false,'failed Save must not reset draft');
assert.match(JSON.stringify(root.children), /Не удалось сохранить/, 'Russian error is visible in the current modal');
assert.doesNotMatch(JSON.stringify(root.children), /rpc_failed/, 'untrusted RPC details are not echoed');
await section.handleModalSave(failingMap, {});
assert.equal(root.children.length,1,'repeated failures replace the visible error');

const staged = [];
for (const sectionId of ['alpha','beta']) {
  closed=false;
  await section.handleModalSave({root,parent,save:async(...args)=>{
    assert.deepEqual(args,[null,true], 'Save stages config without applying/restarting service');
    staged.push(sectionId);
  }}, {});
  assert.equal(closed,true,'successful Save closes modal');
}
assert.deepEqual(staged,['alpha','beta'],'multiple section edits can be staged independently');
assert.equal(reloaded,true,'successful Save refreshes parent map');
console.log('PASS: legacy cloned modal validation, staged saves, and non-destructive visible errors');
