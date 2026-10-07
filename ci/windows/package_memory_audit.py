"""Diagnostic-only trust substitution, reversible to the exact frozen audit."""
import argparse,hashlib,json
from pathlib import Path
import package_audit_timing
PREFIX=r'''
# DIAGNOSTIC_MEMORY_VERIFIER_BEGIN
function Invoke-MemoryAuditVerification([string]$Kind,[string]$Path,[string]$Receipt,[string]$Catalog='') {
 $args=@($Kind,$Path,$certFile.FullName,$Receipt)
 if($Catalog){$args+=@($Catalog)}
 & $sign @args
 $exit=$LASTEXITCODE
 if($exit -ne 0){throw "Native custom Authenticode verification refused $Path (exit $exit)"}
 $v=Get-Content $Receipt -Raw|ConvertFrom-Json
 if($v.finalStatus -ne 'PASS' -or $v.stateVerifyCount -ne 1 -or $v.stateCloseCount -ne 1 -or @($v.results).Count -ne 1){throw 'Verifier qualification receipt invalid'}
 $r=$v.results[0]
 if($r.finalStatus -ne 'PASS' -or -not $r.signerDerMatch -or $r.signerThumbprint -ne $cert.Thumbprint -or $r.packageCertificateDerSha256 -ne (Get-FileHash $certFile.FullName).Hash -or $r.sha256 -ne (Get-FileHash $Path).Hash){throw 'Dynamic Package signer or content identity mismatch'}
 $global:LASTEXITCODE=$exit
}
# DIAGNOSTIC_MEMORY_VERIFIER_END
'''

def substitutions():
 return [
 ("$sign='C:\\Program Files (x86)\\Windows Kits\\10\\bin\\10.0.26100.0\\x64\\signtool.exe'",'$sign=$env:HELIOS_MEMORY_VERIFIER\nif(-not(Test-Path $sign -PathType Leaf)){throw "Qualified diagnostic verifier missing"}'),
 ('$store="Cert:\\CurrentUser\\Root\\$($cert.Thumbprint)";$owned=-not(Test-Path $store)',r'''AuditEvent TRUST BEGIN
$packageManifest=Get-Content "$extract\manifest.json" -Raw|ConvertFrom-Json
if($packageManifest.signing.thumbprint -ne $cert.Thumbprint -or $packageManifest.signing.subject -cne $cert.Subject -or $packageManifest.signing.certificate -cne 'certificate/helios-ci-test.cer'){throw 'Package manifest signing identity mismatch'}'''),
 ('if($owned){Import-Certificate -FilePath $certFile.FullName -CertStoreLocation Cert:\\CurrentUser\\Root|Out-Null}','AuditEvent TRUST END'),
 ('& $sign verify /pa /v "$driver\\$name" *> "$out\\extracted-signature-$name.txt"','Invoke-MemoryAuditVerification embedded "$driver\\$name" "$out\\extracted-signature-$name.json"'),
 ('& $sign verify /pa /v /c $cat $file.FullName *> "$out\\extracted-catalog-$($file.Name).txt"','Invoke-MemoryAuditVerification catalog $file.FullName "$out\\extracted-catalog-$($file.Name).json" $cat'),
 ('& $sign verify /pa /v $file.FullName *> "$out\\extracted-signature-$($file.Name)-$expected.txt"','Invoke-MemoryAuditVerification embedded $file.FullName "$out\\extracted-signature-$($file.Name)-$expected.json"'),
 ('if($owned){Remove-Item $store -Force -ErrorAction SilentlyContinue}','AuditEvent TRUST_CLEANUP BEGIN\n$cert.Dispose()\nAuditEvent TRUST_CLEANUP END'),
 ]
METADATA=[("'signtool verify /pa /v'", "'qualified package-verify embedded'",4),("'signtool verify /pa /v /c catalog'", "'qualified package-verify catalog-member'",2)]

def transform(original):
 text=package_audit_timing.instrument(original)
 for old,new in substitutions():
  if text.count(old)!=1:raise ValueError('Frozen trust anchor mismatch: '+old)
  text=text.replace(old,new)
 for old,new,count in METADATA:
  if text.count(old)!=count:raise ValueError('Verifier timing command metadata mismatch')
  text=text.replace(old,new)
 anchor='AuditEvent CERTIFICATE BEGIN\n$certFile=Get-ChildItem'
 if text.count(anchor)!=1:raise ValueError('Memory helper anchor mismatch')
 text=text.replace(anchor,PREFIX+anchor)
 if restore(text)!=original:raise ValueError('Diagnostic audit restoration failed')
 return text

def restore(text):
 text=text.replace(PREFIX,'')
 for old,new,count in METADATA:text=text.replace(new,old)
 for old,new in reversed(substitutions()):text=text.replace(new,old)
 return package_audit_timing.restore(text)

def main():
 p=argparse.ArgumentParser();p.add_argument('source');p.add_argument('destination');a=p.parse_args();source=Path(a.source);dest=Path(a.destination);original=source.read_text(encoding='utf-8-sig');changed=transform(original);dest.write_text(changed)
 dest.with_suffix('.provenance.json').write_text(json.dumps({'status':'PASS_REVERSIBLE_DIAGNOSTIC_TRUST_DELTA','originalByteSha256':hashlib.sha256(source.read_bytes()).hexdigest(),'restoredTextSha256':hashlib.sha256(restore(changed).encode()).hexdigest(),'originalTextSha256':hashlib.sha256(original.encode()).hexdigest(),'diagnosticSha256':hashlib.sha256(dest.read_bytes()).hexdigest(),'functionalChanges':substitutions(),'timingCommandMetadata':METADATA,'productionAuditChanged':False},indent=2))
if __name__=='__main__':main()
