import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {createHash} from 'node:crypto';

const source = fs.readFileSync(new URL('../openwrt/main.js', import.meta.url), 'utf8');
const clone = value => JSON.parse(JSON.stringify(value));
const extract = name => {
  const match = source.match(new RegExp(`(?:async )?function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n)`));
  assert.ok(match, `${name} is part of the shipped bundle`);
  return match[0];
};
const walk = node => [node, ...(Array.isArray(node?.children) ? node.children.flatMap(walk) : [])];
const section = code => ({code,displayName:code,selectionMode:'all',includeTags:[],excludeTags:[],communityLists:[],requiredServices:[],
  serviceSupport:true,serviceCatalog:[],items:[{id:'one',name:'First',supported:true,enabled:true,services:{}},{id:'two',name:'Second',supported:true,enabled:true,services:{}}],sources:[{id:'source',enabled:true}]});
function backend(sections = [section('Main'),section('Other')]) {
  const db = {sections:clone(sections),writes:[],reads:0,downloads:0,checks:0,status:{busy:false,pending:false},failRead:false,
    snapshotOverride:null,writeError:null,timeout:false,timeoutCommits:false,readHook:null};
  const stamp = row => ({...clone(row),revision:createHash('sha256').update(JSON.stringify(row)).digest('hex')});
  db.snapshot = () => ({success:true,data:{success:true,version:1,sections:db.sections.map(stamp)}});
  db.rpc = async (method,args) => {
    if (method==='get_subscription_snapshot') {
      db.reads++;
      if (db.readHook) return db.readHook();
      if (db.failRead) return {success:false,error:'read interrupted'};
      return db.snapshotOverride || db.snapshot();
    }
    if (method==='get_subscription_operation_status') return {success:true,data:clone(db.status)};
    if (method==='subscription_services_check') {
      db.checks++;
      const row=db.sections.find(row=>row.code===args[0]);
      const item=row.items.find(item=>item.id===args[1]);
      for (const service of JSON.parse(args[2])) item.services[service]={state:'pass',checkedAt:100,expiresAt:100000000000};
      return {success:true,data:{success:true}};
    }
    if (method==='set_subscription_sections_enabled') {
      const payload=JSON.parse(args[0]); db.writes.push(payload);
      if (db.writeError) return {success:true,data:{success:false,error:db.writeError,committed:false,reloaded:false}};
      for (const change of payload.sections) {
        const saved=db.sections.find(row=>row.code===change.section);
        if (!change.expectedRevision || !saved || stamp(saved).revision!==change.expectedRevision)
          return {success:true,data:{success:false,error:change.expectedRevision?'revision_conflict':'revision_required',committed:false,reloaded:false}};
      }
      if (!db.timeout || db.timeoutCommits) for (const change of payload.sections) {
        const saved=db.sections.find(row=>row.code===change.section);
        for (const key of ['selectionMode','includeTags','excludeTags','requiredServices']) if (key in change) saved[key]=clone(change[key]);
        for (const {id,enabled} of change.changes) saved.items.find(item=>item.id===id).enabled=enabled;
        for (const {id,enabled} of change.sources) saved.sources.find(item=>item.id===id).enabled=enabled;
      }
      if (db.timeout) {db.status={busy:true,pending:true}; throw new Error('RPC timeout');}
      return {success:true,data:{success:true,committed:true,reloaded:true}};
    }
    if (/update/.test(method)) {db.downloads++; throw new Error('unexpected network refresh');}
    throw new Error(`Unexpected legacy read or write RPC: ${method}`);
  };
  return db;
}
function tab(db) {
  let widget={data:[],pendingChanges:{},draftRevisions:{},draftConflicts:{},loading:false,failed:false,applying:false,latencyByRow:{},speedByRow:{},actionStatus:'idle',runtimeStatus:clone(db.status)};
  let modal=null;
  const context=vm.createContext({
    store:{get:()=>({subscriptionItemsWidget:widget}),set:state=>{widget=state.subscriptionItemsWidget;},unsubscribe(){}},
    Podkop:{AvailableMethods:{SET_SUBSCRIPTION_SECTIONS_ENABLED:'set_subscription_sections_enabled'}},
    callBaseMethod:(...args)=>db.rpc(...args),
    uci:{callLoad(){throw new Error('snapshot must not read or touch LuCI UCI');}},
    window:{setTimeout:fn=>queueMicrotask(fn)},setTimeout(){},clearTimeout(){},
    logger:{error(){}},showToast(){},_:text=>text,
    E:(tag,attrs,children)=>({tag,attrs,children}),
    ui:{showModal:(title,children)=>{modal={tag:'modal',title,children};},hideModal:()=>{modal=null;}},onStoreUpdate3(){},
    getSubscriptionServiceCheckTargets:(row,services,force,draft)=>row.items.filter(item=>item.supported).slice(0,1)
  });
  const methodsStart=source.indexOf('var PodkopShellMethods = {');
  const methodsEnd=source.indexOf('\n};',methodsStart)+3;
  vm.runInContext(source.slice(methodsStart,methodsEnd),context);
  for (const name of ['buildSubscriptionSectionChanges','normalizeSubscriptionServiceEvidence','getEffectiveSelectionMode','getErrorText','getSubscriptionResourceErrorMessage','getSubscriptionActionErrorMessage','onPageUnmount3']) vm.runInContext(extract(name),context);
  const start=source.indexOf('// src/podkop/tabs/subscriptions/initController.ts');
  const stop=source.indexOf('async function handlePingSubscriptions(',start);
  vm.runInContext(source.slice(start,stop),context);
  return {context, get widget(){return widget;},get modal(){return modal;},
    edit(code,id,value){const row=widget.data.find(row=>row.code===code);const item=id.startsWith('source:')?{id,enabled:row.sources.find(source=>source.id===id.slice(7)).enabled}:row.items.find(item=>item.id===id)||{id,enabled:[]};context.handleToggle(code,item,value);},
    async load(){await context.fetchSubscriptionItems();},
    async apply(code){await context.handleApply(code);},
    review(code){context.handleReviewSubscriptionDraft(code);assert.ok(modal,'conflict offers explicit review');},
    acceptReview(){const button=walk(modal).find(node=>node?.tag==='button'&&/подтвердить просмотр|Подтвердить просмотр/.test(node.children));assert.ok(button);button.attrs.click();},
    set(values){widget={...widget,...values};}
  };
}

