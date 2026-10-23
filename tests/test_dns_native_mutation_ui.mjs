import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source=fs.readFileSync(new URL('../openwrt/dns_benchmark.js',import.meta.url),'utf8');
class Node {
 constructor(tag,attrs={},children=[]){Object.assign(this,{tag,attrs,children:[],style:{},value:'',textContent:'',disabled:false,listeners:{}});this.append(children);}
 append(...children){this.children.push(...children.flat(Infinity).filter(x=>x!=null));}
 appendChild(child){this.children.push(child);return child;}
 replaceChildren(...children){this.children=[];this.append(children);}
 insertBefore(child,before){const old=this.children.indexOf(child);if(old>=0)this.children.splice(old,1);const index=before==null?this.children.length:this.children.indexOf(before);this.children.splice(index,0,child);}
 removeChild(child){this.children.splice(this.children.indexOf(child),1);}
 addEventListener(name,handler){this.listeners[name]=handler;}
 setAttribute(name,value){this.attrs[name]=value;}
 querySelector(){return null;}
 click(){return (this.listeners.click||this.attrs.click)?.({preventDefault(){}});}
}
const walk=n=>n instanceof Node?[n,...n.children.flatMap(walk)]:[];
const flush=()=>new Promise(resolve=>setImmediate(resolve));
const first={protocol:'udp',id:'alidns',dnsServer:'223.5.5.5',bootstrapProtocol:'udp',bootstrapDnsServer:'77.88.8.1',mainFamily:'alidns',bootstrapFamily:'yandex',success:true,successCount:2,totalQueries:2,averageMs:7,httpsTested:false};
const second={...first,id:'other',dnsServer:'dns.example',mainFamily:'other',bootstrapDnsServer:'45.90.28.0',bootstrapFamily:'nextdns'};
const native={state:'done',action:'select',reportId:'selection-1',selectionComplete:true,partial:false,scope:'direct_dns_pair',recommendation:first,secondaryRecommendation:second,pairResults:[first,second]};
const freshSettings={dns_type:'udp',dns_server:'223.5.5.5',bootstrap_dns_server:'77.88.8.1'};
const uciFixture=()=>({state:{values:{podkop:{settings:{}}}},changes:async()=>({}),callLoad:async()=>({settings:freshSettings}),unload(){throw new Error('must preserve shared drafts');},load:async()=>{throw new Error('must preserve shared drafts');}});
for(const action of ['apply','rollback']){
 let exported,modal,poll,reloaded=0,status=action==='apply'?native:{state:'idle',backupAvailable:true};
 const calls=[];
 const context=vm.createContext({baseclass:{extend:x=>(exported=x)},E:(...args)=>new Node(...args),
  document:{getElementById:()=>true},window:{setTimeout:fn=>(poll=fn,1),clearTimeout(){},location:{reload(){reloaded++;}}},
  ui:{showModal:(_title,children)=>{modal=new Node('modal',{},children);},hideModal(){}},
  uci:uciFixture(),
  fs:{exec:async(_path,args)=>{
   calls.push(args);const cmd=args[0];
   if(cmd==='status')return {code:0,stdout:JSON.stringify(status)};
   if(cmd==='catalog')return {code:0,stdout:JSON.stringify({success:true,availableResults:[],availableBootstrapResults:[]})};
   if(cmd==='reserve_status')return {code:0,stdout:JSON.stringify({success:true,reserve:null})};
   if(cmd==='apply_selected_start'||cmd==='rollback_start')status={state:'running',action,results:[],bootstrapResults:[],pairResults:[first,second],backupAvailable:true};
   return {code:0,stdout:'{"success":true}'};
  }}
 });
 vm.runInContext('(function(){'+source+'})()',context);
 exported.renderOpenButton({root:new Node('root')}).click();await flush();
 const button=label=>walk(modal).find(n=>n.tag==='button'&&n.children.includes(label));
 const trigger=button(action==='apply'?'Применить обе пары':'Откатить DNS');assert.equal(trigger.disabled,false);
 await trigger.click();await flush();
 assert.equal(walk(modal).find(n=>n.attrs.role==='alert').textContent,'','native historical rows must not break an in-flight mutation');
 status={...status,state:'done',message:action==='apply'?'apply_complete':'rollback_complete'};
 await poll();await flush();
 assert.equal(walk(modal).find(n=>n.attrs.role==='alert').textContent,'','successful mutation is not a malformed measurement');
 assert.equal(reloaded,0,'successful mutation keeps browser drafts instead of reloading');
 assert.equal(context.uci.state.values.podkop.settings.dns_server,freshSettings.dns_server,'successful mutation rebases DNS');
 assert.ok(walk(modal).some(n=>n.textContent.includes(action==='apply'?'применен':'восстановлены')),'confirmed mutation outcome is visible');
 assert.equal(button('Применить обе пары').disabled,true,'consumed selection cannot be applied again');
 assert.ok(calls.some(a=>a[0]===(action==='apply'?'apply_selected_start':'rollback_start')));
}
console.log('PASS: native selection history cannot mask apply/rollback results or DNS form synchronization');

