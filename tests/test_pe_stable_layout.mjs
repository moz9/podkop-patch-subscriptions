import fs from 'node:fs';
import assert from 'node:assert/strict';
const main=fs.readFileSync(new URL('../openwrt/main.js',import.meta.url),'utf8');
const entry=fs.readFileSync(new URL('../openwrt/podkop.js',import.meta.url),'utf8');
assert.ok(entry.indexOf('classList.add("pdk-pe-page")') < entry.indexOf('await main.CustomPodkopMethods.getSingBoxFeatures()') && entry.includes('classList.add("pdk-pe-page")'),'layout must be selected before async feature loading');
assert.match(main,/\.pdk-pe-page #maincontent\s*\{[^}]*max-width:\s*1800px[^}]*\}/s);
assert.match(main,/#cbi-podkop[^}]*output[^}]*\{[^}]*flex:\s*1 1 0[^}]*min-width:\s*0/s);
assert.match(main,/#subscriptions-status\s*\{[^}]*width:\s*100%/s);
console.log('PASS: PE layout width is selected before loading; output flex sizing is state-independent');
