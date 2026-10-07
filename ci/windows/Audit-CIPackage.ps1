param(
    [Parameter(Mandatory)][string]$OutputDir,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Fingerprint,
    [Parameter(Mandatory)][string]$Verifier,
    [Parameter(Mandatory)][string]$VerifierBuildReceipt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$out = [IO.Path]::GetFullPath($OutputDir)
$extract = Join-Path $out 'extraction-verify'
$driver = Join-Path $extract 'payload\driver'
$cat = Join-Path $driver 'helios_kmd_render.cat'
$llvm = 'C:\Program Files\LLVM\bin\llvm-readobj.exe'
$verifierReceipts = Join-Path $out 'native-signature-receipts'
$eventPath = Join-Path $out 'audit-events.jsonl'
$signatureRecords = [Collections.Generic.List[object]]::new()
$imageRecords = [Collections.Generic.List[object]]::new()
$nativeReceipts = [Collections.Generic.List[object]]::new()
$certificate = $null
$beforeStores = $null
$afterStores = $null
$storeSnapshotsEqual = $false
$status = 'FAIL'
$auditStopwatch = [Diagnostics.Stopwatch]::StartNew()
$failure = $null
$storeSnapshotError = $null
$failureMessage = $null
$manifest = $null
$packageCertificateSha256 = $null
$packageCertificateThumbprint = $null
$verifierSourceSha256 = $null
$verifierBinarySha256 = $null
$verifierBinarySize = $null
$inf = $null
$shimVersion = $null

New-Item -ItemType Directory -Force -Path $verifierReceipts | Out-Null
Set-Content -LiteralPath $eventPath -Value '' -Encoding UTF8

function Write-AuditEvent([string]$Phase, [string]$Edge, [string]$Path = '') {
    [ordered]@{ phase = $Phase; edge = $Edge; path = $Path; utc = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json -Compress | Add-Content -LiteralPath $eventPath -Encoding UTF8
}

function Get-PackageCertificateStoreSnapshot([string]$Thumbprint) {
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($locationName in @('CurrentUser', 'LocalMachine')) {
        $location = if ($locationName -eq 'CurrentUser') {
            [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
        } else {
            [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
        }
        foreach ($storeName in @('Root', 'TrustedPeople', 'TrustedPublisher', 'My')) {
            $store = [Security.Cryptography.X509Certificates.X509Store]::new($storeName, $location)
            try {
                $flags = [Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly -bor
                    [Security.Cryptography.X509Certificates.OpenFlags]::OpenExistingOnly
                $store.Open($flags)
                $matches = $store.Certificates.Find(
                    [Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
                    $Thumbprint,
                    $false
                )
                foreach ($match in $matches) {
                    try {
                        $rows.Add([ordered]@{
                            location = $locationName
                            store = $storeName
                            thumbprint = $match.Thumbprint.ToUpperInvariant()
                            rawData = [Convert]::ToBase64String($match.RawData)
                        })
                    } finally {
                        $match.Dispose()
                    }
                }
            } finally {
                $store.Dispose()
            }
        }
    }
    return @($rows.ToArray() | Sort-Object location, store, thumbprint, rawData)
}

function Invoke-PackageAuthenticodeVerification(
    [ValidateSet('embedded', 'catalog')][string]$Kind,
    [string]$Path,
    [string]$Receipt,
    [string]$Catalog = ''
) {
    if (-not (Test-Path -LiteralPath $Verifier -PathType Leaf)) { throw 'Explicit package verifier is absent.' }
    if (Test-Path -LiteralPath $Receipt) { throw "Closed verifier receipt already exists: $Receipt" }
    $arguments = @($Kind, $Path, $certificateFile.FullName, $Receipt)
    if ($Kind -eq 'catalog') {
        if (-not $Catalog -or -not (Test-Path -LiteralPath $Catalog -PathType Leaf)) { throw 'Catalog verification requires the exact catalog path.' }
        $arguments += $Catalog
    }
    $phase = if ($Kind -eq 'catalog') { 'CATALOG_MEMBER_VERIFY' } else { 'AUTHENTICODE_VERIFY' }
    Write-AuditEvent $phase 'BEGIN' $Path
    & $Verifier @arguments
    $exitCode = [int]$LASTEXITCODE
    if ($exitCode -ne 0) { throw "package-verify $Kind failed for $Path (exit $exitCode)." }
    if (-not (Test-Path -LiteralPath $Receipt -PathType Leaf)) { throw "Verifier receipt is absent for $Path." }
    $receiptObject = Get-Content -LiteralPath $Receipt -Raw | ConvertFrom-Json
    if ($receiptObject.finalStatus -cne 'PASS' -or
        [int]$receiptObject.stateVerifyCount -ne 1 -or
        [int]$receiptObject.stateCloseCount -ne 1 -or
        @($receiptObject.results).Count -ne 1) {
        throw "Verifier top-level receipt is incomplete or failed for $Path."
    }
    $result = $receiptObject.results[0]
    $fileHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($result.finalStatus -cne 'PASS' -or
        $result.winTrustHRESULT -cne '0x800B0109' -or
        $result.winTrustTrustOnlyFailure -ne $true -or
        $result.signerDerMatch -ne $true -or
        $result.signerThumbprint.ToUpperInvariant() -cne $certificate.Thumbprint.ToUpperInvariant() -or
        $result.packageCertificateDerSha256.ToLowerInvariant() -cne $packageCertificateSha256 -or
        $result.sha256.ToLowerInvariant() -cne $fileHash -or
        $result.certificateIntrinsicChecks -ne $true -or
        $result.customChainBuilt -ne $true -or
        $result.customChainStatus -cne '0x00000000' -or
        $result.customPolicyChecked -ne $true -or
        $result.customPolicyStatus -cne '0x00000000' -or
        $result.stateClosed -ne $true -or
        $result.stateCloseHRESULT -cne '0x00000000') {
        throw "Verifier signer, content, exclusive-chain, policy, or close proof is incomplete for $Path."
    }
    $nativeReceipts.Add([ordered]@{
        kind = $Kind
        path = $Path.Substring($extract.Length + 1).Replace('\', '/')
        receipt = $Receipt.Substring($out.Length + 1).Replace('\', '/')
        exitCode = $exitCode
        finalStatus = $receiptObject.finalStatus
        winTrustHRESULT = $result.winTrustHRESULT
        signerThumbprint = $result.signerThumbprint
        packageCertificateDerSha256 = $result.packageCertificateDerSha256
        sha256 = $result.sha256
        stateVerifyCount = [int]$receiptObject.stateVerifyCount
        stateCloseCount = [int]$receiptObject.stateCloseCount
    })
    Write-AuditEvent $phase 'END' $Path
    return $result
}

try {
    foreach ($path in @($extract, $driver, $cat, $llvm, $Verifier, $VerifierBuildReceipt)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Required Package audit input is missing: $path" }
    }
    Write-AuditEvent 'CERTIFICATE' 'BEGIN'
    $certificateFiles = @(Get-ChildItem -LiteralPath (Join-Path $extract 'certificate') -File -Filter '*.cer')
    if ($certificateFiles.Count -ne 1) { throw 'Exactly one extraction-verify/certificate/*.cer is required.' }
    $certificateFile = $certificateFiles[0]
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificateFile.FullName)
    $packageCertificateSha256 = (Get-FileHash -LiteralPath $certificateFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $packageCertificateThumbprint = $certificate.Thumbprint
    $manifest = Get-Content -LiteralPath (Join-Path $extract 'manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.signing.thumbprint.ToUpperInvariant() -cne $certificate.Thumbprint.ToUpperInvariant() -or
        $manifest.signing.subject -cne $certificate.Subject -or
        $manifest.signing.certificate -cne 'certificate/helios-ci-test.cer') {
        throw 'Manifest signing identity does not exactly describe the dynamic Package CER.'
    }

    $Verifier = (Resolve-Path -LiteralPath $Verifier).Path
    $VerifierBuildReceipt = (Resolve-Path -LiteralPath $VerifierBuildReceipt).Path
    $buildReceipt = Get-Content -LiteralPath $VerifierBuildReceipt -Raw | ConvertFrom-Json
    $toolchainPins = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw | ConvertFrom-Json
    $sourcePath = Join-Path $PSScriptRoot 'memory-trust\package_verify.cpp'
    $gatePath = Join-Path $PSScriptRoot 'memory-trust\result_gate.h'
    $verifierSourceSha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $gateSha256 = (Get-FileHash -LiteralPath $gatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $verifierBinarySha256 = (Get-FileHash -LiteralPath $Verifier -Algorithm SHA256).Hash.ToLowerInvariant()
    $verifierBinarySize = [long](Get-Item -LiteralPath $Verifier).Length
    $expectedCompilerTail = "VC\Tools\MSVC\$($toolchainPins.visualStudio.msvcVersion)\bin\Hostx64\x64\cl.exe"
    $compilerPath = ([string]$buildReceipt.compilerPath).Replace('/', '\')
    $requiredCommandContract = @('/nologo', '/std:c++17', '/EHsc', '/W4', '/DUNICODE', '/D_UNICODE', 'wintrust.lib', 'crypt32.lib', 'psapi.lib')
    $commandContractComplete = @($requiredCommandContract | Where-Object { $_ -notin @($buildReceipt.commandContract) }).Count -eq 0
    if ($buildReceipt.status -cne 'PASS' -or
        $buildReceipt.sourceSha256.ToLowerInvariant() -cne $verifierSourceSha256 -or
        $buildReceipt.resultGateSha256.ToLowerInvariant() -cne $gateSha256 -or
        -not $compilerPath.EndsWith($expectedCompilerTail, [StringComparison]::OrdinalIgnoreCase) -or
        -not $commandContractComplete -or
        [IO.Path]::GetFullPath($buildReceipt.outputPath) -cne $Verifier -or
        $buildReceipt.outputSha256.ToLowerInvariant() -cne $verifierBinarySha256 -or
        [long]$buildReceipt.outputSize -ne $verifierBinarySize -or
        $buildReceipt.peMachine -cne 'IMAGE_FILE_MACHINE_AMD64' -or
        $buildReceipt.packagePayload -ne $false) {
        throw 'Verifier build receipt does not bind the exact source, binary, and CI-only output.'
    }

    Write-AuditEvent 'STORE_SNAPSHOT' 'BEGIN'
    $beforeStores = @(Get-PackageCertificateStoreSnapshot $certificate.Thumbprint)
    ConvertTo-Json -InputObject @($beforeStores) -Depth 8 | Set-Content -LiteralPath (Join-Path $out 'package-certificate-stores-before.json') -Encoding UTF8
    Write-AuditEvent 'STORE_SNAPSHOT' 'END'

    Write-AuditEvent 'DRIVER_CAT_SIGNATURE' 'BEGIN'
    foreach ($name in @('helios_kmd_render.cat', 'helios_kmd_render.sys')) {
        $path = Join-Path $driver $name
        $receiptPath = Join-Path $verifierReceipts "embedded-$name.json"
        $null = Invoke-PackageAuthenticodeVerification 'embedded' $path $receiptPath
        $authenticode = Get-AuthenticodeSignature -FilePath $path
        if (-not $authenticode.SignerCertificate -or
            $authenticode.SignerCertificate.Thumbprint.ToUpperInvariant() -cne $certificate.Thumbprint.ToUpperInvariant()) {
            throw "Get-AuthenticodeSignature signer evidence does not match the Package CER: $name"
        }
        $signatureRecords.Add([ordered]@{
            name = $name
            signature = 'PASS'
            thumbprint = $authenticode.SignerCertificate.Thumbprint
            subject = $authenticode.SignerCertificate.Subject
            status = [string]$authenticode.Status
            evidence = 'Get-AuthenticodeSignature'
        })
    }
    Write-AuditEvent 'DRIVER_CAT_SIGNATURE' 'END'

    $expectedDrivers = @('helios_kmd_render.sys', 'helios_umd.dll', 'helios_umd12.dll', 'helios_umd32.dll', 'helios_umd12_32.dll')
    $driverNames = @(Get-ChildItem -LiteralPath $driver -File | Where-Object { $_.Name -in $expectedDrivers } | ForEach-Object Name | Sort-Object)
    if (@($driverNames).Count -ne 5 -or @($expectedDrivers | Where-Object { $_ -notin $driverNames }).Count -ne 0) {
        throw 'The five required CAT-covered driver images are not present exactly once.'
    }

    $version = $Version
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $extract 'payload') -File -Recurse | Where-Object { $_.Extension -in @('.dll', '.sys', '.exe') }) {
        $relative = $file.FullName.Substring($extract.Length + 1)
        $expectedMachine = if ($relative -match '\\x86\\' -or $file.Name -in @('helios_umd32.dll', 'helios_umd12_32.dll')) {
            'IMAGE_FILE_MACHINE_I386'
        } else {
            'IMAGE_FILE_MACHINE_AMD64'
        }
        Write-AuditEvent 'LLVM_READOBJ' 'BEGIN' $relative
        $headers = (& $llvm --file-headers $file.FullName | Out-String)
        $llvmExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        if ($llvmExit -ne 0 -or $headers -notmatch "Machine: $expectedMachine\b") { throw "Architecture mismatch: $relative" }
        Write-AuditEvent 'LLVM_READOBJ' 'END' $relative

        $isDriver = $file.DirectoryName -eq $driver
        $isCatalogImage = $isDriver -and $file.Name -in $expectedDrivers
        $signature = 'EMBEDDED_PASS'
        if ($isCatalogImage) {
            if ($file.VersionInfo.FileVersion -ne $version -or $file.VersionInfo.ProductVersion -ne $version) {
                throw "Driver FileVersion or ProductVersion mismatch: $relative"
            }
            $receiptPath = Join-Path $verifierReceipts "catalog-$($file.Name).json"
            $null = Invoke-PackageAuthenticodeVerification 'catalog' $file.FullName $receiptPath $cat
            $signature = 'CATALOG_COVERED'
        } elseif (-not $isDriver) {
            $safeName = ($relative -replace '[\\/:]', '_')
            $receiptPath = Join-Path $verifierReceipts "embedded-$safeName.json"
            $null = Invoke-PackageAuthenticodeVerification 'embedded' $file.FullName $receiptPath
        } else {
            throw "Unexpected driver image outside the five signed catalog members: $relative"
        }

        Write-AuditEvent 'HASH' 'BEGIN' $relative
        $fileHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        Write-AuditEvent 'HASH' 'END' $relative
        $imageRecords.Add([ordered]@{
            path = $relative
            architecture = $expectedMachine
            fileVersion = $file.VersionInfo.FileVersion
            productVersion = $file.VersionInfo.ProductVersion
            size = [long]$file.Length
            sha256 = $fileHash
            signature = $signature
        })
    }
    if ($imageRecords.Count -ne 27 -or $nativeReceipts.Count -ne 29) {
        throw "Package coverage mismatch: images=$($imageRecords.Count), nativeSignatureReceipts=$($nativeReceipts.Count)."
    }
    $catalogReceipts = @($nativeReceipts | Where-Object { $_.kind -eq 'catalog' })
    if ($catalogReceipts.Count -ne 5) { throw 'Exactly five driver catalog-member receipts are required.' }

    Write-AuditEvent 'INF' 'BEGIN'
    $inf = Get-Content -LiteralPath (Join-Path $driver 'helios_kmd_render.inf') -Raw
    if ($inf -notmatch ('(?im)^DriverVer\s*=\s*[^,]+,' + [regex]::Escape($version) + '\s*$')) { throw 'INF DriverVer mismatch.' }
    if ($inf -notmatch '(?im)^CatalogFile\s*=\s*helios_kmd_render\.cat\s*$') { throw 'INF catalog association mismatch.' }
    foreach ($pattern in @('UserModeDriverName', 'UserModeDriverNameWoW', 'helios_umd\.dll', 'helios_umd32\.dll', 'helios_umd12\.dll', 'helios_umd12_32\.dll')) {
        if ($inf -notmatch $pattern) { throw "INF registration absent: $pattern" }
    }
    $inf | Set-Content -LiteralPath (Join-Path $out 'extracted-driver.inf') -Encoding UTF8
    Write-AuditEvent 'INF' 'END'

    Write-AuditEvent 'SCRIPT_PARSE' 'BEGIN'
    foreach ($script in Get-ChildItem -LiteralPath $extract -File -Filter '*.ps1') {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "Packaged script syntax invalid: $($script.Name)" }
    }
    Write-AuditEvent 'SCRIPT_PARSE' 'END'

    Write-AuditEvent 'INSTALL_STATIC' 'BEGIN'
    $install = Get-Content -LiteralPath (Join-Path $extract 'Install-Helios.ps1') -Raw
    foreach ($pattern in @('Helios\\\$safePackageId', 'mesa\\helios_vulkan.json', 'mesa\\x86\\helios_vulkan.json', 'opencl\\clvk.dll', 'OpenGLDriverNameWow', 'OpenGLDriverName', 'pnputil.exe', '/add-driver')) {
        if ($install -notmatch $pattern) { throw "Static installation contract absent: $pattern" }
    }
    if ($install -match '22\.22\.299\.0') { throw 'Old global install version.' }
    Write-AuditEvent 'INSTALL_STATIC' 'END'

    Write-AuditEvent 'MANIFEST' 'BEGIN'
    if ($manifest.version -ne $version -or $manifest.candidate.sourceFingerprint -ne $Fingerprint) { throw 'Manifest candidate identity mismatch.' }
    Write-AuditEvent 'MANIFEST' 'END'

    Write-AuditEvent 'SHIM' 'BEGIN'
    $shim = Join-Path $extract 'compatibility\DaVinci Resolve\atiadlxx.dll'
    $shimVersion = (Get-Item -LiteralPath $shim).VersionInfo.FileVersion
    if ($shimVersion -ne $version) { throw 'Shim embedded FileVersion is stale.' }
    Write-AuditEvent 'SHIM' 'END'
    $status = 'PASS'
} catch {
    $failure = $_
    $status = 'FAIL'
} finally {
    if ($null -ne $certificate -and $null -ne $beforeStores) {
        try {
            $afterStores = @(Get-PackageCertificateStoreSnapshot $certificate.Thumbprint)
            ConvertTo-Json -InputObject @($afterStores) -Depth 8 | Set-Content -LiteralPath (Join-Path $out 'package-certificate-stores-after.json') -Encoding UTF8
            $beforeJson = ConvertTo-Json -InputObject @($beforeStores) -Compress -Depth 8
            $afterJson = ConvertTo-Json -InputObject @($afterStores) -Compress -Depth 8
            $storeSnapshotsEqual = $beforeJson -ceq $afterJson
        } catch {
            $storeSnapshotError = $_.Exception.Message
            $storeSnapshotsEqual = $false
        }
    }
    if ($certificate) { $certificate.Dispose() }
}

if (-not $storeSnapshotsEqual) {
    $status = 'FAIL'
    if (-not $failure) { $failure = [InvalidOperationException]::new("Persistent Package certificate stores changed or could not be snapshotted: $storeSnapshotError") }
}
$failureMessage = if ($failure -is [System.Management.Automation.ErrorRecord]) { $failure.Exception.Message } elseif ($failure -is [Exception]) { $failure.Message } else { $null }
$auditStopwatch.Stop()
$audit = [ordered]@{
    status = $status
    auditDurationMs = [Math]::Round($auditStopwatch.Elapsed.TotalMilliseconds, 4)
    infVersion = $Version
    infProviderLines = @((($inf -split "`r?`n") | Where-Object { $_ -match '(?i)Provider|DriverVer|CatalogFile|UserModeDriverName' }))
    signatures = @($signatureRecords.ToArray())
    images = @($imageRecords.ToArray())
    expectedPackageRoot = if ($manifest) { "C:\Program Files\Helios\$($manifest.packageId)" } else { $null }
    futureDriverStore = 'PnP selects a new oemN.inf dynamically; five candidate images and four UMD registration entries defined by extracted INF'
    registryAudit = 'STATIC_ONLY'
    installExecution = 'NOT_RUN'
    shimVersion = $shimVersion
    setupExecution = 'NOT_RUN'
    trustMode = 'EXCLUSIVE_MEMORY_PEER'
    verifierSourceSha256 = $verifierSourceSha256
    verifierBinarySha256 = $verifierBinarySha256
    verifierBinarySize = $verifierBinarySize
    verifierBuildReceipt = $VerifierBuildReceipt
    packageCertificateDerSha256 = $packageCertificateSha256
    packageCertificateThumbprint = $packageCertificateThumbprint
    persistentStoreMutation = if ($storeSnapshotsEqual) { 'NONE' } else { 'DETECTED_OR_UNVERIFIABLE' }
    persistentStoreSnapshot = if ($storeSnapshotsEqual) { 'PASS_EXACT_THUMBPRINT_AND_RAWDATA_ALL_EIGHT_STORES' } else { 'FAIL' }
    nativeSignatureReceipts = @($nativeReceipts.ToArray())
    catalogHashAuthority = 'CryptCATAdminCalcHashFromFileHandle2'
    failure = $failureMessage
}
$audit | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $out 'offline-installation-signature-audit.json') -Encoding UTF8
if ($status -ne 'PASS') { throw "OFFLINE_AUDIT=FAIL; $($audit.failure)" }
Write-Host 'OFFLINE_AUDIT=PASS; TRUST_MODE=EXCLUSIVE_MEMORY_PEER; PERSISTENT_STORE_MUTATION=NONE; IMAGES=27; NATIVE_SIGNATURE_RECEIPTS=29'
