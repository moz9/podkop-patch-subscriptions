import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const js = fs.readFileSync(new URL('../openwrt/main.js', import.meta.url), 'utf8');
const now = 1900000000;
const c = vm.createContext({
  Date: {now: () => now * 1000},
  _: text => text,
  E: (tag, attrs, children) => ({tag, attrs, children})
});
const names = [
  'getRowId', 'hasPendingChange', 'getEffectiveEnabled', 'getEffectiveSubscriptionItemEnabled',
  'getEffectiveSelectionMode', 'getEffectiveSubscriptionTags', 'getEffectiveSourceEnabled',
  'subscriptionTagMatches', 'isSubscriptionTagFiltered', 'getEffectiveRequiredServices',
  'getSubscriptionServiceExclusions', 'isSubscriptionServiceEvidenceFresh',
  'getSubscriptionServiceStateLabel', 'canConfirmSubscriptionService', 'getSubscriptionServiceCheckTargets',
  'getSubscriptionServiceRoutingHint', 'getReasonLabel', 'getItemName', 'getStatusClass',
  'getStatusLabel', 'renderRow', 'renderSourceTable', 'renderSubscriptionServiceFilter',
  'hasPendingSubscriptionModeChange', 'getTagFilterPreview', 'getSourceSummary',
  'getSectionCollapsedSummary', 'getToolbarMessage',
  'getSubscriptionRowStatusTitle', 'getSubscriptionServiceSummary'
];
for (const name of names) {
  const match = js.match(new RegExp(`function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n)`));
  if (match) vm.runInContext(match[0], c);
}
const walk = node => Array.isArray(node) ? node.flatMap(walk) :
  !node || typeof node !== 'object' ? [] : [node, ...walk(node.children)];
const evidence = (state, extra = {}) => ({state, checkedAt: now - 10, expiresAt: now + 3600, ...extra});
const item = (id, result, extra = {}) => ({id, name: `US ${id}`, supported: true, enabled: true,
  sourceIds: ['one'], services: {chatgpt: result}, ...extra});
const section = {
  code: 'geo', displayName: 'GEOBLOCK', selectionMode: 'auto', includeTags: ['@prefix:US'],
  excludeTags: [], requiredServices: ['chatgpt'], serviceSupport: true,
  sources: [{id: 'one', sourceIndex: 1, enabled: true}], items: []
};
function row(value, changes = {}) {
  return c.renderRow({section, item: value, index: 0, pendingChanges: changes,
    latencyByRow: {}, speedByRow: {}, enabledSupportedCount: 2, applying: false, onToggle() {}});
}
const unknown = item('unknown', evidence('unknown', {network: 'pass', reason: 'challenge_required'}));
const unknownRow = row(unknown);
const unknownStatus = walk(unknownRow).find(node => node.tag === 'td' && node.attrs['data-label'] === 'Status');
assert.match(unknownStatus.attrs.title, /Требует подтверждения/,
  'fresh unknown must describe the actual cached outcome, not claim absent evidence');
assert.doesNotMatch(unknownStatus.attrs.title, /нет свежего подтверждения/);
const failStatus = walk(row(item('fail', evidence('fail', {reason: 'region_denied', region: 'RUS'}))))
  .find(node => node.tag === 'td' && node.attrs['data-label'] === 'Status');
assert.match(failStatus.attrs.title, /Регион.*отклонён/);
const staleStatus = walk(row(item('stale', evidence('pass', {expiresAt: now - 1}))))
  .find(node => node.tag === 'td' && node.attrs['data-label'] === 'Status');
assert.match(staleStatus.attrs.title, /устарела/);
const missingStatus = walk(row(item('missing', undefined)))
  .find(node => node.tag === 'td' && node.attrs['data-label'] === 'Status');
assert.match(missingStatus.attrs.title, /Не проверен/);
const tagStatus = walk(row({...unknown, name: 'SE not eligible'}))
  .find(node => node.tag === 'td' && node.attrs['data-label'] === 'Status');
assert.match(tagStatus.children, /тег/);
assert.match(tagStatus.attrs.title, /тег/,
  'tooltip must use the same primary exclusion reason as the visible status');
assert.doesNotMatch(tagStatus.attrs.title, /ChatGPT/);

