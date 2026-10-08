import fs from 'node:fs';
import assert from 'node:assert/strict';

const main = fs.readFileSync(new URL('../openwrt/main.js', import.meta.url), 'utf8');
assert.ok(/\.pdk-page #cbi-podkop \.cbi-value > output\s*\{[^}]*flex:\s*1 1 0[^}]*min-width:\s*0/s.test(main),
  'legacy custom widgets must fill the available theme width before data loads');
assert.ok(/\.pdk-page #subscriptions-status\s*\{[^}]*width:\s*100%/s.test(main));
assert.doesNotMatch(main, /\.pdk-page #maincontent\s*\{/,
  'the outer page width belongs to the LuCI theme');
const entry = fs.readFileSync(new URL('../openwrt/podkop.js', import.meta.url), 'utf8');
assert.ok(entry.includes('classList.add("pdk-page")') &&
  entry.indexOf('classList.add("pdk-page")') < entry.indexOf('main.injectGlobalStyles()'),
  'layout class must be set before render and async operations');
assert.doesNotMatch(entry, /getSingBoxFeatures/, 'legacy must not call a PE-only capability RPC');
for (const version of ['0.7.20', '0.7.22']) {
  const runtimeEntry = fs.readFileSync(new URL(`../openwrt/runtime-${version}/www/luci-static/resources/view/podkop/podkop.js`, import.meta.url), 'utf8');
  assert.equal(runtimeEntry.replace(/\r\n/g, '\n'), entry.replace(/\r\n/g, '\n'),
    `runtime ${version} must ship the same section entry point`);
}
console.log('PASS: legacy preserves theme width at first render and ships the same entry point for both runtimes');
