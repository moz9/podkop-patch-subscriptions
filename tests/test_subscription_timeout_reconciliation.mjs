import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../openwrt/main.js', import.meta.url), 'utf8');
const controllerStart = source.indexOf('// src/podkop/tabs/subscriptions/initController.ts');
const controllerEnd = source.indexOf('async function handleRefreshSubscriptions(', controllerStart);
assert.ok(controllerStart >= 0 && controllerEnd > controllerStart, 'subscription controller must be present');

function extract(name) {
  const match = source.match(new RegExp(`(?:async )?function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n)`));
  assert.ok(match, `${name} must exist in the LuCI bundle`);
  return match[0];
}

const initialSection = {
  code: 'main', displayName: 'main', selectionMode: 'selected',
  includeTags: ['old*'], excludeTags: [],
  items: [{id: 'node', enabled: false, supported: true}],
  sources: [{id: 'source', enabled: true}]
};
const intendedDraft = {
  'main:selection:mode': 'auto',
  'main:tags:include': ['SE*'],
  'main:tags:exclude': ['*slow'],
  'main:node': true,
  'main:source:source': false
};

function makeHarness({savedSection = initialSection, status = {busy: true, pending: false}, readError = false} = {}) {
  const calls = {apply: 0, downloads: 0, status: 0, reads: 0, errors: [], timers: []};
  let currentSaved = savedSection;
  let currentStatus = status;
  let shouldFailRead = readError;
  let widget = {
    loading: false, failed: false, applying: false, status: 'dirty',
    action: 'none', actionStatus: 'idle', actionMessage: '', actionError: '',
    runtimeStatus: {busy: false, pending: false},
    pendingChanges: {...intendedDraft}, data: [initialSection],
    latencyByRow: {}, speedByRow: {}
  };
  const methods = {
    async setSubscriptionSectionsEnabled() {
      calls.apply++;
      throw new Error('Command timed out');
    },
    async getSubscriptionOperationStatus() {
      calls.status++;
      return {success: true, data: currentStatus};
    },
    async getSubscriptionItemsCached() {
      return {success: true, data: currentSaved.items};
    },
    async getSubscriptionSources() {
      return {success: true, data: currentSaved.sources};
    },
    async updateSubscriptions() {
      calls.downloads++;
      throw new Error('read-only recovery must not download subscriptions');
    }
  };
  const context = vm.createContext({
    store: {
      get: () => ({subscriptionItemsWidget: widget}),
      set: update => { widget = {...widget, ...update.subscriptionItemsWidget}; },
      unsubscribe() {}
    },
    PodkopShellMethods: methods,
    uci: {async callLoad() {
      calls.reads++;
      if (shouldFailRead) throw new Error('read failed');
      return {main: {
        '.name': 'main', connection_type: 'proxy', proxy_config_type: 'subscription_urltest',
        subscription_selection_mode: currentSaved.selectionMode,
        subscription_include_tags: currentSaved.includeTags,
        subscription_exclude_tags: currentSaved.excludeTags
      }};
    }},
    window: {setTimeout: (callback, ms) => {calls.timers.push({callback, ms}); queueMicrotask(callback); return calls.timers.length;}},
    setTimeout: (callback, ms) => {calls.timers.push({callback, ms}); return calls.timers.length;},
    clearTimeout() {},
    logger: {error(...args) {calls.errors.push(args);}},
    showToast(message, kind) {if (kind === 'error') calls.errors.push(['toast', message]);},
    getSubscriptionActionErrorMessage: (error, fallback) => error?.message || fallback,
    onStoreUpdate3() {},
    _: text => text
  });
  vm.runInContext(extract('getEffectiveSelectionMode'), context);
  vm.runInContext(extract('normalizeSubscriptionTags'), context);
  vm.runInContext(source.slice(controllerStart, controllerEnd), context);
  vm.runInContext(extract('handleRefreshSubscriptions'), context);
  vm.runInContext(extract('onPageUnmount3'), context);
  return {
    context, calls,
    get widget() {return widget;},
    setSaved(section) {currentSaved = section;},
    setStatus(value) {currentStatus = value;},
    setReadError(value) {shouldFailRead = value;}
  };
}

{
  const h = makeHarness();
  await h.context.handleApply();
  assert.equal(h.calls.apply, 1, 'a timed-out call must never be submitted again automatically');
  assert.equal(h.widget.actionStatus, 'verifying', 'timeout is unresolved, not a confirmed failure');
  assert.equal(h.context.subscriptionStateLabel(h.widget)[1], 'Проверяем результат');
  assert.deepEqual({...h.widget.pendingChanges}, intendedDraft, 'the draft remains available while checking');
  assert.equal(h.calls.reads, 0, 'do not compare cached config while the backend is still busy');
  assert.equal(h.calls.errors.some(([kind]) => kind === 'toast'), false, 'an unresolved timeout must not raise a red failure toast');
}

