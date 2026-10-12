#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

node - "$repo_root/openwrt/podkop.ru.lmo.base64" <<'NODE'
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const encoded = fs.readFileSync(process.argv[2], 'utf8').trim();
const lmo = Buffer.from(encoded, 'base64');

function u32(value) {
  return value >>> 0;
}

function sfhHash(value) {
  const data = Buffer.from(value, 'utf8');
  let length = data.length;
  let hash = u32(length);
  const remainder = length & 3;
  length >>= 2;
  let offset = 0;
  const uint16 = (position) => data[position] | (data[position + 1] << 8);

  while (length-- > 0) {
    hash = u32(hash + uint16(offset));
    const temp = u32((uint16(offset + 2) << 11) ^ hash);
    hash = u32((hash << 16) ^ temp);
    offset += 4;
    hash = u32(hash + (hash >>> 11));
  }

  if (remainder === 3) {
    hash = u32(hash + uint16(offset));
    hash = u32(hash ^ (hash << 16));
    hash = u32(hash ^ (data.readInt8(offset + 2) << 18));
    hash = u32(hash + (hash >>> 11));
  } else if (remainder === 2) {
    hash = u32(hash + uint16(offset));
    hash = u32(hash ^ (hash << 11));
    hash = u32(hash + (hash >>> 17));
  } else if (remainder === 1) {
    hash = u32(hash + data.readInt8(offset));
    hash = u32(hash ^ (hash << 10));
    hash = u32(hash + (hash >>> 1));
  }

  hash = u32(hash ^ (hash << 3));
  hash = u32(hash + (hash >>> 5));
  hash = u32(hash ^ (hash << 4));
  hash = u32(hash + (hash >>> 17));
  hash = u32(hash ^ (hash << 25));
  return u32(hash + (hash >>> 6));
}

if (lmo.length < 20) throw new Error('Russian LMO asset is empty or truncated');

const indexOffset = lmo.readUInt32BE(lmo.length - 4);
if (indexOffset <= 0 || indexOffset >= lmo.length - 4) {
  throw new Error(`Invalid LMO index offset: ${indexOffset}`);
}
if ((lmo.length - indexOffset - 4) % 16 !== 0) {
  throw new Error('LMO index has an invalid length');
}

const translations = new Map();
for (let position = indexOffset; position < lmo.length - 4; position += 16) {
  const key = lmo.readUInt32BE(position);
  const valueOffset = lmo.readUInt32BE(position + 8);
  const valueLength = lmo.readUInt32BE(position + 12);
  if (valueOffset + valueLength > indexOffset) {
    throw new Error(`LMO entry ${key.toString(16)} points outside the value area`);
  }
  translations.set(key, lmo.subarray(valueOffset, valueOffset + valueLength).toString('utf8'));
}

const expected = new Map([
  ['Browser FakeIP probe is unavailable', 'Проверка FakeIP в браузере недоступна'],
  [
    'Browser uses another DNS (normal over remote access or with Secure DNS enabled)',
    'Браузер использует другой DNS (это нормально при удалённом доступе или включённом безопасном DNS)',
  ],
  ['Proxy routing probe is unavailable', 'Проверка маршрутизации через прокси недоступна'],
  ['Router DNS did not return an answer', 'DNS роутера не вернул ответ'],
  ['Router FakeIP probe is unavailable', 'Проверка FakeIP на роутере недоступна'],
]);

for (const [message, translation] of expected) {
  const actual = translations.get(sfhHash(message));
  if (actual !== translation) {
    throw new Error(`${JSON.stringify(message)} has translation ${JSON.stringify(actual)}`);
  }
}

const pluralFormula = translations.get(0);
if (!pluralFormula || !pluralFormula.includes('nplurals=3')) {
  throw new Error('Russian plural formula is missing from the LMO asset');
}

// Check the shipped dictionary, not a fake identity translator.
const source = fs.readFileSync(path.join(path.dirname(process.argv[2]), 'main.js'), 'utf8');
const assetDir = path.dirname(process.argv[2]);
const uiSource = fs.readdirSync(assetDir).filter(name => name.endsWith('.js')).map(name => fs.readFileSync(path.join(assetDir,name),'utf8')).join('\n');
const uiKeys = [...uiSource.matchAll(/_\(\s*((?:"(?:[^"\\]|\\.)*")(?:\s*\+\s*"(?:[^"\\]|\\.)*")*)\s*,?\s*\)/g)]
  .map(m=>[...m[1].matchAll(/"(?:[^"\\]|\\.)*"/g)].map(s=>JSON.parse(s[0])).join(''));
const untranslated = [...new Set(uiKeys)]
  .filter(key=>/[A-Za-z]/.test(key) && !/[А-Яа-яЁё]/.test(key) && !['Podkop','Sing-box'].includes(key) && !translations.has(sfhHash(key)));
if (untranslated.length) throw new Error('Untranslated UI labels: ' + JSON.stringify(untranslated));
for (const label of ['Proxy','Block','Exclusion','Trace','Debug','Info','Warn','Fatal','Panic','Service list','Domains list','IP or subnet']) {
  if (new RegExp('(?:o\\.value\\("[^"]+",\\s*|o\\.placeholder\\s*=\\s*)"'+label+'"').test(uiSource)) throw new Error('Unlocalized form label: '+label);
}
if (/"(?:Flash|RAM) \(/.test(uiSource)) throw new Error('Storage labels must be Russian');
const subscriptions = source.slice(source.indexOf('function formatMbitPerSecond('), source.indexOf('// src/podkop/tabs/subscriptions/styles.ts'));
const missing = [...new Set([...subscriptions.matchAll(/_\(\s*"((?:[^"\\]|\\.)*)"\s*\)/g)].map(m => JSON.parse('"' + m[1] + '"')))]
  .filter(key => /[A-Za-z]/.test(key) && !/[А-Яа-яЁё]/.test(translations.get(sfhHash(key)) || ''));
if (missing.length) throw new Error('Missing Russian subscription messages: ' + JSON.stringify(missing));
const context = vm.createContext({_: key => translations.get(sfhHash(key)) || key});
for (const name of ['getSpeedtestStatusMessage','getErrorText','getSubscriptionActionErrorMessage','formatMbitPerSecond']) {
  const match = source.match(new RegExp('function ' + name + '\\([\\s\\S]*?\\n}(?=\\r?\\n)'));
  if (!match) throw new Error('Missing function ' + name);
  vm.runInContext(match[0], context);
}
const message = context.getSpeedtestStatusMessage({message:'probe_start_failed'}, {displayName:'main'}, {name:'Node'});
if (!/[А-Яа-яЁё]/.test(message) || message.includes('probe_start_failed')) throw new Error('Technical benchmark status leaked to the UI: ' + message);
if (!context.formatMbitPerSecond(125000).includes('Мбит/с')) throw new Error('Speed units must be Russian');
NODE

printf '%s\n' 'PASS: FakeIP diagnostic Russian translations are packaged in the LMO asset'
