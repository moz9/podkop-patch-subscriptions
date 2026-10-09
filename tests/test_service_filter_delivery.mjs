import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const installer = fs.readFileSync(path.join(root, 'openwrt/install.sh'), 'utf8');
assert.equal(fs.readFileSync(path.join(root, 'i'), 'utf8'), installer);
assert.ok(installer.includes("grep -Fqx '# subscription_services_v1 end'"), 'installer must detect old backends without service checks');
assert.ok(installer.includes("! grep -Fqx '# subscription_services_v1 end'"), 'installer must upgrade a previously patched backend');
assert.ok(installer.includes("# subscription_service_filter_v1"), 'installer must require runtime admission, not just probe helper');
assert.ok(installer.includes("# subscription_service_snapshot_v1 end"), 'installer must deliver safe expired-proof boot preservation');
assert.ok(installer.includes("grep -Fqx '# subscription_gemini_region_v2'"), 'installer must detect the new classifier, not just the old helper');
assert.ok(installer.includes("! grep -Fqx '# subscription_gemini_region_v2'"), 'installer must replace the already patched classifier');
assert.ok(installer.includes("# subscription_probe_context_v2"), 'installer must deliver native DNS context for isolated probes');
// Inline helpers must be byte-equivalent after line-ending normalization.
// Replacement-string dollar expansion can otherwise silently corrupt shell $$.
for (const [filename, marker] of [
  ['podkop-service-checks.sh', 'subscription_services_v1'],
  ['podkop-service-snapshot.sh', 'subscription_service_snapshot_v1'],
]) {
  const canonical = fs.readFileSync(path.join(root, 'openwrt', filename), 'utf8').replace(/\r\n/g, '\n').trim();
  for (const directory of fs.readdirSync(path.join(root, 'openwrt')).filter(name => /^runtime-/.test(name))) {
    const runtime = fs.readFileSync(path.join(root, 'openwrt', directory, 'usr/bin/podkop'), 'utf8').replace(/\r\n/g, '\n');
    const start = runtime.indexOf('# ' + marker + ' begin');
    const end = runtime.indexOf('# ' + marker + ' end', start);
    assert.ok(start >= 0 && end > start, directory + ': missing helper ' + marker);
    assert.equal(runtime.slice(start, end + ('# ' + marker + ' end').length).trim(), canonical, directory + ': inline helper drift ' + marker);
  }
}
console.log('Service filter delivery checks passed');
