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
assert.match(text(active),/9 узлов/);
assert.equal(active.attrs['aria-labelledby'],'pdk-subscription-section-main pdk-composition-active-heading');
assert.equal(future.attrs['aria-labelledby'],'pdk-subscription-section-main pdk-composition-preview-heading');
assert.match(text(future),/0.*[Пп]рименение будет отклонено/);
assert.match(text(future),/[Рр]абочая конфигурация не изменится/,'zero future eligibility must not imply current outage');
assert.doesNotMatch(text(tree),/Текущий рабочий набор|Предпросмотр нового применения/,'section rows must not repeat the shared headings');
assert.doesNotMatch(text(active),/0 узлов/,'catalog eligibility must not replace working count');
for(const status of [{unknown:true,...known},{...known,busy:true},{sections:[]},{sections:[{section:'main',ready:false,activeNodeCount:9}]},{sections:[{section:'main',ready:true,activeNodeCount:null}]}]){
 const current=walk(render(status)).find(n=>n.attrs?.class==='pdk_subscriptions-page__composition-active');
 assert.match(text(current),/не подтверждено|проверяем состояние/i);
 assert.doesNotMatch(text(current),/0 узлов/);
}
preview={enabled:4,uncertain:false};
assert.match(text(walk(render(known)).find(n=>n.attrs?.class==='pdk_subscriptions-page__composition-preview')),/4 из 6/);
preview={enabled:4,uncertain:true};
assert.match(text(walk(render(known)).find(n=>n.attrs?.class==='pdk_subscriptions-page__composition-preview')),/Для нового режима пока не рассчитано.*По сохранённому: 4/);
c.getPendingCount=()=>0;c.renderToolbar=()=>null;
c.renderSections2=({sections,sourceActions})=>sections.map(section=>c.renderSection({section,pendingChanges:{},collapsedSections:{},sourceActions}));
vm.runInContext(js.match(/function renderSubscriptionSections\([\s\S]*?\n}(?=\r?\n)/)[0],c);
const page=c.renderSubscriptionSections({sections:[{code:'main',displayName:'main',items:[]},{code:'peer',displayName:'peer',items:[]}],pendingChanges:{},runtimeStatus:known});
assert.equal(walk(page).filter(n=>n.attrs?.id==='pdk-composition-active-heading').length,1,'working heading appears once for all sections');
assert.equal(walk(page).filter(n=>n.attrs?.id==='pdk-composition-preview-heading').length,1,'apply heading appears once for all sections');
assert.match(text(page),/Рабочий набор/);assert.match(text(page),/К применению/);
assert.doesNotMatch(text(page),/Предпросмотр нового применения/);
assert.match(text(page),/Доступность сайтов здесь не проверяется/,'the shared explanation retains the live-access caveat');
console.log('PASS: one shared composition header, concise section rows, and distinct zero/unknown states');
