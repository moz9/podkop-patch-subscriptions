import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const js=fs.readFileSync(new URL('../openwrt/main.js',import.meta.url),'utf8');
const now=1900000000;
const c=vm.createContext({Error,Date:{now:()=>now*1000},_:x=>x,E:(tag,attrs,children)=>({tag,attrs,children})});
for(const name of ['getEffectiveEnabled','getEffectiveSubscriptionItemEnabled','getEffectiveSelectionMode','getRowId','getEffectiveSubscriptionTags','getEffectiveSourceEnabled','subscriptionTagMatches','isSubscriptionTagFiltered','buildSubscriptionSectionChanges','getEffectiveRequiredServices','getSubscriptionServiceExclusions','getSubscriptionServiceStateLabel','canConfirmSubscriptionService','renderSubscriptionServiceFilter','normalizeSubscriptionServiceEvidence','isSubscriptionServiceEvidenceFresh','getSubscriptionServiceCheckTargets','getSubscriptionServiceRoutingHint']){
 const match=js.match(new RegExp(`function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n)`));
 assert.ok(match,`${name} must exist`);
 vm.runInContext(match[0],c);
}
const section={code:'geo',requiredServices:[],serviceSupport:true,items:[]};
assert.match(c.getSubscriptionServiceRoutingHint({...section,communityLists:['google_ai']},['gemini']),/Google AI выбран в этой секции/);
assert.match(c.getSubscriptionServiceRoutingHint(section,['gemini']),/Секции.*Списки.*фильтр узлов маршруты не меняет/i);
assert.equal(c.getSubscriptionServiceRoutingHint({...section,communityLists:['google_ai']},['chatgpt']),'','do not invent OpenAI routing lists or show unrelated Gemini hints');
assert.deepEqual(JSON.parse(JSON.stringify(c.normalizeSubscriptionServiceEvidence({id:'a',checkedAt:now-10,expiresAt:now+30,services:{gemini:{state:'unknown',network:'pass',manual:false}}}))),{gemini:{state:'unknown',network:'pass',manual:false,checkedAt:now-10,expiresAt:now+30}},'backend row-level TTL must be honored');
assert.deepEqual([...c.getEffectiveRequiredServices({},section)],[],'filter defaults off');
const draft={'geo:services:required':['gemini','chatgpt']};
assert.deepEqual([...c.getEffectiveRequiredServices(draft,section)],['gemini','chatgpt']);
assert.deepEqual(JSON.parse(JSON.stringify(c.buildSubscriptionSectionChanges('geo',[{id:'services:required',enabled:['gemini']},{id:'a',enabled:false}]))),{section:'geo',requiredServices:['gemini'],changes:[{id:'a',enabled:false}],sources:[]});
const item={id:'a',services:{gemini:{state:'pass',expiresAt:now+30,checkedAt:now-60},chatgpt:{state:'unknown',expiresAt:now+30,checkedAt:now-60,network:true}}};
const targetPool={items:[{...item,supported:true},{id:'b',supported:true,services:{gemini:{state:'fail',expiresAt:now+30,checkedAt:now-60}}},{id:'c',supported:true,services:{gemini:{state:'pass',expiresAt:now-1}}},{id:'d',supported:false}]};
assert.deepEqual(c.getSubscriptionServiceCheckTargets(targetPool,['gemini']).map(row=>row.id).join(','),'c','fresh pass/fail/unknown must all be cached');
assert.deepEqual(c.getSubscriptionServiceCheckTargets(targetPool,['gemini','chatgpt']).map(row=>row.id).join(','),'b,c','adding required service checks only nodes missing its evidence');
assert.deepEqual(c.getSubscriptionServiceCheckTargets(targetPool,['gemini'],true).map(row=>row.id).join(','),'a,b,c','force explicitly rechecks every supported node');
assert.deepEqual([...c.getSubscriptionServiceExclusions(item,['gemini'])],[]);
assert.deepEqual([...c.getSubscriptionServiceExclusions(item,['gemini','chatgpt'])],['chatgpt']);
assert.deepEqual([...c.getSubscriptionServiceExclusions(item,['youtube'])],['youtube'],'unknown evidence fails closed');
assert.deepEqual([...c.getSubscriptionServiceExclusions({...item,services:{gemini:{state:'pass',expiresAt:now}}},['gemini'])],['gemini'],'expired pass fails closed');
assert.equal(c.canConfirmSubscriptionService('gemini',item.services.chatgpt),true);
assert.equal(c.canConfirmSubscriptionService('gemini',{state:'unknown',network:'pass',expiresAt:now+30,checkedAt:now-60}),true);
assert.equal(c.canConfirmSubscriptionService('gemini',{state:'unknown',network:false,expiresAt:now+30,checkedAt:now-60}),false);
assert.equal(c.canConfirmSubscriptionService('gemini',{state:'unknown',network:true,expiresAt:now-1}),false);
assert.match(c.getSubscriptionServiceStateLabel({state:'unknown',network:true,expiresAt:now+30,checkedAt:now-60}),/Требует подтверждения/i);
assert.equal(c.getSubscriptionServiceStateLabel({state:'pass',manual:false,expiresAt:now+30,checkedAt:now-60}),'Предварительно проходит');
assert.equal(c.getSubscriptionServiceStateLabel({state:'pass',manual:true,expiresAt:now+30,checkedAt:now-60}),'Подтверждён вами');
assert.doesNotMatch(c.getSubscriptionServiceStateLabel({state:'unknown',network:'fail',expiresAt:now+30,checkedAt:now-60}),/Сеть проверена/);
let toggled;
const filter=c.renderSubscriptionServiceFilter(section,draft,false,(...args)=>toggled=args,{});
const walk=node=>[node,...(Array.isArray(node?.children)?node.children.flatMap(walk):[])];
const gemini=walk(filter).find(node=>node?.tag==='input'&&node.attrs.value==='gemini');
gemini.attrs.change({target:{checked:false}});
assert.deepEqual(JSON.parse(JSON.stringify(toggled)),['geo',{id:'services:required',enabled:[]},['chatgpt']]);
assert.match(JSON.stringify(filter),/HTTP 200/,'must distinguish public HTTP reachability from chat proof');
const unsupported=c.renderSubscriptionServiceFilter({...section,serviceSupport:false},draft,false,()=>{},{});
assert.match(JSON.stringify(unsupported),/не поддерживает/i,'old backend must not silently ignore filter');
console.log('PASS: service draft, all-required admission, expiry, proof labels and fixed selector');
for(const name of ['getEffectiveEnabled','getEffectiveSubscriptionItemEnabled','getEffectiveSelectionMode','getRowId','getRowId2','getEffectiveSubscriptionTags','getEffectiveSourceEnabled','subscriptionTagMatches','isSubscriptionTagFiltered','hasPendingSubscriptionModeChange','getTagFilterPreview','getStatusLabel','rebaseSubscriptionDraft','getSourceSummary']){
 const match=js.match(new RegExp(`function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n)`));
 assert.ok(match,`${name} must exist`);vm.runInContext(match[0],c);
}
const pool={...section,items:[{...item,supported:true,enabled:true},{id:'b',supported:true,enabled:true}]};
assert.equal(c.getTagFilterPreview(pool,{'geo:services:required':['gemini']}).enabled,1,'preview excludes nodes without current proof');
assert.match(c.getStatusLabel({item:{supported:true},effectiveEnabled:true,serviceExcluded:['gemini'],tagFiltered:false}),/сервис/i);
assert.deepEqual({...c.rebaseSubscriptionDraft({...draft,'geo:a':false},[{...pool,requiredServices:['gemini','chatgpt']}])},{'geo:a':false},'persisted service draft rebase does not lose node choices');
assert.deepEqual({...c.rebaseSubscriptionDraft(draft,[{...pool,requiredServices:['chatgpt','gemini']}])},{},'service order has no meaning when rebasing the committed draft');
const group={id:'s',items:pool.items,enabled:true};
const subset={code:'geo',selectionMode:'selected',includeTags:['US*'],sources:[{id:'on',enabled:true},{id:'off',enabled:false}],items:[
 {id:'eligible',name:'US unknown',supported:true,enabled:true,sourceIds:['on']},
 {id:'manual-no',name:'US not selected',supported:true,enabled:false,sourceIds:['on']},
 {id:'wrong-tag',name:'SE wrong tag',supported:true,enabled:true,sourceIds:['on']},
 {id:'source-off',name:'US source off',supported:true,enabled:true,sourceIds:['off']}
]};
assert.equal(c.getSubscriptionServiceCheckTargets(subset,['gemini']).map(row=>row.id).join(','),'eligible','do not probe manual-excluded, tag-excluded or source-disabled nodes');
assert.equal(c.getSubscriptionServiceCheckTargets(subset,['gemini'],true,{'geo:manual-no':true,'geo:source:off':true}).map(row=>row.id).join(','),'eligible,manual-no,source-off','force respects the effective draft subset, ignoring only the service gate');
assert.deepEqual([...c.getSubscriptionServiceExclusions({services:{gemini:{state:'pass',checkedAt:now+1,expiresAt:now+30}}},['gemini'])],['gemini'],'future timestamps cannot admit a node');
assert.match(c.getSubscriptionServiceStateLabel({state:'pass',checkedAt:now+1,expiresAt:now+30}),/устарела/i,'malformed timestamp must not be labelled passing');
assert.equal(c.getSubscriptionServiceCheckTargets({items:[{id:'bad-date',supported:true,services:{gemini:{state:'pass',expiresAt:now+30}}}]},['gemini']).length,1,'missing checkedAt requires a new observation');
assert.match(c.getSourceSummary({section:pool,group,pendingChanges:{'geo:services:required':['gemini']}}),/Доступно: 1/);
console.log('PASS: service eligibility is reflected in preview, source counts, status and draft recovery');
let state={subscriptionItemsWidget:{data:[pool],pendingChanges:{'geo:a':false},actionStatus:'idle'}};
const calls=[];
c.store={get:()=>state,set:value=>state={...state,...value}};
c.isActionRunning=()=>false;
c.getSubscriptionActionErrorMessage=(error,fallback)=>error?.message||fallback;
c.PodkopShellMethods={
 checkSubscriptionServices:async(code,id,services)=>{calls.push([code,id,[...services]]);c.handleCancelSubscriptionServices();return {success:true,data:{success:true}};},
 getSubscriptionServices:async()=>({success:true,data:{success:true,requiredServices:[],catalog:[],results:[{id:'a',services:item.services}]}})
};
for(const name of ['setActionState','handleCancelSubscriptionServices','handleCheckSubscriptionServices','refreshSubscriptionServiceEvidence']){
 const match=js.match(new RegExp(`(?:async )?function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n)`));assert.ok(match,`${name} must exist`);vm.runInContext(match[0],c);
}
await c.handleCheckSubscriptionServices('geo',['gemini']);
assert.equal(calls.length,1,'cancellation finishes current node but never starts later nodes');
assert.equal(state.subscriptionItemsWidget.actionStatus,'idle');
assert.equal(state.subscriptionItemsWidget.pendingChanges['geo:a'],false,'isolated checks must preserve unrelated drafts');
assert.deepEqual(JSON.parse(JSON.stringify(state.subscriptionItemsWidget.data[0].items[0].services)),item.services);
console.log('PASS: isolated sequential service checks cancel safely and preserve drafts');
for(const name of ['getErrorText','getSubscriptionActionErrorMessage']) {
 const match=js.match(new RegExp(`function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n)`));assert.ok(match);vm.runInContext(match[0],c);
}
assert.match(c.getSubscriptionActionErrorMessage(new Error('service_manual_links_unsupported'),'generic fallback'),/отдельные proxy-ссылки/i,'manual links must not bypass the service filter silently');
assert.match(c.getSubscriptionActionErrorMessage(new Error('service_snapshot_storage_unavailable'),'generic fallback'),/безопасную копию.*свободное место или локальные списки.*не применены/i,'snapshot preparation failures must not be misreported as applied changes or certain low space');
assert.match(JSON.stringify(filter),/Для конфигов подписок; отдельные proxy-ссылки не проверяются/,'selector must state its supported scope');
console.log('PASS: unsupported manual links receive an explicit service filter error');
calls.length=0;
state.subscriptionItemsWidget={data:[{...pool,items:[{...item,supported:true},{...item,id:'b',supported:true}]}],pendingChanges:{'geo:a':false},actionStatus:'idle'};
c.PodkopShellMethods.checkSubscriptionServices=async(code,id,services)=>{calls.push([code,id,[...services]]);return {success:true,data:{success:true}};};
await c.handleCheckSubscriptionServices('geo',['gemini']);
assert.equal(calls.length,0,'default action must perform zero RPC probes for fully fresh evidence');
await c.handleCheckSubscriptionServices('geo',['gemini'],true);
assert.equal(calls.length,2,'force action explicitly probes cached nodes');
assert.match(JSON.stringify(filter),/Перепроверить всё/);
assert.match(JSON.stringify(filter),/24 часа/);
assert.match(JSON.stringify(filter),/плюс запуск.*не гарантированный срок/i);
console.log('PASS: default checks skip cached observations; explicit force rechecks all');
