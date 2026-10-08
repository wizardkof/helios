Set-StrictMode -Version Latest

function New-CICheckOptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Definition,
        [Parameter(Mandatory)][hashtable]$BaseOptions
    )
    foreach ($required in @('name','args','expected')) {
        if (-not $Definition.ContainsKey($required) -or $null -eq $Definition[$required]) {
            throw "CHECK_DEFINITION_INVALID: required key '$required' is missing or null"
        }
    }
    $options = @{}
    foreach ($key in $BaseOptions.Keys) { $options[$key] = $BaseOptions[$key] }
    $options.Name = [string]$Definition['name']
    $options.Arguments = [string[]]@($Definition['args'])
    $options.ExpectedVersion = [string]$Definition['expected']
    if ($Definition.ContainsKey('phase')) {
        if ($null -eq $Definition['phase']) { throw "CHECK_DEFINITION_INVALID: present key 'phase' must not be null" }
        $options.Phase = [string]$Definition['phase']
    }
    if ($Definition.ContainsKey('pattern')) {
        if ($Definition['pattern'] -isnot [string] -or [string]::IsNullOrWhiteSpace($Definition['pattern'])) {
            throw "CHECK_DEFINITION_INVALID: present key 'pattern' must be a non-empty string"
        }
        $options['VersionPattern'] = $Definition['pattern']
    }
    if ($Definition.ContainsKey('rustupVersion')) {
        if ($Definition['rustupVersion'] -isnot [string] -or [string]::IsNullOrWhiteSpace($Definition['rustupVersion'])) {
            throw "CHECK_DEFINITION_INVALID: present key 'rustupVersion' must be a non-empty string"
        }
        $options['RustupVersion'] = $Definition['rustupVersion']
    }
    return $options
}

function Get-CIRustupExpectedExit {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Case)
    $hasExit = $false
    $rawExit = $null
    if ($Case -is [System.Collections.IDictionary]) {
        $hasExit = $Case.Contains('exit')
        if ($hasExit) { $rawExit = $Case['exit'] }
    } else {
        $property = $Case.PSObject.Properties['exit']
        $hasExit = $null -ne $property
        if ($hasExit) { $rawExit = $property.Value }
    }
    if (-not $hasExit) { return 0 }
    if ($null -eq $rawExit -or $rawExit -is [bool]) {
        throw 'RUSTUP_EXPECTED_EXIT_INVALID: present exit must be an integer'
    }
    $parsed = 0
    if (-not [int]::TryParse([string]$rawExit, [ref]$parsed)) {
        throw 'RUSTUP_EXPECTED_EXIT_INVALID: present exit must be an integer'
    }
    return $parsed
}

function Test-CIRustupFixtureExpectation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Case,
        [Parameter(Mandatory)][object]$ObservedExit,
        [Parameter(Mandatory)][string]$ObservedStatus,
        [AllowNull()][string]$ObservedError
    )
    if ($null -eq $ObservedExit -or $ObservedExit -is [bool]) {
        throw 'RUSTUP_OBSERVED_EXIT_INVALID: observed exit must be an integer'
    }
    $parsedObservedExit = 0
    if (-not [int]::TryParse([string]$ObservedExit, [ref]$parsedObservedExit)) {
        throw 'RUSTUP_OBSERVED_EXIT_INVALID: observed exit must be an integer'
    }
    $expectedExit = Get-CIRustupExpectedExit -Case $Case
    $statusProperty = $Case.PSObject.Properties['pass']
    $errorProperty = $Case.PSObject.Properties['expectedError']
    if ($Case -is [System.Collections.IDictionary]) {
        if (-not $Case.Contains('pass') -or -not $Case.Contains('expectedError')) {
            throw 'RUSTUP_EXPECTATION_INVALID: pass and expectedError are required'
        }
        $expectedStatus = if ($Case['pass']) { 'PASS' } else { 'FAIL' }
        $expectedError = $Case['expectedError']
    } else {
        if ($null -eq $statusProperty -or $null -eq $errorProperty) {
            throw 'RUSTUP_EXPECTATION_INVALID: pass and expectedError are required'
        }
        $expectedStatus = if ($statusProperty.Value) { 'PASS' } else { 'FAIL' }
        $expectedError = $errorProperty.Value
    }
    return ($parsedObservedExit -eq $expectedExit -and $ObservedStatus -ceq $expectedStatus -and $ObservedError -ceq $expectedError)
}

Export-ModuleMember -Function New-CICheckOptions, Get-CIRustupExpectedExit, Test-CIRustupFixtureExpectation