for(const scenario of ['fresh','changed','not-ready','wrong-tuple','dirty','old-reserve']) {
 let exported,modal,poll,reloaded=0,status=scenario==='old-reserve'?{state:'done',action:'recommend_reserve',results:[],bootstrapResults:[],pairResults:[],reportId:'old-reserve'}:{state:'idle'},dirty=false;
 const calls=[];
 const main={protocol:'udp',id:'google',dnsServer:'8.8.8.8',primaryEligible:true};
 const bootstrap={protocol:'udp',server:'9.9.9.9',provider:'Quad9'};
 const pair={...main,bootstrapProtocol:'udp',bootstrapDnsServer:'9.9.9.9',success:true,reliable:true,httpsTested:false};
 const context=vm.createContext({baseclass:{extend:x=>(exported=x)},E:(...args)=>new Node(...args),
  document:{getElementById:()=>true},window:{setTimeout:fn=>(poll=fn,1),clearTimeout(){},location:{reload(){reloaded++;}}},
  ui:{showModal:(_title,children)=>{modal=new Node('modal',{},children);},hideModal(){}},
  uci:uciFixture(),
  fs:{exec:async(_path,args)=>{
   calls.push(args);
   if(args[0]==='status')return {code:0,stdout:JSON.stringify(status)};
   if(args[0]==='catalog')return {code:0,stdout:JSON.stringify({success:true,availableResults:[main],availableBootstrapResults:[bootstrap]})};
   if(args[0]==='reserve_status')return {code:0,stdout:'{"success":true,"reserve":null}'};
   if(args[0]==='light_pair_start')status={state:'done',action:'light_pair',reportId:'manual-1',scope:'direct_dns_pair',manualApplyReady:scenario!=='not-ready',pairResult:{...pair,dnsServer:scenario==='wrong-tuple'?'1.1.1.1':pair.dnsServer}};
   if(args[0]==='apply_manual_start')status={state:'running',action:'apply'};
   return {code:0,stdout:'{"success":true}'};
  }}
 });
 vm.runInContext('(function(){'+source+'})()',context);
 const root=new Node('root');root.querySelector=()=>dirty?{}:null;
 exported.renderOpenButton({root}).click();await flush();
 const button=label=>walk(modal).find(n=>n.tag==='button'&&n.children.includes(label));
 await button('Лёгкая проверка пары').click();await flush();
 const apply=button('Применить пару');
 assert.equal(apply.disabled,['not-ready','wrong-tuple'].includes(scenario),'fresh native proof enables only the exact manual tuple');
 if(scenario==='changed') {
  walk(modal).find(n=>n.tag==='select'&&n.attrs['aria-label']==='Основной DNS').listeners.change();
  assert.equal(apply.disabled,true,'changing selection invalidates proof');
 } else if(['fresh','dirty','old-reserve'].includes(scenario)) {
  dirty=scenario==='dirty';await apply.click();await flush();
  assert.equal(calls.some(a=>a[0]==='apply_manual_start'),true,'unrelated draft changes do not block native apply');
  assert.equal(calls.some(a=>a[0]==='apply_start'),false,'native proof never enters the full-HTTPS apply path');
  {
   assert.deepEqual(Array.from(calls.find(a=>a[0]==='apply_manual_start')),['apply_manual_start','manual-1']);
   status={state:'done',action:'apply',message:'apply_complete'};await poll();await flush();
   assert.equal(reloaded,0,'native manual apply preserves browser form');
   assert.equal(context.uci.state.values.podkop.settings.dns_server,freshSettings.dns_server,'manual apply rebases DNS');
  }
 }
}
console.log('PASS: manual native DNS proof, exact tuple binding, draft isolation and separate apply command');
