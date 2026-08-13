#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

node - "$repo_root/openwrt/podkop.ru.lmo.base64" <<'NODE'
const fs = require('fs');

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
NODE

printf '%s\n' 'PASS: FakeIP diagnostic Russian translations are packaged in the LMO asset'