const confirmedSection = {
  ...initialSection, selectionMode: 'auto', includeTags: ['SE*'], excludeTags: ['*slow'],
  items: [{...initialSection.items[0], enabled: true}],
  sources: [{...initialSection.sources[0], enabled: false}]
};

{
  const h = makeHarness();
  await h.context.handleApply();
  h.setSaved(confirmedSection);
  h.setStatus({busy: false, pending: false});
  await h.context.refreshSubscriptionRuntimeStatus();
  assert.equal(h.widget.status, 'success', 'all intended values must be confirmed from a fresh saved read');
  assert.deepEqual({...h.widget.pendingChanges}, {}, 'only a fully confirmed draft may be cleared');
  assert.equal(h.calls.apply, 1, 'reconciliation is read-only');
  const reads = h.calls.reads;
  await h.context.refreshSubscriptionRuntimeStatus();
  assert.equal(h.calls.reads, reads, 'stable idle polls must not repeat the successful reconciliation');
}

{
  const h = makeHarness();
  await h.context.handleApply();
  h.setSaved({...confirmedSection, selectionMode: 'selected'});
  h.setStatus({busy: false, pending: false});
  await h.context.refreshSubscriptionRuntimeStatus();
  assert.notEqual(h.widget.status, 'success', 'matching nodes, tags and source do not prove a mismatched mode was applied');
  assert.equal(h.widget.pendingChanges['main:selection:mode'], 'auto', 'unconfirmed mode remains in the draft');
  assert.equal(h.calls.apply, 1, 'mismatch must not automatically repeat the write');
  assert.equal(h.context.canRefreshSubscriptions(), true, 'unconfirmed mismatch needs an available read-only retry');
  h.setSaved(confirmedSection);
  await h.context.handleRefreshSubscriptions();
  assert.equal(h.widget.status, 'success', 'retrying the read may later confirm an already completed apply');
  assert.equal(h.calls.downloads, 0, 'read-only retry must not download subscriptions');
  assert.equal(h.calls.apply, 1, 'read-only retry must not write or reapply');
}

{
  const h = makeHarness();
  await h.context.handleApply();
  h.setSaved({...confirmedSection, selectionMode: 'selected'});
  h.setStatus({busy: false, pending: false});
  await h.context.refreshSubscriptionRuntimeStatus();
  assert.ok(h.widget.applyUnconfirmed, 'mismatch retains the old verification snapshot');
  h.setSaved(confirmedSection);
  h.context.PodkopShellMethods.setSubscriptionSectionsEnabled = async () => {
    h.calls.apply++;
    return {success: true, data: {success: true}};
  };
  await h.context.handleApply();
  assert.equal(h.widget.status, 'success');
  assert.equal(h.widget.applyUnconfirmed, null, 'a later explicitly confirmed apply supersedes the old unconfirmed snapshot');
  assert.equal(h.calls.apply, 2, 'the second write is only the user-triggered apply');
}

{
  const h = makeHarness();
  await h.context.handleApply();
  h.setSaved({...confirmedSection, includeTags: ['old*']});
  h.setStatus({busy: false, pending: false});
  await h.context.refreshSubscriptionRuntimeStatus();
  assert.notEqual(h.widget.status, 'success', 'matching mode, node and source do not prove tags were applied');
  assert.deepEqual([...h.widget.pendingChanges['main:tags:include']], ['SE*']);
  assert.equal(h.calls.apply, 1);
}

{
  const h = makeHarness();
  await h.context.handleApply();
  h.setSaved({...confirmedSection, sources: [{...confirmedSection.sources[0], enabled: true}]});
  h.setStatus({busy: false, pending: false});
  await h.context.refreshSubscriptionRuntimeStatus();
  assert.notEqual(h.widget.status, 'success', 'matching mode, tags and node do not prove source selection was applied');
  assert.equal(h.widget.pendingChanges['main:source:source'], false);
  assert.equal(h.calls.apply, 1);
}

{
  const h = makeHarness();
  await h.context.handleApply();
  h.setSaved({...confirmedSection, items: []});
  h.setStatus({busy: false, pending: false});
  await h.context.refreshSubscriptionRuntimeStatus();
  assert.notEqual(h.widget.status, 'success', 'a missing node ID is not evidence of success');
  assert.equal(h.widget.pendingChanges['main:node'], true, 'unknown IDs remain in the draft');
  assert.equal(h.calls.apply, 1);
}

