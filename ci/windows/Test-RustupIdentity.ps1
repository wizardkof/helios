param([Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CIToolchainReceipts.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CIToolchainOptions.psm1') -Force
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
  @{mode='valid';pass=$true;expectedError=$null}, @{mode='valid-info';pass=$true;expectedError=$null}, @{mode='valid-after';pass=$true;expectedError=$null},
  @{mode='lf';pass=$true;expectedError=$null}, @{mode='crlf';pass=$true;expectedError=$null}, @{mode='stderr';pass=$true;expectedError=$null},
  @{mode='wrong';pass=$false;expectedError='VERSION_MISMATCH'}, @{mode='prefix';pass=$false;expectedError='VERSION_MISMATCH'}, @{mode='suffix-custom';pass=$false;expectedError='VERSION_MISMATCH'},
  @{mode='suffix-zero';pass=$false;expectedError='VERSION_MISMATCH'}, @{mode='suffix-plus';pass=$false;expectedError='VERSION_MISMATCH'}, @{mode='info-only';pass=$false;expectedError='VERSION_MISMATCH'},
  @{mode='prefixed';pass=$false;expectedError='VERSION_MISMATCH'}, @{mode='empty';pass=$false;expectedError='VERSION_MISMATCH'}, @{mode='duplicate';pass=$false;expectedError='AMBIGUOUS_RUSTUP_IDENTITY'},
  @{mode='conflict';pass=$false;expectedError='AMBIGUOUS_RUSTUP_IDENTITY'}, @{mode='exit23';pass=$false;expectedError='EXECUTION_EXIT_NONZERO';exit=23}
)
$rows = foreach ($case in $cases) {
    $expectedExit = Get-CIRustupExpectedExit -Case $case
    $row = Invoke-RustupFixture $case.mode
    $saved = New-CIToolReceipt -Name "rustup-$($case.mode)" -Checks @($row)
    Write-CIToolReceipt -Path (Join-Path $ReceiptDir "$($case.mode).json") -Receipt $saved
    $actualError = if ($null -eq $row.error) { $null } else { (($row.error -split ';\s*') | Where-Object { $_ -in @('VERSION_MISMATCH','AMBIGUOUS_RUSTUP_IDENTITY','EXECUTION_EXIT_NONZERO') } | Select-Object -Last 1) }
    if (-not (Test-CIRustupFixtureExpectation -Case $case -ObservedExit $row.exitCode -ObservedStatus ([string]$row.status) -ObservedError $actualError)) {
        throw "Fixture expectation mismatch for $($case.mode): exit=$($row.exitCode), status=$($row.status), error=$actualError; expected exit=$expectedExit, pass=$($case.pass), error=$($case.expectedError)"
    }
    if ($case.mode -eq 'valid-info') {
        Assert-That ($row.observedVersion -match 'info: This is the version' -and $row.observedVersion -match 'rustc 1.99.0-nightly') 'full stdout must be retained'
        Assert-That ($row.path -ceq $fixture -and $row.size -gt 0 -and $row.sha256.Length -eq 64 -and $row.exitCode -eq 0) 'executable identity and exit must be retained'
    }
    if ($case.mode -eq 'stderr') { Assert-That ($row.observedVersion -match 'stderr before' -and $row.observedVersion -match 'stderr after') 'stderr lines must be captured with stdout' }
    [pscustomobject]@{mode=$case.mode;status=$row.status;error=$actualError;exitCode=$row.exitCode}
}

# The expected-exit assertion must reject a VERSION_MISMATCH expectation when the
# executable actually failed before producing a valid observation.
$unknown = Invoke-RustupFixture 'unknown-mode-control'
$unknownExpectedMismatch = @{mode='unknown-mode-control';pass=$false;expectedError='VERSION_MISMATCH'}
$unknownWouldMatchVersionMismatch = Test-CIRustupFixtureExpectation -Case $unknownExpectedMismatch -ObservedExit $unknown.exitCode -ObservedStatus ([string]$unknown.status) -ObservedError ([string]$unknown.error)
Assert-That ($unknown.exitCode -eq 99 -and -not $unknownWouldMatchVersionMismatch) 'unknown mode exit 99 must not satisfy a VERSION_MISMATCH control'
Write-CIToolReceipt -Path (Join-Path $ReceiptDir 'unknown-exit-control.json') -Receipt (New-CIToolReceipt -Name 'rustup-unknown-exit-control' -Checks @($unknown))

# Exercise the same production option builder used by both canonical checkers.
$commonDefinition = @{name='python';args=@('--version');expected='Python 3.12.10';pattern='^Python 3\.12\.10$';phase='preflight'}
$commonOptions = New-CICheckOptions -Definition $commonDefinition -BaseOptions @{Name='';Arguments=@();ExpectedVersion='';Phase=''}
Assert-That ($commonOptions.Name -eq 'python' -and $commonOptions.ExpectedVersion -eq 'Python 3.12.10' -and $commonOptions.VersionPattern -eq '^Python 3\.12\.10$' -and -not $commonOptions.ContainsKey('RustupVersion')) 'common definition options were not preserved/selected'
$rustupDefinition = @{name='rustup';args=@('--version');expected='rustup 1.29.1';rustupVersion='1.29.1';phase='preflight'}
$rustupOptions = New-CICheckOptions -Definition $rustupDefinition -BaseOptions @{Name='';Arguments=@();ExpectedVersion='';Phase=''}
Assert-That ($rustupOptions.RustupVersion -eq '1.29.1' -and -not $rustupOptions.ContainsKey('VersionPattern') -and $rustupOptions.Phase -eq 'preflight') 'rustup definition options were not preserved/selected'
foreach ($badDefinition in @(@{name='invalid-version';args=@();expected='x';pattern=''}, @{name='invalid-rustup';args=@();expected='x';rustupVersion=$null})) {
    $rejected = $false
    try { $null = New-CICheckOptions -Definition $badDefinition -BaseOptions @{} } catch { $rejected = $true }
    Assert-That $rejected 'invalid present optional definition value must be rejected'
}
foreach ($exitCase in @(@{expected=0},@{expected=0;exit=0},@{expected=23;exit=23})) {
    Assert-That ((Get-CIRustupExpectedExit -Case $exitCase) -eq $exitCase.expected) 'exit expectation contract mismatch'
}
foreach ($exitCase in @(@{exit=$null},@{exit='bad'})) {
    $rejected = $false
    try { $null = Get-CIRustupExpectedExit -Case $exitCase } catch { $rejected = $true }
    Assert-That $rejected 'present null/invalid exit expectation must be rejected'
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
    $fixtureIdentity = [pscustomobject]@{path=[IO.Path]::GetFullPath($namedFixture);size=[long](Get-Item -LiteralPath $namedFixture).Length;sha256=(Get-FileHash -LiteralPath $namedFixture -Algorithm SHA256).Hash.ToLowerInvariant()}
    foreach ($target in $targets) {
        $targetArgs = $target.args
        $checkerException = $null
        try { & (Join-Path $PSScriptRoot $target.script) @targetArgs } catch { $checkerException = [pscustomobject]@{type=$_.Exception.GetType().FullName;message=$_.Exception.Message} }
        $receiptPath = Join-Path $target.dir $target.receipt
        $receipt = $null
        if (Test-Path -LiteralPath $receiptPath -PathType Leaf) { $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json }
        $rowsForRustup = if ($receipt) { @($receipt.checks | Where-Object requestedName -eq 'rustup') } else { @() }
        $rustupRowResult = 'FAIL'
        if ($rowsForRustup.Count -eq 1) {
            $row = $rowsForRustup[0]
            $identityOk = $row.path -ceq $fixtureIdentity.path -and $row.resolvedPath -ceq $fixtureIdentity.path -and [long]$row.size -eq $fixtureIdentity.size -and $row.sha256 -ceq $fixtureIdentity.sha256 -and [int]$row.exitCode -eq 0 -and $row.status -eq 'PASS' -and $null -eq $row.error -and $row.observedVersion -match 'info: This is the version' -and $row.observedVersion -match 'rustc 1.99.0-nightly'
            if ($identityOk) { $rustupRowResult = 'PASS' }
        }
        $otherFailedChecks = if ($receipt) { @($receipt.checks | Where-Object { $_.requestedName -ne 'rustup' -and $_.status -ne 'PASS' } | ForEach-Object { [pscustomobject]@{name=$_.requestedName;status=$_.status;error=$_.error} }) } else { @() }
        $blockers = if ($receipt) { @($receipt.blocked) } else { @() }
        $wholeCheckerResult = if ($receipt) { [string]$receipt.status } else { 'NO_RECEIPT' }
        $control = [pscustomobject][ordered]@{schemaVersion=1;name="checker-focal-control-$($target.name)";status='FOCAL_ROW_ONLY';target=$target.name;RUSTUP_ROW_RESULT=$rustupRowResult;WHOLE_CHECKER_RESULT=$wholeCheckerResult;OTHER_FAILED_CHECKS=$otherFailedChecks;BLOCKERS=$blockers;CHECKER_EXCEPTION=$checkerException;PRODUCT_SOURCE_READINESS='NOT_PROVEN';rustupRowCount=$rowsForRustup.Count;fixture=$fixtureIdentity}
        Write-CIToolReceipt -Path (Join-Path $ReceiptDir "checker-$($target.name).json") -Receipt $control
        if ($rustupRowResult -ne 'PASS') { throw "$($target.name) rustup focal receipt row failed identity/result assertions" }
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
