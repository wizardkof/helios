param([Parameter(Mandatory)][string]$ReceiptDir)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $ReceiptDir | Out-Null
if($PSVersionTable.PSVersion.ToString() -ne '7.6.6' -or $PSVersionTable.PSEdition -ne 'Core' -or -not [Environment]::Is64BitProcess){throw 'Native Package PowerShell identity mismatch'}
$fixture=Join-Path $PSScriptRoot 'fixtures/package-313/helios_kmd_render.inf'
$provenance=Get-Content (Join-Path $PSScriptRoot 'fixtures/package-313/provenance.json') -Raw | ConvertFrom-Json
if((Get-FileHash $fixture -Algorithm SHA256).Hash.ToLowerInvariant() -ne $provenance.inf.sha256){throw 'Historical INF SHA256 mismatch'}
$infText=Get-Content -LiteralPath $fixture -Raw
if($infText -notmatch '(?im)^\s*DriverVer\s*=\s*([^,\r\n]+),\s*([^\r\n]+)\s*$'){throw 'Historical INF regex refusal'}
$realDate=$Matches[1].Trim();$realVersion=$Matches[2].Trim()
if($realDate -cne '10/06/2026' -or $realVersion -cne '22.22.313.0'){throw 'Unexpected real INF date/version'}
$cases=@()
foreach($date in @('10/06/2026',$realDate)){
 foreach($typed in @($false,$true)){
  $driverDate=$date
  if($typed){[string[]]$formats=@('M/d/yyyy','MM/dd/yyyy')}else{Remove-Variable formats -ErrorAction SilentlyContinue;$formats=@('M/d/yyyy','MM/dd/yyyy')}
  $row=[ordered]@{date=$date;typed=$typed;formatArrayRuntimeType=$formats.GetType().FullName;elementTypes=@($formats|ForEach-Object{$_.GetType().FullName});result='NOT_RUN'}
  $trace=Join-Path $ReceiptDir ('method-'+$cases.Count+'.txt')
  try {
   # Historical expression is kept verbatim; only the typed arm changes its array argument.
   if($typed){$value=Trace-Command -Name MethodInvocation -FilePath $trace -Expression {[DateTime]::ParseExact($driverDate,$formats,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None)}}
   else{$value=Trace-Command -Name MethodInvocation -FilePath $trace -Expression {[DateTime]::ParseExact($driverDate,@('M/d/yyyy','MM/dd/yyyy'),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None)}}
   $row.result='PASS';$row.value=$value.ToString('yyyy-MM-dd')
  }catch{
   $row.result='FAIL';$row.exceptionType=$_.Exception.GetType().FullName;$row.message=$_.Exception.Message;$row.fullyQualifiedErrorId=$_.FullyQualifiedErrorId;$row.scriptStackTrace=$_.ScriptStackTrace
   $row.innerExceptionType=if($_.Exception.InnerException){$_.Exception.InnerException.GetType().FullName}else{$null}
   $row.innerMessage=if($_.Exception.InnerException){$_.Exception.InnerException.Message}else{$null}
  }
  $cases+=$row
 }
}
$receipt=[ordered]@{powerShell=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;x64=[Environment]::Is64BitProcess;culture=[Globalization.CultureInfo]::InvariantCulture.Name;styles='None';realInfSha256=$provenance.inf.sha256;realDate=$realDate;realDateLength=$realDate.Length;codePoints=@($realDate.ToCharArray()|ForEach-Object{[int]$_});realVersion=$realVersion;cases=$cases}
$receipt|ConvertTo-Json -Depth 12|Set-Content (Join-Path $ReceiptDir 'driver-date-diagnostic.json') -Encoding utf8
if($cases[0].result -ne 'FAIL' -or $cases[1].result -ne 'PASS' -or $cases[2].result -ne 'FAIL' -or $cases[3].result -ne 'PASS'){throw 'Date array hypothesis NOT_PROVEN; production patch prohibited'}
Write-Host 'PACKAGE_DRIVER_DATE_RED_GREEN=PASS'

# Execute the production regex/version/typed-date gate, not a parallel parser.
$assembly=Get-Content (Join-Path $PSScriptRoot 'Assemble-Package.ps1') -Raw
$start=$assembly.IndexOf('$infText = Get-Content')
$end=$assembly.IndexOf('foreach ($name in @("helios_kmd_render.sys", "helios_umd.dll", "helios_umd12.dll"))', $start)
if($start -lt 0 -or $end -lt $start){throw 'Production driver-date block not found'}
$gate=[scriptblock]::Create($assembly.Substring($start,$end-$start))
$negativeCases=@(
 @{date='10/06/2026';version='22.22.313.0';accept=$true},
 @{date='1/6/2026';version='22.22.313.0';accept=$true},
 @{date='01/06/2026';version='22.22.313.0';accept=$true},
 @{date='13/06/2026';version='22.22.313.0';accept=$false},
 @{date='10/32/2026';version='22.22.313.0';accept=$false},
 @{date='2026-10-06';version='22.22.313.0';accept=$false},
 @{date='';version='22.22.313.0';accept=$false},
 @{date='10/06/2026';version='22.22.314.0';accept=$false}
)
$matrix=@();$Version='22.22.313.0'
foreach($case in $negativeCases){
 $caseDir=Join-Path $ReceiptDir ('negative-'+$matrix.Count)
 New-Item -ItemType Directory -Force $caseDir|Out-Null
 $driverOut=$caseDir;$OutputDir=$caseDir
 "DriverVer=$($case.date),$($case.version)"|Set-Content (Join-Path $driverOut 'helios_kmd_render.inf')
 $accepted=$false;$errorText=$null
 try{& $gate;$accepted=$true}catch{$errorText=$_.Exception.Message}
 $matrix+=@{date=$case.date;version=$case.version;accepted=$accepted;expected=$case.accept;error=$errorText}
 if($accepted -ne $case.accept){throw 'Strict production DriverVer matrix failed'}
 if($case.date -in @('13/06/2026','10/32/2026','2026-10-06')){
  $diagnostic=Get-Content (Join-Path $caseDir 'driver-date-diagnostic.json') -Raw|ConvertFrom-Json
  if($diagnostic.formatArrayRuntimeType -ne 'System.String[]' -or -not $diagnostic.innerMessage -or -not $diagnostic.exceptionType){throw 'Production invalid-date cause lost'}
 }
}
$matrix|ConvertTo-Json -Depth 8|Set-Content (Join-Path $ReceiptDir 'driver-date-negative-matrix.json') -Encoding utf8
Write-Host 'PACKAGE_DRIVER_DATE_STRICT_MATRIX=PASS_8_OF_8'
