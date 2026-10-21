import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source=fs.readFileSync(process.argv[2]||new URL('../openwrt/main.js',import.meta.url),'utf8');
let state;
const context=vm.createContext({Error,Map,store:{get:()=>state,set:value=>state={...state,...value}},
 isActionRunning:()=>false,getSubscriptionServiceCheckTargets:section=>section.items,
 normalizeSubscriptionServiceEvidence:row=>row.services,
 getSubscriptionActionErrorMessage:(_error,fallback)=>fallback});
for(const name of ['setActionState','refreshSubscriptionServiceEvidence','getSubscriptionServiceCheckError','handleCheckSubscriptionServices']){
 const match=source.match(new RegExp(`(?:async )?function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n)`));
 if(match)vm.runInContext(match[0],context);
}
const section={code:'main',displayName:'main',serviceSupport:true,items:[{id:'one',name:'SE First'},{id:'two',name:'FI Second'}]};
const reset=()=>state={subscriptionItemsWidget:{data:[section],pendingChanges:{'main:one':false},actionStatus:'idle'}};
let calls=[];
context.PodkopShellMethods={
 checkSubscriptionServices:async(_section,id)=>{calls.push(id);return id==='two'?{success:true,data:{success:false,error:'probe_config_invalid',diagnostic:{stage:'config_check',error:'probe_config_invalid'}}}:{success:true,data:{success:true}};},
 getSubscriptionServices:async()=>({success:true,data:{success:true,results:[],requiredServices:[]}})
};
reset();await context.handleCheckSubscriptionServices('main',['gemini']);
assert.match(state.subscriptionItemsWidget.actionMessage,/main.*FI Second.*probe_config_invalid/,'fatal result must identify the exact failed node and error');
assert.match(state.subscriptionItemsWidget.actionMessage,/config_check/,'preserve diagnostic stage');
assert.equal(calls.join(','),'one,two');
assert.equal(state.subscriptionItemsWidget.pendingChanges['main:one'],false);
reset();calls=[];
context.PodkopShellMethods.checkSubscriptionServices=async()=>{throw new Error('request timed out https://secret.example/token');};
await context.handleCheckSubscriptionServices('main',['gemini']);
assert.match(state.subscriptionItemsWidget.actionMessage,/SE First.*request_timeout/);
assert.doesNotMatch(state.subscriptionItemsWidget.actionMessage,/secret|https:/);
reset();
context.PodkopShellMethods.checkSubscriptionServices=async()=>({success:true,data:{success:true}});
context.PodkopShellMethods.getSubscriptionServices=async()=>{throw new Error('broken raw response');};
await context.handleCheckSubscriptionServices('main',['gemini']);
assert.match(state.subscriptionItemsWidget.actionMessage,/SE First.*read_results.*request_failed/);
assert.doesNotMatch(state.subscriptionItemsWidget.actionMessage,/broken raw response/);
console.log('PASS: services errors retain section/node/stage/code and preserve drafts without exposing raw transport data');
for(const name of ['isSubscriptionServiceEvidenceFresh','getSubscriptionServiceStateLabel']){
 const match=source.match(new RegExp(`function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n)`));vm.runInContext(match[0],context);
}
const now=Date.now()/1000;
assert.match(context.getSubscriptionServiceStateLabel({state:'unknown',reason:'network_failed',curlCode:28,checkedAt:now-1,expiresAt:now+100}),/curl 28/,'ordinary network failure retains concrete curl code');
