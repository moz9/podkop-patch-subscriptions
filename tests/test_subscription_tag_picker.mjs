import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const js = fs.readFileSync(new URL('../openwrt/main.js', import.meta.url), 'utf8');
const c = vm.createContext({Intl});
for (const name of ['normalizeSubscriptionTags', 'getEffectiveSubscriptionTags', 'subscriptionTagMatches', 'getSubscriptionTagChoices', 'renderSubscriptionTagPicker']) {
  const match = js.match(new RegExp(`function ${name}\\([\\s\\S]*?\\n}`));
  assert.ok(match, `${name} must exist`);
  vm.runInContext(match[0], c);
}
c.E = (tag, attrs, children) => ({tag, attrs, children});
c.subscriptionTagPickerOpen = {};
const section = {code:'main', includeTags:[], excludeTags:[], items:[
  {name:'🇫🇮 Финляндия ⚡️'}, {name:'🇫🇮 Финляндия [Игровой]'},
  {name:'🇳🇱 Нидерланды'}, {name:'EU Euro'}, {name:'ZZ Unknown'}, {name:'Авто выбор'}, {name:'Node [one]'}, {name:'  Node [spaced]  '}
]};
const choices = JSON.parse(JSON.stringify(c.getSubscriptionTagChoices(section, ['old*'])));
assert.equal(choices.filter(x => x.value === '@prefix:FI').length, 1, 'one country tag for multiple nodes');
assert.equal(choices.find(x => x.value === '@prefix:FI').label, 'FI');
assert.equal(choices.find(x => x.value === '@prefix:FI').description, 'Финляндия', 'prefix choice has Russian region description');
assert.equal(choices.find(x => x.value === '@prefix:EU').description, 'Европейский союз', 'EU prefix has Russian region description');
assert.equal(choices.find(x => x.value === '@prefix:ZZ').description, undefined, 'unknown region falls back to the short code');
assert.equal(c.subscriptionTagMatches('*🇫🇮*', 'Новый 🇫🇮 сервер'), true, 'new nodes keep country rule');
assert.equal(c.subscriptionTagMatches('*🇫🇮*', '🇳🇱 Другой'), false);
assert.equal(c.subscriptionTagMatches(choices.find(x => x.label === 'Node [one]').value, 'Node [one]'), true, 'literal bracket escaped');
const spacedChoice = choices.find(x => x.label === 'Node [spaced]');
assert.equal(c.subscriptionTagMatches(spacedChoice.value, '  Node [spaced]  '), true, 'literal choice matches its exact raw name including surrounding spaces');
assert.equal(c.subscriptionTagMatches(spacedChoice.value, 'Node [spaced]'), false, 'literal choice does not silently normalize custom glob semantics');
assert.equal(choices.find(x => x.value === 'old*').missing, true, 'missing saved rules are retained');
let changed;
const draft = {'main:tags:include':['*🇫🇮*']};
const picker = c.renderSubscriptionTagPicker(section, draft, 'include', false, (...args) => changed=args);
const walk = node => node && typeof node === 'object' ? [node, ...([node.children].flat(Infinity).flatMap(walk))] : [];
const nodes = walk(picker);
assert.ok(nodes.filter(x => Array.isArray(x.children)).every(x=>!x.children.includes(null)), 'native LuCI E must never receive null text children');
assert.equal(nodes.some(x => x.tag === 'textarea'), false, 'no mandatory hand typed tags');
assert.equal(nodes.find(x => x.tag === 'summary').children, 'FI', 'collapsed summary remains short');
assert.ok(nodes.some(x => x.tag === 'span' && Array.isArray(x.children) && x.children.join('') === 'FI — Финляндия'), 'expanded choices show compact inline descriptions');
const fi = nodes.find(x => x.tag === 'input' && x.attrs.value === '*🇫🇮*');
assert.equal(fi.attrs.checked, 'checked', 'selected state visible on first render');
fi.attrs.change({target:{checked:false}});
assert.deepEqual(JSON.parse(JSON.stringify(changed)), ['main',{id:'tags:include',enabled:[]},[]]);
const busy = walk(c.renderSubscriptionTagPicker(section, draft, 'exclude', true, ()=>{}));
assert.ok(busy.filter(x=>x.tag === 'input').every(x=>x.attrs.disabled === 'disabled'));
const choicesSource = js.match(/function getSubscriptionTagChoices\([\s\S]*?\n}/)[0];
const unavailableIntl = vm.createContext({Intl:{}});
vm.runInContext(choicesSource, unavailableIntl);
assert.equal(unavailableIntl.getSubscriptionTagChoices({items:[{name:'US Server'}]},[])[0].description, undefined, 'missing DisplayNames keeps code only');
const brokenIntl = vm.createContext({Intl:{DisplayNames:function(){throw new Error('unsupported locale data');}}});
vm.runInContext(choicesSource, brokenIntl);
assert.equal(brokenIntl.getSubscriptionTagChoices({items:[{name:'US Server'}]},[])[0].description, undefined, 'failed DisplayNames construction keeps code only');
console.log('PASS: automatic country tags, literal safety, retained rules, initial checks and draft changes');
