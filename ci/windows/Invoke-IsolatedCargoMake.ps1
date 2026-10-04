param([string]$KmdRoot,[string]$Profile,[string]$Task="default",[Parameter(Mandatory)][string]$AuditFile)
$ErrorActionPreference='Stop'
$cargo=$env:HELIOS_PINNED_CARGO
$hostTool=$env:HELIOS_HOST_RUST_SCRIPT
$private=$env:HELIOS_WDK_PRIVATE_ROOT
$expected='E7362E736CB2954856E15F662CCE6E300C744CEA2B91B8C0E4C05B8D81DE05BD'
$run=Join-Path $env:HELIOS_ISOLATION_ROOT ('make-'+$Profile+'-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
$names=@('PATH','CARGO_INSTALL_ROOT','HELIOS_HOST_RUST_SCRIPT','HELIOS_PINNED_CARGO','HELIOS_RUST_SCRIPT_AUDIT')
$previous=@{};foreach($name in $names){$previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
$hostBefore=(Get-FileHash $hostTool).Hash
$make=Join-Path $env:HELIOS_ISOLATION_ROOT 'host-dispatch\cargo.exe'
if((Get-FileHash $make).Hash -ne (Get-FileHash $env:HELIOS_ORIGINAL_CARGO).Hash){throw 'External cargo executable differs from qualified pin'}
 Write-Output "CARGO_EXECUTABLE=$make SHA256=$((Get-FileHash $make).Hash)"
try {
 $env:HELIOS_HOST_RUST_SCRIPT=$hostTool;$env:HELIOS_PINNED_CARGO=$cargo
 if(Test-Path $AuditFile){throw 'Fresh per-invocation producer audit required'}
 $env:HELIOS_RUST_SCRIPT_AUDIT=$AuditFile
 "PRODUCER_PROFILE=$Profile TASK=$Task RUN=$run"|Set-Content $AuditFile -Encoding UTF8
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
"""
'@
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