// Tab A commits; stale B sends its original token and cannot silently overwrite A.
{
  const db=backend(),a=tab(db),b=tab(db);await a.load();await b.load();
  const original=b.widget.data[0].revision;
  a.edit('Main','one',false);b.edit('Main','two',false);
  await a.apply('Main');const afterA=JSON.stringify(db.sections);
  await b.apply('Main');
  assert.equal(db.writes[1].sections[0].expectedRevision,original);
  assert.equal(JSON.stringify(db.sections),afterA,'stale tab retains byte-identical saved state');
  assert.equal(b.widget.pendingChanges['Main:two'],false);
  assert.equal(b.widget.draftRevisions.Main,original);
  assert.ok(b.widget.draftConflicts.Main);
  await b.apply('Main');await b.load();await b.apply('Main');
  assert.equal(db.writes.length,2,'reads and repeated apply cannot approve a changed base');
  b.review('Main');b.acceptReview();
  assert.equal(db.writes.length,2,'explicit review does not itself apply');
  assert.equal(b.widget.draftRevisions.Main,b.widget.data[0].revision);
  await b.apply('Main');assert.equal(db.writes.length,3);
  assert.deepEqual(db.sections[0].items.map(item=>item.enabled),[false,false]);
  assert.deepEqual(clone(b.widget.pendingChanges),{});
}

// Different sections retain independent draft bases through another section's apply/read.
{
  const db=backend(),t=tab(db);await t.load();t.edit('Main','one',false);t.edit('Other','two',false);
  const other=t.widget.draftRevisions.Other;
  await t.apply('Main');await t.load();
  assert.equal(t.widget.draftRevisions.Other,other);
  assert.equal(t.widget.pendingChanges['Other:two'],false);
  await t.apply('Other');assert.equal(db.writes[1].sections[0].expectedRevision,other);
  assert.deepEqual(db.writes.map(write=>write.sections.map(row=>row.section)),[['Main'],['Other']]);
}

