import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const source = fs.readFileSync(new URL('../openwrt/settings.js', import.meta.url), 'utf8');
const calls = [];
const context = vm.createContext({
  main: {}, _: value => value, E: (tag, attrs, children) => ({tag, attrs, children}),
  dnsOptimizerState: {status: {state: 'idle'}},
  uci: {get: () => undefined},
  callDnsOptimizer: async args => { calls.push(Array.from(args)); return {success: true}; },
  updateDnsOptimizerNode: () => {}, scheduleDnsOptimizerRefresh: () => {},
  injectDnsOptimizerStyles: () => {},
  document: {body: {classList: {add() {}, remove() {}}}},
  rollbackDns: () => { throw new Error('unexpected rollback'); },
  renderRecommendation: () => null, renderBenchmarkHistory: () => null,
});
for (const name of ['normalizeProtocolSelection', 'benchmarkSnapshot', 'startDnsBenchmark', 'optimizerMessage', 'renderActionButton', 'renderDnsOptimizer', 'compatibilityLabel', 'compatibilityTitle', 'communityServiceLabel', 'communityResultTitle', 'renderCommunityCheck', 'renderChecks', 'communityRecommendationText']) {
  const definition = source.match(new RegExp(`(?:async )?function ${name}\\([\\s\\S]*?\\n}`));
  assert.ok(definition, `${name} exists`);
  vm.runInContext(definition[0], context);
}
vm.runInContext(source.match(/const COMMUNITY_SERVICE_LABELS = \{[\s\S]*?\n};/)[0], context);
for (const mode of [undefined, 'economy', 'full']) {
  await context.startDnsBenchmark(mode);
  assert.deepEqual(calls.at(-1), ['benchmark_start', 'auto', mode || 'auto'], 'requested mode is explicit and never applies DNS');
}
context.dnsOptimizerState.status = {state: 'idle'};
const tree = context.renderDnsOptimizer();
const flatten = node => !node || typeof node !== 'object' ? [] : [node, ...(Array.isArray(node.children) ? node.children.flatMap(flatten) : [])];
const buttons = flatten(tree).filter(node => node.tag === 'button');
assert.ok(buttons.some(node => /эконом/i.test(node.children)), 'economy button is visible');
assert.ok(buttons.some(node => /полный/i.test(node.children)), 'full button is visible');
for (const button of buttons.filter(node => !/Откатить/.test(node.children))) {
  await button.attrs.click({type: 'click'});
  assert.ok(['auto', 'economy', 'full'].includes(calls.at(-1)[2]), 'DOM event never becomes a mode');
}
assert.match(context.optimizerMessage({message: 'waiting_for_memory'}), /памят/i);
assert.match(context.optimizerMessage({message: 'resource_wait_timeout'}), /памят/i);
assert.match(context.optimizerMessage({message: 'resource_wait_timeout'}), /не изменены/i);
assert.match(context.optimizerMessage({message: 'benchmark_complete', benchmarkMode: 'economy', diagnosticsSkipped: true}), /эконом/i);
assert.match(context.optimizerMessage({message: 'benchmark_complete', benchmarkMode: 'economy', diagnosticsSkipped: true}), /пропущ/i);
assert.doesNotMatch(context.optimizerMessage({message: 'benchmark_complete'}), /эконом|пропущ/i, 'old JSON does not invent a mode');
assert.match(context.optimizerMessage({message: 'waiting_for_memory', memory: {waitLimitSeconds: 7}}), /7 секунд/, 'memory wait reflects configured bounded timeout');
assert.match(context.optimizerMessage({message: 'benchmark_complete', benchmarkMode: 'full'}), /полный/i);
assert.ok(flatten(tree).some(node=>node.tag==='a'&&node.children==='Справка'&&node.attrs.href.endsWith('/docs/user-guide.md')),'auto low-memory methodology is linked from GitHub guide');
const skipped = {diagnosticsSkipped: true, communitySelected: 2, compatibilityPassed: 6, compatibilityTotal: 6, communityResults: [{id: 'youtube', tested: false, skipped: true}]};
assert.match(context.communityRecommendationText(skipped), /пропущ/i);
assert.doesNotMatch(context.communityRecommendationText(skipped), /прошли|доступны/i, 'skipped extras are not passed');
const checks = context.renderChecks(skipped);
const skipChip = checks.children.find(node => /пропущ/i.test(node.children));
assert.ok(skipChip, 'skipped diagnostics visibly disclosed');
assert.match(skipChip.attrs.class, /muted/);
assert.doesNotMatch(skipChip.attrs.class, /check--ok/);
const previousBenchmark = {results: [{id: 'old'}], recommendation: {id: 'old'}};
let shownRecommendation, shownHistory;
context.renderRecommendation = benchmark => { shownRecommendation = benchmark; return null; };
context.renderBenchmarkHistory = (benchmark, previous) => { shownHistory = {benchmark, previous}; return null; };
for (const message of ['resource_wait_timeout', 'benchmark_cancelled', 'worker_stopped']) {
  context.dnsOptimizerState.status = {action: 'benchmark', state: 'error', message, lastBenchmark: previousBenchmark};
  context.renderDnsOptimizer();
  assert.equal(shownRecommendation, null, `${message} must not resurrect the old recommendation`);
  assert.equal(shownHistory.benchmark, previousBenchmark, 'previous measurements stay accessible');
  assert.equal(shownHistory.previous, true, 'measurements are labelled as previous');
}
context.dnsOptimizerState.status = {action: 'apply', state: 'error', message: 'worker_stopped', lastBenchmark: previousBenchmark};
context.renderDnsOptimizer();
assert.equal(shownRecommendation, previousBenchmark, 'apply behavior is unchanged');
console.log('PASS: legacy economy UI mode commands, explicit controls, memory status and skipped diagnostics');
