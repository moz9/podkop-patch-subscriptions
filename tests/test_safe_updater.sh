#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
mkdir -p "$work/release/openwrt"
# Use the real installer's asset consumer, without router mutations.
sed '/^tmp_dir="$(mktemp -d)"$/,$d' "$repo/i" > "$work/release/i"
cat >> "$work/release/i" <<'EOF'
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
prefetch_patch_assets
EOF
node - "$repo" "$work/release" <<'NODE'
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const [repo, release] = process.argv.slice(2);
fs.cpSync(path.join(repo, 'openwrt'), path.join(release, 'openwrt'), {recursive:true});
function normalize(dir) { for(const entry of fs.readdirSync(dir,{withFileTypes:true})) {
  const p=path.join(dir,entry.name); if(entry.isDirectory()) normalize(p);
  else fs.writeFileSync(p,fs.readFileSync(p,'utf8').replace(/\r\n/g,'\n'));
} }
normalize(release);
const manifestPath=path.join(release,'openwrt/update-manifest.json');
const manifest=JSON.parse(fs.readFileSync(manifestPath,'utf8'));
if(manifest.sha256) manifest.sha256.i=crypto.createHash('sha256').update(fs.readFileSync(path.join(release,'i'))).digest('hex');
fs.writeFileSync(manifestPath,JSON.stringify(manifest));
NODE
PODKOP_PATCH_RAW_ROOT="file://$work/release" \
PODKOP_PATCH_SAFE_WORK_DIR="$work/update" PODKOP_PATCH_SAFE_LOG="$work/update.log" \
PODKOP_PATCH_SAFE_STATUS="$work/status" PODKOP_PATCH_SAFE_FOREGROUND=1 \
    sh "$repo/s" > "$work/output" 2>&1 || {
    cat "$work/output" "$work/update.log" 2>/dev/null || true
    echo 'FAIL: safe updater must stage every asset consumed by i'; exit 1;
}
grep -q '^ok ' "$work/status"
printf '\n# tampered after publication\n' >> "$work/release/openwrt/main.js"
if PODKOP_PATCH_RAW_ROOT="file://$work/release" \
    PODKOP_PATCH_SAFE_WORK_DIR="$work/update" PODKOP_PATCH_SAFE_LOG="$work/update.log" \
    PODKOP_PATCH_SAFE_STATUS="$work/status" PODKOP_PATCH_SAFE_FOREGROUND=1 \
    sh "$repo/s" > "$work/tampered-output" 2>&1; then
    echo 'FAIL: a modified release asset passed verification'; exit 1
fi
grep -q 'release checksum mismatch for openwrt/main.js' "$work/tampered-output"
grep -q '^failed ' "$work/status"
if PODKOP_PATCH_RAW_BASE="file://$work/release/openwrt" sh "$work/release/i" > "$work/direct-output" 2>&1; then
    echo 'FAIL: direct installer accepted a modified release asset'; exit 1
fi
grep -q 'release checksum mismatch for main.js' "$work/direct-output"
echo 'PASS: safe updater stages the complete local release for the real prefetch consumer'
# Wrong release identity fails in installer prefetch; missing assets fail in staging.
cp "$repo/openwrt/main.js" "$work/release/openwrt/main.js"
cp "$work/release/openwrt/update-manifest.json" "$work/original-manifest"
jq '.patchVersion="wrong-release"' "$work/original-manifest" > "$work/release/openwrt/update-manifest.json"
if PODKOP_PATCH_RAW_ROOT="file://$work/release" PODKOP_PATCH_SAFE_WORK_DIR="$work/update" PODKOP_PATCH_SAFE_LOG="$work/update.log" PODKOP_PATCH_SAFE_STATUS="$work/status" PODKOP_PATCH_SAFE_FOREGROUND=1 sh "$repo/s" > "$work/wrong" 2>&1; then
 echo 'FAIL: wrong manifest accepted'; exit 1
fi
grep -q 'release manifest does not match this installer' "$work/update.log"
cp "$work/original-manifest" "$work/release/openwrt/update-manifest.json"
rm "$work/release/openwrt/main.js"
if PODKOP_PATCH_RAW_ROOT="file://$work/release" PODKOP_PATCH_SAFE_WORK_DIR="$work/update" PODKOP_PATCH_SAFE_LOG="$work/update.log" PODKOP_PATCH_SAFE_STATUS="$work/status" PODKOP_PATCH_SAFE_FOREGROUND=1 sh "$repo/s" > "$work/missing" 2>&1; then
 echo 'FAIL: missing asset accepted'; exit 1
fi
grep -q 'local source not found' "$work/missing"
# Failed competitors preserve all pre-existing work and owner lock, even no PID yet.
mkdir -p "$work/update"
mkdir "$work/update.lock"
echo owner > "$work/update.lock/owner"
echo sentinel > "$work/update/keep"
if PODKOP_PATCH_RAW_ROOT="file://$work/release" PODKOP_PATCH_SAFE_WORK_DIR="$work/update" PODKOP_PATCH_SAFE_LOG="$work/update.log" PODKOP_PATCH_SAFE_STATUS="$work/status" PODKOP_PATCH_SAFE_FOREGROUND=1 sh "$repo/s" > "$work/busy" 2>&1; then
 echo 'FAIL: concurrent staging accepted'; exit 1
fi
[ "$(cat "$work/update/keep")" = sentinel ] && [ "$(cat "$work/update.lock/owner")" = owner ]
rm "$work/update.lock/owner"; rmdir "$work/update.lock"
echo 'PASS: wrong release, missing asset and concurrent staging fail closed'