// A read cannot erase matching intent or removed item/source choices, and review must be explicit.
{
  const db=backend(),t=tab(db);await t.load();t.edit('Main','one',false);t.edit('Main','source:source',false);t.edit('Main','two',false);
  const original=t.widget.draftRevisions.Main;
  db.sections[0].items=db.sections[0].items.filter(item=>item.id!=='one');db.sections[0].sources=[];db.sections[0].items[0].enabled=false;
  await t.load();
  assert.deepEqual(clone(t.widget.pendingChanges),{'Main:one':false,'Main:source:source':false,'Main:two':false});
  assert.equal(t.widget.draftRevisions.Main,original);
  t.review('Main');assert.match(JSON.stringify(t.modal),/Main:one.*больше нет/);assert.match(JSON.stringify(t.modal),/Main:source:source.*больше нет/);
  t.acceptReview();assert.deepEqual(clone(t.widget.pendingChanges),{'Main:two':false},'only explicitly reviewed dropped choices are discarded');
  assert.equal(db.writes.length,0);
}

// Deleted sections remain visible as conflicts and require explicit discard.
{
  const db=backend(),t=tab(db);await t.load();t.edit('Main','one',false);db.sections.shift();await t.load();
  assert.ok(t.widget.draftConflicts.Main);t.review('Main');assert.match(JSON.stringify(t.modal),/Секция удалена/);
  assert.equal(t.widget.pendingChanges['Main:one'],false);t.acceptReview();assert.deepEqual(clone(t.widget.pendingChanges),{});
}

// Conflict refresh failing does not lose the draft/base or unlock apply; later read stays stale.
{
  const db=backend(),a=tab(db),b=tab(db);await a.load();await b.load();a.edit('Main','one',false);b.edit('Main','two',false);
  const original=b.widget.draftRevisions.Main;await a.apply('Main');db.failRead=true;await b.apply('Main');
  assert.equal(b.widget.failed,true);assert.equal(b.widget.draftRevisions.Main,original);await b.apply('Main');assert.equal(db.writes.length,2);
  db.failRead=false;await b.context.handleRefreshSubscriptions();assert.equal(db.downloads,0);assert.equal(b.widget.draftRevisions.Main,original);assert.ok(b.widget.draftConflicts.Main);
}

// A known successful apply with interrupted reread is read-only recovered; peer draft is untouched.
{
  const db=backend(),t=tab(db);await t.load();t.edit('Main','one',false);t.edit('Other','two',false);
  const original=t.widget.draftRevisions.Main,other=t.widget.draftRevisions.Other;
  db.failRead=true;await t.apply('Main');assert.equal(t.widget.draftRevisions.Main,original);assert.ok(t.widget.applyCommitted);
  await t.apply('Main');assert.equal(db.writes.length,1);
  db.failRead=false;await t.context.handleRefreshSubscriptions();assert.equal(db.writes.length,1);assert.equal(db.downloads,0);
  assert.deepEqual(clone(t.widget.pendingChanges),{'Other:two':false});assert.equal(t.widget.draftRevisions.Other,other);
}

// Timeout verification never automatically writes or silently rebases the unresolved draft.
for (const commits of [false,true]) {
  const db=backend(),t=tab(db);await t.load();t.edit('Main','one',false);t.edit('Other','two',false);
  const original=t.widget.draftRevisions.Main,other=t.widget.draftRevisions.Other;
  db.timeout=true;db.timeoutCommits=commits;await t.apply('Main');assert.ok(t.widget.applyVerification);assert.equal(t.widget.draftRevisions.Main,original);
  db.status={busy:false,pending:false};await t.context.refreshSubscriptionRuntimeStatus();assert.equal(db.writes.length,1);assert.equal(t.widget.draftRevisions.Other,other);
  if (commits) {assert.equal(t.widget.status,'success');assert.deepEqual(clone(t.widget.pendingChanges),{'Other:two':false});}
  else {assert.ok(t.widget.applyUnconfirmed);assert.equal(t.widget.draftRevisions.Main,original);assert.ok(t.widget.draftConflicts.Main);await t.apply('Main');assert.equal(db.writes.length,1);}
}

