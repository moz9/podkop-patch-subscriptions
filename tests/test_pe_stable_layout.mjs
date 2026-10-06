import fs from 'node:fs';
import assert from 'node:assert/strict';
const main=fs.readFileSync(new URL('../openwrt/main.js',import.meta.url),'utf8');
const entry=fs.readFileSync(new URL('../openwrt/podkop.js',import.meta.url),'utf8');
assert.ok(entry.indexOf('classList.add("pdk-pe-page")') < entry.indexOf('await main.CustomPodkopMethods.getSingBoxFeatures()') && entry.includes('classList.add("pdk-pe-page")'),'layout must be selected before async feature loading');
assert.doesNotMatch(main,/\.pdk-pe-page #maincontent\s*\{/,'outer width belongs to the LuCI theme, not the PE page');
assert.match(main,/#cbi-podkop[^}]*output[^}]*\{[^}]*flex:\s*1 1 0[^}]*min-width:\s*0/s);
assert.match(main,/#subscriptions-status\s*\{[^}]*width:\s*100%/s);
console.log('PASS: PE preserves theme width; output flex sizing is selected before loading and state-independent');
