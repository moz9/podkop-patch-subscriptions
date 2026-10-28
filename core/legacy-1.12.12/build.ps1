param(
    [Parameter(Mandatory=$true)][string]$SourceDirectory,
    [string]$Go = 'go',
    [ValidateSet('test','build')][string]$Mode = 'test',
    [string]$OutputPath = (Join-Path $PSScriptRoot 'sing-box-legacy-arm64')
)
$ErrorActionPreference = 'Stop'
$sourceRoot = (Resolve-Path -LiteralPath $SourceDirectory).Path
$goExe = (Get-Command $Go -ErrorAction Stop).Source
$metadata = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'provenance.json') -Raw | ConvertFrom-Json
$patchPath = Join-Path $PSScriptRoot 'reality-mlkem.patch'
$wireTest = Join-Path $sourceRoot 'common/tls/reality_mlkem_test.go'

function Assert-Sha256([string]$Path, [string]$Expected) {
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() -ne $Expected) {
        throw "Source/provenance hash mismatch: $Path"
    }
}

if ((& git -C $sourceRoot rev-parse HEAD) -ne $metadata.upstream.commit -or $LASTEXITCODE -ne 0) {
    throw 'Use a separate checkout at the exact upstream commit from provenance.json.'
}
# Only the pinned patch/test may be dirty; never replace unrelated user changes.
$status = @(& git -C $sourceRoot -c core.quotepath=false status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect source checkout.' }
foreach ($entry in $status) {
    if ($entry -notin @(' M common/tls/reality_client.go', '?? common/tls/reality_mlkem_test.go')) {
        throw "Unexpected source change: $entry"
    }
}
Assert-Sha256 (Join-Path $sourceRoot 'go.mod') $metadata.dependencies.goModSha256
Assert-Sha256 (Join-Path $sourceRoot 'go.sum') $metadata.dependencies.goSumSha256
if ($status -notcontains ' M common/tls/reality_client.go') {
    & git -C $sourceRoot -c core.autocrlf=false apply --check $patchPath
    if ($LASTEXITCODE -ne 0) { throw 'Exact Reality patch does not apply.' }
    & git -C $sourceRoot -c core.autocrlf=false apply $patchPath
    if ($LASTEXITCODE -ne 0) { throw 'Reality patch failed.' }
}
Assert-Sha256 (Join-Path $sourceRoot $metadata.patch.sourceFile) $metadata.patch.patchedSourceSha256
Assert-Sha256 (Join-Path $PSScriptRoot $metadata.regressionTest.file) $metadata.regressionTest.sha256
if (!(Test-Path -LiteralPath $wireTest)) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $metadata.regressionTest.file) -Destination $wireTest
}
Assert-Sha256 $wireTest $metadata.regressionTest.sha256

$environmentNames = @('GOROOT','GOENV','GOTOOLCHAIN','CGO_ENABLED','GOOS','GOARCH','GOARM64','GOAMD64','GOFLAGS','GOEXPERIMENT','GOWORK')
$savedEnvironment = @{}
foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
Push-Location $sourceRoot
try {
    $env:GOROOT = Split-Path (Split-Path $goExe -Parent) -Parent
    $env:GOENV = 'off'
    $env:GOTOOLCHAIN = 'local'
    $env:CGO_ENABLED = '0'
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    $env:GOAMD64 = 'v1'
    $env:GOFLAGS = ''
    $env:GOEXPERIMENT = ''
    $env:GOWORK = 'off'
    if ((& $goExe version) -ne 'go version go1.23.12 windows/amd64' -or $LASTEXITCODE -ne 0) {
        throw 'The byte-reproducible recipe requires the pinned Windows/amd64 Go1.23.12 toolchain.'
    }
    if ($Mode -eq 'test') {
        & $goExe test -gcflags=all=-l -tags $metadata.build.tags ./common/tls -run '^TestRealityChromeHybridClientHello$' -count 20 -v
        if ($LASTEXITCODE -ne 0) { throw 'Serialized ClientHello regression test failed.' }
    } else {
        $outputFile = [IO.Path]::GetFullPath($OutputPath)
        if (Test-Path -LiteralPath $outputFile) { throw "Refusing to overwrite output: $outputFile" }
        $env:GOOS = 'linux'
        $env:GOARCH = 'arm64'
        $env:GOARM64 = 'v8.0'
        & $goExe build -mod=readonly -trimpath -gcflags=all=-l -tags $metadata.build.tags -ldflags $metadata.build.ldflags -o $outputFile ./cmd/sing-box
        if ($LASTEXITCODE -ne 0) { throw 'ARM64 build failed.' }
        Assert-Sha256 $outputFile $metadata.artifact.sha256
        if ((Get-Item -LiteralPath $outputFile).Length -ne $metadata.artifact.bytes) { throw 'Artifact size mismatch.' }
        Write-Output "Verified artifact: $outputFile ($($metadata.artifact.sha256))"
    }
    Assert-Sha256 (Join-Path $sourceRoot 'go.mod') $metadata.dependencies.goModSha256
    Assert-Sha256 (Join-Path $sourceRoot 'go.sum') $metadata.dependencies.goSumSha256
} finally {
    Pop-Location
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
}
