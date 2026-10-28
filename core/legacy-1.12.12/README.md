# Unofficial Legacy Reality backport

`1.12.12-pdk-reality1` is an unofficial drop-in core for the Legacy channel,
Podkop 0.7.20/0.7.22 on Linux aarch64. It is not an official SagerNet release
and does not imply endorsement or association with the upstream application.

The source is [SagerNet/sing-box v1.12.12](https://github.com/SagerNet/sing-box/tree/54ed58499d7063136ed52dabf87d179d252425d0),
commit `54ed58499d7063136ed52dabf87d179d252425d0`. The included patch removes
exactly 17 lines from `common/tls/reality_client.go`: the X25519MLKEM768
filter, its now-unused import and the redundant second handshake-state build.
This is the bounded change corresponding to the reference fix commit
`87f2d718a06af194b9335a3abd3b6611ec37b97a`; no other production source,
`go.mod` or `go.sum` changes are part of this build.

The uTLS dependency remains `github.com/metacubex/utls v1.8.3`.
The existing Reality authentication wire client-version tuple remains **1.8.1**
(`hello.SessionId[0..2]` before encryption). Those are different version fields.
No server minimum-version policy is bypassed or rewritten.

## Scope and evidence

Only the `chrome` fingerprint is covered by the supplied real serialized
ClientHello regression test. It checks supported group 4588 and the 1216-byte
hybrid key share preceding a classical share. The test uses `net.Pipe`, not a
synthetic handshake-state inspection; it is not a complete server handshake.
The original source failed this regression, and the patched source passed
20 repetitions with the accepted build tags and compiler flags.

The accepted ARM64 artifact was separately checked with an unchanged Legacy
configuration and bounded Reality, WebSocket and Hysteria2 transport probes.
That historical acceptance is not universal server/fingerprint compatibility
or phone/LAN application acceptance. In particular this backport adds no XHTTP
support, does not migrate Podkop to Podkop Engine, and is not used for the PE
channel's native engine. It does not claim support for every fingerprint or
for servers requiring a newer Reality client-version tuple.

Accepted artifact: 36,569,223 bytes, SHA-256
`b16d1530c45417a28317aa188bc32b845e09b6232aab2f5cc5831b37a770744a`.
The ELF is not duplicated in this source/provenance directory.

## Reproduce on Windows/amd64

Use a separate checkout with LF source and the pinned Go 1.23.12 Windows/amd64
toolchain. The official `go1.23.12.windows-amd64.zip` archive SHA-256 is
`07c35866cdd864b81bb6f1cfbf25ac7f87ddc3a976ede1bf5112acbb12dfe6dc`.
Obtain the archive from `https://go.dev/dl/` and verify it before extraction.

```powershell
git -c core.autocrlf=false clone --depth 1 --branch v1.12.12 https://github.com/SagerNet/sing-box.git source
.\build.ps1 -SourceDirectory .\source -Go C:\toolchains\go1.23.12\bin\go.exe -Mode test
.\build.ps1 -SourceDirectory .\source -Go C:\toolchains\go1.23.12\bin\go.exe -Mode build -OutputPath C:\build\sing-box-legacy-arm64
```

The script checks the exact base and clean/pinned source state, applies only
the included patch, copies the exact regression test, preserves module files,
and verifies the resulting artifact hash and size. Existing unrelated source
changes and existing output files are refused. Dependencies may be fetched by
Go according to the unchanged module checksums. The source remains deliberately
dirty so the embedded VCS metadata matches the accepted ELF (`vcs.modified=true`).

The build retains all six tags in `provenance.json`, uses `CGO_ENABLED=0`,
`GOOS=linux`, `GOARCH=arm64`, `GOARM64=v8.0`, `-mod=readonly`, `-trimpath`,
`-gcflags=all=-l`, and the exact linker flags in that file. No UPX is used.
`GOPATH` and `GOCACHE` may be set to existing dependency/build caches.

Installation, publication and rollback are outside this build script. A successful
local build does not authorize a router change. Preserve the current core and
configuration and verify the requested router/channel before any separate update.

## License

`LICENSE` reproduces the license notice from the exact upstream base, including
its naming/association restriction. The corresponding upstream source is identified
above, and this directory provides the complete production modification, test and
build recipe. See the [GNU GPL version 3](https://www.gnu.org/licenses/gpl-3.0.html)
for the full license text.
