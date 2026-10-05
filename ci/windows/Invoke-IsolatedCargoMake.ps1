param([string]$KmdRoot,[string]$Profile,[string]$Task="default",[Parameter(Mandatory)][string]$AuditFile,[switch]$ControlOriginalRustRunner)
$ErrorActionPreference='Stop'
$cargo=$env:HELIOS_PINNED_CARGO
$hostTool=$env:HELIOS_HOST_RUST_SCRIPT
$private=$env:HELIOS_WDK_PRIVATE_ROOT
$expected='E7362E736CB2954856E15F662CCE6E300C744CEA2B91B8C0E4C05B8D81DE05BD'
$run=Join-Path $env:HELIOS_ISOLATION_ROOT ('make-'+$Profile+'-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
$invocation=[guid]::NewGuid().ToString('N')
$names=@('PATH','CARGO_INSTALL_ROOT','HELIOS_HOST_RUST_SCRIPT','HELIOS_PINNED_CARGO','HELIOS_RUST_SCRIPT_AUDIT','HELIOS_PRODUCER_PROFILE','HELIOS_PRODUCER_INVOCATION')
$previous=@{};foreach($name in $names){$previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
$hostBefore=(Get-FileHash $hostTool).Hash
$make=Join-Path $env:HELIOS_ISOLATION_ROOT 'host-dispatch\cargo.exe'
if((Get-FileHash $make).Hash -ne (Get-FileHash $env:HELIOS_ORIGINAL_CARGO).Hash){throw 'External cargo executable differs from qualified pin'}
 Write-Output "CARGO_EXECUTABLE=$make SHA256=$((Get-FileHash $make).Hash)"
try {
 $env:HELIOS_HOST_RUST_SCRIPT=$hostTool;$env:HELIOS_PINNED_CARGO=$cargo
 if(Test-Path $AuditFile){throw 'Fresh per-invocation producer audit required'}
 $env:HELIOS_RUST_SCRIPT_AUDIT=$AuditFile
 $env:HELIOS_PRODUCER_PROFILE=$Profile;$env:HELIOS_PRODUCER_INVOCATION=$invocation
 $header=[ordered]@{event='invocation';invocation=$invocation;profile=$Profile;task=$Task;run=$run}|ConvertTo-Json -Compress
 [IO.File]::WriteAllText($AuditFile,$header+"`n",[Text.UTF8Encoding]::new($false))
 $env:PATH="$(Join-Path $env:HELIOS_ISOLATION_ROOT 'host-dispatch');$env:PATH"
 Remove-Item Env:CARGO_INSTALL_ROOT -ErrorAction SilentlyContinue
 $top=Get-Content (Join-Path $KmdRoot 'Cargo.make.toml') -Raw
 $load=[regex]::Match($top,"(?s)load_script\s*=\s*'''(.*?)'''")
 if(!$load.Success){throw 'Candidate load script missing'}
 $generator="[config]`n"+$load.Value+"`n[tasks.generate]`ncommand = `"cmd.exe`"`nargs = [`"/c`", `"exit`", `"0`"]`n"
 $genPath=Join-Path $run 'Generate.toml';[IO.File]::WriteAllText($genPath,$generator)
 & $make make --makefile $genPath generate
 if($LASTEXITCODE -ne 0){throw 'Effective recipe generation failed'}
 $generated=Join-Path $KmdRoot 'target\rust-driver-makefile.toml'
 $link=Get-Item $generated
 $targets=@($link.Target)
 if($targets.Count -ne 1 -or !$targets[0]){throw 'Expected one generated WDK symlink target'}
 $origin=[IO.Path]::GetFullPath($targets[0])
 $wdk=(Split-Path -Parent $origin).Replace('\','/')
 if((Get-FileHash $generated).Hash -ne $expected){throw 'Effective WDK recipe identity changed'}
 $raw=Get-Content $generated -Raw
 $raw=$raw.Replace('${taskjson.env.CARGO_MAKE_CURRENT_TASK_INITIAL_MAKEFILE_DIRECTORY}',$wdk).Replace('${CARGO_MAKE_CURRENT_TASK_INITIAL_MAKEFILE_DIRECTORY}',$wdk)
 $adapted=Join-Path $run 'Wdk.toml'
 $rawPath=Join-Path $run 'Wdk-upstream.toml';[IO.File]::WriteAllText($rawPath,$raw)
 & python (Join-Path $PSScriptRoot 'adapt_wdk_recipe.py') --input $rawPath --output $adapted --helper ((Join-Path $env:HELIOS_ISOLATION_ROOT 'Invoke-WdkRustScript.ps1').Replace('\','/')) --private-root $private.Replace('\','/')
 if($LASTEXITCODE -ne 0){throw 'WDK recipe isolation rejected'}
 # Adaptation changes the plugin calls only; every candidate task is retained.
 $top=[regex]::Replace($top,'(?m)^extend\s*=\s*[^\r\n]+','extend = "'+$adapted.Replace('\','/')+'"')
 $top=[regex]::Replace($top,'(?m)^env_files\s*=\s*[^\r\n]+','env_files = ["'+(Join-Path $KmdRoot 'driver-version.env').Replace('\','/')+'"]')
 $top=$top.Replace($load.Value,'# Original load_script executed by Generate.toml above.')
 $top += @'

[tasks.isolation-host-probe]
script_runner = "@rust"
script = """
println!("HOST_FOCAL_TASK_EXECUTED=YES");
println!("HOST_TASK_PATH={}", std::env::var("PATH").unwrap_or_default());
use std::process::Command;
let query = format!("$child=Get-CimInstance Win32_Process -Filter 'ProcessId={}' ; $parent=Get-CimInstance Win32_Process -Filter ('ProcessId='+$child.ParentProcessId) ; $parent.ExecutablePath", std::process::id());
let selected = Command::new("powershell.exe").arg("-NoProfile").arg("-Command").arg(query).output().expect("query selected script runner");
assert!(selected.status.success(), "selected script runner process query failed");
println!("HOST_SELECTED_EXECUTABLE={}", String::from_utf8_lossy(&selected.stdout).trim());
"""

[tasks.producer-audit-diagnostic]
dependencies = ["setup-wdk-config-env-vars", "isolation-host-probe"]

[tasks.producer-audit-diagnostic-fail]
dependencies = ["setup-wdk-config-env-vars", "isolation-host-probe-fail"]

[tasks.isolation-host-probe-fail]
script_runner = "@rust"
script = """
std::process::exit(17);
"""
'@
if(-not $ControlOriginalRustRunner){
 $dispatch=(Join-Path $env:HELIOS_ISOLATION_ROOT 'host-dispatch\rust-script.exe').Replace('\','/')
 $top=[regex]::Replace($top,'(?m)^script_runner\s*=\s*"@rust"\s*$','script_runner = "'+$dispatch+'"'+"`nscript_extension = `"rs`"")
}
 $local=Join-Path $run 'Driver.toml';[IO.File]::WriteAllText($local,$top)
 Write-Output "EFFECTIVE_WDK_RECIPE_SOURCE=$origin SHA256=$expected"
 Write-Output "CANDIDATE_MAKEFILE_SHA256=$((Get-FileHash (Join-Path $KmdRoot 'Cargo.make.toml')).Hash)"
 Write-Output "EXTERNAL_DRIVER_MAKEFILE=$local SHA256=$((Get-FileHash $local).Hash)"
 Write-Output "PRODUCER_EXECUTION_AUDIT=$env:HELIOS_RUST_SCRIPT_AUDIT"
 & $make make --profile $Profile --makefile $local $Task
 if($LASTEXITCODE -ne 0){throw "Isolated cargo-make failed: $LASTEXITCODE"}
 if((Get-FileHash $hostTool).Hash -ne $hostBefore){throw 'HOST_RUST_SCRIPT_MUTATED during producer execution'}
 Write-Output 'PRODUCER_HOST_HASH_PRESERVED=PASS'
 $global:LASTEXITCODE=0
} finally {
 foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$previous[$name],'Process')}
}
