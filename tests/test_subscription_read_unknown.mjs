import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source=fs.readFileSync(new URL('../openwrt/main.js',import.meta.url),'utf8');
function extract(name){const i=source.search(new RegExp('^(?:async )?function '+name+'\\(','m'));assert(i>=0);return source.slice(i,source.indexOf('\n}',i)+2);}
let widget;
const ctx={store:{get:()=>({subscriptionItemsWidget:widget})},isActionRunning:()=>['running','verifying'].includes(widget.actionStatus),getPendingCount2:o=>Object.keys(o).length};
vm.createContext(ctx);vm.runInContext(extract('canRefreshSubscriptions'),ctx);
const base={failed:true,loading:false,applying:false,pendingChanges:{'main:item':false},runtimeStatus:{unknown:true}};
widget=structuredClone(base);assert.equal(ctx.canRefreshSubscriptions(),true,'read retry blocked by missing status');
for(const flag of ['loading','applying','applyVerification']){widget={...base,[flag]:true};assert.equal(ctx.canRefreshSubscriptions(),false,flag);}
widget={...base,runtimeStatus:{busy:true}};assert.equal(ctx.canRefreshSubscriptions(),false);
widget={...base,failed:false,pendingChanges:{}};assert.equal(ctx.canRefreshSubscriptions(),false,'unknown status allowed subscription download');
let reads=0,statusReads=0,writes=0;
Object.assign(ctx,{refreshSubscriptionRuntimeStatus:async()=>{statusReads++},fetchSubscriptionItems:async()=>{reads++},PodkopShellMethods:{updateSubscriptions:async()=>{writes++;throw Error('mutation forbidden')}},setActionState:()=>{throw Error('mutation branch reached')}});
vm.runInContext(extract('handleRefreshSubscriptions'),ctx);
widget=structuredClone(base);const draft=widget.pendingChanges;await ctx.handleRefreshSubscriptions();
assert.equal(reads,1);assert.equal(writes,0);assert.equal(widget.pendingChanges,draft);assert.equal(statusReads,1);
console.log('PASS: unknown-status read recovery preserves drafts and mutation guards');
