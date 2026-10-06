import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const file = new URL('../openwrt/dns_benchmark.js',import.meta.url);
assert.ok(fs.existsSync(file),'PE has a dedicated DNS benchmark UI');
let exported;
const context=vm.createContext({baseclass:{extend:x=>(exported=x)},fs:{},ui:{},uci:{},E:()=>{},document:{},window:{}});
vm.runInContext('(function(){'+fs.readFileSync(file,'utf8')+'})()',context);
const candidate={protocol:'doh',id:'google',provider:'Google',dnsServer:'dns.google',successCount:3,totalQueries:4,averageMs:22.5,reliable:false,primaryEligible:true};
const report=exported.normalizeReport({results:[candidate],bootstrapResults:[{id:'google_1',provider:'Google',server:'8.8.8.8',successCount:4,totalQueries:4,averageMs:15,reliable:true}]});
assert.equal(report.results[0].averageMs,22.5);
for(const invalid of [{...candidate,successCount:5},{...candidate,averageMs:-1},{...candidate,protocol:'unknown'},{...candidate,dnsServer:''}]){
 assert.throws(()=>exported.normalizeReport({results:[invalid],bootstrapResults:[]}));
}
assert.throws(()=>exported.normalizeReport({results:Array(161).fill(candidate),bootstrapResults:[]}));
const pair={protocol:'doh',id:'google',dnsServer:'dns.google',bootstrapDnsServer:'8.8.8.8'};
assert.equal(exported.pairMatches(pair,{...pair,success:true}),true);
assert.equal(exported.pairMatches(pair,{...pair,bootstrapDnsServer:'1.1.1.1',success:true}),false);
assert.equal(exported.pairMatches(pair,{...pair,success:false}),false);
for(const code of ['busy','pair_not_verified','verification_expired','configuration_changed','worker_stopped','cancelled','invalid_pair']){
 assert.match(exported.errorMessage(code),/[А-Яа-яЁё]/,code+' readable in Russian');
}
const settings=fs.readFileSync(new URL('../openwrt/settings.js',import.meta.url),'utf8');
assert.match(settings,/require view\.podkop\.dns_benchmark as dnsBenchmark/);
assert.match(settings,/dnsBenchmark\.renderOpenButton\(this\.map\)/);
assert.doesNotMatch(settings,/dnsOptimizerState\.node = renderDnsOptimizer\(\)/);
// Exercise the actual modal handlers with a minimal DOM, not a second UI implementation.
class Node {
 constructor(tag,attrs,children){this.tag=tag;this.attrs=attrs||{};this.children=[];this.style={};this.disabled=false;this.value='';this.textContent='';this.listeners={};this.append(...(Array.isArray(children)?children:[children]));}
 append(...children){for(const child of children.flat(Infinity))if(child!=null)this.children.push(child);}
 replaceChildren(...children){this.children=[];this.append(...children);}
 addEventListener(name,handler){this.listeners[name]=handler;}
 querySelector(){return null;}
 click(){return (this.listeners.click||this.attrs.click)?.({preventDefault(){}});}
}
let modal,pending=false,reloaded=false,failureCommand='',statusFailure=false,status={state:'idle'},nextStatus=status;const calls=[];
const good={...candidate,successCount:4,reliable:true};
const complete={state:'done',action:'benchmark',results:[good],bootstrapResults:report.bootstrapResults,progress:100};
const walk=node=>node instanceof Node?[node,...node.children.flatMap(walk)]:[];
const button=label=>walk(modal).find(n=>n.tag==='button'&&n.children.includes(label));
const flush=()=>new Promise(r=>setImmediate(r));
const ctx=vm.createContext({baseclass:{extend:x=>(exported=x)},
 E:(tag,attrs,children)=>new Node(tag,attrs,children),
 document:{getElementById:()=>true,createElement:()=>new Node('style'),head:{appendChild(){}}},
 window:{setTimeout:()=>1,clearTimeout(){},location:{reload(){reloaded=true;}}},
 ui:{showModal:(title,children)=>{modal=new Node('modal',{},children)},hideModal:()=>{}},
 uci:{changes:async()=>pending?{podkop:[{}]}:{},unload(){},load:async()=>{}},
 fs:{exec:async(path,args)=>{calls.push(args);const command=args[0];
   if(command===failureCommand)return {code:1,stdout:JSON.stringify({success:false,error:'busy'})};
   if(command==='status'&&statusFailure)return {code:1,stdout:'not-json'};
   if(command==='status')status=nextStatus;
   if(command==='benchmark_start')nextStatus=complete;
   if(command==='pair_test_start')nextStatus={...complete,action:'pair_test',pairResult:{...pair,success:true}};
   if(command==='apply_start')nextStatus={...complete,action:'apply'};
   return {code:0,stdout:JSON.stringify(command==='status'?status:{success:true})};
 }}
});
vm.runInContext('(function(){'+fs.readFileSync(file,'utf8')+'})()',ctx);
exported.renderOpenButton({root:new Node('root')}).click();await flush();
pending=true;await button('Проверить DNS').click();await flush();
assert.ok(!calls.some(a=>a[0]==='benchmark_start'),'pending settings block measurement');
pending=false;await button('Проверить DNS').click();await flush();
assert.ok(calls.some(a=>a[0]==='benchmark_start'));
assert.equal(button('Применить пару').disabled,true,'unverified pair cannot be applied');
await button('Проверить пару').click();await flush();
assert.equal(button('Применить пару').disabled,false,'successful exact pair unlocks Apply');
await button('Применить пару').click();await flush();
assert.ok(calls.some(a=>a[0]==='apply_start'));
assert.equal(button('Применить пару').disabled,true,'Apply consumes verification');
assert.equal(reloaded,true,'server-side apply reloads LuCI to avoid saving a stale form');
status=nextStatus={state:'idle'}; failureCommand='benchmark_start';
exported.renderOpenButton({root:new Node('root')}).click();await flush();
await button('Проверить DNS').click();await flush();
assert.ok(walk(modal).some(n=>n.textContent.includes('Podkop ещё применяет')),'nonzero backend response retains actionable busy reason');
failureCommand='';status=nextStatus={state:'idle'};
exported.renderOpenButton({root:new Node('root')}).click();await flush();
statusFailure=true;await button('Проверить DNS').click();await flush();
assert.equal(button('Проверить DNS').disabled,true,'accepted worker stays busy if first status request fails');
console.log('PASS: PE DNS report validation, exact pair matching, Russian errors and settings integration');
