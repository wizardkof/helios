param([Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Initialize-HeliosBuild.ps1')
Import-Module (Join-Path $PSScriptRoot 'CIToolchainReceipts.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CIToolchainOptions.psm1') -Force
$pins = Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null
$checks = [Collections.Generic.List[object]]::new()
$blocked = [Collections.Generic.List[object]]::new()
$observer = Join-Path $PSScriptRoot 'Observe-NinjaResolution.ps1'

function Add-CIEnvironmentCheck([string]$Name, [string]$Expected, [string]$Observed, [bool]$Pass, [string]$Path = $null) {
    if ($Name -eq 'VULKAN_SDK') {
        $Expected = ([string]$Expected).Replace('\','/').TrimEnd('/')
        $Observed = ([string]$Observed).Replace('\','/').TrimEnd('/')
        $Pass = $Expected -ieq $Observed
    }
    $row = [ordered]@{
        requestedName = $Name
        phase = 'environment'
        commandType = 'Environment'
        path = $Path
        resolvedCommandType = 'Environment'
        resolvedPath = $Path
        expectedVersion = $Expected
        observedVersion = $Observed
        exitCode = 0
        size = $null
        sha256 = $null
        status = if ($Pass) { 'PASS' } else { 'FAIL' }
        error = if ($Pass) { $null } else { 'ENVIRONMENT_PIN_MISMATCH' }
        resolutionCandidates = @()
    }
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        try {
            $item = Get-Item -LiteralPath $Path -ErrorAction Stop
            $row.size = [long]$item.Length
            $row.sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        } catch { $row.status = 'FAIL'; $row.error = 'FILE_READ: ' + $_.Exception.Message }
    }
    $script:checks.Add([pscustomobject]$row)
}

try { & $observer -Phase 'immediately-before-citoolchain-vs-import' -ReceiptDir $ReceiptDir } catch { $blocked.Add([pscustomobject]@{name='ninja-observer-pre-vs';reason=$_.Exception.Message}) }
try { Import-VisualStudioEnvironment -Architecture x64 } catch { $blocked.Add([pscustomobject]@{name='visual-studio-environment-x64';reason=$_.Exception.Message}) }
try { & $observer -Phase 'immediately-after-citoolchain-vs-import' -ReceiptDir $ReceiptDir } catch { $blocked.Add([pscustomobject]@{name='ninja-observer-post-vs';reason=$_.Exception.Message}) }
try { & (Join-Path $PSScriptRoot 'Assert-WindowsKitPins.ps1') -ReceiptDir $ReceiptDir } catch { $blocked.Add([pscustomobject]@{name='windows-kit-pins';reason=$_.Exception.Message}) }

$toolChecks = @(
    @{name='python'; args=@('--version'); expected=('Python ' + $pins.pythonVersion); pattern=('^Python ' + [regex]::Escape($pins.pythonVersion) + '$')},
    @{name='meson'; args=@('--version'); expected=$pins.mesonVersion; pattern=('^' + [regex]::Escape($pins.mesonVersion) + '$')},
    @{name='cargo.exe'; args=@('make','--version'); expected=('cargo-make ' + $pins.rust.cargoMakeVersion); pattern=('(?m)^cargo-make ' + [regex]::Escape($pins.rust.cargoMakeVersion) + '$')},
    @{name='clang-cl'; args=@('--version'); expected=('clang version ' + $pins.llvmVersion); pattern=('(?m)^clang version ' + [regex]::Escape($pins.llvmVersion) + '(?:\s|$)')},
    @{name='rustc'; args=@('--version'); expected=$pins.qualifiedObservedTools.rustc; pattern=('(?m)^' + [regex]::Escape($pins.qualifiedObservedTools.rustc) + '$')},
    @{name='cargo'; args=@('--version'); expected=$pins.qualifiedObservedTools.cargo; pattern=('^' + [regex]::Escape($pins.qualifiedObservedTools.cargo) + '$')},
    @{name='rustup'; args=@('--version'); expected=('rustup ' + $pins.rust.rustupVersion); rustupVersion=$pins.rust.rustupVersion},
    @{name='git'; args=@('--version'); expected=('git version ' + $pins.gitVersion); pattern=('^git version ' + [regex]::Escape(($pins.gitVersion -replace '\.\d+$','')) + '(?:\.windows\.\d+)?$')},
    @{name='widl'; args=@('-V'); expected=$pins.qualifiedObservedTools.widlVersion; pattern=('(?m)^Wine IDL Compiler version ' + [regex]::Escape($pins.qualifiedObservedTools.widlVersion) + '(?![0-9.])')}
)
$priorityBin = @($env:HELIOS_LLVM_BIN, $(if ($env:HELIOS_NINJA) { Split-Path -Parent $env:HELIOS_NINJA }), $(if ($env:HELIOS_WIDL) { Split-Path -Parent $env:HELIOS_WIDL }), (Join-Path (Join-Path 'C:/VulkanSDK' $pins.vulkanSdkVersion) 'Bin')) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique
if ($priorityBin.Count -gt 0) { $env:PATH = (@($priorityBin) + @($env:PATH -split ';' | Where-Object { $_ -and $_ -notin $priorityBin } | Select-Object -Unique)) -join ';' }
$env:VULKAN_SDK = (Join-Path 'C:/VulkanSDK' $pins.vulkanSdkVersion).Replace('\','/')
foreach ($tool in $toolChecks) {
    $toolOptions = New-CICheckOptions -Definition $tool -BaseOptions @{Phase='post-vs-x64'}
    if ($tool.name -eq 'clang-cl' -and $env:HELIOS_LLVM_BIN) { $toolOptions.ExecutablePath = Join-Path $env:HELIOS_LLVM_BIN 'clang-cl.exe'; $toolOptions.ExpectedResolvedPath = $toolOptions.ExecutablePath }
    if ($tool.name -eq 'widl' -and $env:HELIOS_WIDL) { $toolOptions.ExecutablePath = $env:HELIOS_WIDL; $toolOptions.ExpectedResolvedPath = $env:HELIOS_WIDL }
    $checks.Add((Invoke-CIToolCheck @toolOptions))
}

$ninjaPath = [string]$env:HELIOS_NINJA
$ninjaOptions = @{Name='ninja.exe';Arguments=@('--version');ExpectedVersion=$pins.ninjaUpstream.executableVersion;VersionPattern=('^' + [regex]::Escape($pins.ninjaUpstream.executableVersion) + '$');Phase='post-vs-x64'}
if ($ninjaPath) { $ninjaOptions.ExecutablePath = $ninjaPath; $ninjaOptions.ExpectedResolvedPath = $ninjaPath }
$checks.Add((Invoke-CIToolCheck @ninjaOptions))

$pwshPath = [string]$pins.powerShell7.installPath
$pwshOptions = @{Name='pwsh.exe';Arguments=@('-NoProfile','-Command','$PSVersionTable.PSVersion.ToString()');ExpectedVersion=$pins.powerShell7.version;VersionPattern=('^' + [regex]::Escape($pins.powerShell7.version) + '$');Phase='pinned-powershell'}
$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pwsh) { $pwshOptions.ExpectedResolvedPath = $pwshPath }
$checks.Add((Invoke-CIToolCheck @pwshOptions))

$observedSdk = ([string]$env:WindowsSDKVersion).TrimEnd('\')
Add-CIEnvironmentCheck 'WindowsSDKVersion' $pins.windowsKit.family $observedSdk ($observedSdk -ceq $pins.windowsKit.family)
$observedMsvc = ([string]$env:VCToolsVersion).TrimEnd('\')
Add-CIEnvironmentCheck 'VCToolsVersion' $pins.visualStudio.msvcVersion $observedMsvc ($observedMsvc -ceq $pins.visualStudio.msvcVersion)
$llvmBin = [string]$env:HELIOS_LLVM_BIN
if ($llvmBin -and (Test-Path -LiteralPath (Join-Path $llvmBin 'clang-cl.exe') -PathType Leaf)) { $env:PATH = "$llvmBin;$env:PATH" }
$ninjaBin = if ($env:HELIOS_NINJA) { Split-Path -Parent $env:HELIOS_NINJA } else { $null }
if ($ninjaBin -and (Test-Path -LiteralPath $ninjaBin -PathType Container)) { $env:PATH = "$ninjaBin;$env:PATH" }
$vulkanBin = Join-Path (Join-Path 'C:/VulkanSDK' $pins.vulkanSdkVersion) 'Bin'
if (Test-Path -LiteralPath $vulkanBin -PathType Container) { $env:PATH = "$vulkanBin;$env:PATH"; $env:VULKAN_SDK = Split-Path -Parent $vulkanBin }
if ($env:HELIOS_WIDL -and (Test-Path -LiteralPath $env:HELIOS_WIDL -PathType Leaf)) { $env:PATH = "$(Split-Path -Parent $env:HELIOS_WIDL);$env:PATH" }
$vulkanRoot = [string]$env:VULKAN_SDK
$expectedVulkanRoot = (Join-Path 'C:/VulkanSDK' $pins.vulkanSdkVersion).Replace('\','/')
$vulkanPass = $vulkanRoot -and (Split-Path $vulkanRoot -Leaf) -ceq $pins.vulkanSdkVersion -and
    (Test-Path -LiteralPath (Join-Path $vulkanRoot 'Include/vulkan/vulkan.h') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $vulkanRoot 'Lib/vulkan-1.lib') -PathType Leaf)
Add-CIEnvironmentCheck 'VULKAN_SDK' $expectedVulkanRoot $vulkanRoot ([bool]$vulkanPass)

try {
    . (Join-Path $PSScriptRoot 'CI-Qualification.ps1')
    Write-CIRustScriptContract $ReceiptDir 'preflight'
} catch { $blocked.Add([pscustomobject]@{name='rust-script-host-private';reason=$_.Exception.Message}) }

$context = @{
    visualStudio = [string]$env:VSINSTALLDIR
    msvcVersion = [string]$env:VCToolsVersion
    windowsSdkVersion = [string]$env:WindowsSDKVersion
    vulkanSdk = $vulkanRoot
    selectedNinja = $ninjaPath
    candidateMode = 'infrastructure-only-unreserved-source'
}
$receipt = New-CIToolReceipt -Name 'native-toolchain' -Checks @($checks.ToArray()) -Blocked @($blocked.ToArray()) -Context $context
Write-CIToolReceipt -Path (Join-Path $ReceiptDir 'toolchain.json') -Receipt $receipt
Write-Host (ConvertTo-Json -InputObject $receipt -Depth 16)
Assert-CIToolReceiptPass -Receipt $receipt
