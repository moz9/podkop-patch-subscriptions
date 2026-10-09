import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../openwrt/main.js', import.meta.url), 'utf8');

function extract(name) {
  const match = source.match(new RegExp(`(?:async )?function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n)`));
  assert.ok(match, `${name} must exist in the LuCI bundle`);
  return match[0];
}

function makeHarness({sections, getItems, getSources} = {}) {
  const calls = {callLoad: [], items: [], sources: [], sleep: [], writes: []};
  const cachedConfig = {
    main: {'.name': 'main', connection_type: 'proxy', proxy_config_type: 'subscription_urltest', subscription_selection_mode: 'all'},
    newDraft: {'.name': 'newDraft', connection_type: 'proxy', proxy_config_type: 'manual', proxy_string: 'unsaved local draft'}
  };
  const cachedSnapshot = JSON.stringify(cachedConfig);
  const freshSections = sections ?? [{
    '.name': 'main', connection_type: 'proxy', proxy_config_type: 'subscription_urltest',
    subscription_selection_mode: 'selected', subscription_include_tags: ['RU *'], subscription_exclude_tags: ['*slow']
  }];
  const uci = {
    unload() { throw new Error('read must not discard unsaved UCI changes'); },
    async callLoad(packageName) {
      calls.callLoad.push(packageName);
      return Object.fromEntries(freshSections.map((section, index) => [`section${index}`, section]));
    }
  };
  const methods = {
    getSubscriptionItemsCached: async name => { calls.items.push(name); return getItems ? getItems(name, calls.items.length) : {success: true, data: [{id: 'node', enabled: true}]}; },
    getSubscriptionSources: async name => { calls.sources.push(name); return getSources ? getSources(name, calls.sources.length) : {success: true, data: [{id: 'source', enabled: true}]}; },
    setSubscriptionSectionsEnabled: async () => { calls.writes.push('setSubscriptionSectionsEnabled'); throw new Error('write RPC must not be called while reading'); },
    updateSubscription: async () => { calls.writes.push('updateSubscription'); throw new Error('write RPC must not be called while reading'); }
  };
  const context = vm.createContext({
    uci,
    PodkopShellMethods: methods,
    window: {setTimeout: (callback, milliseconds) => { calls.sleep.push(milliseconds); queueMicrotask(callback); }}
  });
  vm.runInContext(extract('normalizeSubscriptionTags'), context);
  vm.runInContext(extract('sleep'), context);
  vm.runInContext(extract('readSubscriptionSections'), context);
  vm.runInContext(extract('readSubscriptionSectionsWithRetry'), context);
  return {context, calls, methods, cachedConfig, cachedSnapshot};
}

{
  const {context, calls, cachedConfig, cachedSnapshot} = makeHarness();
  const result = await context.readSubscriptionSections();
  assert.deepEqual(calls.callLoad, ['podkop'], 'read must bypass stale cached UCI without unloading it');
  assert.equal(JSON.stringify(cachedConfig), cachedSnapshot, 'direct read must preserve unsaved local UCI data');
  assert.deepEqual(calls.items, ['main']);
  assert.deepEqual(calls.sources, ['main']);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [{
    code: 'main', displayName: 'main', selectionMode: 'selected',
    includeTags: ['RU *'], excludeTags: ['*slow'],
    requiredServices: [], serviceSupport: false,
    communityLists: [],
    items: [{id: 'node', enabled: true, services: {}}], sources: [{id: 'source', enabled: true}]
  }], 'fresh selection mode and tags must be read alongside subscription items and sources');
  assert.deepEqual(calls.writes, []);
}

for (const [label, options, expectedMode] of [
  ['old excluded IDs list', {subscription_excluded_link_ids:['node']}, 'all'],
  ['old excluded ID scalar', {subscription_excluded_link_ids:'node'}, 'all'],
  ['no old exclusions', {}, 'auto'],
  ['empty old exclusions list', {subscription_excluded_link_ids:[]}, 'auto'],
  ['blank old exclusions list', {subscription_excluded_link_ids:['','  ']}, 'auto'],
  ['explicit auto with retained exclusions', {subscription_selection_mode:'auto',subscription_excluded_link_ids:['node']}, 'auto'],
  ['explicit selected', {subscription_selection_mode:'selected',subscription_excluded_link_ids:['node']}, 'selected'],
  ['explicit all', {subscription_selection_mode:'all'}, 'all']
]) {
  const {context, calls} = makeHarness({sections:[{
    '.name':'main', connection_type:'proxy', proxy_config_type:'subscription_urltest', ...options
  }]});
  const result = await context.readSubscriptionSections();
  assert.equal(result[0].selectionMode, expectedMode, `${label} preserves intended manual/automatic pool`);
  assert.deepEqual(calls.writes, [], 'mode fallback is read-only');
}

{
  const retries = [];
  const {context, calls, cachedConfig, cachedSnapshot} = makeHarness({
    getItems: (_name, attempt) => attempt === 1 ? {success: false, error: 'temporary read failure'} : {success: true, data: [{id: 'node'}]}
  });
  const result = await context.readSubscriptionSectionsWithRetry(attempt => retries.push(attempt));
  assert.equal(result[0].items.length, 1, 'second read succeeds');
  assert.deepEqual(calls.items, ['main', 'main']);
  assert.deepEqual(calls.callLoad, ['podkop', 'podkop'], 'each attempt directly reads saved UCI');
  assert.equal(JSON.stringify(cachedConfig), cachedSnapshot, 'retry must preserve unsaved local UCI data');
  assert.deepEqual(calls.sleep, [1500]);
  assert.deepEqual(retries, [1]);
  assert.deepEqual(calls.writes, []);
}

{
  const retries = [];
  const {context, calls, cachedConfig, cachedSnapshot} = makeHarness({getItems: () => ({success: false, error: 'temporary read failure'})});
  await assert.rejects(context.readSubscriptionSectionsWithRetry(attempt => retries.push(attempt)), /temporary read failure/);
  assert.equal(calls.items.length, 3, 'sustained failure makes exactly three read attempts');
  assert.deepEqual(calls.callLoad, ['podkop', 'podkop', 'podkop']);
  assert.equal(JSON.stringify(cachedConfig), cachedSnapshot, 'failed reads must preserve unsaved local UCI data');
  assert.deepEqual(calls.sleep, [1500, 1500]);
  assert.deepEqual(retries, [1, 2]);
  assert.deepEqual(calls.writes, []);
}

for (const [label, setup, expected] of [
  ['missing source support', {getSources: () => ({success: true, data: null})}, /source_support_missing/],
  ['access denied', {getItems: () => ({success: false, error: 'access denied'})}, /access denied/]
]) {
  const {context, calls, cachedConfig, cachedSnapshot} = makeHarness(setup);
  await assert.rejects(context.readSubscriptionSectionsWithRetry(), expected, `${label} is not retryable`);
  assert.equal(calls.items.length, 1, `${label} stops after one attempt`);
  assert.equal(JSON.stringify(cachedConfig), cachedSnapshot, `${label} preserves unsaved local UCI data`);
  assert.deepEqual(calls.sleep, []);
  assert.deepEqual(calls.writes, []);
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

console.log('PASS: subscription reads bypass cached UCI without discarding local drafts, retry transient failures, and never write during recovery');
