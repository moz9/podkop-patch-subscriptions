import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source=fs.readFileSync(new URL('../openwrt/main.js',import.meta.url),'utf8');
const rows=[{code:'main-out',outbounds:[{code:'group',isGroup:true},{code:'one',latency:0,latencyState:'unknown'},{code:'two',latency:0,latencyState:'unknown'}]}];
let state={sectionsWidget:{data:structuredClone(rows)}};
const context=vm.createContext({store:{get:()=>state,set:patch=>{state={...state,...patch};}},PodkopShellMethods:{
 getClashApiProxyLatency:async()=>({success:true,data:{message:'An error occurred in the delay test'}}),
 getClashApiGroupLatency:async()=>({success:true,data:{one:100}})},
 fetchDashboardSections:async()=>{state.sectionsWidget.data=structuredClone(rows);}});
for(const name of ['applyDashboardProbeResult','handleTestGroupLatency','handleTestProxyLatency']){
 const code=source.match(new RegExp(`(?:async )?function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n|$)`));
 if(code)vm.runInContext(code[0],context);
}
await context.handleTestProxyLatency('one');
assert.equal(state.sectionsWidget.data[0].outbounds[1].latencyState,'unavailable','completed failed test must not remain unknown');
await context.handleTestGroupLatency('main-out');
assert.equal(state.sectionsWidget.data[0].outbounds[1].latency,100);
assert.equal(state.sectionsWidget.data[0].outbounds[2].latencyState,'unavailable','group omissions are failed probes, not untested nodes');
context.PodkopShellMethods.getClashApiProxyLatency=async()=>{throw Error('RPC disconnected');};
await context.handleTestProxyLatency('one');
assert.equal(state.sectionsWidget.latencyFetching,false,'RPC errors must release UI');
assert.equal(state.sectionsWidget.data[0].outbounds[1].latencyState,'error','RPC failure is not proof of an unreachable node');
assert.match(source,/latencyState === "error" \? "Ошибка проверки"/);
console.log('PASS: explicit failed probes, group omissions and RPC errors remain distinct from untested nodes');
