param([Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CIToolchainReceipts.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CIToolchainReceipts-RustupRed.psm1') -Prefix Red -Force
New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null
$failures = [Collections.Generic.List[string]]::new()
function Assert-That([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION_FAILED: $Message" } }

$fixtureDirectory = Join-Path $env:RUNNER_TEMP ('helios-rustup-fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixtureDirectory | Out-Null
$fixture = Join-Path $fixtureDirectory 'rustup-fixture.exe'
$source = Join-Path $fixtureDirectory 'rustup-fixture.c'
@'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <io.h>
#include <fcntl.h>
int main(int argc, char **argv) {
  _setmode(_fileno(stdout), _O_BINARY);
  _setmode(_fileno(stderr), _O_BINARY);
  const char *mode = argc > 1 && !strcmp(argv[1],"--version") ? getenv("HELIOS_RUSTUP_FIXTURE_MODE") : (argc > 1 ? argv[1] : "valid-info");
  if (!mode) mode = "valid-info";
  if (!strcmp(mode,"valid")) puts("rustup 1.29.1");
  else if (!strcmp(mode,"valid-info")) { puts("info: This is the version for the rustup toolchain manager, not the rustc compiler."); puts("rustup 1.29.1 (d95a37b6a 2026-08-13)"); puts("info: the currently active `rustc` version is `rustc 1.99.0-nightly (daf2e5e18 2026-07-13)`"); }
  else if (!strcmp(mode,"valid-after")) { puts("rustup 1.29.1"); puts("info: trailing information"); }
  else if (!strcmp(mode,"lf")) fputs("info: before\nrustup 1.29.1\ninfo: after\n",stdout);
  else if (!strcmp(mode,"crlf")) fputs("info: before\r\nrustup 1.29.1\r\ninfo: after\r\n",stdout);
  else if (!strcmp(mode,"stderr")) { fputs("info: stderr before\n",stderr); puts("rustup 1.29.1"); fputs("info: stderr after\n",stderr); }
  else if (!strcmp(mode,"wrong")) puts("rustup 1.29.0");
  else if (!strcmp(mode,"prefix")) puts("rustup 1.29.10");
  else if (!strcmp(mode,"suffix-custom")) puts("rustup 1.29.1-custom");
  else if (!strcmp(mode,"suffix-zero")) puts("rustup 1.29.1.0");
  else if (!strcmp(mode,"suffix-plus")) puts("rustup 1.29.1+custom");
  else if (!strcmp(mode,"info-only")) puts("info: rustup 1.29.1");
  else if (!strcmp(mode,"prefixed")) puts("x rustup 1.29.1");
  else if (!strcmp(mode,"empty")) return 0;
  else if (!strcmp(mode,"duplicate")) { puts("rustup 1.29.1"); puts("rustup 1.29.1"); }
  else if (!strcmp(mode,"conflict")) { puts("rustup 1.29.0"); puts("rustup 1.29.1"); }
  else if (!strcmp(mode,"exit23")) { puts("rustup 1.29.1"); return 23; }
  else return 99;
  return 0;
}
'@ | Set-Content -LiteralPath $source -Encoding ascii
. (Join-Path $PSScriptRoot 'Initialize-HeliosBuild.ps1')
Import-VisualStudioEnvironment -Architecture x64
$compiler = Get-Command cl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $compiler) { throw 'Native MSVC cl.exe is required for real process fixture.' }
& $compiler.Path /nologo /O2 /Fe:$fixture $source
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fixture -PathType Leaf)) { throw 'Could not compile real rustup process fixture.' }

function Invoke-RustupFixture([string]$Mode, [string]$Name='rustup') {
    Invoke-CIToolCheck -Name $Name -ExecutablePath $fixture -ExpectedResolvedPath $fixture -Arguments @($Mode) -ExpectedVersion 'rustup 1.29.1' -RustupVersion '1.29.1' -Phase "rustup-fixture-$Mode"
}
$red = Invoke-RedCIToolCheck -Name 'rustup' -ExecutablePath $fixture -ExpectedResolvedPath $fixture -Arguments @('valid-info') -ExpectedVersion 'rustup 1.29.1' -VersionPattern '^rustup 1\.29\.1(?:\s|$)' -Phase 'rustup-original-red'
Assert-That ($red.status -eq 'FAIL' -and $red.error -match 'VERSION_MISMATCH') 'R4 matcher must reproduce RED for valid rustup identity after info line'
Write-CIToolReceipt -Path (Join-Path $ReceiptDir 'original-red.json') -Receipt (New-CIToolReceipt -Name 'rustup-original-red' -Checks @($red))
$cases = @(
  @{mode='valid';pass=$true}, @{mode='valid-info';pass=$true}, @{mode='valid-after';pass=$true},
  @{mode='lf';pass=$true}, @{mode='crlf';pass=$true}, @{mode='stderr';pass=$true},
  @{mode='wrong';pass=$false}, @{mode='prefix';pass=$false}, @{mode='suffix-custom';pass=$false},
  @{mode='suffix-zero';pass=$false}, @{mode='suffix-plus';pass=$false}, @{mode='info-only';pass=$false},
  @{mode='prefixed';pass=$false}, @{mode='empty';pass=$false}, @{mode='duplicate';pass=$false},
  @{mode='conflict';pass=$false}, @{mode='exit23';pass=$false;exit=23}
)
$rows = foreach ($case in $cases) {
    $row = Invoke-RustupFixture $case.mode
    $saved = New-CIToolReceipt -Name "rustup-$($case.mode)" -Checks @($row)
    Write-CIToolReceipt -Path (Join-Path $ReceiptDir "$($case.mode).json") -Receipt $saved
    if ($case.pass -and $row.status -ne 'PASS') { throw "Expected $($case.mode) to pass: $($row.error)" }
    if (-not $case.pass -and $row.status -ne 'FAIL') { throw "Expected $($case.mode) to fail: $($row.status)" }
    if ($case.exit -and $row.exitCode -ne $case.exit) { throw "Expected $($case.mode) exit $($case.exit), got $($row.exitCode)" }
    if ($case.mode -eq 'valid-info') {
        Assert-That ($row.observedVersion -match 'info: This is the version' -and $row.observedVersion -match 'rustc 1.99.0-nightly') 'full stdout must be retained'
        Assert-That ($row.path -ceq $fixture -and $row.size -gt 0 -and $row.sha256.Length -eq 64 -and $row.exitCode -eq 0) 'executable identity and exit must be retained'
    }
    if ($case.mode -eq 'stderr') { Assert-That ($row.observedVersion -match 'stderr before' -and $row.observedVersion -match 'stderr after') 'stderr lines must be captured with stdout' }
    [pscustomobject]@{mode=$case.mode;status=$row.status;error=$row.error;exitCode=$row.exitCode}
}

$identityChecks = @(
  @{text='rustup 1.29.1';ok=$true},
  @{text="info: before`n rustup 1.29.1`ninfo: after";ok=$false},
  @{text="rustup 1.29.0`nrustup 1.29.1";ok=$false},
  @{text="rustup 1.29.1`nrustup 1.29.1";ok=$false},
  @{text="info: before`r`nrustup 1.29.1 (d95a37b6a 2026-08-13)`r`ninfo: after";ok=$true}
)
foreach ($item in $identityChecks) {
    $identity = Test-CIRustupIdentity -Output $item.text -Version '1.29.1'
    Assert-That ($identity.IsValid -eq $item.ok) "shared identity helper mismatch for [$($item.text)]"
}
$duplicate = Test-CIRustupIdentity -Output "rustup 1.29.1`nrustup 1.29.1" -Version '1.29.1'
Assert-That ($duplicate.Error -eq 'AMBIGUOUS_RUSTUP_IDENTITY') 'duplicate identities must be an explicit refusal'

# Exercise the actual production checkers. Other machine pins may fail in this focused
# harness; each durable receipt must still show the rustup row accepted by the shared rule.
$namedFixture = Join-Path $fixtureDirectory 'rustup.exe'
Copy-Item -LiteralPath $fixture -Destination $namedFixture -Force
$savedPath = $env:PATH
$savedMode = $env:HELIOS_RUSTUP_FIXTURE_MODE
$env:PATH = "$fixtureDirectory;$savedPath"
$env:HELIOS_RUSTUP_FIXTURE_MODE = 'valid-info'
try {
    $targets = @(
        [pscustomobject]@{name='native';script='Assert-CIToolchain.ps1';args=@('-ReceiptDir',(Join-Path $ReceiptDir 'checker-native'));dir=(Join-Path $ReceiptDir 'checker-native');receipt='toolchain.json'},
        [pscustomobject]@{name='driver';script='Assert-ComponentToolchain.ps1';args=@('-Component','driver','-ReceiptDir',(Join-Path $ReceiptDir 'checker-driver'));dir=(Join-Path $ReceiptDir 'checker-driver');receipt='pre-producer-tools.json'},
        [pscustomobject]@{name='package-pre';script='Assert-ComponentToolchain.ps1';args=@('-Component','package','-Phase','pre','-ReceiptDir',(Join-Path $ReceiptDir 'checker-package-pre'));dir=(Join-Path $ReceiptDir 'checker-package-pre');receipt='pre-producer-tools.json'},
        [pscustomobject]@{name='package-post';script='Assert-ComponentToolchain.ps1';args=@('-Component','package','-Phase','post','-ReceiptDir',(Join-Path $ReceiptDir 'checker-package-post'));dir=(Join-Path $ReceiptDir 'checker-package-post');receipt='post-producer-tools.json'}
    )
    foreach ($target in $targets) {
        $targetArgs = $target.args
        try { & (Join-Path $PSScriptRoot $target.script) @targetArgs } catch { }
        $receiptPath = Join-Path $target.dir $target.receipt
        if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw "$($target.name) did not write its production receipt" }
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        $row = $receipt.checks | Where-Object requestedName -eq 'rustup' | Select-Object -First 1
        if (-not $row -or $row.status -ne 'PASS' -or $row.exitCode -ne 0 -or $row.observedVersion -notmatch 'info: This is the version') { throw "$($target.name) did not accept the pinned rustup identity while preserving output" }
        Write-CIToolReceipt -Path (Join-Path $ReceiptDir "checker-$($target.name).json") -Receipt $receipt
    }
} finally {
    $env:PATH = $savedPath
    $env:HELIOS_RUSTUP_FIXTURE_MODE = $savedMode
}
Write-Host 'RUSTUP_NATIVE_FIXTURE_MATRIX=PASS_17_CASES'
Write-Host 'RUSTUP_ORIGINAL_MATCHER_RED=PASS'
Write-Host "RUSTUP_FIXTURE_EXE=$fixture"
$fixtureIdentity = [pscustomobject][ordered]@{path=[IO.Path]::GetFullPath($fixture);size=[long](Get-Item -LiteralPath $fixture).Length;sha256=(Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash.ToLowerInvariant();sourceSha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()}
Write-CIToolReceipt -Path (Join-Path $ReceiptDir 'fixture-identity.json') -Receipt (New-CIToolReceipt -Name 'rustup-native-fixture' -Checks @([pscustomobject][ordered]@{requestedName='rustup-fixture.exe';phase='native-test';commandType='ExplicitPath';path=$fixtureIdentity.path;resolvedCommandType='ExplicitPath';resolvedPath=$fixtureIdentity.path;expectedVersion='fixture source pinned by current CI commit';observedVersion=$null;exitCode=0;size=$fixtureIdentity.size;sha256=$fixtureIdentity.sha256;status='PASS';error=$null;resolutionCandidates=@()}) -Context @{sourceSha256=$fixtureIdentity.sourceSha256})
Write-Host "RUSTUP_FIXTURE_SHA256=$($fixtureIdentity.sha256)"
