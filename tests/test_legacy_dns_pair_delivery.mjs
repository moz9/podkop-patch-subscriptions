import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const read=name=>fs.readFileSync(path.join(repo,name),'utf8');
for(const name of ['dns_benchmark.js','podkop-dns-benchmark','podkop-dns-apply','dns-main.json','dns-bootstrap.json']) {
  assert.ok(fs.existsSync(path.join(repo,'openwrt',name)),`legacy missing ${name}`);
}
const ui=read('openwrt/settings.js');
assert.match(ui,/require view\.podkop\.dns_benchmark as dnsBenchmark/);
assert.match(ui,/section\.tab\("dns", "DNS"\)/);
assert.match(ui,/section\.tab\("benchmark", "Проверка DNS"\)/);
assert.match(ui,/dnsBenchmark\.renderOpenButton\(this\.map\)/);
assert.doesNotMatch(read('openwrt/podkop-dns-benchmark'),/podkop-engine|\/usr\/bin\/engine/);
assert.match(read('openwrt/podkop-dns-optimizer'),/PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY/);
for(const installer of ['i','openwrt/install.sh']) {
  const source=read(installer);
  for(const file of ['dns_benchmark.js','podkop-dns-benchmark','podkop-dns-apply','dns-main.json','dns-bootstrap.json']) assert.ok(source.includes(file),`installer missing ${file}`);
  assert.match(source,/read\.file\["\/usr\/bin\/podkop-dns-benchmark"\] = \["exec"\]/);
  assert.ok(/read\.file\["\/usr\/bin\/podkop-dns-benchmark"\] == \["exec"\]/.test(source),'installer fast-path must check benchmark ACL');
  assert.ok(/ash -n \/usr\/lib\/podkop\/dns-native\.sh/.test(source),'installer must validate native facade syntax');
}
console.log('PASS: legacy paired DNS UI, native worker and delivery contract');
