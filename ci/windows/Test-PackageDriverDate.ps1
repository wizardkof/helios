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
