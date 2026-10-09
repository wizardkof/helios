param([Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CIRustupCheckerTargets.psm1') -Force
New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null
$temp = Join-Path ([IO.Path]::GetTempPath()) ('rustup-binding-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$results = [Collections.Generic.List[object]]::new()
try {
    $targets = @(Get-CIRustupCheckerTargets -ReceiptDir $ReceiptDir)
    if ($targets.Count -ne 4 -or (($targets.name | Sort-Object) -join ',') -cne 'driver,native,package-post,package-pre') { throw 'Expected four checker targets' }
    foreach ($target in $targets) {
        # Only parse production signatures. Never execute the canonical toolchains.
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $target.script), [ref]$tokens, [ref]$errors)
        if ($errors.Count -or $null -eq $ast.ParamBlock) { throw "Invalid canonical signature: $($target.script)" }
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $expectedNames = if ($target.name -eq 'native') { @('ReceiptDir') } else { @('Component','ReceiptDir','Phase') }
        if ((($names | Sort-Object) -join ',') -cne (($expectedNames | Sort-Object) -join ',')) { throw "Canonical signature changed: $($target.script)" }
        $expected = @{ReceiptDir=(Join-Path $ReceiptDir "checker-$($target.name)")}
        if ($target.name -eq 'driver') { $expected.Component = 'driver' }
        if ($target.name -like 'package-*') { $expected.Component = 'package'; $expected.Phase = $target.name.Substring(8) }
        if ($target.parameters.Count -ne $expected.Count) { throw "Unexpected parameter count: $($target.name)" }
        foreach ($key in $expected.Keys) {
            if ($key -notin $names -or -not $target.parameters.ContainsKey($key) -or $target.parameters[$key] -cne $expected[$key]) { throw "Incorrect named parameter ${key}: $($target.name)" }
        }
        $stub = Join-Path $temp "$($target.name).ps1"
        # Reuse the exact canonical param block, including Mandatory/ValidateSet.
        $body = $ast.ParamBlock.Extent.Text + @'

Set-StrictMode -Version Latest
[pscustomobject]@{ReceiptDir=$ReceiptDir;Component=$(if (Test-Path variable:Component) {$Component} else {$null});Phase=$(if (Test-Path variable:Phase) {$Phase} else {$null})}
'@
        Set-Content -LiteralPath $stub -Value $body
        $parameters = $target.parameters
        $observed = & $stub @parameters
        foreach ($key in $expected.Keys) {
            if ($observed.$key -cne $expected[$key]) { throw "Binder changed ${key}: $($target.name)" }
        }
        $expectedPhase = if ($target.name -eq 'native') { $null } elseif ($expected.ContainsKey('Phase')) { $expected.Phase } else { 'pre' }
        $expectedComponent = if ($expected.ContainsKey('Component')) { $expected.Component } else { $null }
        if ($observed.Phase -cne $expectedPhase -or $observed.Component -cne $expectedComponent) { throw "Incorrect default/component binding: $($target.name)" }
        # Historical array splatting passes named-looking strings positionally.
        $legacy = @('-ReceiptDir', $expected.ReceiptDir)
        if ($expected.ContainsKey('Component')) { $legacy += @('-Component', $expected.Component) }
        if ($expected.ContainsKey('Phase')) { $legacy += @('-Phase', $expected.Phase) }
        $legacyRejected = $false
        try { $null = & $stub @legacy } catch [System.Management.Automation.ParameterBindingException] { $legacyRejected = $true }
        if (-not $legacyRejected) { throw "Legacy array control accepted: $($target.name)" }
        # NonInteractive child refuses Mandatory omissions without prompting.
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = (Get-Process -Id $PID).Path
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile','-NonInteractive','-File',$stub)) { $start.ArgumentList.Add($argument) }
        $child = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $child.StandardOutput.ReadToEndAsync()
            $stderr = $child.StandardError.ReadToEndAsync()
            if (-not $child.WaitForExit(30000)) { $child.Kill(); throw 'Mandatory binding control timed out' }
            $missingOutput = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
            $missingExit = $child.ExitCode
        } finally { $child.Dispose() }
        $missingRejected = $missingExit -ne 0 -and $missingOutput -match 'mandatory|Mandatory|NonInteractive'
        if (-not $missingRejected) { throw "Missing mandatory parameters accepted: $($target.name)" }
        $unknown = $parameters.Clone(); $unknown.UnknownBindingControl = 'refuse'
        $unknownRejected = $false
        try { $null = & $stub @unknown } catch [System.Management.Automation.ParameterBindingException] { $unknownRejected = $true }
        if (-not $unknownRejected) { throw "Unknown parameter accepted: $($target.name)" }
        $results.Add([pscustomobject]@{target=$target.name;status='PASS';parameters=$parameters;observed=$observed;canonicalParameters=$names;legacyArrayRejected=$legacyRejected;missingMandatoryRejected=$missingRejected;unknownParameterRejected=$unknownRejected;missingMandatoryExit=$missingExit;missingMandatoryOutput=$missingOutput})
    }
    [pscustomobject]@{status='PASS';strictMode='Latest';powershellVersion=$PSVersionTable.PSVersion.ToString();targets=@($results)} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ReceiptDir 'checker-binding.json')
    Write-Host 'RUSTUP_CHECKER_BINDING=PASS_FOUR_TARGETS'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
