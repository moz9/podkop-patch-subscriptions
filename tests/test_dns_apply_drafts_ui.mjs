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
  querySelector(){return this.tag==='root'?{}:null;}
  click(){return (this.listeners.click||this.attrs.click)?.({preventDefault(){}});}
}
const walk=n=>n instanceof Node?[n,...n.children.flatMap(walk)]:[];
const flush=()=>new Promise(resolve=>setImmediate(resolve));
const primary={protocol:'udp',id:'alidns',dnsServer:'223.5.5.5',bootstrapProtocol:'udp',bootstrapDnsServer:'77.88.8.1',mainFamily:'alidns',bootstrapFamily:'yandex',success:true,successCount:2,totalQueries:2,averageMs:7,httpsTested:false};
const secondary={...primary,id:'other',dnsServer:'dns.example',mainFamily:'other',bootstrapDnsServer:'45.90.28.0',bootstrapFamily:'nextdns'};
const selection={state:'done',action:'select',reportId:'selection-1',selectionComplete:true,partial:false,scope:'direct_dns_pair',recommendation:primary,secondaryRecommendation:secondary,pairResults:[primary,secondary]};
const before={dns_type:'udp',dns_server:'8.8.8.8',bootstrap_dns_type:'udp',bootstrap_dns_server:'1.1.1.1',secondary_dns_enabled:'1',secondary_dns_type:'udp',secondary_dns_server:'9.9.9.9',secondary_bootstrap_dns_type:'udp',secondary_bootstrap_dns_server:'77.88.8.8',dns_failover_enabled:'0',dns_failover_active_slot:'primary',dns_optimizer_candidates:['google'],unrelated:'old'};
const after={...before,dns_type:'doh',dns_server:'dns.new.example',secondary_dns_server:'dns.reserve.example',dns_optimizer_candidates:['server-list'],unrelated:'server-value'};

async function fixture({action='apply',conflict,readFailure=false,readValues=after}={}) {
  let exported,modal,poll,status=action==='apply'?selection:{state:'idle',backupAvailable:true},reloads=0,loads=0;
  const calls=[],writes=[];
  const options=new Map(Object.entries(before).map(([name,value])=>{
    const option={baseline:value,current:value,marker:true,sets:0,default:'',cfgvalue(sid,next){if(arguments.length===2)this.baseline=next;return this.baseline;},formvalue(){return this.current;},getUIElement(){return {node:{getAttribute:()=>option.marker?'true':null,removeAttribute:()=>{option.marker=false;}},isChanged:()=>option.marker,setValue(next){option.current=next;option.marker=true;option.sets++;}};}};
    return [name,option];
  }));
  options.get('dns_optimizer_candidates').current=['cloudflare','google'];
  options.get('unrelated').current='my browser draft';
  const uci={state:{values:{podkop:{settings:{...before},main:{filter:'old'}}},changes:{podkop:{main:{filter:'my saved draft'}}},deletes:{},creates:{}},
    changes:async()=>({podkop:[['set','main','filter','my saved draft']]}),
    callLoad:async()=>{loads++;if(readFailure)throw new Error('offline');return {settings:{...readValues},main:{filter:'server-value'}};},
    unload(){throw new Error('must not discard shared UCI state');},load(){throw new Error('must not replace shared UCI state');},set(...args){writes.push(args);}};
  if(conflict==='form')options.get('dns_server').current='my.manual.example';
  if(conflict==='staged')uci.state.changes.podkop.settings={dns_server:'my.staged.example'};
  if(conflict==='delete')uci.state.deletes.podkop={settings:{dns_server:true}};
  const context=vm.createContext({baseclass:{extend:x=>(exported=x)},E:(...args)=>new Node(...args),
    document:{getElementById:()=>true},window:{setTimeout:fn=>(poll=fn,1),clearTimeout(){},location:{reload(){reloads++;}}},
    ui:{showModal:(_title,children)=>{modal=new Node('modal',{},children);},hideModal(){}},uci,
    fs:{exec:async(_path,args)=>{
      calls.push(args);const cmd=args[0];
      if(cmd==='status')return {code:0,stdout:JSON.stringify(status)};
      if(cmd==='catalog')return {code:0,stdout:JSON.stringify({success:true,availableResults:[],availableBootstrapResults:[]})};
      if(cmd==='reserve_status')return {code:0,stdout:'{"success":true,"reserve":null}'};
      if(cmd==='apply_selected_start'||cmd==='rollback_start')status={state:'running',action,pairResults:[primary,secondary],backupAvailable:true};
      return {code:0,stdout:'{"success":true}'};
    }}
  });
  vm.runInContext('(function(){'+source+'})()',context);
  exported.renderOpenButton({root:new Node('root'),lookupOption:name=>[options.get(name)]}).click();await flush();
  const button=label=>walk(modal).find(n=>n.tag==='button'&&n.children.includes(label));
  return {options,uci,calls,writes,button,get texts(){return walk(modal).map(n=>n.textContent);},get reloads(){return reloads;},get loads(){return loads;},get error(){return walk(modal).find(n=>n.attrs.role==='alert').textContent;},
    async apply(){await button(action==='apply'?'Применить обе пары':'Откатить DNS').click();await flush();},
    async finish(){status={...status,state:'done',message:action==='apply'?'apply_complete':'rollback_complete'};await poll();await flush();},
    allowRead(){readFailure=false;}};
}

