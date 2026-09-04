import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../openwrt/main.js', import.meta.url), 'utf8');
const toolbar = source.slice(source.indexOf('function renderToolbar('), source.indexOf('function renderRow('));
assert.ok(toolbar.startsWith('function renderToolbar('));
const buttons = [];
const context = {
  _: value => value,
  E: (tag, attrs, children) => ({ tag, attrs, children }),
  renderButton: options => { buttons.push(options); return options; },
  getToolbarClass: () => '',
  getToolbarMessage: () => ''
};
for (const icon of toolbar.match(/render\w+Icon24/g) || []) context[icon] = () => {};
vm.createContext(context);
vm.runInContext(toolbar, context);
for (const state of [
  {}, { loading: true }, { failed: true }, { pendingCount: 2 },
  { action: 'speed', actionStatus: 'running' }
]) {
  buttons.length = 0;
  context.renderToolbar({ pendingCount: 0, actionStatus: 'idle', ...state });
  assert.equal(buttons.length, 5, 'Subscriptions must contain only refresh, ping, speed, apply and reset');
  assert.deepEqual(buttons.map(button => button.text), ['Refresh', 'Ping', state.action === 'speed' ? 'Stop' : 'Speed', 'Apply', 'Reset']);
  assert.ok(buttons.every(button => button.title !== 'Update patch'));
}
assert.doesNotMatch(source, /\bonPatchUpdate\b/, 'Subscriptions must not wire a hidden patch update action');
assert.ok(!source.includes('function handlePatchUpdate('), 'Remove unused subscriptions patch controller');
const diagnostics = source.slice(source.indexOf('function renderUpdateCenter('), source.indexOf('function renderUpdateCenter(') + 12000);
assert.match(diagnostics, /onUpdate/);
assert.match(diagnostics, /patchUpdateAvailable/);
assert.match(source, /kind === "check" \? await PodkopShellMethods.checkSubscriptionPatchUpdate\(\) : await PodkopShellMethods.updateSubscriptionPatch\(\)/);
const manager = fs.readFileSync(new URL('../openwrt/podkop-update-manager', import.meta.url), 'utf8');
const readme = fs.readFileSync(new URL('../README.md', import.meta.url), 'utf8');
const installerUrl = 'https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/main/i';
assert.ok(manager.includes(installerUrl) && readme.includes(installerUrl), 'Diagnostics and README must use the same universal installer');
console.log('PASS: patch update is available through Diagnostics/universal installer only');
