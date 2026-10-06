import { createHash } from 'node:crypto';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const manifestPath = path.join(root, 'openwrt/update-manifest.json');
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
const files = ['a', 'i', 's'];

async function visit(directory) {
  for (const entry of await readdir(path.join(root, directory), { withFileTypes: true })) {
    const relative = path.posix.join(directory, entry.name);
    if (relative === 'openwrt/update-manifest.json') continue;
    if (entry.isDirectory()) await visit(relative);
    else if (entry.isFile()) files.push(relative);
  }
}

await visit('openwrt');
manifest.sha256 = {};
for (const relative of files.sort()) {
  manifest.sha256[relative] = createHash('sha256')
    .update((await readFile(path.join(root, relative), 'utf8')).replace(/\r\n/g, '\n'))
    .digest('hex');
}
const expected = JSON.stringify(manifest, null, 2) + '\n';
if (process.argv.includes('--check')) {
  if ((await readFile(manifestPath, 'utf8')).replace(/\r\n/g, '\n') !== expected) {
    console.error('Release hashes are missing or stale. Run node scripts/update-release-hashes.mjs');
    process.exitCode = 1;
  }
} else {
  await writeFile(manifestPath, expected);
}
