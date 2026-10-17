# PE fastfix source candidate

Source: existing local pe-0724-adaptation-20261012, not Legacy i. Includes full existing openwrt payload and top-level a/i/s/m required by the unchanged release-hash generator; no project test/doc tree or binaries downloaded.

Changes: exact authoritative DNS benchmark and .24 runtime source copies; installer marker and direct LuCI namespace/backup paths renamed 20261017-pe-fastfix-v1-candidate; manifest patchVersion/publishedAt and generated sha256 updated. releaseStatus remains prepared, channel podkop-pe. Date is bundle metadata, not a publication claim.

Native checks passed: unchanged generator --check; every LF-normalized manifest digest; identical installer mirrors; byte identity of both authoritative fixes; marker/namespace/prepared contract and package-mutation-disabled guard. No shell installation executed here.

Blockers: PE adapter still requires an already matching .24 + Engine1.14.2-pdk-r14 stack and all five features. Package migration remains disabled. Public APK metadata alone does not establish router ABI, dependency closure or installed package integrity. This is source review payload, not a working fresh installer or promoted stable release. Runtime fixes require independent Linux/BusyBox and agreed live validation as tracked by root.