// Service proof refresh returns a coherent new snapshot; existing drafts cannot auto-adopt its token.
{
  const db=backend(),t=tab(db);await t.load();const old=t.widget.data[0].revision;
  await t.context.handleCheckSubscriptionServices('Main',['gemini'],true);
  assert.notEqual(t.widget.data[0].revision,old);assert.equal(t.widget.data[0].items[0].services.gemini.state,'pass');
  t.edit('Main','one',false);const base=t.widget.draftRevisions.Main;
  db.sections[0].items[0].services.gemini.checkedAt++;
  await t.context.refreshSubscriptionServiceEvidence('Main');
  assert.equal(t.widget.draftRevisions.Main,base);assert.ok(t.widget.draftConflicts.Main);assert.equal(db.writes.length,0);
}

// Changing a review's saved base while the dialog is open requires reviewing the new snapshot again.
{
  const db=backend(),t=tab(db);await t.load();t.edit('Main','one',false);db.sections[0].includeTags=['US'];await t.load();t.review('Main');
  const base=t.widget.draftRevisions.Main;db.sections[0].excludeTags=['RU'];await t.load();t.acceptReview();assert.equal(t.widget.draftRevisions.Main,base);assert.ok(t.widget.draftConflicts.Main);
}

// Missing/version-mismatched snapshot or missing draft revision blocks every mutation route.
for (const response of [
  {success:true,data:{success:true,sections:[]}},
  {success:true,data:{success:true,version:2,sections:[]}},
  {success:true,data:{success:true,version:1,sections:[section('Main')]}},
  {success:false,error:'unknown command get_subscription_snapshot'}
]) {
  const db=backend(),t=tab(db);db.snapshotOverride=response;await t.load();
  assert.equal(t.widget.snapshotBundleMismatch,true);assert.equal(db.reads,1,'bundle mismatch is not a transient retry');
  assert.match(t.widget.actionMessage,/Обновите патч.*перезагрузите страницу/);await t.apply();assert.equal(db.writes.length,0);
}
{
  const db=backend(),t=tab(db);await t.load();t.set({pendingChanges:{'Main:one':false}});await t.load();
  assert.equal(t.widget.snapshotBundleMismatch,true);await t.apply('Main');assert.equal(db.writes.length,0);
  await assert.rejects(t.context.PodkopShellMethods.setSubscriptionLinkEnabled('Main','one',false),/revision_required/);
  await assert.rejects(t.context.PodkopShellMethods.setSubscriptionLinksEnabled('Main',[{id:'one',enabled:false}]),/revision_required/);
  assert.equal(db.writes.length,0,'compatibility helpers cannot obtain an implicit fresh token');
}
{
  const db=backend(),t=tab(db);await t.load();t.edit('Main','one',false);db.writeError='revision_required';await t.apply('Main');
  assert.equal(t.widget.snapshotBundleMismatch,true);await t.load();await t.apply('Main');assert.equal(db.writes.length,1,'mismatch remains disabled until bundle reload');
}

// An old, interrupted read cannot overwrite a new mount's snapshot or draft base.
{
  const db=backend(),t=tab(db);await t.load();t.edit('Main','one',false);const base=t.widget.draftRevisions.Main;
  let finish;const old=db.snapshot();db.readHook=()=>new Promise(resolve=>{finish=resolve;});const stale=t.load();
  for(let i=0;i<5&&!finish;i++) await Promise.resolve();assert.equal(typeof finish,'function');
  t.context.onPageUnmount3();db.readHook=null;db.sections[0].includeTags=['new'];await t.load();const latest=t.widget.data[0].revision;
  finish(old);await stale;assert.equal(t.widget.data[0].revision,latest);assert.equal(t.widget.draftRevisions.Main,base);assert.ok(t.widget.draftConflicts.Main);
}

// One stale row prevents the whole multi-section mutation; neither base is replaced implicitly.
{
  const db=backend(),t=tab(db);await t.load();t.edit('Main','one',false);t.edit('Other','two',false);
  const bases=clone(t.widget.draftRevisions);db.sections[1].includeTags=['external'];const before=JSON.stringify(db.sections);
  await t.apply();assert.equal(JSON.stringify(db.sections),before);assert.equal(db.writes[0].sections.length,2);
  assert.deepEqual(clone(t.widget.draftRevisions),bases);assert.equal(Object.keys(t.widget.pendingChanges).length,2);
}

