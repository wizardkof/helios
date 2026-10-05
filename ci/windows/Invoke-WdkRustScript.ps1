param([ValidateSet('Install','Run')][string]$Mode,[string]$PrivateRoot,[string]$TaskName,[string]$BasePath='', [string]$ScriptPath='', [Parameter(ValueFromRemainingArguments=$true)][string[]]$RustArgs)
$ErrorActionPreference='Stop'
$hostTool=$env:HELIOS_HOST_RUST_SCRIPT
$hostHash=(Get-FileHash -LiteralPath $hostTool).Hash
$tool=Join-Path $PrivateRoot 'bin\rust-script.exe'
# This is a separate child process: private install/cache variables cannot leak
# into cargo-make or into later ordinary @rust producer tasks.
$env:CARGO_HOME=Join-Path $PrivateRoot 'cargo-home'
$env:CARGO_INSTALL_ROOT=$PrivateRoot
New-Item -ItemType Directory -Force $env:CARGO_HOME | Out-Null
if($Mode -eq 'Install') {
 $installArgs=@('install','--locked','rust-script','--version','0.30.0','--root',$PrivateRoot)
 # A copied fixture has no cargo install receipt. Overwrite only that private,
 # untracked destination; tracked real installs keep cargo's normal no-op path.
 if((Test-Path $tool) -and !(Test-Path (Join-Path $PrivateRoot '.crates.toml'))){$installArgs+='--force'}
 & $env:HELIOS_PINNED_CARGO @installArgs
 if($LASTEXITCODE -ne 0){throw "WDK installation failed: $LASTEXITCODE"}
}
$version=(& $tool --version) -join ''
if($LASTEXITCODE -ne 0 -or $version -ne 'rust-script 0.30.0'){throw 'WDK private version mismatch'}
$hash=(Get-FileHash -LiteralPath $tool).Hash
$receipt="WDK_RUST_SCRIPT_$Mode path=$tool version=$version sha256=$hash task=$TaskName cargoHome=$env:CARGO_HOME installRoot=$env:CARGO_INSTALL_ROOT"
Write-Output $receipt
if($Mode -eq 'Run'){
 Write-Output "WDK_EXECUTABLE_PATH=$tool"
 Write-Output "WDK_EXECUTABLE_VERSION=$version"
 $exitCode=0
 try { & $tool --base-path $BasePath $ScriptPath @RustArgs; $exitCode=$LASTEXITCODE }
 catch { $exitCode=94 }
 $event=[ordered]@{event='wdk-run';invocation=$env:HELIOS_PRODUCER_INVOCATION;profile=$env:HELIOS_PRODUCER_PROFILE;task=$TaskName;version=$version;executable=$tool;sha256=$hash;args=@('--base-path',$BasePath,$ScriptPath)+$RustArgs;exitCode=[int]$exitCode}
 $json=$event|ConvertTo-Json -Compress -Depth 6
 [IO.File]::AppendAllText($env:HELIOS_RUST_SCRIPT_AUDIT,$json+"`n",[Text.UTF8Encoding]::new($false))
 if($exitCode -ne 0){throw "WDK private execution failed: $exitCode"}
} else {
 $event=[ordered]@{event='wdk-install';invocation=$env:HELIOS_PRODUCER_INVOCATION;profile=$env:HELIOS_PRODUCER_PROFILE;task=$TaskName;version=$version;executable=$tool;sha256=$hash;exitCode=0}
 $json=$event|ConvertTo-Json -Compress -Depth 6
 [IO.File]::AppendAllText($env:HELIOS_RUST_SCRIPT_AUDIT,$json+"`n",[Text.UTF8Encoding]::new($false))
}
if((Get-FileHash -LiteralPath $hostTool).Hash -ne $hostHash){throw 'HOST_RUST_SCRIPT_MUTATED during private WDK operation'}
exit 0
