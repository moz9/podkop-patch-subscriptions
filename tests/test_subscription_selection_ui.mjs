import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const js = fs.readFileSync(new URL('../openwrt/main.js', import.meta.url), 'utf8');
const c = vm.createContext({});
for (const name of ['buildSubscriptionSectionChanges', 'getEffectiveSelectionMode', 'rebaseSubscriptionDraft']) {
  const match = js.match(new RegExp(`function ${name}\\([\\s\\S]*?\\n}`));
  assert.ok(match, `${name} must exist`);
  vm.runInContext(match[0], c);
}
const payload = c.buildSubscriptionSectionChanges('geo', [
  {id:'selection:mode', enabled:true}, {id:'us', enabled:true},
  {id:'de', enabled:false}, {id:'source:one', enabled:true}
]);
assert.deepEqual(JSON.parse(JSON.stringify(payload)), {
  section:'geo', selectionMode:'selected', changes:[{id:'us',enabled:true},{id:'de',enabled:false}],
  sources:[{id:'one',enabled:true}]
});
assert.equal(c.buildSubscriptionSectionChanges('main', []).selectionMode, undefined);
assert.equal(c.buildSubscriptionSectionChanges('geo', [{id:'selection:mode',enabled:false}]).selectionMode, 'all');
assert.equal(c.getEffectiveSelectionMode({}, {code:'geo'}), 'auto');
assert.equal(c.getEffectiveSelectionMode({'geo:selection:mode':true}, {code:'geo',selectionMode:'all'}), 'selected');
assert.equal(c.getEffectiveSelectionMode({'geo:selection:mode':false}, {code:'geo',selectionMode:'selected'}), 'all');
assert.deepEqual({...c.rebaseSubscriptionDraft({'geo:selection:mode':true}, [{code:'geo',selectionMode:'selected',items:[]}])}, {});
assert.deepEqual({...c.rebaseSubscriptionDraft({'geo:selection:mode':true}, [{code:'geo',selectionMode:'all',items:[]}])}, {'geo:selection:mode':true});
assert.match(js, /Только выбранные/);
assert.match(js, /Новые конфиги не включаются автоматически/);
assert.match(js, /selectionMode: section\.subscription_selection_mode/);
assert.match(js, /buildSubscriptionSectionChanges\(section, changes\)/);
c.E = (tag, attrs, children) => ({tag, attrs, children});
c._ = x => x;
c.getSourceGroups = () => [];
c.getEffectiveEnabled = (_, __, item) => item.enabled;
c.getTagFilterPreview = () => ({enabled:0,filtered:0,unsupported:0,sourceExcluded:0,manualExcluded:0,serviceExcluded:0});
c.getSectionCollapsedSummary = () => '0 конфигов · к применению 0';
c.isSubscriptionSectionCollapsed = (collapsed,code) => collapsed?.[code] !== false;
c.getEffectiveSubscriptionTags = () => [];
c.renderSubscriptionTagPicker = () => null;
c.renderEmptyState = text => text;
vm.runInContext(js.match(/function renderSection\([\s\S]*?\n}(?=\r?\n)/)[0], c);
let toggled;
const props = {section:{code:'geo',selectionMode:'all',displayName:'GeoBlock',items:[]},pendingChanges:{'geo:us':true},applying:false,onToggle:(...args)=>toggled=args,sourceActions:{disabled:true,modeDisabled:false}};
assert.equal(c.renderSection({...props,collapsedSections:{}}).children.length,1,'section defaults closed');
const rendered = c.renderSection({...props,collapsedSections:{geo:false}});
const walk = node => Array.isArray(node) ? node.flatMap(walk) :
  !node || typeof node !== 'object' ? [] : [node,...walk(node.children)];
const select = walk(rendered).find(node => node.tag === 'select');
assert.equal(select.tag, 'select');
assert.equal(select.attrs.disabled, undefined, 'pending row edits must not prevent changing mode');
select.attrs.change({target:{value:'selected'}});
assert.deepEqual(JSON.parse(JSON.stringify(toggled)), ['geo',{id:'selection:mode',enabled:'all'},'selected']);
console.log('PASS: section selection mode shares one transaction with node/source choices; drafts persist');
