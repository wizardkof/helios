param([Parameter(Mandatory)][string]$OutputDir,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)][string]$Fingerprint)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
$out=$OutputDir;$fp=$Fingerprint
$extract="$out\extraction-verify"
$sign='C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe'
$llvm='C:\Program Files\LLVM\bin\llvm-readobj.exe'
$certFile=Get-ChildItem "$extract\certificate" -File -Filter '*.cer'
if(@($certFile).Count -ne 1){throw 'Unique package certificate required'}
$cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new($certFile.FullName)
$store="Cert:\CurrentUser\Root\$($cert.Thumbprint)";$owned=-not(Test-Path $store)
try {
if($owned){Import-Certificate -FilePath $certFile.FullName -CertStoreLocation Cert:\CurrentUser\Root|Out-Null}
$driver="$extract\payload\driver";$cat="$driver\helios_kmd_render.cat"
$version=$Version;$records=@()
foreach($name in @('helios_kmd_render.cat','helios_kmd_render.sys')){
& $sign verify /pa /v "$driver\$name" *> "$out\extracted-signature-$name.txt"
if($LASTEXITCODE -ne 0){throw "Extracted signature failed $name"}
$a=Get-AuthenticodeSignature "$driver\$name";$records+=@{name=$name;signature='PASS';thumbprint=$a.SignerCertificate.Thumbprint;subject=$a.SignerCertificate.Subject}
}
$images=@()
foreach($file in Get-ChildItem "$extract\payload" -File -Recurse | Where-Object {$_.Extension -in @('.dll','.sys','.exe')}){
$rel=$file.FullName.Substring($extract.Length+1)
$expected=if($rel -match '\\x86\\' -or $file.Name -in @('helios_umd32.dll','helios_umd12_32.dll')){'IMAGE_FILE_MACHINE_I386'}else{'IMAGE_FILE_MACHINE_AMD64'}
$h=(& $llvm --file-headers $file.FullName | Out-String)
if($LASTEXITCODE -ne 0 -or $h -notmatch "Machine: $expected\b"){throw "Architecture mismatch $rel"}
$isDriver=$file.DirectoryName -eq $driver
if($isDriver){
if($file.VersionInfo.FileVersion -ne $version -or $file.VersionInfo.ProductVersion -ne $version){throw "Driver version mismatch $rel"}
& $sign verify /pa /v /c $cat $file.FullName *> "$out\extracted-catalog-$($file.Name).txt"
if($LASTEXITCODE -ne 0){throw "Catalog coverage failed $rel"}
}else{
& $sign verify /pa /v $file.FullName *> "$out\extracted-signature-$($file.Name)-$expected.txt"
if($LASTEXITCODE -ne 0){throw "Payload signature failed $rel"}
}
$images+=@{path=$rel;architecture=$expected;fileVersion=$file.VersionInfo.FileVersion;productVersion=$file.VersionInfo.ProductVersion;size=$file.Length;sha256=(Get-FileHash $file.FullName).Hash;signature=if($isDriver){'CATALOG_COVERED'}else{'EMBEDDED_PASS'}}
}
$inf=Get-Content "$driver\helios_kmd_render.inf" -Raw
if($inf -notmatch ('(?im)^DriverVer\s*=\s*[^,]+,'+[regex]::Escape($version)+'\s*$')){throw 'INF DriverVer mismatch'}
if($inf -notmatch '(?im)^CatalogFile\s*=\s*helios_kmd_render\.cat\s*$'){throw 'INF catalog association mismatch'}
foreach($pattern in @('UserModeDriverName','UserModeDriverNameWoW','helios_umd\.dll','helios_umd32\.dll','helios_umd12\.dll','helios_umd12_32\.dll')){if($inf -notmatch $pattern){throw "INF registration absent $pattern"}}
$inf | Set-Content "$out\extracted-driver.inf" -Encoding UTF8
foreach($f in Get-ChildItem $extract -File -Filter '*.ps1'){
$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$t,[ref]$e)
if($e.Count){throw "Packaged script syntax invalid $($f.Name)"}
}
$install=Get-Content "$extract\Install-Helios.ps1" -Raw
foreach($pattern in @('Helios\\\$safePackageId','mesa\\helios_vulkan.json','mesa\\x86\\helios_vulkan.json','opencl\\clvk.dll','OpenGLDriverNameWow','OpenGLDriverName','pnputil.exe','/add-driver')){if($install -notmatch $pattern){throw "Static installation contract absent $pattern"}}
if($install -match '22\.22\.299\.0'){throw 'Old global install version'}
$m=Get-Content "$extract\manifest.json" -Raw | ConvertFrom-Json
if($m.version -ne $version -or $m.candidate.sourceFingerprint -ne $fp){throw 'Manifest identity mismatch'}
$shim="$extract\compatibility\DaVinci Resolve\atiadlxx.dll"
if((Get-Item $shim).VersionInfo.FileVersion -ne $version){throw 'Shim embedded version stale'}
[ordered]@{status='PASS';infVersion=$version;infProviderLines=@(($inf -split "`r?`n") | Where-Object {$_ -match '(?i)Provider|DriverVer|CatalogFile|UserModeDriverName'});signatures=$records;images=$images;expectedPackageRoot="C:\Program Files\Helios\$($m.packageId)";futureDriverStore='PnP selects a new oemN.inf dynamically; five candidate images and four UMD registration entries defined by extracted INF';registryAudit='STATIC_ONLY';installExecution='NOT_RUN';shimVersion=$version;setupExecution='NOT_RUN'} | ConvertTo-Json -Depth 8 | Set-Content "$out\offline-installation-signature-audit.json" -Encoding UTF8
Write-Host 'OFFLINE_AUDIT=PASS'

} finally {if($owned){Remove-Item $store -Force -ErrorAction SilentlyContinue}}
