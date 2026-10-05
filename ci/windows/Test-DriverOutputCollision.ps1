param([string]$Source=(Join-Path $PSScriptRoot 'Build-Driver.ps1'), [Parameter(Mandatory)][string]$Receipt, [switch]$ExpectHistoricalRed)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$tokens=$null; $parseErrors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Production script parse failed'}
$assignment=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$alreadyBuilt'},$false))
$guard=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$alreadyBuilt.Count -gt 0'},$false))
if($assignment.Count -ne 1 -or $guard.Count -ne 1){throw 'Expected unique real production collision guard'}
$text=[IO.File]::ReadAllText((Resolve-Path $Source))
$start=$assignment[0].Extent.StartOffset; $end=$guard[0].Extent.EndOffset
$span=$text.Substring($start,$end-$start)
$prefix=$text.Substring(0,$start) -replace '[^\r\n]',' '
$temp=Join-Path ([IO.Path]::GetTempPath()) ('helios-collision-'+[guid]::NewGuid())
New-Item -ItemType Directory $temp|Out-Null
$extracted=Join-Path $temp 'production-guard.ps1'
[IO.File]::WriteAllText($extracted,$prefix+$span)
$cases=@()
try {
 foreach($case in @('zero','one','multiple','unrelated','query-error')) {
  $OutputDir=Join-Path $temp $case
  New-Item -ItemType Directory $OutputDir|Out-Null
  if($case -in @('one','multiple')){[IO.File]::WriteAllText((Join-Path $OutputDir 'helios_umd.dll'),'synthetic')}
  if($case -eq 'multiple'){[IO.File]::WriteAllText((Join-Path $OutputDir 'helios_umd12.dll'),'synthetic')}
  if($case -eq 'unrelated'){[IO.File]::WriteAllText((Join-Path $OutputDir 'unrelated.dll'),'synthetic')}
  if($case -eq 'query-error'){$OutputDir='HeliosMissingProviderDrive:\synthetic'}
  $alreadyBuilt=$null; $errorRecord=$null
  try { . $extracted } catch {
   $errorRecord=[ordered]@{message=$_.Exception.Message;fullyQualifiedErrorId=$_.FullyQualifiedErrorId;positionMessage=$_.InvocationInfo.PositionMessage;scriptStackTrace=$_.ScriptStackTrace;line=$_.InvocationInfo.ScriptLineNumber;sourceLine=$_.InvocationInfo.Line}
  }
  $count=if($null -eq $alreadyBuilt){0}else{@($alreadyBuilt).Length}
  $kind=if($null -eq $alreadyBuilt){'null-empty-pipeline'}else{$alreadyBuilt.GetType().FullName}
  $outcome=if($null -eq $errorRecord){'continue'}elseif($errorRecord.message -like 'Build output already contains a candidate artifact identity:*'){'collision-refused'}elseif($errorRecord.fullyQualifiedErrorId -like 'PropertyNotFound*'){'count-error'}else{'query-error'}
  $expected=if($case -in @('one','multiple')){'collision-refused'}elseif($case -eq 'query-error'){'query-error'}elseif($ExpectHistoricalRed){'count-error'}else{'continue'}
  $cases += [ordered]@{case=$case;outcome=$outcome;expected=$expected;pass=($outcome -eq $expected);producerType=$kind;producerCardinality=$count;error=$errorRecord}
 }
 $receiptObject=[ordered]@{source=(Resolve-Path $Source).Path;sourceSha256=(Get-FileHash $Source).Hash;startLine=$assignment[0].Extent.StartLineNumber;endLine=$guard[0].Extent.EndLineNumber;productionSpan=$span;strictMode='Latest';errorActionPreference=$ErrorActionPreference;powerShellVersion=$PSVersionTable.PSVersion.ToString();processArchitecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();executable=(Get-Process -Id $PID).Path;cases=$cases;status='PASS'}
 if(@($cases|Where-Object {-not $_.pass}).Count){$receiptObject.status='FAIL'}
 $receiptObject|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $Receipt -Encoding utf8
 if($receiptObject.powerShellVersion -ne '7.6.6' -or $receiptObject.processArchitecture -ne 'X64'){throw 'Historical native PowerShell identity mismatch'}
 if($receiptObject.status -ne 'PASS'){throw 'Collision regression failed; see receipt'}
} finally {Remove-Item -LiteralPath $temp -Recurse -Force}