// A stale peer must not block an explicitly scoped apply for an unaffected section.
{
  const db=backend(),t=tab(db);await t.load();t.edit('Main','one',false);t.edit('Other','two',false);
  const other=t.widget.draftRevisions.Other;db.sections[1].excludeTags=['external'];await t.load();
  assert.ok(t.widget.draftConflicts.Other);await t.apply('Main');assert.equal(db.writes.length,1);
  assert.deepEqual(db.writes[0].sections.map(row=>row.section),['Main']);assert.equal(t.widget.draftRevisions.Other,other);assert.ok(t.widget.draftConflicts.Other);
}

// An acknowledged commit clears only its unchanged submitted keys, even if backend normalizes them.
// A newer local edit made while the request is outstanding must remain for explicit review.
{
  const db=backend(),t=tab(db);await t.load();t.edit('Main','one',false);t.edit('Other','two',false);
  let release;const original=t.context.PodkopShellMethods.setSubscriptionSectionsEnabled;
  t.context.PodkopShellMethods.setSubscriptionSectionsEnabled=async(...args)=>{const result=await original(...args);await new Promise(resolve=>{release=resolve;});return result;};
  const applying=t.apply('Main');for(let i=0;i<10&&!release;i++)await Promise.resolve();assert.equal(typeof release,'function');
  t.set({pendingChanges:{...t.widget.pendingChanges,'Main:one':true}});release();await applying;
  assert.equal(t.widget.pendingChanges['Main:one'],true);assert.equal(t.widget.pendingChanges['Other:two'],false);assert.ok(t.widget.draftConflicts.Main);
}
{
  const db=backend(),t=tab(db);await t.load();t.edit('Main','one',false);
  t.context.PodkopShellMethods.setSubscriptionSectionsEnabled=async()=>({success:true,data:{success:true,committed:true,reloaded:true}});
  await t.apply('Main');assert.deepEqual(clone(t.widget.pendingChanges),{},'acknowledged success may normalize a submitted choice');
}

// Snapshot evidence honors per-service timestamps and row-level fallback without merging stale RPCs.
{
  const db=backend(),t=tab(db);db.sections[0].items[0]={...db.sections[0].items[0],checkedAt:100,expiresAt:200,
    services:{gemini:{state:'pass'},chatgpt:{state:'pass',checkedAt:90,expiresAt:150}}};
  await t.load();const proof=t.widget.data[0].items[0].services;
  assert.equal(proof.gemini.checkedAt,100);assert.equal(proof.gemini.expiresAt,200);
  assert.equal(proof.chatgpt.checkedAt,90);assert.equal(proof.chatgpt.expiresAt,150);
}

// Visible toolbar blocks stale/global and mismatched-bundle apply while exposing read-only recovery.
{
  const db=backend(),t=tab(db);await t.load();
  for(const name of ['getToolbarMessage','getToolbarClass','renderToolbar','renderSubscriptionState']) vm.runInContext(extract(name),t.context);
  t.context.renderButton=props=>({tag:'button',attrs:{disabled:props.disabled,title:props.title},children:props.text});
  for(const name of ['renderRotateCcwIcon24','renderSearchIcon24','renderCircleStopIcon24','renderSquareChartGanttIcon24'])t.context[name]=()=>null;
  for(const props of [{draftConflicts:{Main:'revision_conflict'}},{snapshotBundleMismatch:true}]) {
    const tree=t.context.renderToolbar({pendingCount:1,actionStatus:'idle',runtimeStatus:{busy:false},...props});
    assert.equal(walk(tree).find(node=>node.tag==='button'&&node.children==='Apply').attrs.disabled,true);
  }
  const tree=t.context.renderToolbar({pendingCount:1,actionStatus:'idle',runtimeStatus:{busy:false},draftConflicts:{Main:'revision_conflict'}});
  assert.equal(walk(tree).find(node=>node.tag==='button'&&node.children==='Refresh').attrs.disabled,false);
  assert.match(walk(tree).find(node=>node.tag==='button'&&node.children==='Refresh').attrs.title,/чтение/);
}

console.log('PASS: shipped CAS UI handlers protect stale tabs, isolated drafts, dropped choices, read recovery, service proof, bundle mismatch and interrupted mounts');