const selected = walk(unknownRow).find(node => node.tag === 'input');
assert.equal(selected.attrs.checked, 'checked', 'selection remains independent of admission');
assert.equal(selected.attrs.disabled, 'disabled', 'auto selection remains read-only');
assert.match(selected.attrs['aria-label'], /^Выбран:/);
assert.match(selected.attrs.title, /тегов и сервисов/);
const manualSelected = walk(row(unknown, {'geo:selection:mode': 'selected'})).find(node => node.tag === 'input');
assert.equal(manualSelected.attrs.disabled, undefined, 'manual selection behavior is unchanged');

const freshPool = {...section, items: [unknown, item('unknown2', evidence('unknown', {network: 'pass'})),
  item('fail', evidence('fail'))]};
const filter = c.renderSubscriptionServiceFilter(freshPool, {}, false, () => {}, {});
const summary = walk(filter).find(node => node.tag === 'small' && node.attrs.role === 'status');
assert.match(summary.children, /Подходят: 0 из 3/);
assert.match(summary.children, /Свежие результаты: 3/);
assert.match(summary.children, /Нужна проверка: 0/);
assert.match(summary.children, /Отказ: 1/);
assert.match(summary.children, /Не определено: 2/);
const nextStep = walk(filter).find(node => node.attrs?.['data-service-next-step']);
assert.match(nextStep.children, /результаты|подтверд/i,
  'zero admission with fresh unknown evidence needs a visible next step');
assert.equal(c.getSubscriptionServiceCheckTargets(freshPool, ['chatgpt']).length, 0,
  'fresh unknown and fail must not become automatic rechecks');
assert.equal(c.getSubscriptionServiceCheckTargets(freshPool, ['chatgpt'], true).length, 3);
const forceButton = walk(filter).find(node => node.tag === 'button' && node.children === 'Перепроверить всё');
assert.equal(forceButton.attrs.disabled, undefined, 'explicit recheck remains available');
assert.deepEqual(JSON.parse(JSON.stringify(c.getSubscriptionServiceSummary(freshPool, ['chatgpt'], {}))),
  {candidates: 3, passed: 0, fresh: 3, needsCheck: 0, failed: 1, unknown: 2});
const mixedPool = {...section, items: [unknown, item('pass', evidence('pass', {manual: true})),
  item('stale', evidence('pass', {expiresAt: now - 1})), item('missing', undefined)]};
assert.deepEqual(JSON.parse(JSON.stringify(c.getSubscriptionServiceSummary(mixedPool, ['chatgpt'], {}))),
  {candidates: 4, passed: 1, fresh: 2, needsCheck: 2, failed: 0, unknown: 1});

const reasonPool = {...section, selectionMode: 'selected', sources: [
  {id: 'one', sourceIndex: 1, enabled: true}, {id: 'off', sourceIndex: 2, enabled: false}
], items: [
  item('good', evidence('pass')),
  item('tag', evidence('fail'), {name: 'SE tag'}),
  item('service', evidence('unknown')),
  item('manual', evidence('fail'), {enabled: false}),
  item('source', evidence('fail'), {name: 'SE source', sourceIds: ['off']}),
  item('unsupported', undefined, {supported: false}),
  item('duplicate-source', evidence('pass'), {sourceIds: ['one', 'off']})
]};
const preview = c.getTagFilterPreview(reasonPool, {});
assert.deepEqual(JSON.parse(JSON.stringify(preview)), {enabled: 2, filtered: 1, uncertain: false,
  unsupported: 1, sourceExcluded: 1, manualExcluded: 1, serviceExcluded: 1});
assert.equal(preview.enabled + preview.filtered + preview.unsupported + preview.sourceExcluded +
  preview.manualExcluded + preview.serviceExcluded, reasonPool.items.length,
  'section reasons partition unique nodes without double counting overlapping sources or exclusions');
const changed = c.getTagFilterPreview(reasonPool, {'geo:source:one': false});
assert.equal(changed.enabled, 0);
assert.equal(changed.sourceExcluded, 6);
const uncertain = c.getTagFilterPreview({...section, items: reasonPool.items}, {'geo:selection:mode': 'selected'});
assert.equal(uncertain.uncertain, true, 'auto-to-manual mode change keeps the conservative preview');
const sourceSummary = c.getSourceSummary({section: reasonPool,
  group: {id: 'one', enabled: true, items: reasonPool.items.filter(value => value.sourceIds.includes('one'))},
  pendingChanges: {}});
assert.match(sourceSummary, /К применению: 2/);
assert.match(c.getSectionCollapsedSummary(reasonPool, {}), /к применению 2/);
assert.doesNotMatch(c.getToolbarMessage({}), /Select configs/);
console.log('PASS: truthful service freshness, selection labels, admission counts and exclusion priority');