{
  const h = makeHarness();
  await h.context.handleApply();
  h.setSaved(confirmedSection);
  h.setStatus({busy: false, pending: true});
  await h.context.refreshSubscriptionRuntimeStatus();
  assert.notEqual(h.widget.status, 'success', 'saved values alone do not confirm that the worker activated pending configs');
  assert.notEqual(h.widget.actionStatus, 'verifying', 'known idle with pending configs needs a terminal, actionable state');
  assert.match(h.widget.actionMessage, /(?:не применен|не подтвержден|проверьте|чтени)/i);
  assert.equal(h.calls.apply, 1);
}

{
  const h = makeHarness();
  await h.context.handleApply();
  h.setStatus({busy: false, pending: false});
  h.setReadError(true);
  await h.context.refreshSubscriptionRuntimeStatus();
  assert.notEqual(h.widget.status, 'success', 'read failure must be reported as unconfirmed');
  assert.deepEqual({...h.widget.pendingChanges}, intendedDraft, 'failed reads do not discard the draft');
  assert.match(h.widget.actionMessage, /(?:повторите|чтени|подтвер)/i, 'give the user a read-only recovery action');
  assert.equal(h.calls.apply, 1);
}

{
  const h = makeHarness();
  await h.context.handleApply();
  h.setSaved(confirmedSection);
  h.setStatus({pending: false});
  await h.context.refreshSubscriptionRuntimeStatus();
  assert.notEqual(h.widget.status, 'success', 'status without a valid busy flag cannot confirm completion');
  assert.equal(h.calls.reads, 0, 'unknown runtime state must not trigger reconciliation');
  assert.equal(h.calls.apply, 1);
}

{
  const h = makeHarness();
  await h.context.handleApply();
  const before = h.widget;
  let finishStatus;
  h.context.PodkopShellMethods.getSubscriptionOperationStatus = () => new Promise(resolve => {finishStatus = resolve;});
  const oldPoll = h.context.refreshSubscriptionRuntimeStatus();
  vm.runInContext('subscriptionStatusGeneration++', h.context);
  finishStatus({success: true, data: {busy: false, pending: false}});
  await oldPoll;
  assert.equal(h.widget, before, 'an old generation must not reconcile into a remounted subscriptions tab');
  assert.equal(h.calls.reads, 0, 'stale status cannot start a fresh read');
}

{
  const h = makeHarness();
  await h.context.handleApply();
  h.setSaved(confirmedSection);
  h.setStatus({busy: false, pending: false});
  const savedUci = {main: {
    '.name': 'main', connection_type: 'proxy', proxy_config_type: 'subscription_urltest',
    subscription_selection_mode: confirmedSection.selectionMode,
    subscription_include_tags: confirmedSection.includeTags,
    subscription_exclude_tags: confirmedSection.excludeTags
  }};
  let finishRead;
  h.context.uci.callLoad = () => new Promise(resolve => {finishRead = resolve;});
  const oldRead = h.context.refreshSubscriptionRuntimeStatus();
  for (let i = 0; i < 10 && !finishRead; i++) await Promise.resolve();
  assert.equal(typeof finishRead, 'function', 'the old generation started its fresh read');
  vm.runInContext('subscriptionStatusGeneration++', h.context);
  finishRead(savedUci);
  await oldRead;
  h.context.uci.callLoad = async () => savedUci;
  await h.context.refreshSubscriptionRuntimeStatus();
  assert.equal(h.widget.status, 'success', 'a remounted tab may retry the stale generation read');
  assert.equal(h.calls.apply, 1, 'stale read recovery remains read-only');
}

{
  const h = makeHarness();
  await h.context.handleApply();
  h.setSaved(confirmedSection);
  h.setStatus({busy: false, pending: false});
  const savedUci = {main: {
    '.name': 'main', connection_type: 'proxy', proxy_config_type: 'subscription_urltest',
    subscription_selection_mode: confirmedSection.selectionMode,
    subscription_include_tags: confirmedSection.includeTags,
    subscription_exclude_tags: confirmedSection.excludeTags
  }};
  let finishOldRead;
  let readAttempts = 0;
  h.context.uci.callLoad = () => {
    readAttempts++;
    return readAttempts === 1 ? new Promise(resolve => {finishOldRead = resolve;}) : Promise.resolve(savedUci);
  };
  const oldRead = h.context.refreshSubscriptionRuntimeStatus();
  for (let i = 0; i < 10 && !finishOldRead; i++) await Promise.resolve();
  assert.equal(typeof finishOldRead, 'function');
  h.context.onPageUnmount3();
  await h.context.refreshSubscriptionRuntimeStatus();
  assert.equal(h.widget.status, 'success', 'remount must not wait for a stale RPC that may never finish');
  assert.equal(readAttempts, 2, 'new generation starts its own bounded fresh read');
  finishOldRead(savedUci);
  await oldRead;
  assert.equal(h.widget.status, 'success', 'old RPC completion cannot overwrite the new generation');
}

console.log('PASS: timed-out apply is verified without discarding the draft or resubmitting');
