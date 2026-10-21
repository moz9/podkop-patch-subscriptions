import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const js=fs.readFileSync(new URL('../openwrt/main.js',import.meta.url),'utf8');
const body=js.match(/async function refreshSubscriptionSources\([\s\S]*?\n}(?=\r?\n)/);
assert.ok(body,'global refresh must avoid a single long-running LuCI request');
const calls=[],progress=[];
const c=vm.createContext({Error,store:{get:()=>({subscriptionItemsWidget:{data:[
 {code:'main',sources:[{id:'a'},{id:'b'}]}, {code:'GEOBLOCK',sources:[{id:'a'},{id:'b'}]}
]}})},setActionState:value=>progress.push(value),PodkopShellMethods:{updateSubscriptions:async(...args)=>{calls.push(args);return {success:true,data:{success:true}};}}});
vm.runInContext(body[0],c);
await c.refreshSubscriptionSources();
assert.deepEqual(calls,[['main','a'],['main','b'],['GEOBLOCK','a'],['GEOBLOCK','b']]);
assert.match(progress.at(-1).actionMessage,/4\/4/,'bounded source progress is visible');
calls.length=0;
await c.refreshSubscriptionSources({sectionCode:'GEOBLOCK',sourceId:'b'});
assert.deepEqual(calls,[['GEOBLOCK','b']],'targeted refresh stays targeted');
calls.length=0;
c.PodkopShellMethods.updateSubscriptions=async(...args)=>{calls.push(args);return {success:false,error:'request_timeout'};};
await assert.rejects(c.refreshSubscriptionSources(),/request_timeout/);
assert.equal(calls.length,1,'unconfirmed work is not followed by another potentially overlapping mutation');
calls.length=0;
c.PodkopShellMethods.updateSubscriptions=async(...args)=>{calls.push(args);return {success:true,data:{success:false,error:'download_failed'}};};
assert.equal((await c.refreshSubscriptionSources()).data.success,false,'ordinary source failure is never reported as success');
assert.equal(calls.length,4,'confirmed source failure does not prevent other independent sources from being refreshed');
console.log('PASS: sequential per-source refresh, visible progress, targeted identity and no overlap after uncertain timeout');
