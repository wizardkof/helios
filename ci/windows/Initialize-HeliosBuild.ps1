Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-WindowsKitVersion([Parameter(Mandatory)][string]$Value) {
    $version = [version]"0.0"
    if ([version]::TryParse($Value, [ref]$version)) { return $version }
    return [version]"0.0"
}

function Import-VisualStudioEnvironment(
    [ValidateSet("x64", "x86")][string]$Architecture = "x64"
) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw "vswhere.exe was not found; Visual Studio 2022 with C++ tools is required."
    }

    $installation = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
    if (-not $installation) {
        throw "Visual Studio 2022 with the x86/x64 C++ toolchain was not found."
    }

    $devCmd = Join-Path $installation "Common7\Tools\VsDevCmd.bat"
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $env:SystemRoot "System32\cmd.exe"
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $clean = ""
    if ($env:__VSCMD_PREINIT_PATH) {
        # Repeated imports otherwise accumulate VS paths until cmd's 8191-byte
        # line limit is reached. Reset in the child before even -clean_env runs;
        # its batch files also expand PATH. VS owns the rest of its cleanup.
        $baseline = $env:__VSCMD_PREINIT_PATH
        $additions = @()
        if ($env:HELIOS_VS_IMPORTED_PATH) {
            # Preserve paths added by our caller after the previous import
            # (LLVM/WDK/MSYS2, for example). This marker travels to Cargo's
            # child PowerShell process, unlike a script-scoped cache.
            $imported = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $env:HELIOS_VS_IMPORTED_PATH.Split(';')) { [void]$imported.Add($entry) }
            $additions = @($env:PATH.Split(';') | Where-Object { $_ -and -not $imported.Contains($_) } | Select-Object -Unique)
        } else {
            # A caller may enter from a Developer shell we did not initialize.
            # Preserve its extra tools while discarding VS-owned paths (which
            # include the old architecture's compiler). The explicit LLVM
            # selection may itself live inside the VS installation.
            $vsRoots = @($env:VSINSTALLDIR, $installation) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') + '\' }
            $additions = @($env:PATH.Split(';') | Where-Object {
                $entry = $_
                $entry -and -not @($vsRoots | Where-Object { $entry.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count
            })
            if ($env:LIBCLANG_PATH) { $additions = @($env:LIBCLANG_PATH) + $additions }
        }
        if ($additions.Count -gt 0) {
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $baseline = (@($additions + $baseline.Split(';') | Where-Object { $_ -and $seen.Add($_) }) -join ';')
        }
        $start.Environment["PATH"] = $baseline
        $start.Environment["__VSCMD_PREINIT_PATH"] = $baseline
        foreach ($name in @("INCLUDE", "LIB", "LIBPATH", "EXTERNAL_INCLUDE")) {
            $previous = [Environment]::GetEnvironmentVariable("__VSCMD_PREINIT_$name")
            if ($previous) { $start.Environment[$name] = $previous }
            else { [void]$start.Environment.Remove($name) }
        }
        $clean = "call `"$devCmd`" -no_logo -clean_env && "
    }
    $toolset = ""
    if ($env:HELIOS_MSVC_VERSION) {
        if ($env:HELIOS_MSVC_VERSION -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid MSVC pin." }
        $toolset = " -vcvars_ver=$($env:HELIOS_MSVC_VERSION)"
    }
    if ($env:HELIOS_WINDOWS_KIT_VERSION) {
        if ($env:HELIOS_WINDOWS_KIT_VERSION -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw "Invalid Windows kit pin." }
        $toolset += " -winsdk=$($env:HELIOS_WINDOWS_KIT_VERSION)"
    }
    $start.Arguments = "/d /s /c `"${clean}call `"$devCmd`" -no_logo -arch=$Architecture -host_arch=x64$toolset && set`""
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "Could not start VsDevCmd.bat." }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "VsDevCmd.bat failed with exit code $($process.ExitCode): $($stderr.Result)"
        }
        $environment = @{}
        foreach ($line in ($stdout.Result -split "`r?`n")) {
            $parts = $line -split "=", 2
            if ($parts.Count -eq 2 -and $parts[0]) { $environment[$parts[0]] = $parts[1] }
        }
    } finally {
        $process.Dispose()
    }
    # Mirror removals too: assigning only returned variables would retain stale
    # architecture-specific state that -clean_env removed in the child.
    foreach ($entry in @(Get-ChildItem Env:)) {
        if (-not $environment.ContainsKey($entry.Name)) { Remove-Item -LiteralPath "Env:$($entry.Name)" }
    }
    foreach ($name in $environment.Keys) {
        Set-Item -LiteralPath "Env:$name" -Value $environment[$name]
    }
    # Keep CI consumers on the exact release-identified Ninja even when
    # VsDevCmd inserts a Visual Studio copy ahead of existing PATH entries.
    # Preserve every other PATH entry and make repeated architecture imports
    # idempotent.
    if ($env:HELIOS_NINJA -and (Test-Path -LiteralPath $env:HELIOS_NINJA -PathType Leaf)) {
        $ninjaDirectory = (Split-Path -Parent ([IO.Path]::GetFullPath($env:HELIOS_NINJA))).TrimEnd('\')
        $remainingPath = @($env:PATH -split ';' | Where-Object {
            $_ -and -not [string]::Equals($_.TrimEnd('\'), $ninjaDirectory, [StringComparison]::OrdinalIgnoreCase)
        })
        $env:PATH = (@($ninjaDirectory) + $remainingPath) -join ';'
    }
    $env:HELIOS_VS_IMPORTED_PATH = $env:PATH
}

function Find-WindowsKitTool([Parameter(Mandatory)][string]$Name) {
    $kitsBin = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (-not (Test-Path -LiteralPath $kitsBin -PathType Container)) {
        throw "Windows Kits bin directory was not found at $kitsBin."
    }
    $pins=Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw|ConvertFrom-Json
    $selected=@($pins.windowsKit.selectedFiles|Where-Object {(Split-Path $_.path -Leaf) -ieq $Name})
    $preferred=@($selected|Where-Object {$_.path -match '/x64/'})
    if($preferred.Count -eq 1){$selected=$preferred}
    if($selected.Count -ne 1){throw "No unique pinned path for tool $Name"}
    $path=Join-Path (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10') $selected[0].path
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Pinned tool missing: $path"}
    return $path
}

function Find-WindowsKitInclude {
    $includeRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Include"
    $pins=Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw|ConvertFrom-Json
    $path=Join-Path $includeRoot $pins.windowsKit.family
    if(-not (Test-Path -LiteralPath (Join-Path $path 'km/ntddk.h') -PathType Leaf)){throw "Pinned WDK include missing: $path"}
    return $path
}

function Assert-Command([Parameter(Mandatory)][string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) { throw "Required command is missing from PATH: $Name" }
    return $command.Source
}
