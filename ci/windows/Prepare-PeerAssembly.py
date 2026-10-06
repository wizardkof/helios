"""Add reversible observations around successful normal signing and Inf2Cat."""
import sys,json,hashlib
from pathlib import Path
p=Path(sys.argv[1]);s=p.read_text();original=s
anchors={
'    & $inf2Cat "/driver:$driverOut" "/os:10_X64" /uselocaltime': '''    @(Get-ChildItem $driverOut -File|Where-Object {$_.Extension -in @('.sys','.dll')}|ForEach-Object {[ordered]@{name=$_.Name;sha256=(Get-FileHash $_.FullName).Hash;size=$_.Length}})|ConvertTo-Json|Set-Content "$env:RUNNER_TEMP/timing/inf2cat-input-bytes.json"
    & $inf2Cat "/driver:$driverOut" "/os:10_X64" /uselocaltime''',
'    Invoke-SignTool $signTool $certificate.Thumbprint $catalog': '''    Invoke-SignTool $signTool $certificate.Thumbprint $catalog
    [ordered]@{status='PASS_NORMAL_INF2CAT_AND_CATALOG_SIGN';thumbprint=$certificate.Thumbprint;catSha256=(Get-FileHash $catalog).Hash}|ConvertTo-Json|Set-Content "$env:RUNNER_TEMP/timing/catalog-producer.json"'''}
for a,b in anchors.items():
 if s.count(a)!=1:raise ValueError('Signing observation anchor mismatch')
 s=s.replace(a,b)
restored=s
for a,b in anchors.items():restored=restored.replace(b,a)
if restored!=original:raise ValueError('Signing observation restoration failed')
p.write_text(s)
Path(sys.argv[2]).write_text(json.dumps({'classification':'REVERSIBLE_SIGNING_OBSERVATIONS_ONLY','beforeSha256':hashlib.sha256(original.encode()).hexdigest(),'afterSha256':hashlib.sha256(s.encode()).hexdigest()}))
