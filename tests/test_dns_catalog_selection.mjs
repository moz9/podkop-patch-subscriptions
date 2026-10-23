import fs from 'node:fs';
import assert from 'node:assert/strict';
const source=fs.readFileSync(new URL('../openwrt/dns_benchmark.js',import.meta.url),'utf8');
const api=new Function('baseclass',source)({extend:x=>x});
const rows=[
 {id:'cloudflare',protocol:'udp',dnsServer:'1.1.1.1'},
 {id:'cloudflare',protocol:'tcp',dnsServer:'1.1.1.1'},
 {id:'google',protocol:'doh',dnsServer:'dns.google'},
 {id:'saved_custom_dot_1',protocol:'dot',dnsServer:'mine.example'},
];
const catalog={availableResults:rows,availableBootstrapResults:[
 {id:'yandex_1',protocol:'udp',server:'77.88.8.8'},
 {id:'yandex_1',protocol:'dot',server:'77.88.8.8'},
 {id:'google_1',protocol:'udp',server:'8.8.8.8'},
]};
const selection={dns_optimizer_protocols:['udp','dot'],dns_optimizer_candidates:['cloudflare'],
 dns_optimizer_custom_dot:['mine.example'],dns_optimizer_bootstrap_protocols:['udp'],dns_optimizer_bootstrap_candidates:['yandex_1']};
assert.deepEqual(api.catalogCandidates(null,catalog,false,selection),[rows[0],rows[3]],'manual choices must obey candidate AND protocol filters');
assert.deepEqual(api.catalogCandidates(null,catalog,true,selection),[catalog.availableBootstrapResults[0]]);
assert.deepEqual(api.catalogCandidates({results:[rows[2]]},catalog,false,selection),[rows[0],rows[3]],'old report cannot reintroduce excluded candidates');
assert.deepEqual(api.catalogCandidates(null,catalog,false,{...selection,dns_optimizer_candidates:[],dns_optimizer_custom_dot:[]}),[],'empty user selection must not become full catalog');
assert.deepEqual(api.catalogCandidates(null,catalog,false,{...selection,dns_optimizer_protocols:[]}),[]);
console.log('PASS: manual DNS choices obey selected protocols, providers and explicit custom values, including empty choices');
