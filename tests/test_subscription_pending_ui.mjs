import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const js=fs.readFileSync(new URL('../openwrt/main.js',import.meta.url),'utf8');
let state={subscriptionItemsWidget:{pendingChanges:{'main:a':false},data:[{code:'main',items:[{id:'a',enabled:true}],sources:[]}],actionStatus:'idle'}};
const c=vm.createContext({store:{get:()=>state,set:x=>state={...state,...x}},_:x=>x,logger:{error(){}},showToast(){},
  uci:{callLoad:async()=>({main:{'.name':'main',connection_type:'proxy',proxy_config_type:'subscription_urltest'}})}, window:{setTimeout:callback=>queueMicrotask(callback)},
  CustomPodkopMethods:{getConfigSections:async()=>[{'.name':'main',connection_type:'proxy',proxy_config_type:'subscription_urltest'}]},
  PodkopShellMethods:{getSubscriptionItemsCached:async()=>({success:true,data:[{id:'a',enabled:true}]}),getSubscriptionSources:async()=>({success:true,data:[]}),setSubscriptionSectionsEnabled:async()=>({success:true,data:{success:false,error:'service_busy'}})},
  isActionRunning:()=>false,getPendingCount2:x=>Object.keys(x).length,getSubscriptionActionErrorMessage:(e,f)=>e.message||f
});
vm.runInContext('var subscriptionStatusGeneration=0; var subscriptionStatusTimer;',c);
for(const name of ['sleep','readSubscriptionSections','readSubscriptionSectionsWithRetry']) {
 const m=js.match(new RegExp(`(?:async )?function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n)`));
 assert.ok(m, `${name} must exist`);
 vm.runInContext(m[0],c);
}
for(const name of ['getRowId','getSourceId','getEffectiveEnabled','getEffectiveSubscriptionItemEnabled','getEffectiveSourceEnabled','getEffectiveSelectionMode','hasPendingSubscriptionModeChange','getStatusLabel','getSourceSummary','getSectionCollapsedSummary','isSubscriptionSectionCollapsed','isSubscriptionSourceCollapsed','handleToggleSection','handleToggleSource','getChangesBySection','buildSubscriptionSectionChanges','parseSubscriptionTagList','normalizeSubscriptionTags','getEffectiveSubscriptionTags','subscriptionTagMatches','isSubscriptionTagFiltered','getTagFilterPreview','fetchSubscriptionItems','handleApply','rebaseSubscriptionDraft','setActionState','subscriptionStateLabel','canRefreshSubscriptions','canRunServiceAction','refreshSubscriptionRuntimeStatus','getToolbarMessage']){
 const m=js.match(new RegExp(`(?:async )?function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n)`));
 if(m) vm.runInContext(m[0],c);
}
const source={id:'stable-source',sourceIndex:3};
assert.equal(c.isSubscriptionSectionCollapsed({},'main'),true,'sections start closed');
assert.equal(c.isSubscriptionSourceCollapsed({},'main',source),true,'sources start closed');
c.handleToggleSection('main');
c.handleToggleSource('main',source);
assert.equal(c.isSubscriptionSectionCollapsed(state.subscriptionItemsWidget.collapsedSections,'main'),false);
assert.equal(c.isSubscriptionSourceCollapsed(state.subscriptionItemsWidget.collapsedSources,'main',{...source,sourceIndex:8}),false,'source expansion follows stable ID after reordering');
assert.equal(c.isSubscriptionSectionCollapsed(state.subscriptionItemsWidget.collapsedSections,'peer'),true,'other sections remain closed');
await c.fetchSubscriptionItems();
assert.equal(c.isSubscriptionSectionCollapsed(state.subscriptionItemsWidget.collapsedSections,'main'),false,'fetch retains section expansion');
assert.equal(c.isSubscriptionSourceCollapsed(state.subscriptionItemsWidget.collapsedSources,'main',source),false,'fetch retains source expansion');
c.handleToggleSource('main',source);
c.handleToggleSection('main');
assert.equal(c.isSubscriptionSectionCollapsed(state.subscriptionItemsWidget.collapsedSections,'main'),true,'user can close section again');
assert.equal(c.isSubscriptionSourceCollapsed(state.subscriptionItemsWidget.collapsedSources,'main',source),true,'user can close source again');
assert.deepEqual([...c.parseSubscriptionTagList('🇷🇺 Москва *\nUS [abc]\n\n')],['🇷🇺 Москва *','US [abc]']);
assert.deepEqual([...c.parseSubscriptionTagList('🇵🇱 Польша ⚡️ \n  \n')],['🇵🇱 Польша ⚡️ '],'exact labels must keep trailing spaces');
assert.equal(c.subscriptionTagMatches('?? Россия','🇷🇺 Россия'),true,'question mark consumes one Unicode codepoint');
assert.equal(c.subscriptionTagMatches('Node [0-9]','Node 7'),true,'class range matches one codepoint');
assert.equal(c.subscriptionTagMatches('Cost $HOME;[*][?]','Cost $HOME;*?'),true,'shell text and wildcard class literals remain data');
assert.equal(c.subscriptionTagMatches('A[bc','A[bc'),true,'unmatched bracket is literal');
assert.equal(c.subscriptionTagMatches('A\\[bc\\]','A[bc]'),true,'escaped brackets are literal');
assert.equal(c.subscriptionTagMatches('Node [!0-9]','Node x'),true,'negated class matches non-digits');
assert.equal(c.subscriptionTagMatches('**','x'.repeat(300000)),true,'long untrusted node name must not overflow argument spreading');
const tagDraft={'main:tags:include':['🇷🇺 Москва *'],'main:tags:exclude':['*2'],'main:selection:mode':true,'main:a':false,'main:source:s':false};
const tagChanges=c.getChangesBySection(tagDraft);
const payload=c.buildSubscriptionSectionChanges('main',tagChanges.main);
assert.deepEqual(JSON.parse(JSON.stringify(payload)),{section:'main',selectionMode:'selected',includeTags:['🇷🇺 Москва *'],excludeTags:['*2'],changes:[{id:'a',enabled:false}],sources:[{id:'s',enabled:false}]});
assert.deepEqual({...c.rebaseSubscriptionDraft(tagDraft,[{code:'main',selectionMode:'all',includeTags:['🇷🇺 Москва *'],excludeTags:[],items:[{id:'a',enabled:true}],sources:[]}])},{'main:tags:exclude':['*2'],'main:selection:mode':true,'main:a':false,'main:source:s':false});
const preview=c.getTagFilterPreview({code:'main',items:[{id:'a',name:'🇷🇺 Москва 1',supported:true,enabled:true},{id:'b',name:'🇷🇺 Москва 2',supported:true,enabled:true},{id:'c',name:'US West',supported:true,enabled:true}],sources:[],includeTags:[],excludeTags:[]},{'main:tags:include':['🇷🇺 Москва ?'],'main:tags:exclude':['*2']});
assert.equal(preview.enabled,1);
assert.equal(preview.filtered,2);
assert.equal(c.getTagFilterPreview({code:'main',items:[{id:'a',name:'🇷🇺 Москва 1',supported:true,enabled:true,sourceIds:['s']}],sources:[{id:'s',sourceIndex:1,enabled:true}],includeTags:[],excludeTags:[]},{'main:source:s':false}).enabled,0,'source draft must be reflected in tag preview');
assert.equal(c.getStatusLabel({item:{supported:true},effectiveEnabled:true,tagFiltered:true,pending:false}),'Исключён фильтром тегов');
const summarySection={code:'main',displayName:'Основная',selectionMode:'all',includeTags:[],excludeTags:[],sources:[{id:'s',sourceIndex:1,enabled:true}],items:[{id:'a',name:'🇷🇺 Москва 1',sourceIds:['s'],supported:true,enabled:true},{id:'b',name:'US West',sourceIds:['s'],supported:true,enabled:true},{id:'c',name:'🇷🇺 Москва 2',sourceIds:['s'],supported:true,enabled:false}]};
const summaryDraft={'main:tags:include':['🇷🇺 Москва *']};
assert.match(c.getSectionCollapsedSummary(summarySection,summaryDraft),/3 конфигов · доступно 1 · фильтр тегов/);
assert.match(c.getSectionCollapsedSummary({...summarySection,selectionMode:'selected'},summaryDraft),/только выбранные · фильтр тегов/);
const summaryGroup={id:'s',sourceIndex:1,enabled:true,items:summarySection.items};
assert.match(c.getSourceSummary({section:summarySection,group:summaryGroup,pendingChanges:summaryDraft}),/Выбрано: 2\/3 \| Доступно: 1/);
assert.match(c.getSourceSummary({section:summarySection,group:summaryGroup,pendingChanges:{...summaryDraft,'main:source:s':false}}),/Выбрано: 2\/3 \| Доступно: 0 \| Выключена/);
const switchingSection={...summarySection,selectionMode:'selected',items:[{...summarySection.items[0],enabled:true},{...summarySection.items[1],enabled:false}]};
const switchingDraft={'main:selection:mode':false};
assert.match(c.getSectionCollapsedSummary(switchingSection,switchingDraft),/доступно сейчас 1 · после смены режима — после применения/);
assert.match(c.getSourceSummary({section:switchingSection,group:{...summaryGroup,items:switchingSection.items},pendingChanges:switchingDraft}),/Выбрано сейчас: 1\/2 \| Доступно сейчас: 1 \| После смены режима — после применения/);
const sourceRender=js.match(/function renderSourceGroup\([\s\S]*?\n}(?=\r?\n)/);
vm.runInContext(sourceRender[0],c);
c.E=(tag,attrs,children)=>({tag,attrs,children});
c.renderSubscriptionSourceActions=()=>({tag:'actions'});
c.renderSourceTable=()=>({tag:'table'});
const renderedSource=c.renderSourceGroup({section:summarySection,group:summaryGroup,pendingChanges:summaryDraft,collapsedSources:{},latencyByRow:{},speedByRow:{},applying:false,enabledSupportedCount:1,onToggle(){},onToggleSource(){},sourceActions:{}});
assert.equal(renderedSource.children[0].children[1].attrs['aria-expanded'],'false','source is initially announced collapsed');
assert.equal(renderedSource.children[0].children[0].tag,'label','source checkbox remains outside disclosure button');
await c.handleApply();
assert.equal(state.subscriptionItemsWidget.pendingChanges['main:a'],false,'busy/failed apply must preserve draft');
assert.equal(state.subscriptionItemsWidget.applying,false);
for (const runtimeStatus of [{busy:true},{unknown:true}]) {
 state.subscriptionItemsWidget.runtimeStatus=runtimeStatus;
 assert.equal(c.canRefreshSubscriptions(),false);
 assert.equal(c.canRunServiceAction(),false);
 const draft=state.subscriptionItemsWidget.pendingChanges;
 await c.handleApply();
 assert.equal(state.subscriptionItemsWidget.pendingChanges,draft);
}
assert.equal(c.subscriptionStateLabel({runtimeStatus:{busy:true}})[1],'Podkop занят');
assert.equal(c.subscriptionStateLabel({runtimeStatus:{pending:true}})[1],'Нужно применить');
assert.equal(c.subscriptionStateLabel({})[1],'Готово');
assert.match(c.getToolbarMessage({runtimeStatus:{busy:true}}),/Кнопки станут доступны автоматически/);
assert.match(c.getToolbarMessage({runtimeStatus:{pending:true}}),/ещё не используются/);
assert.deepEqual({...c.rebaseSubscriptionDraft({'main:a':false,'main:b':false},[{code:'main',items:[{id:'a',enabled:false}]}])},{'main:b':false});
let finish, calls=0;
c.PodkopShellMethods.setSubscriptionSectionsEnabled=()=>{calls++;return new Promise(resolve=>finish=resolve)};
state.subscriptionItemsWidget.runtimeStatus={busy:false};
state.subscriptionItemsWidget.actionStatus='idle';
const applying=c.handleApply();
await c.handleApply();
assert.equal(calls,1,'double click must not start a second apply');
finish({success:true,data:{success:true}});
await applying;
assert.equal(Object.keys(state.subscriptionItemsWidget.pendingChanges).length,0);
state.subscriptionItemsWidget.actionError='service_busy';
state.subscriptionItemsWidget.actionStatus='error';
c.PodkopShellMethods.getSubscriptionOperationStatus=async()=>({success:true,data:{busy:false,pending:false}});
await c.refreshSubscriptionRuntimeStatus();
assert.equal(state.subscriptionItemsWidget.actionStatus,'idle','busy error recovers when the router becomes ready');
const ready=state.subscriptionItemsWidget;
await c.refreshSubscriptionRuntimeStatus();
assert.equal(state.subscriptionItemsWidget,ready,'unchanged status must not redraw the table and lose focus');
c.PodkopShellMethods.getSubscriptionOperationStatus=()=>new Promise(resolve=>finish=resolve);
const oldPoll=c.refreshSubscriptionRuntimeStatus();
vm.runInContext('subscriptionStatusGeneration++',c);
finish({success:true,data:{busy:true}});
await oldPoll;
assert.equal(state.subscriptionItemsWidget,ready,'unmounted poll cannot overwrite the new tab');
console.log('PASS: drafts survive failures, busy/unknown states block actions, and double apply is prevented');
