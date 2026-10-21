import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const js=fs.readFileSync(new URL('../openwrt/main.js',import.meta.url),'utf8');
let preview={enabled:0,uncertain:false};
const c=vm.createContext({E:(tag,attrs,children)=>({tag,attrs,children}),
 getTagFilterPreview:()=>preview,getSourceGroups:()=>[],isSubscriptionSectionCollapsed:()=>true,
 getEffectiveSubscriptionTags:()=>[],getSectionCollapsedSummary:()=>''});
vm.runInContext(js.match(/function renderSection\([\s\S]*?\n}(?=\r?\n)/)[0],c);
const walk=node=>Array.isArray(node)?node.flatMap(walk):!node||typeof node!=='object'?[]:[node,...walk(node.children)];
const text=node=>Array.isArray(node)?node.map(text).join(' '):node&&typeof node==='object'?text(node.children):String(node??'');
function render(runtimeStatus){return c.renderSection({section:{code:'main',displayName:'main',items:Array.from({length:6},()=>({}))},pendingChanges:{},collapsedSections:{},sourceActions:{runtimeStatus}});}
const known={busy:false,sections:[{section:'main',ready:true,activeNodeCount:9}]};
const tree=render(known);
const active=walk(tree).find(n=>n.attrs?.class==='pdk_subscriptions-page__composition-active');
const future=walk(tree).find(n=>n.attrs?.class==='pdk_subscriptions-page__composition-preview');
assert.ok(active,'current working composition must have its own visible block');
assert.ok(future,'next application preview must have a separate visible block');
assert.match(text(active),/Текущий рабочий набор.*9 узлов/);
assert.match(text(future),/Предпросмотр нового применения.*0/);
assert.match(text(future),/не означает.*рабочий набор пуст/,'zero future eligibility must not imply current outage');
assert.doesNotMatch(text(active),/0 узлов/,'catalog eligibility must not replace working count');
for(const status of [{unknown:true,...known},{...known,busy:true},{sections:[]},{sections:[{section:'main',ready:false,activeNodeCount:9}]},{sections:[{section:'main',ready:true,activeNodeCount:null}]}]){
 const current=walk(render(status)).find(n=>n.attrs?.class==='pdk_subscriptions-page__composition-active');
 assert.match(text(current),/нет подтверждённых данных/i);
 assert.doesNotMatch(text(current),/0 узлов/);
}
preview={enabled:4,uncertain:false};
assert.match(text(walk(render(known)).find(n=>n.attrs?.class==='pdk_subscriptions-page__composition-preview')),/4 из 6/);
preview={enabled:4,uncertain:true};
assert.match(text(walk(render(known)).find(n=>n.attrs?.class==='pdk_subscriptions-page__composition-preview')),/сохранённому режиму/);
console.log('PASS: current graph and next-apply preview remain distinct, including zero and unavailable states');
