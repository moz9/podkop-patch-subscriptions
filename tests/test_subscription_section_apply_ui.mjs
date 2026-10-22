import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const js=fs.readFileSync(new URL('../openwrt/main.js',import.meta.url),'utf8');
const sections=['Other','Main'].map(code=>({code,displayName:code==='Main'?'Основная':code,includeTags:code==='Other'?['US']:[],selectionMode:'auto',items:[{id:'a',supported:true,enabled:true}],sources:[]}));
let state, payload, outcome, reads;
const c=vm.createContext({Error,store:{get:()=>state,set:x=>state={...state,...x}},_:x=>x,logger:{error(){}},showToast(){},
  E:(tag,attrs,children)=>({tag,attrs,children}),getPendingCount2:x=>Object.keys(x).length,isActionRunning:()=>false,
  readSubscriptionSectionsWithRetry:async()=>reads,
  PodkopShellMethods:{setSubscriptionSectionsEnabled:async changes=>{payload=JSON.parse(JSON.stringify(changes)); if(outcome instanceof Error) throw outcome; return outcome;}}});
for(const name of ['getErrorText','getChangesBySection','handleApply','fetchSubscriptionItems','rebaseSubscriptionDraft','getEffectiveSelectionMode','setActionState','getSubscriptionActionErrorMessage','refreshSubscriptionRuntimeStatus','reconcileSubscriptionApplyTimeout','releaseSubscriptionApplyRead','renderSection']) {
  const match=js.match(new RegExp(`(?:async )?function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n)`));
  assert.ok(match,name);vm.runInContext(match[0],c);
}
vm.runInContext('var subscriptionStatusGeneration=0;',c);
const other={'Other:a':false,'Other:tags:include':['US']};
const main={'Main:a':false,'Main:tags:exclude':['RU'],'Main:selection:mode':'selected','Main:services:required':['youtube'],'Main:source:s':false};
function reset(runtimeStatus={busy:false,pending:false}) {
  delete c.PodkopShellMethods.getSubscriptionOperationStatus;
  state={subscriptionItemsWidget:{pendingChanges:{...other,...main},data:sections,latencyByRow:{},speedByRow:{},actionStatus:'idle',runtimeStatus}};
  payload=null;outcome={success:true,data:{success:true}};reads=sections;
}
reset(); await c.handleApply('Main');
assert.deepEqual(Object.keys(payload),['Main'],'section Apply must not submit other section drafts');
assert.deepEqual(payload.Main.map(x=>x.id).sort(),['a','tags:exclude','selection:mode','services:required','source:s'].sort());
assert.equal(state.subscriptionItemsWidget.pendingChanges['Other:a'],false,'success preserves other draft');
await c.fetchSubscriptionItems();assert.deepEqual({...state.subscriptionItemsWidget.pendingChanges},other,'later refetch preserves peer drafts exactly, even if saved values now match');
reset();outcome={success:true,data:{success:false,error:'service_busy'}};await c.handleApply('Main');
assert.deepEqual({...state.subscriptionItemsWidget.pendingChanges},{...other,...main},'error preserves drafts');
reset({busy:false,pending:true,isolatedSection:'Main',isolatedReady:true});state.subscriptionItemsWidget.pendingChanges={};
await c.handleApply('Main');assert.deepEqual(Object.keys(payload),['Main'],'runtime-only Apply uses target, not first section');
reset({busy:false,isolatedSection:'Main',isolatedReady:true});await c.handleApply();
assert.equal(payload,null,'global Apply rejects other drafts in isolation mode');
assert.match(state.subscriptionItemsWidget.actionMessage,/других секций/);
reset({busy:false,isolatedSection:'Main',isolatedReady:true});await c.handleApply('Other');assert.equal(payload,null);
reset({busy:false,isolatedSection:'Main',isolatedReady:false});await c.handleApply('Main');assert.equal(payload,null);
reset();outcome=new Error('RPC timeout');await c.handleApply('Main');
assert.deepEqual(Object.keys(state.subscriptionItemsWidget.applyVerification.pendingChanges),Object.keys(main));
reads=sections.map(s=>s.code==='Main'?{...s,selectionMode:'selected',excludeTags:['RU'],requiredServices:['youtube'],sources:[{id:'s',enabled:false}],items:[{id:'a',enabled:false}]}:s);
state.subscriptionItemsWidget.runtimeStatus={busy:false,pending:false};
await c.reconcileSubscriptionApplyTimeout(state.subscriptionItemsWidget.applyVerification,0);
assert.equal(state.subscriptionItemsWidget.status,'success');assert.deepEqual({...state.subscriptionItemsWidget.pendingChanges},other);
for(const runtimeStatus of [{busy:false,pending:false,isolatedSection:'Main',isolatedReady:false},{busy:false,pending:false,isolatedSection:'Other',isolatedReady:true},{busy:false,pending:false,isolatedSection:'',isolatedReady:false}]) {
  reset({busy:false,pending:false,isolatedSection:'Main',isolatedReady:true});outcome=new Error('RPC timeout');await c.handleApply('Main');
  reads=sections.map(s=>s.code==='Main'?{...s,selectionMode:'selected',excludeTags:['RU'],requiredServices:['youtube'],sources:[{id:'s',enabled:false}],items:[{id:'a',enabled:false}]}:s);
  state.subscriptionItemsWidget.runtimeStatus=runtimeStatus;
  await c.reconcileSubscriptionApplyTimeout(state.subscriptionItemsWidget.applyVerification,0);
  assert.equal(state.subscriptionItemsWidget.status,'error','saved UCI alone cannot confirm a failed or replaced isolated worker');
}
c.getTagFilterPreview=()=>({});c.getSourceGroups=()=>[];c.isSubscriptionSectionCollapsed=()=>true;c.getEffectiveSubscriptionTags=()=>[];c.getSectionCollapsedSummary=()=>'';
function button(status,code='Main',draft=main) {
  const tree=c.renderSection({section:sections.find(s=>s.code===code),pendingChanges:draft,collapsedSections:{},applying:false,onToggleSection(){},sourceActions:{runtimeStatus:status,onApply(){}}});
  return tree.children.find(n=>n?.attrs?.class==='pdk_subscriptions-page__section-apply');
}
assert.match(button({isolatedSection:'Main',isolatedReady:true}).children,/Применить Main без перезапуска других секций/);
const singleButton=button({runtimeMode:'single',isolatedSections:['Main','Other'],isolatedReady:true});
assert.doesNotMatch(singleButton.children,/без перезапуска/,'single runtime must not promise peer connection isolation');
assert.match(singleButton.attrs.title,/соединени/i,'single runtime warns about shared connection interruption');
reset({runtimeMode:'single',busy:false,pending:false,isolatedSections:['Main','Other'],isolatedReady:true});
await c.handleApply('Other');assert.deepEqual(Object.keys(payload),['Other'],'single runtime allows peer section apply');
assert.deepEqual({...state.subscriptionItemsWidget.pendingChanges},main,'single runtime retains every other draft');
assert.equal(button({isolatedSection:'Main',isolatedReady:true},'Other',other).attrs.disabled,'disabled');
assert.equal(button({pending:true},'Main',{}).attrs.disabled,undefined);
assert.equal(button({},'Main',{}).attrs.disabled,'disabled');
for(const error of ['section_isolation_unavailable','shared_config_changed','isolated_section_only','uci_pending_changes']) assert.notEqual(c.getSubscriptionActionErrorMessage(new Error(error),'fallback'),'fallback');
reset();c.PodkopShellMethods.getSubscriptionOperationStatus=async()=>({success:true,data:{busy:false,pending:false,isolatedSection:'Main',isolatedReady:true}});
await c.refreshSubscriptionRuntimeStatus();
assert.equal(state.subscriptionItemsWidget.runtimeStatus.isolatedSection,'Main');assert.equal(state.subscriptionItemsWidget.runtimeStatus.isolatedReady,true,'status refresh preserves isolation readiness fields');
// A second isolated worker may stay pending while the selected one completes.
reset({busy:false,pending:true,pendingSections:['Main','Other'],isolatedSections:['Main','Other'],isolatedReady:true});
await c.handleApply('Main');
assert.deepEqual(Object.keys(payload),['Main']);
assert.deepEqual({...state.subscriptionItemsWidget.pendingChanges},other);
reset({busy:false,pending:true,pendingSections:['Main','Other'],isolatedSections:['Main','Other'],isolatedReady:true});
outcome=new Error('RPC timeout');await c.handleApply('Main');
reads=sections.map(s=>s.code==='Main'?{...s,selectionMode:'selected',excludeTags:['RU'],requiredServices:['youtube'],sources:[{id:'s',enabled:false}],items:[{id:'a',enabled:false}]}:s);
state.subscriptionItemsWidget.runtimeStatus={busy:false,pending:true,pendingSections:['Other'],isolatedSections:['Main','Other'],isolatedReady:true};
await c.reconcileSubscriptionApplyTimeout(state.subscriptionItemsWidget.applyVerification,0);
assert.equal(state.subscriptionItemsWidget.status,'success','peer pending must not prevent target confirmation');
assert.deepEqual({...state.subscriptionItemsWidget.pendingChanges},other,'timeout preserves peer drafts exactly');
for (const runtimeStatus of [
  {busy:true,isolatedSections:['Main','Other'],isolatedReady:true},
  {busy:false,unknown:true,isolatedSections:['Main','Other'],isolatedReady:true},
  {busy:false,isolatedSections:['Main','Other'],isolatedReady:false}
]) {
  reset(runtimeStatus);await c.handleApply('Main');assert.equal(payload,null,'unsafe status blocks scoped RPC');
}
reset({busy:false,pending:true,pendingSections:['Other'],isolatedSections:['Main','Other'],isolatedReady:true});
state.subscriptionItemsWidget.pendingChanges={};await c.handleApply('Main');
assert.equal(payload,null,'peer runtime pending must not activate a clean target');
reset({busy:false,pending:true,pendingSections:['Main'],isolatedSections:['Main','Other'],isolatedReady:true});
state.subscriptionItemsWidget.pendingChanges={...other};await c.handleApply();
assert.deepEqual(Object.keys(payload||{}),['Other'],'a peer catalog update must not block or join the only user draft');
reset({busy:false,pending:true,pendingSections:['Main'],isolatedSections:['Main','Other'],isolatedReady:true});
state.subscriptionItemsWidget.pendingChanges={};await c.handleApply();
assert.equal(payload,null,'ordinary Apply cannot apply a catalog without a user draft');
const catalogButton=button({pendingSections:['Main'],isolatedSections:['Main','Other'],isolatedReady:true},'Main',{});
assert.match(catalogButton.children,/Применить каталог Main/,'catalog application is an explicit section action');
const allButtons=['Main','Other'].map(code=>button({pendingSections:[code],isolatedSections:['Main','Other'],isolatedReady:true},code,{}));
assert.ok(allButtons.every(b=>b && b.attrs.disabled===undefined),'collapsed isolated sections retain their action');
for(const error of ['section_memory_low','section_memory_unavailable']) {
  reset();outcome={success:true,data:{success:false,state:'rolled_back',error}};await c.handleApply('Main');
  assert.deepEqual({...state.subscriptionItemsWidget.pendingChanges},{...other,...main},'memory failure preserves drafts');
  assert.match(state.subscriptionItemsWidget.actionMessage,/памят/i);
  assert.match(state.subscriptionItemsWidget.actionMessage,/рабоч.*процесс.*не (?:измен|перезапущ)/i);
  assert.match(state.subscriptionItemsWidget.actionMessage,/выбор сохранён|черновик/i);
}
for(const error of ['section_runtime_start_failed','section_runtime_health_failed']) assert.notEqual(c.getSubscriptionActionErrorMessage(new Error(error),'fallback'),'fallback');
console.log('PASS: section Apply scopes payload, preserves peer drafts, and reconciles isolated workers safely');