for(const action of ['apply','rollback']) {
  const f=await fixture({action});
  await f.apply();
  assert.ok(f.calls.some(a=>a[0]===(action==='apply'?'apply_selected_start':'rollback_start')),'unrelated browser drafts and stale markers must not block DNS '+action);
  await f.finish();
  assert.equal(f.error,'');assert.equal(f.reloads,0,'do not reload away unrelated browser drafts');assert.equal(f.loads,1);
  for(const name of Object.keys(before).filter(n=>!['unrelated','dns_optimizer_candidates'].includes(n))) {
    assert.equal(f.options.get(name).current,after[name],name+' follows saved DNS');
    assert.equal(f.options.get(name).baseline,after[name],name+' has no stale form baseline');
    assert.equal(f.uci.state.values.podkop.settings[name],after[name],name+' has no stale UCI baseline');
  }
  assert.deepEqual(f.options.get('dns_optimizer_candidates').current,['cloudflare','google']);
  assert.equal(f.options.get('unrelated').current,'my browser draft');
  assert.equal(f.uci.state.values.podkop.settings.unrelated,'old');
  assert.equal(f.uci.state.changes.podkop.main.filter,'my saved draft');
  assert.equal(f.uci.state.values.podkop.main.filter,'old');
  assert.equal(f.writes.length,0);assert.equal(f.button('Закрыть').disabled,false);
  assert.ok(f.texts.some(t=>t.includes('Сохранённый резерв: dns.reserve.example')),'reserve status follows the completed DNS transaction without a page reload');
  assert.equal(f.button('Применить обе пары').disabled,true,'proof consumed only once');
}
for(const conflict of ['form','staged','delete']) {
  const f=await fixture({conflict});await f.apply();
  assert.ok(!f.calls.some(a=>a[0]==='apply_selected_start'),'do not overwrite a real DNS draft: '+conflict);
  assert.match(f.error,/Основной DNS/,'name the conflicting field');
  assert.doesNotMatch(f.error,/изменения Podkop|Затем запускайте проверку/,'do not demand applying all Podkop drafts');
  assert.equal(f.button('Применить обе пары').disabled,false,'conflict refusal preserves the selection proof');
}
{
  const f=await fixture({readFailure:true});await f.apply();await f.finish();
  assert.match(f.error,/Обновить поля DNS/,'a readback failure explains how to recover without reapplying');
  assert.equal(f.button('Закрыть').disabled,true,'do not expose a stale form for ordinary Save');
  f.allowRead();await f.button('Обновить поля DNS').click();await flush();
  assert.equal(f.error,'');assert.equal(f.button('Закрыть').disabled,false);
  assert.equal(f.calls.filter(a=>a[0]==='apply_selected_start').length,1,'readback retry never repeats apply');
  assert.equal(f.options.get('unrelated').current,'my browser draft');
}
{
  const f=await fixture();await f.apply();
  f.options.get('dns_server').current='edit-during-apply.example';
  f.uci.state.changes.podkop.settings={dns_server:'staged-during-apply.example'};
  await f.finish();
  assert.equal(f.options.get('dns_server').current,'edit-during-apply.example');
  assert.equal(f.options.get('dns_server').baseline,after.dns_server);
  assert.equal(f.uci.state.changes.podkop.settings.dns_server,'staged-during-apply.example');
}
{
  const f=await fixture();
  f.uci.state.changes.podkop.settings={dns_server:before.dns_server,unrelated:'keep'};
  await f.apply();await f.finish();
  assert.equal(f.uci.state.changes.podkop.settings.dns_server,undefined,'redundant old-value delta must not undo DNS on the next ordinary Save');
  assert.equal(f.uci.state.changes.podkop.settings.unrelated,'keep');
}
{
  const readValues={...after};delete readValues.secondary_dns_enabled;delete readValues.dns_failover_active_slot;
  const f=await fixture({action:'rollback',readValues});await f.apply();await f.finish();
  for(const name of ['secondary_dns_enabled','dns_failover_active_slot']) {
    assert.equal(f.options.get(name).current,'');assert.equal(f.options.get(name).baseline,undefined);
    assert.equal(Object.hasOwn(f.uci.state.values.podkop.settings,name),false,'rollback can remove optional settings');
  }
}
for(const readValues of [{},{...after,dns_server:[]},{...after,secondary_dns_type:[]}]) {
  const f=await fixture({readValues});await f.apply();await f.finish();
  assert.match(f.error,/Обновить поля DNS/);
  assert.equal(f.options.get('dns_server').current,before.dns_server,'invalid readback does not partially rewrite the form');
  assert.equal(f.button('Закрыть').disabled,true);
}
console.log('PASS: scoped DNS conflicts, draft-preserving form rebase, rollback and readback recovery');
