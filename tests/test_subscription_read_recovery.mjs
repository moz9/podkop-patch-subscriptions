import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../openwrt/main.js', import.meta.url), 'utf8');
const revision = 'a'.repeat(64);
function extract(name) {
  const match = source.match(new RegExp(`(?:async )?function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n)`));
  assert.ok(match, `${name} must exist in the LuCI bundle`);
  return match[0];
}
const defaultSection={code:'main',displayName:'main',revision,selectionMode:'selected',includeTags:['RU *'],excludeTags:['*slow'],
  requiredServices:[],serviceSupport:false,serviceCatalog:[],communityLists:[],items:[{id:'node',enabled:true,services:{}}],sources:[{id:'source',enabled:true}]};
function makeHarness({sections=[defaultSection],getSnapshot}={}) {
  const calls={snapshots:0,callLoad:[],items:[],sources:[],sleep:[],writes:[]};
  const cachedConfig={main:{'.name':'main',connection_type:'proxy',proxy_config_type:'subscription_urltest',subscription_selection_mode:'all'},
    newDraft:{'.name':'newDraft',connection_type:'proxy',proxy_config_type:'manual',proxy_string:'unsaved local draft'}};
  const cachedSnapshot=JSON.stringify(cachedConfig);
  const methods={
    getSubscriptionSnapshot:async()=>{calls.snapshots++;return getSnapshot?getSnapshot(calls.snapshots):{success:true,data:{success:true,version:1,sections}};},
    getSubscriptionItemsCached:async()=>{calls.items.push('forbidden');throw new Error('independent items read is incoherent');},
    getSubscriptionSources:async()=>{calls.sources.push('forbidden');throw new Error('independent sources read is incoherent');},
    setSubscriptionSectionsEnabled:async()=>{calls.writes.push('apply');throw new Error('reading cannot apply');},
    updateSubscription:async()=>{calls.writes.push('refresh');throw new Error('reading cannot download');}
  };
  const context=vm.createContext({
    PodkopShellMethods:methods,
    uci:{unload(){throw new Error('must not discard unsaved changes');},callLoad(){calls.callLoad.push('forbidden');throw new Error('snapshot must not stitch UCI data');}},
    window:{setTimeout:(callback,ms)=>{calls.sleep.push(ms);queueMicrotask(callback);}}
  });
  for(const name of ['normalizeSubscriptionServiceEvidence','sleep','readSubscriptionSections','readSubscriptionSectionsWithRetry']) vm.runInContext(extract(name),context);
  return {context,calls,methods,cachedConfig,cachedSnapshot};
}
{
  const {context,calls,cachedConfig,cachedSnapshot}=makeHarness();
  const result=await context.readSubscriptionSections();
  assert.equal(calls.snapshots,1,'policy, identities and proof must come from one coherent operation');
  assert.deepEqual(calls.callLoad,[],'snapshot must not read LuCI saved/staged data independently');
  assert.equal(JSON.stringify(cachedConfig),cachedSnapshot,'unsaved local UCI data remains unchanged');
  assert.deepEqual(calls.items,[]);assert.deepEqual(calls.sources,[]);
  assert.deepEqual(JSON.parse(JSON.stringify(result)),[defaultSection],'revision, policy and lists stay together');
  assert.deepEqual(calls.writes,[]);
}
// The backend owns legacy mode normalization. The UI trusts its explicit mode,
// even when LuCI still caches a different saved mode or unsaved legacy fields.
for(const selectionMode of ['auto','all','selected']) {
  const {context,calls,cachedConfig,cachedSnapshot}=makeHarness({sections:[{...defaultSection,selectionMode}]});
  const result=await context.readSubscriptionSections();
  assert.equal(result[0].selectionMode,selectionMode,'coherent backend mode wins over stale LuCI mode');
  assert.equal(JSON.stringify(cachedConfig),cachedSnapshot);
  assert.deepEqual(calls.callLoad,[]);assert.deepEqual(calls.writes,[]);
}
{
  const retries=[];
  const {context,calls,cachedConfig,cachedSnapshot}=makeHarness({getSnapshot:attempt=>attempt===1?{success:false,error:'temporary read failure'}:{success:true,data:{success:true,version:1,sections:[defaultSection]}}});
  const result=await context.readSubscriptionSectionsWithRetry(attempt=>retries.push(attempt));
  assert.equal(result[0].items.length,1);assert.equal(calls.snapshots,2);
  assert.equal(JSON.stringify(cachedConfig),cachedSnapshot);assert.deepEqual(calls.callLoad,[]);
  assert.deepEqual(calls.sleep,[1500]);assert.deepEqual(retries,[1]);assert.deepEqual(calls.writes,[]);
}
{
  const retries=[];
  const {context,calls,cachedConfig,cachedSnapshot}=makeHarness({getSnapshot:()=>({success:false,error:'temporary read failure'})});
  await assert.rejects(context.readSubscriptionSectionsWithRetry(attempt=>retries.push(attempt)),/temporary read failure/);
  assert.equal(calls.snapshots,3,'sustained failure has bounded attempts');assert.deepEqual(calls.callLoad,[]);
  assert.equal(JSON.stringify(cachedConfig),cachedSnapshot);assert.deepEqual(calls.sleep,[1500,1500]);assert.deepEqual(retries,[1,2]);assert.deepEqual(calls.writes,[]);
}
for(const [label,response,expected] of [
  ['missing snapshot support',{success:true,data:null},/subscription_snapshot_unsupported/],
  ['malformed version',{success:true,data:{success:true,version:2,sections:[]}},/subscription_snapshot_unsupported/],
  ['missing revision',{success:true,data:{success:true,version:1,sections:[{...defaultSection,revision:null}]}},/subscription_snapshot_unsupported/],
  ['access denied',{success:false,error:'access denied'},/access denied/]
]) {
  const {context,calls,cachedConfig,cachedSnapshot}=makeHarness({getSnapshot:()=>response});
  await assert.rejects(context.readSubscriptionSectionsWithRetry(),expected,label);
  assert.equal(calls.snapshots,1,`${label} stops without retries or permissive fallback`);
  assert.equal(JSON.stringify(cachedConfig),cachedSnapshot);assert.deepEqual(calls.sleep,[]);assert.deepEqual(calls.writes,[]);
}
{
  const draft = {'main:node': false};
  const data = [{code: 'main', items: [{id: 'node', enabled: true}], sources: []}];
  const calls = {guard: 0, fetch: [], writes: []};
  let widget = {failed: true, loading: false, applying: false, pendingChanges: draft, data};
  const context = vm.createContext({
    store: {get: () => ({subscriptionItemsWidget: widget}), set: update => {widget = {...widget, ...update.subscriptionItemsWidget};}},
    canRefreshSubscriptions: () => {calls.guard++; return true;},
    fetchSubscriptionItems: async (...args) => {calls.fetch.push(args);},
    setActionState: () => {calls.writes.push('setActionState'); throw new Error('manual read recovery must not start refresh action');},
    PodkopShellMethods: {updateSubscriptions: async () => {calls.writes.push('updateSubscriptions'); throw new Error('manual read recovery must not update subscriptions');}}
  });
  vm.runInContext(extract('handleRefreshSubscriptions'), context);
  await context.handleRefreshSubscriptions();
  assert.equal(calls.guard, 1, 'manual recovery checks whether refresh is allowed first');
  assert.deepEqual(calls.fetch, [['idle']], 'failed read invokes a plain read without a download');
  assert.equal(widget.pendingChanges, draft, 'manual recovery keeps the user draft');
  assert.equal(widget.data, data, 'manual recovery keeps the last good data until the read completes');
  assert.deepEqual(calls.writes, []);
}

console.log('PASS: coherent subscription snapshots preserve local UCI drafts, retry transient failures, reject mismatched bundles and never mutate during recovery');
