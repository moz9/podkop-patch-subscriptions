#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

node - "$repo_root/openwrt/main.js" <<'NODE'
const fs = require("fs");
const source = fs.readFileSync(process.argv[2], "utf8");
const match = source.match(
  /function versionValue\([\s\S]*?\n}\nfunction renderUpdateCenter/,
);
if (!match) throw new Error("versionValue helper not found");
const helperSource = match[0].replace(/\nfunction renderUpdateCenter$/, "");
const versionValue = new Function(`${helperSource}; return versionValue;`)();

const cases = [
  [["20260813-reliability-responsive-v1", "20260720-update-center-force-v1", false], "20260813-reliability-responsive-v1"],
  [["20260720-update-center-force-v1", "20260813-reliability-responsive-v1", true], "20260720-update-center-force-v1 → 20260813-reliability-responsive-v1"],
  [["0.7.21", "0.7.21", false], "0.7.21"],
];
for (const [args, expected] of cases) {
  const actual = versionValue(...args);
  if (actual !== expected) {
    throw new Error(`versionValue(${JSON.stringify(args)}) = ${actual}; expected ${expected}`);
  }
}

if (!/status\.patchUpdateAvailable[\s\S]{0,160}versionValue|versionValue\([\s\S]{0,160}status\.patchUpdateAvailable/.test(source)) {
  throw new Error("patch update row does not gate the target version on patchUpdateAvailable");
}
NODE

printf '%s\n' 'PASS: update center hides older patch targets when no update is available'
