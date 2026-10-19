import fs from 'node:fs';
import assert from 'node:assert/strict';
const source=fs.readFileSync(new URL('../openwrt/dns_benchmark.js',import.meta.url),'utf8');
const api=new Function('baseclass',source)({extend:x=>x});
assert.equal(typeof api.normalizeLightSelection,'function');
const pair=(m,b)=>({success:true,protocol:'udp',id:m,dnsServer:m+'.example',bootstrapDnsServer:b+'.example',bootstrapProtocol:'udp',mainFamily:m,bootstrapFamily:b,httpsTested:false});
const valid={action:'select',state:'done',reportId:'test',selectionComplete:true,partial:false,scope:'direct_dns_pair',recommendation:pair('a','b'),secondaryRecommendation:pair('c','d')};
assert.ok(api.normalizeLightSelection(valid));
for(const change of [{state:'running'},{state:'cancelled'},{partial:true},{selectionComplete:false},{secondaryRecommendation:null},{scope:'endpoint_ordering_only'},{secondaryRecommendation:pair('a','d')}])
  assert.equal(api.normalizeLightSelection({...valid,...change}),null);
assert.match(source,/Подобрать обе пары/);
assert.match(source,/Применить обе пары/);
assert.match(source,/operate\("select_start"\)/);
assert.match(source,/operate\("apply_selected_start"/);
assert.ok(!/operate\("select_start"[^;]*apply_selected_start/s.test(source));
assert.match(source,/querySelector\('\[data-changed="true"\]'\)/);
console.log('PASS: identical two-pair UI contract, partial/stale refusal and separate selection/apply');
