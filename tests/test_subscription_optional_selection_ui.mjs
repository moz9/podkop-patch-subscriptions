import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const js = fs.readFileSync(new URL('../openwrt/main.js', import.meta.url), 'utf8');
const c = vm.createContext({Intl});
for (const name of ['getEffectiveRequiredServices','getSubscriptionServiceExclusions','buildSubscriptionSectionChanges','getEffectiveSelectionMode','getEffectiveSubscriptionItemEnabled','subscriptionTagMatches','isSubscriptionTagFiltered','getSubscriptionTagChoices','getEffectiveSubscriptionTags','hasPendingSubscriptionModeChange','getTagFilterPreview','getEffectiveEnabled','getRowId','getEffectiveSourceEnabled']) {
  const match = js.match(new RegExp(`function ${name}\\([\\s\\S]*?\\n}`));
  assert.ok(match, `${name} must exist`);
  vm.runInContext(match[0], c);
}
assert.equal(c.getEffectiveSelectionMode({}, {code:'main'}), 'auto');
assert.equal(c.getEffectiveSelectionMode({'main:selection:mode':'auto'}, {code:'main',selectionMode:'selected'}), 'auto');
assert.equal(c.buildSubscriptionSectionChanges('main',[{id:'selection:mode',enabled:'auto'}]).selectionMode, 'auto');
const section = {code:'main',selectionMode:'selected',includeTags:['*🇸🇪*'],excludeTags:[],sources:[{id:'one',enabled:true},{id:'two',enabled:true}],items:[
  {id:'a',name:'🇸🇪 Швеция',supported:true,enabled:true,sourceIds:['one']},
  {id:'b',name:'SE Kazam · Reality',supported:true,enabled:false,sourceIds:['two']},
  {id:'c',name:'US Dots · Reality',supported:true,enabled:false,sourceIds:['two']},
  {id:'d',name:'SE broken',supported:false,enabled:false,sourceIds:['two']}
]};
const draft = {'main:selection:mode':'auto'};
assert.equal(c.getEffectiveSubscriptionItemEnabled(draft,section,section.items[1]),true,'auto ignores previously unselected nodes');
assert.equal(c.getTagFilterPreview(section,draft).enabled,2,'both subscriptions contribute matching nodes');
assert.equal(c.getTagFilterPreview(section,{...draft,'main:source:two':false}).enabled,1,'source disable still applies');
assert.equal(c.getTagFilterPreview(section,{...draft,'main:tags:exclude':['@prefix:SE']}).enabled,0,'exclude has priority');
assert.equal(c.subscriptionTagMatches('@prefix:SE','SE Kazam'),true);
assert.equal(c.subscriptionTagMatches('@prefix:SE','SEVER wrong'),false,'prefix requires boundary');
assert.equal(c.subscriptionTagMatches('*🇸🇪*','SE Amin'),true,'saved flag filters also cover text prefixes');
const choices = JSON.parse(JSON.stringify(c.getSubscriptionTagChoices({...section,items:[...section.items,{name:'EU Auto'},{name:'FI Finland'}]},[])));
assert.equal(choices.filter(x=>x.label==='SE').length,1,'flags and text codes are deduplicated');
assert.ok(choices.some(x=>x.label==='EU' && x.value==='@prefix:EU'));
assert.ok(choices.some(x=>x.label==='FI'));
assert.ok(!choices.some(x=>/Швеция|Соединенные/.test(x.label)),'compact codes, not country names');
assert.match(js,/Ручной отбор конфигов/);
assert.match(js,/selectionMode: section\.subscription_selection_mode \|\| \(normalizeSubscriptionTags\(section\.subscription_excluded_link_ids\)/);
Object.assign(c, {
  E: (tag, attrs, children) => ({tag, attrs, children}),
  _: text => text,
  getSourceGroups: () => [],
  isSubscriptionSectionCollapsed: () => false,
  getSectionCollapsedSummary: () => '',
  renderEmptyState: () => null,
  renderSubscriptionTagPicker: (_section, _draft, kind) => ({picker:kind})
});
vm.runInContext(js.slice(js.indexOf('function renderSection({'),js.indexOf('function renderSections2(')),c);
function pickers(node) {
  if (Array.isArray(node)) return node.flatMap(pickers);
  if (!node || typeof node !== 'object') return [];
  return node.picker ? [node.picker] : pickers(node.children);
}
for (const pending of [draft, {}]) {
  const tree=c.renderSection({section,pendingChanges:pending,sourceActions:{}});
  assert.deepEqual(Array.from(pickers(tree)),['include','exclude'],'tag selectors remain visible with or without manual selection');
}
console.log('PASS: optional manual selection, real short prefixes, shared legacy flag rules and source/tag priority');
