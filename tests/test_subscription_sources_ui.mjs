import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const js=fs.readFileSync(new URL('../openwrt/main.js',import.meta.url),'utf8');
const c=vm.createContext({_:s=>s,E:(tag,attrs,children)=>({tag,attrs,children})});
for(const name of ['getSourceGroups','getEffectiveSourceEnabled','getChangesBySection']) {
 const match=js.match(new RegExp(`function ${name}\\([\\s\\S]*?\\n}`));
 assert.ok(match,`${name} must exist`);
 vm.runInContext(match[0],c);
}
const section={code:'main',sources:[{id:'one',sourceIndex:1,enabled:false},{id:'two',sourceIndex:2,enabled:true}],items:[{id:'shared',sourceIds:['one','two']}]};
const groups=c.getSourceGroups(section);
assert.equal(groups.length,2);
assert.equal(groups[0].items[0].id,'shared');
assert.equal(groups[1].items[0].id,'shared');
assert.equal(c.getEffectiveSourceEnabled({},'main',groups[0]),false);
assert.equal(c.getEffectiveSourceEnabled({'main:source:one':true},'main',groups[0]),true);
assert.match(js,/loading && !sections\.length/,'loading must retain existing table');
assert.match(js,/failed && !sections\.length/,'errors must retain existing table');
assert.match(js,/subscription_ping/,'disabled configs need an isolated probe');
console.log('PASS: subscription source UI grouping, toggle and stale-cache rendering');
