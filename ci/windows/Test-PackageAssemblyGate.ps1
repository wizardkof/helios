param(
 [Parameter(Mandatory)][string]$RepoRoot,
 [Parameter(Mandatory)][string]$DriverArtifact,
 [Parameter(Mandatory)][string]$InstallerArtifact,
 [Parameter(Mandatory)][ValidateSet('Release','Debug')][string]$Configuration,
 [Parameter(Mandatory)][string]$ReceiptDir
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
& python (Join-Path $PSScriptRoot 'verify_package_control_input.py') --directory $DriverArtifact --configuration $Configuration --receipt (Join-Path $ReceiptDir 'historical-input.json')
if($LASTEXITCODE -ne 0){throw 'Historical input identity or bytes failed'}
if((Get-Content (Join-Path $InstallerArtifact 'configuration.txt') -Raw).Trim() -cne $Configuration){throw 'Installer configuration mismatch'}
$skeleton=Join-Path $InstallerArtifact 'HeliosSetup.exe'
if(-not(Test-Path -LiteralPath $skeleton -PathType Leaf)){throw 'Real installer skeleton missing'}
. (Join-Path $RepoRoot 'packaging/windows/Helios-PackageCommon.ps1')
. (Join-Path $RepoRoot 'metadata/Read-HeliosMetadata.ps1')
$metadata=Read-HeliosMetadata $RepoRoot
$Version='22.22.313.0'
$OutputDir=Join-Path $ReceiptDir 'assembly-gate'
$payload=Join-Path $OutputDir 'payload'
New-Item -ItemType Directory -Force $payload|Out-Null
# Execute contiguous production instructions: real image resources, original INF,
# exact typed date and architecture gates. Full signing/package acceptance is later.
$sourcePath=Join-Path $PSScriptRoot 'Assemble-Package.ps1'
$source=Get-Content $sourcePath -Raw
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'Production assembly parse failed'}
$copy=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-Required'},$true))
if($copy.Count -ne 1){throw 'Production Copy-Required function must be unique'}
. ([scriptblock]::Create($copy[0].Extent.Text))
$start=$source.IndexOf('$driverOut = Join-Path $payload "driver"')
$end=$source.IndexOf('foreach ($optional in @(', $start)
if($start -lt 0 -or $end -le $start){throw 'Contiguous production driver gate block missing'}
$gateText=$source.Substring($start,$end-$start)
$gateText|Set-Content (Join-Path $ReceiptDir 'executed-production-gate.ps1') -Encoding utf8
. ([scriptblock]::Create($gateText))
if($driverDateValue.ToString('yyyy-MM-dd') -cne '2026-10-06' -or $infVersion -cne $Version){throw 'Real .313 production date gate returned unexpected value'}
$sha=(& git -C $RepoRoot rev-parse HEAD) -join ''
if($LASTEXITCODE -ne 0){throw 'Control source SHA unavailable'}
[ordered]@{
 status='PASS_PRODUCTION_DRIVER_GATE_BLOCK'
 configuration=$Configuration
 scope='CONTROL_ONLY_NOT_FULL_PACKAGE_NOT_RELEASE'
 controlSourceSha=$sha
 historicalRunId='37392622277'
 historicalSourceSha='8be68221360e2ae59f92b8598da9ed3d5eb0ccb9'
 productionAssemblySha256=(Get-FileHash $sourcePath).Hash.ToLowerInvariant()
 gateTextSha256=(Get-FileHash (Join-Path $ReceiptDir 'executed-production-gate.ps1')).Hash.ToLowerInvariant()
 installerSkeletonSha256=(Get-FileHash $skeleton).Hash.ToLowerInvariant()
 installerProfile=if($Configuration -eq 'Release'){'cargo build --release'}else{'cargo build'}
 driverDate=$driverDate;driverDateValue=$driverDateValue.ToString('yyyy-MM-dd');driverVersion=$infVersion
} | ConvertTo-Json -Depth 8|Set-Content (Join-Path $ReceiptDir 'assembly-preflight.json') -Encoding utf8
Write-Host "PACKAGE_${Configuration}_PREFLIGHT=PASS_PRODUCTION_DRIVER_GATE_BLOCK"
