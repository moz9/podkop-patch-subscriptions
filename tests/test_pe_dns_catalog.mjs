import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const root = new URL('../openwrt/', import.meta.url);
const installer = fs.readFileSync(new URL('../i', root), 'utf8');
const backupAssets = installer.slice(installer.indexOf('RUNTIME_FILES="'), installer.indexOf('\n"', installer.indexOf('RUNTIME_FILES="')));
for (const name of ['dns-main.json', 'dns-bootstrap.json']) {
  assert.ok(backupAssets.includes(`usr/share/podkop/${name}`), `${name} included in runtime backup/restore`);
  assert.ok(installer.includes(`"${name}"`), `${name} installer asset declared`);
}
const source = fs.readFileSync(new URL('main.js', root), 'utf8');
assert.match(source, /var DNS_MAIN_CATALOG =/, 'full main catalog embedded for LuCI');
const catalogSource = source.slice(source.indexOf('var DNS_MAIN_CATALOG ='), source.indexOf('var DIAGNOSTICS_UPDATE_INTERVAL'));
const validators = source.slice(source.indexOf('function validateIPV4'), source.indexOf('// src/validators/validateUrl.ts'));
const api = vm.runInNewContext('(function(){' + validators + catalogSource + ';return {DNS_MAIN_CATALOG,DNS_BOOTSTRAP_CATALOG,DNS_SUPPORTED_PROTOCOLS,getDnsServerOptionsForType,validateDnsByType};})()', { _: x => x });
assert.deepEqual(Array.from(api.DNS_SUPPORTED_PROTOCOLS), ['udp', 'tcp', 'doh', 'dot']);
for (const kind of ['main', 'bootstrap']) {
  const catalog = JSON.parse(fs.readFileSync(new URL(`dns-${kind}.json`, root), 'utf8'));
  assert.equal(JSON.stringify(kind === 'main' ? api.DNS_MAIN_CATALOG : api.DNS_BOOTSTRAP_CATALOG), JSON.stringify(catalog));
  assert.ok(catalog.servers.length >= (kind === 'main' ? 40 : 24), 'full provider catalog');
  for (const row of catalog.servers) for (const type of row.protocols) {
    if (!api.DNS_SUPPORTED_PROTOCOLS.includes(type)) continue;
    assert.equal(api.getDnsServerOptionsForType(type, kind === 'bootstrap')[row.value], row.label);
    assert.equal(api.validateDnsByType(row.value, type, kind === 'bootstrap').valid, true, `${kind} ${row.value} ${type}`);
  }
  for (const type of ['doq', 'h3']) {
    assert.equal(Object.keys(api.getDnsServerOptionsForType(type, kind === 'bootstrap')).length, 0, 'unsupported engine transports are not offered');
    const validation = api.validateDnsByType(kind === 'main' ? 'dns.quad9.net' : '9.9.9.9', type, kind === 'bootstrap');
    assert.equal(validation.valid, false);
    assert.match(validation.message, /движ|engine/i, 'explicit engine support message');
  }
}
assert.equal(api.validateDnsByType('dns.google', 'tcp').valid, false);
assert.equal(api.validateDnsByType('dns.google/dns-query', 'dot').valid, false);
assert.equal(api.validateDnsByType('dns.example', 'doh', true).valid, false, 'bootstrap hostname cannot fall back to system DNS');
const settings = fs.readFileSync(new URL('settings.js', root), 'utf8');
assert.ok(settings.includes('function configureDnsServerChoices('));
const configure = vm.runInNewContext(settings.slice(settings.indexOf('function configureDnsServerChoices('), settings.indexOf('function createSettingsContent(')) + ';configureDnsServerChoices', {
  main: api, uci: { get: () => 'doh' }, candidateIsPrimaryEligible: ({ dnsServer }) => !dnsServer.includes('yandex') && !dnsServer.startsWith('77.88.8.'),
});
let added;
const protocolOption = { formvalue: () => 'doh' };
const widget = { clearChoices: reset => assert.equal(reset, false), addChoices: keys => { added = keys; } };
const option = { map: { lookupOption: () => [protocolOption] }, renderWidget() { return this.keylist; }, getUIElement: () => widget };
configure(option, 'dns_type');
assert.ok(option.renderWidget('settings', 0, 'dns.google').includes('dns.google'));
protocolOption.onchange(null, 'settings', 'tcp');
assert.ok(added.includes('223.5.5.5'));
assert.ok(!added.includes('dns.google'));
console.log('PASS: DNS catalog metadata, supported engine protocols, validation and protocol-specific choices');
