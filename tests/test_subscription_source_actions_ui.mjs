import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const js=fs.readFileSync(new URL('../openwrt/main.js',import.meta.url),'utf8');
assert.ok(js.includes('Подписки скачаны. Применение новых конфигов выполняется отдельно.'), 'refresh must not claim active configuration was updated');
const source={id:'one',sourceIndex:1,enabled:false};
const section={code:'main',displayName:'main',sources:[source,{id:'two',sourceIndex:2}],items:[
  {id:'a',supported:true,enabled:false,sourceIds:['one']},
  {id:'shared',supported:true,sourceIds:['one','two']},
  {id:'b',supported:true,sourceIds:['two']},
  {id:'unsupported',supported:false,sourceIds:['one']}
]};
const other={code:'other',displayName:'other',items:[{id:'other',supported:true}]};
let state={subscriptionItemsWidget:{data:[section,other],pendingChanges:{},latencyByRow:{'main:b':42},speedByRow:{'main:b':{success:true}},actionStatus:'idle'}};
const calls=[];
const c=vm.createContext({_:x=>x,E:(tag,attrs,children)=>({tag,attrs,children}),renderButton:options=>options,
  store:{get:()=>state,set:value=>{state={...state,...value}}},
  logger:{error:()=>{}},showToast:()=>{},
  canRunServiceAction:()=>true,canRefreshSubscriptions:()=>true,isSpeedtestRunning:()=>false,
  getSubscriptionSectionsForAction:async()=>[section,other],
  getEnabledSupportedItems:section=>section.items.filter(item=>item.supported),
  PodkopShellMethods:{
    pingSubscription:async(section,id)=>{calls.push(['ping',section,id]);return {success:true,data:{success:true,latencyMs:10}}},
    startSubscriptionSpeedtest:async(section,id)=>{calls.push(['speed',section,id]);return {success:true,data:{success:true}}},
    updateSubscriptions:async(section,id)=>{calls.push(['refresh',section,id]);return {success:true,data:{success:true}}}
  },
  pollSpeedtestStatus:async(section,item)=>({success:true,results:[{id:item.id,success:true}]}),
  fetchSubscriptionItems:async()=>{},speedtestRunToken:0
});
for(const name of ['getSourceGroups','getSubscriptionActionSections','getRowId2','retainOtherSubscriptionResults','renderSubscriptionSourceActions','setActionState','handlePingSubscriptions','handleSpeedtestSubscriptions','handleRefreshSubscriptions']) {
  const match=js.match(new RegExp(`(?:async )?function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n)`));
  assert.ok(match,name);
  for(const icon of match[0].match(/render\w+Icon24/g)||[])c[icon]=()=>{};
  vm.runInContext(match[0],c);
}
const target={sectionCode:'main',sourceId:'one'};
const grouped=c.getSubscriptionActionSections([section,other],target);
assert.equal(grouped.length,1);
assert.deepEqual(Array.from(grouped[0].items,item=>item.id),['a','shared','unsupported']);
assert.throws(()=>c.getSubscriptionActionSections([section],{sectionCode:'main',sourceId:'missing'}));
await c.handlePingSubscriptions(target);
assert.deepEqual(calls.splice(0),[['ping','main','a'],['ping','main','shared']]);
assert.equal(state.subscriptionItemsWidget.latencyByRow['main:b'],42);
await c.handleSpeedtestSubscriptions(target);
assert.deepEqual(calls.splice(0),[['speed','main','a'],['speed','main','shared']]);
assert.equal(state.subscriptionItemsWidget.speedByRow['main:b'].success,true);
await c.handleRefreshSubscriptions(target);
assert.deepEqual(calls.splice(0),[['refresh','main','one']]);
await c.handlePingSubscriptions();
assert.deepEqual(calls.splice(0),[['ping','main','a'],['ping','main','shared'],['ping','main','b'],['ping','other','other']]);
const retained=c.retainOtherSubscriptionResults({'main:a':1,'main:b':42,'missing':2},[section],target);
assert.deepEqual(Object.keys(retained),['main:b']);
const clicked=[];
const actions={disabled:false,refreshDisabled:false,onRefresh:t=>clicked.push(['refresh',t]),onPing:t=>clicked.push(['ping',t]),onSpeedtest:t=>clicked.push(['speed',t])};
const buttons=c.renderSubscriptionSourceActions(section,{...source,items:grouped[0].items},actions).children;
assert.equal(buttons.length,3);
for(const button of buttons){assert.equal(button.disabled,false);button.onClick();}
assert.deepEqual(clicked.map(([kind,t])=>[kind,t.sectionCode,t.sourceId]),[['refresh','main','one'],['ping','main','one'],['speed','main','one']]);
const stop=c.renderSubscriptionSourceActions(section,{...source,items:grouped[0].items},{...actions,disabled:true,refreshDisabled:true,speedRunning:true,target}).children;
assert.equal(stop[0].disabled,true);assert.equal(stop[1].disabled,true);assert.equal(stop[2].disabled,false);assert.equal(stop[2].text,'Stop');
console.log('PASS: individual actions scope RPC calls, preserve peer results, support disabled sources and keep global actions');
