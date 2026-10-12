import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const js=fs.readFileSync(new URL('../openwrt/main.js',import.meta.url),'utf8');
const c=vm.createContext({Error,_ : x=>x});
for(const name of ['getErrorText','getSubscriptionResourceErrorMessage','getSubscriptionActionErrorMessage']) {
 const source=js.match(new RegExp(`function ${name}\\([\\s\\S]*?\\n}`));
 assert.ok(source,name);vm.runInContext(source[0],c);
}
for(const code of ['too_large','too_many_nodes','link_too_large','cache_too_large','cache_invalid','insufficient_memory','memory_unavailable','resource_limits_invalid','parse_failed','download_incomplete']) {
 const error='subscription_'+code;
 const message=c.getSubscriptionActionErrorMessage(new Error('Subscription refresh refused: '+error+'; previous cache kept'),'fallback');
 assert.notEqual(message,'fallback',error);
 assert.match(message,/сохранён|не сохранён|не изменено/,error+' explains retained working data');
}
assert.match(c.getSubscriptionResourceErrorMessage('subscription_too_large'),/по умолчанию/,'override-aware size message');
assert.match(c.getSubscriptionResourceErrorMessage('subscription_too_many_nodes'),/по умолчанию/,'override-aware node message');
console.log('PASS: every resource/download/parse refusal has an actionable, cache-preserving and override-aware UI message');
