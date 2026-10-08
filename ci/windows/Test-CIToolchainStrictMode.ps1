param([Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CIToolchainOptions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CIToolchainReceipts.psm1') -Force
New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null
$checks = [Collections.Generic.List[object]]::new()
function Assert-Preflight([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "STRICTMODE_PREFLIGHT_FAILED: $Message" } }

$common = @{name='python';args=@('--version');expected='Python 3.12.10';pattern='^Python 3\.12\.10$'}
$commonOptions = New-CICheckOptions -Definition $common -BaseOptions @{Phase='native-preflight';ExpectedResolvedPath='C:/tools/python.exe'}
Assert-Preflight ($commonOptions.Name -eq 'python' -and $commonOptions.Arguments.Count -eq 1 -and $commonOptions.Arguments[0] -eq '--version' -and $commonOptions.ExpectedVersion -eq 'Python 3.12.10' -and $commonOptions.Phase -eq 'native-preflight' -and $commonOptions.ExpectedResolvedPath -eq 'C:/tools/python.exe' -and $commonOptions.VersionPattern -eq $common.pattern -and -not $commonOptions.ContainsKey('RustupVersion')) 'common tool options'
$rustup = @{name='rustup';args=@('--version');expected='rustup 1.29.1';rustupVersion='1.29.1'}
$rustupOptions = New-CICheckOptions -Definition $rustup -BaseOptions @{Phase='component-preflight'}
Assert-Preflight ($rustupOptions.Name -eq 'rustup' -and $rustupOptions.Arguments[0] -eq '--version' -and $rustupOptions.ExpectedVersion -eq 'rustup 1.29.1' -and $rustupOptions.Phase -eq 'component-preflight' -and $rustupOptions.RustupVersion -eq '1.29.1' -and -not $rustupOptions.ContainsKey('VersionPattern')) 'rustup tool options'
foreach ($bad in @(@{name='bad-pattern';args=@();expected='x';pattern=''},@{name='bad-rustup';args=@();expected='x';rustupVersion=$null})) {
    $rejected = $false
    try { $null = New-CICheckOptions -Definition $bad -BaseOptions @{} } catch { $rejected = $_.Exception.Message -like 'CHECK_DEFINITION_INVALID:*' }
    Assert-Preflight $rejected 'invalid present tool option must fail closed'
}

$exitExpectations = @(
    [pscustomobject]@{case=[pscustomobject]@{};expected=0},
    [pscustomobject]@{case=[pscustomobject]@{exit=0};expected=0},
    [pscustomobject]@{case=[pscustomobject]@{exit=23};expected=23}
)
foreach ($entry in $exitExpectations) { Assert-Preflight ((Get-CIRustupExpectedExit -Case $entry.case) -eq $entry.expected) "expected exit $($entry.expected)" }
foreach ($case in @([pscustomobject]@{exit=$null},[pscustomobject]@{exit='invalid'})) {
    $rejected = $false
    try { $null = Get-CIRustupExpectedExit -Case $case } catch { $rejected = $_.Exception.Message -like 'RUSTUP_EXPECTED_EXIT_INVALID:*' }
    Assert-Preflight $rejected 'present null/invalid expected exit must fail closed'
}
$zeroCase = @{mode='expected-zero';pass=$true;expectedError=$null}
Assert-Preflight (-not (Test-CIRustupFixtureExpectation -Case $zeroCase -ObservedExit 23 -ObservedStatus 'PASS' -ObservedError $null)) 'expected zero versus observed 23 must fail'
$mismatchCase = @{mode='version-mismatch';pass=$false;expectedError='VERSION_MISMATCH'}
Assert-Preflight (-not (Test-CIRustupFixtureExpectation -Case $mismatchCase -ObservedExit 23 -ObservedStatus 'FAIL' -ObservedError 'EXECUTION_EXIT_NONZERO')) 'execution failure must not satisfy version mismatch'

$identityCases = @(
    [pscustomobject]@{output='unrelated output';count=0;valid=$false;error='VERSION_MISMATCH'},
    [pscustomobject]@{output='rustup 1.29.1';count=1;valid=$true;error=$null},
    [pscustomobject]@{output="rustup 1.29.1`nrustup 1.29.1";count=2;valid=$false;error='AMBIGUOUS_RUSTUP_IDENTITY'}
)
foreach ($entry in $identityCases) {
    $identity = Test-CIRustupIdentity -Output $entry.output -Version '1.29.1'
    Assert-Preflight ($identity.IdentityCount -eq $entry.count -and $identity.IsValid -eq $entry.valid -and $identity.Error -ceq $entry.error) "identity result expected count=$($entry.count), valid=$($entry.valid), error=$($entry.error)"
}

# Preserve executable reproductions of the two R1 StrictMode failures. These calls
# intentionally use the unsafe property expressions from R1 and must be rejected.
$unsafeRustupRead = $false
$unsafeExitRead = $false
Set-StrictMode -Version Latest
try { $tool = @{name='python'}; $null = $tool.rustupVersion } catch { $unsafeRustupRead = $_.Exception.Message -match 'rustupVersion' }
try { $case = [pscustomobject]@{mode='valid'}; $null = $case.exit } catch { $unsafeExitRead = $_.Exception.Message -match 'exit' }
Assert-Preflight ($unsafeRustupRead -and $unsafeExitRead) 'preflight must reproduce and detect both R1 unsafe optional reads'

$files = @('CIToolchainOptions.psm1','Assert-CIToolchain.ps1','Assert-ComponentToolchain.ps1','Test-RustupIdentity.ps1','Test-CIToolchainStrictMode.ps1')
foreach ($file in $files) {
    $path = Join-Path $PSScriptRoot $file
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors) | Out-Null
    Assert-Preflight ($parseErrors.Count -eq 0) "PowerShell parser rejected ${file}: $($parseErrors -join '; ')"
}

$receipt = New-CIToolReceipt -Name 'rustup-strictmode-preflight' -Checks @([pscustomobject]@{requestedName='real-check-option-builder';phase='pre-provision';status='PASS';error=$null;exitCode=0},[pscustomobject]@{requestedName='exit-and-identity-contracts';phase='pre-provision';status='PASS';error=$null;exitCode=0},[pscustomobject]@{requestedName='r1-unsafe-read-reproductions';phase='pre-provision';status='PASS';error=$null;exitCode=0},[pscustomobject]@{requestedName='powershell-parser';phase='pre-provision';status='PASS';error=$null;exitCode=0}) -Context @{powershellVersion=$PSVersionTable.PSVersion.ToString();strictMode='Latest';testedFiles=$files;unsafeReadReproductions=@('tool.rustupVersion','case.exit')}
Write-CIToolReceipt -Path (Join-Path $ReceiptDir 'strictmode-preflight.json') -Receipt $receipt
Assert-CIToolReceiptPass -Receipt $receipt
Write-Host 'RUSTUP_STRICTMODE_PREFLIGHT=PASS'
