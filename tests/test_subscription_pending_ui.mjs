import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const js=fs.readFileSync(new URL('../openwrt/main.js',import.meta.url),'utf8');
let state={subscriptionItemsWidget:{pendingChanges:{'main:a':false},data:[{code:'main',items:[{id:'a',enabled:true}],sources:[]}],actionStatus:'idle'}};
const c=vm.createContext({store:{get:()=>state,set:x=>state={...state,...x}},_:x=>x,logger:{error(){}},showToast(){},
  CustomPodkopMethods:{getConfigSections:async()=>[{'.name':'main',connection_type:'proxy',proxy_config_type:'subscription_urltest'}]},
  PodkopShellMethods:{getSubscriptionItemsCached:async()=>({success:true,data:[{id:'a',enabled:true}]}),getSubscriptionSources:async()=>({success:true,data:[]}),setSubscriptionSectionsEnabled:async()=>({success:true,data:{success:false,error:'service_busy'}})},
  isActionRunning:()=>false,getPendingCount2:x=>Object.keys(x).length,getSubscriptionActionErrorMessage:(e,f)=>e.message||f
});
vm.runInContext('var subscriptionStatusGeneration=0; var subscriptionStatusTimer;',c);
for(const name of ['getChangesBySection','fetchSubscriptionItems','handleApply','rebaseSubscriptionDraft','setActionState','subscriptionStateLabel','canRefreshSubscriptions','canRunServiceAction','refreshSubscriptionRuntimeStatus','getToolbarMessage']){
 const m=js.match(new RegExp(`(?:async )?function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n)`));
 if(m) vm.runInContext(m[0],c);
}
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
