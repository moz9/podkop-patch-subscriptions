import fs from 'node:fs';
import assert from 'node:assert/strict';
const src=fs.readFileSync(new URL('../openwrt/runtime-0.7.22/usr/bin/podkop',import.meta.url),'utf8');
assert.ok(src.includes('rules_zerotier_mark_count'),'known ZeroTier protection needs separate reporting');
assert.ok(src.includes('rules_unknown_mark_count'),'unknown rules must remain visible');
console.log('PASS: separate known and unknown mark reporting');
