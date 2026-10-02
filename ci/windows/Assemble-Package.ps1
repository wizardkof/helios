param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$DriverArtifact,
    [Parameter(Mandatory)][string]$MesaArtifact,
    [Parameter(Mandatory)][string]$MesaX86Artifact,
    [Parameter(Mandatory)][string]$OpenClArtifact,
    [Parameter(Mandatory)][string]$LoadersArtifact,
    [Parameter(Mandatory)][string]$CompatibilityArtifact,
    [Parameter(Mandatory)][string]$InstallerArtifact,
    [Parameter(Mandatory)][string]$OutputDir,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][ValidateSet("Debug", "Release")][string]$Configuration,
    [Parameter(Mandatory)][string]$RepositoryCommit,
    [Parameter(Mandatory)][string]$MesaCommit,
    [Parameter(Mandatory)][string]$DxvkCommit,
    [Parameter(Mandatory)][string]$Vkd3dCommit,
    [Parameter(Mandatory)][string]$ClvkCommit,
    [Parameter(Mandatory)][string]$VulkanLoaderCommit,
    [Parameter(Mandatory)][string]$VulkanHeadersCommit,
    [Parameter(Mandatory)][string]$OpenClLoaderCommit,
    [Parameter(Mandatory)][string]$OpenClHeadersCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Initialize-HeliosBuild.ps1")
. (Join-Path $RepoRoot "packaging\windows\Helios-PackageCommon.ps1")
. (Join-Path $RepoRoot "metadata\Read-HeliosMetadata.ps1")
& (Join-Path $RepoRoot "ci\windows\Verify-CandidateSource.ps1") -RepoRoot $RepoRoot `
    -Configuration $Configuration -Architecture "x64+x86"
$metadata = Read-HeliosMetadata $RepoRoot
if ($Version -ne $metadata.HELIOS_KMD_VERSION) {
    throw "Package version $Version differs from kmd_render/driver-version.env ($($metadata.HELIOS_KMD_VERSION))."
}
$candidateLock = Get-Content -LiteralPath (Join-Path $RepoRoot "metadata\candidate-reservation.json") -Raw | ConvertFrom-Json
foreach ($pin in @(
    @{ name = "mesa"; actual = $MesaCommit },
    @{ name = "dxvk"; actual = $DxvkCommit },
    @{ name = "vkd3d"; actual = $Vkd3dCommit }
)) {
    $lockedCommit = [string]$candidateLock.sourceCommits.PSObject.Properties[$pin.name].Value
    if ($lockedCommit -ne [string]$pin.actual) {
        throw "$($pin.name) artifact source $($pin.actual) differs from the candidate lock $lockedCommit."
    }
}
$driverReceiptPath = Join-Path $DriverArtifact "candidate-artifact.json"
if (-not (Test-Path -LiteralPath $driverReceiptPath -PathType Leaf)) {
    throw "Driver artifact has no candidate identity receipt."
}
$driverReceipt = Get-Content -LiteralPath $driverReceiptPath -Raw | ConvertFrom-Json
if ($driverReceipt.version -ne $Version -or $driverReceipt.sourceFingerprint -ne $candidateLock.sourceFingerprint -or
    $driverReceipt.configuration -ne $Configuration) {
    throw "Driver artifact candidate/version/configuration does not match this package."
}
$driverFiles = @($driverReceipt.files)
if ($driverFiles.Count -ne 5) { throw "Driver artifact receipt must identify the SYS and all four UMD images." }
foreach ($name in @("helios_kmd_render.sys", "helios_umd.dll", "helios_umd12.dll", "helios_umd32.dll", "helios_umd12_32.dll")) {
    $entry = @($driverFiles | Where-Object { $_.name -ceq $name })
    $imagePath = Join-Path $DriverArtifact $name
    if ($entry.Count -ne 1 -or -not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
        throw "Driver artifact receipt is missing a unique identity for $name."
    }
    $actualHash = (Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $actualSize = (Get-Item -LiteralPath $imagePath).Length
    if ($actualHash -ne [string]$entry[0].sha256 -or $actualSize -ne [int64]$entry[0].size) {
        throw "$name bytes do not match the driver artifact identity receipt."
    }
    $expectedArchitecture = if ($name -in @("helios_umd32.dll", "helios_umd12_32.dll")) { "x86" } else { "x64" }
    if ($entry[0].architecture -ne $expectedArchitecture) {
        throw "$name architecture in the driver receipt does not match its Helios filename slot."
    }
}
foreach ($component in @("mesa", "dxvk", "vkd3d")) {
    $locked = [string]$candidateLock.sourceCommits.PSObject.Properties[$component].Value
    $built = [string]$driverReceipt.sourceCommits.PSObject.Properties[$component].Value
    if ($locked -ne $built) { throw "Driver artifact $component source $built differs from candidate lock $locked." }
}
foreach ($name in @("mesa", "mesa-x86")) {
    $artifactRoot = if ($name -eq "mesa") { $MesaArtifact } else { $MesaX86Artifact }
    $receiptPath = Join-Path $artifactRoot "source.json"
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw "$name artifact is missing its source provenance receipt."
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if ($receipt.component -ne "mesa" -or $receipt.sourceCommit -ne $MesaCommit -or
        $receipt.sourceCommit -ne $candidateLock.sourceCommits.mesa) {
        throw "$name payload was built from a Mesa source that differs from the candidate source lock."
    }
}
Import-VisualStudioEnvironment

function Copy-Required([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Required artifact is missing: $Source" }
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Invoke-SignTool([string]$SignTool, [string]$Thumbprint, [string]$Path) {
    & $SignTool sign /v /fd SHA256 /sha1 $Thumbprint /s My $Path
    if ($LASTEXITCODE -ne 0) { throw "signtool failed to sign $Path." }
}

function Assert-SignTool([string]$SignTool, [string]$Path, [string[]]$AdditionalArguments = @()) {
    & $SignTool verify /pa /all /v @AdditionalArguments $Path
    if ($LASTEXITCODE -ne 0) { throw "signtool could not verify the test signature for $Path." }
}

$shortCommit = $RepositoryCommit.Substring(0, 8)
$configurationSuffix = if ($Configuration -eq "Debug") { "-debug" } else { "" }
$packageId = "helios-windows-x64-$Version-$shortCommit$configurationSuffix"
$finalDir = Join-Path $OutputDir $packageId
$zipPath = Join-Path $OutputDir "$packageId.zip"
$symbolsZipPath = Join-Path $OutputDir "$packageId-symbols.zip"
$releaseManifestPath = Join-Path $OutputDir "$packageId.release.json"
if ((Test-Path -LiteralPath $finalDir) -or (Test-Path -LiteralPath $zipPath) -or
    (Test-Path -LiteralPath "$zipPath.sha256") -or (Test-Path -LiteralPath "$zipPath.identity.json") -or (Test-Path -LiteralPath $symbolsZipPath) -or
    (Test-Path -LiteralPath $releaseManifestPath)) {
    throw "Closed package identity $packageId already exists in $OutputDir; refusing replacement."
}
$stagingRoot = Join-Path (Join-Path $OutputDir "staging") $packageId
$payload = Join-Path $stagingRoot "payload"
# Symbols are never embedded in the installer. They are useless at install time
# and are ~25 MB even after compression, so they ship as a separate artifact.
$symbolsRoot = Join-Path $OutputDir "$packageId-symbols"
if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $payload | Out-Null

# The driver and installer artifacts must be the same configuration as this
# bundle, or a "debug" bundle silently ships release binaries.
$driverConfigurationFile = Join-Path $DriverArtifact "configuration.txt"
if (Test-Path -LiteralPath $driverConfigurationFile -PathType Leaf) {
    $driverConfiguration = (Get-Content -LiteralPath $driverConfigurationFile -Raw).Trim()
    if ($driverConfiguration -ne $Configuration) {
        throw "Driver artifact is $driverConfiguration but this bundle is $Configuration."
    }
}
$installerConfigurationFile = Join-Path $InstallerArtifact "configuration.txt"
if (Test-Path -LiteralPath $installerConfigurationFile -PathType Leaf) {
    $installerConfiguration = (Get-Content -LiteralPath $installerConfigurationFile -Raw).Trim()
    if ($installerConfiguration -ne $Configuration) {
        throw "Installer artifact is $installerConfiguration but this bundle is $Configuration."
    }
}

$packageSource = Join-Path $RepoRoot "packaging\windows"
# Only the scripts the installer runs after extraction are embedded. The
# human-facing README is placed next to the final exe, not inside it, and the
# old Install-Helios.cmd launcher is gone now that the exe is the entry point.
foreach ($script in @("Install-Helios.ps1", "Uninstall-Helios.ps1", "Verify-Helios.ps1", "Helios-PackageCommon.ps1")) {
    Copy-Required (Join-Path $packageSource $script) (Join-Path $stagingRoot $script)
}
# The Rust skeleton is NOT copied into the payload; it is the template the
# packer appends the payload to at the end of this script.
$skeleton = Join-Path $InstallerArtifact "HeliosSetup.exe"
if (-not (Test-Path -LiteralPath $skeleton -PathType Leaf)) {
    throw "The installer skeleton is missing: $skeleton"
}

$driverOut = Join-Path $payload "driver"
foreach ($name in @("helios_kmd_render.inf", "helios_kmd_render.sys", "helios_umd.dll", "helios_umd12.dll", "helios_umd32.dll", "helios_umd12_32.dll", "toolchain.json")) {
    Copy-Required (Join-Path $DriverArtifact $name) (Join-Path $driverOut $name)
}
foreach ($name in @("helios_kmd_render.sys", "helios_umd.dll", "helios_umd12.dll", "helios_umd32.dll", "helios_umd12_32.dll")) {
    $info = (Get-Item -LiteralPath (Join-Path $driverOut $name)).VersionInfo
    if ($info.FileVersion -ne $Version -or $info.ProductVersion -ne $Version -or
        $info.ProductName -ne $metadata.HELIOS_PRODUCT -or $info.CompanyName -ne $metadata.HELIOS_PUBLISHER) {
        throw "$name has stale version/branding resources. Rebuild all five driver images from this checkout."
    }
}
$infText = Get-Content -LiteralPath (Join-Path $driverOut "helios_kmd_render.inf") -Raw
if ($infText -notmatch "(?im)^\s*DriverVer\s*=\s*([^,\r\n]+),\s*([^\r\n]+)\s*$") {
    throw "Driver INF has no parseable DriverVer field."
}
$driverDate = $Matches[1].Trim()
$infVersion = $Matches[2].Trim()
if ($infVersion -ne $Version) { throw "INF DriverVer version $infVersion differs from candidate $Version." }
try {
    $driverDateValue = [DateTime]::ParseExact($driverDate, @("M/d/yyyy", "MM/dd/yyyy"), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
} catch { throw "INF DriverVer date is invalid: $driverDate" }
foreach ($name in @("helios_kmd_render.sys", "helios_umd.dll", "helios_umd12.dll")) {
    Assert-HeliosPeArchitecture (Join-Path $driverOut $name) x64
}
foreach ($name in @("helios_umd32.dll", "helios_umd12_32.dll")) {
    Assert-HeliosPeArchitecture (Join-Path $driverOut $name) x86
}
foreach ($optional in @("helios_kmd_render.pdb", "helios_kmd_render.map", "helios_umd.pdb", "helios_umd12.pdb", "helios_umd32.pdb", "helios_umd12_32.pdb")) {
    $source = Join-Path $DriverArtifact $optional
    if (Test-Path -LiteralPath $source -PathType Leaf) { Copy-Required $source (Join-Path $symbolsRoot $optional) }
}
$installerPdb = Join-Path $InstallerArtifact "HeliosSetup.pdb"
if (Test-Path -LiteralPath $installerPdb -PathType Leaf) { Copy-Required $installerPdb (Join-Path $symbolsRoot "HeliosSetup.pdb") }

$mesaOut = Join-Path $payload "mesa"
foreach ($name in @("vulkan_virtio.dll", "libgallium_wgl.dll")) {
    Copy-Required (Join-Path $MesaArtifact $name) (Join-Path $mesaOut $name)
}
foreach ($dependency in Get-ChildItem -LiteralPath $MesaArtifact -Filter "lib*.dll" -File) {
    if ($dependency.Name -eq "libgallium_wgl.dll") { continue }
    Copy-Required $dependency.FullName (Join-Path $mesaOut $dependency.Name)
}
$mesaX86Out = Join-Path $mesaOut "x86"
foreach ($name in @("vulkan_virtio.dll", "libgallium_wgl.dll")) {
    Copy-Required (Join-Path $MesaX86Artifact $name) (Join-Path $mesaX86Out $name)
}
foreach ($dependency in Get-ChildItem -LiteralPath $MesaX86Artifact -Filter "lib*.dll" -File) {
    if ($dependency.Name -eq "libgallium_wgl.dll") { continue }
    Copy-Required $dependency.FullName (Join-Path $mesaX86Out $dependency.Name)
}

$openClOut = Join-Path $payload "opencl"
Copy-Required (Join-Path $OpenClArtifact "clvk.dll") (Join-Path $openClOut "clvk.dll")
$clvkPdb = Join-Path $OpenClArtifact "clvk.pdb"
if (Test-Path -LiteralPath $clvkPdb -PathType Leaf) { Copy-Required $clvkPdb (Join-Path $symbolsRoot "clvk.pdb") }

$loadersOut = Join-Path $payload "loaders"
Copy-Required (Join-Path $LoadersArtifact "vulkan-1.dll") (Join-Path $loadersOut "vulkan-1.dll")
Copy-Required (Join-Path $LoadersArtifact "OpenCL.dll") (Join-Path $loadersOut "OpenCL.dll")
Copy-Required (Join-Path $LoadersArtifact "x86\vulkan-1.dll") (Join-Path $loadersOut "x86\vulkan-1.dll")
foreach ($probe in @(
    "vulkan-smoke.exe",
    "vulkan-wsi-probe.exe",
    "d3d11-smoke.exe",
    "d3d12-smoke.exe",
    "d3d12-clear.exe",
    "opengl-smoke.exe",
    "opencl-smoke.exe",
    "opencl-gl-sharing-smoke.exe"
)) {
    Copy-Required (Join-Path $LoadersArtifact "smoke\$probe") (Join-Path $payload "smoke\$probe")
}
foreach ($probe in @("vulkan-smoke.exe", "vulkan-wsi-probe.exe", "opengl-smoke.exe", "d3d11-smoke.exe", "d3d12-smoke.exe", "d3d12-clear.exe")) {
    Copy-Required (Join-Path $LoadersArtifact "smoke\x86\$probe") (Join-Path $payload "smoke\x86\$probe")
}

foreach ($probe in Get-ChildItem -LiteralPath (Join-Path $payload "smoke") -Filter "*.exe" -File -Recurse) {
    $architecture = if ($probe.Directory.Name -eq "x86") { "x86" } else { "x64" }
    Assert-HeliosPeArchitecture $probe.FullName $architecture
}

$resolveCompatibilityOut = Join-Path $stagingRoot "compatibility\DaVinci Resolve"
foreach ($name in @(
    "atiadlxx.dll",
    "Resolve-CompatibilityCommon.ps1",
    "Install-Resolve-Compatibility.ps1",
    "Uninstall-Resolve-Compatibility.ps1",
    "README.md"
)) {
    Copy-Required (Join-Path $CompatibilityArtifact $name) (Join-Path $resolveCompatibilityOut $name)
}

# No VC++ redistributables are shipped: both UMDs are built with the static CRT
# (vkd3d `-Db_vscrt=mt` + crt-static), asserted in Build-Driver.ps1.

$licenseOut = Join-Path $stagingRoot "licenses"
foreach ($artifact in @($DriverArtifact, $MesaArtifact, $MesaX86Artifact, $OpenClArtifact, $LoadersArtifact, $CompatibilityArtifact)) {
    $artifactLicenses = Join-Path $artifact "licenses"
    if (Test-Path -LiteralPath $artifactLicenses -PathType Container) {
        New-Item -ItemType Directory -Force -Path $licenseOut | Out-Null
        Copy-Item -Path (Join-Path $artifactLicenses "*") -Destination $licenseOut -Recurse -Force
    }
}

$inf2Cat = Find-WindowsKitTool "Inf2Cat.exe"
$signTool = Find-WindowsKitTool "signtool.exe"
$catalog = Join-Path $driverOut "helios_kmd_render.cat"
Remove-Item -LiteralPath $catalog -Force -ErrorAction SilentlyContinue

$subject = "CN=$($metadata.HELIOS_PUBLISHER) $($metadata.HELIOS_PRODUCT) GitHub CI Test Signing $shortCommit"
$certificate = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject $subject `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyAlgorithm RSA `
    -KeyLength 3072 `
    -HashAlgorithm SHA256 `
    -KeyExportPolicy NonExportable `
    -NotAfter ([DateTime]::UtcNow.AddYears(2))
try {
    $certificateOut = Join-Path $stagingRoot "certificate\helios-ci-test.cer"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $certificateOut) | Out-Null
    Export-Certificate -Cert $certificate -FilePath $certificateOut -Type CERT | Out-Null
    Import-Certificate -FilePath $certificateOut -CertStoreLocation "Cert:\CurrentUser\Root" | Out-Null

    # The catalog hashes the SYS and all four UMDs. Sign those first, generate the
    # catalog over the final bytes, and sign the catalog last.
    Invoke-SignTool $signTool $certificate.Thumbprint (Join-Path $driverOut "helios_kmd_render.sys")
    Invoke-SignTool $signTool $certificate.Thumbprint (Join-Path $driverOut "helios_umd.dll")
    Invoke-SignTool $signTool $certificate.Thumbprint (Join-Path $driverOut "helios_umd12.dll")
    Invoke-SignTool $signTool $certificate.Thumbprint (Join-Path $driverOut "helios_umd32.dll")
    Invoke-SignTool $signTool $certificate.Thumbprint (Join-Path $driverOut "helios_umd12_32.dll")
    & $inf2Cat "/driver:$driverOut" "/os:10_X64" /uselocaltime
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $catalog -PathType Leaf)) {
        throw "Inf2Cat failed to produce the Helios catalog."
    }
    Invoke-SignTool $signTool $certificate.Thumbprint $catalog

    $signable = @(
        (Join-Path $openClOut "clvk.dll"),
        (Join-Path $loadersOut "vulkan-1.dll"),
        (Join-Path $loadersOut "x86\vulkan-1.dll"),
        (Join-Path $loadersOut "OpenCL.dll"),
        (Join-Path $resolveCompatibilityOut "atiadlxx.dll")
    )
    $signable += @(Get-ChildItem -LiteralPath $mesaOut -Filter "*.dll" -File -Recurse | ForEach-Object FullName)
    $signable += @(Get-ChildItem -LiteralPath (Join-Path $payload "smoke") -Filter "*.exe" -File -Recurse | ForEach-Object FullName)
    foreach ($file in $signable) { Invoke-SignTool $signTool $certificate.Thumbprint $file }

    $signedDriverImages = @(
        (Join-Path $driverOut "helios_kmd_render.sys"),
        (Join-Path $driverOut "helios_umd.dll"),
        (Join-Path $driverOut "helios_umd12.dll"),
        (Join-Path $driverOut "helios_umd32.dll"),
        (Join-Path $driverOut "helios_umd12_32.dll")
    )
    foreach ($file in $signable + $signedDriverImages + @($catalog)) {
        Assert-SignTool $signTool $file
    }
    foreach ($file in $signedDriverImages) {
        & $signTool verify /pa /v /c $catalog $file
        if ($LASTEXITCODE -ne 0) { throw "The signed catalog does not verify $([IO.Path]::GetFileName($file))." }
    }
} finally {
    Remove-Item -LiteralPath "Cert:\CurrentUser\Root\$($certificate.Thumbprint)" -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($certificate.Thumbprint)" -Force -ErrorAction SilentlyContinue
}

$files = @()
foreach ($file in Get-ChildItem -LiteralPath $stagingRoot -File -Recurse | Where-Object { $_.Name -ne "manifest.json" } | Sort-Object FullName) {
    $relative = $file.FullName.Substring($stagingRoot.Length + 1).Replace("\", "/")
    if ($relative -notlike "payload/*" -and $relative -notlike "certificate/*" -and
        $relative -notlike "compatibility/*" -and $relative -notin @("Install-Helios.ps1", "Uninstall-Helios.ps1", "Verify-Helios.ps1", "Helios-PackageCommon.ps1")) { continue }
    $architecture = if ($relative -match "(^|/)x86/" -or $relative -match "payload/driver/helios_umd(32|12_32)\.dll$") { "x86" }
        elseif ($relative -match "^payload/driver/" -or $relative -match "^payload/mesa/" -or $relative -match "^payload/loaders/" -or $relative -match "^payload/smoke/") { "x64" }
        else { "shared" }
    $files += [ordered]@{
        path = $relative
        architecture = $architecture
        configuration = $Configuration
        size = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    }
}

function Get-ManifestPayloadFiles([string]$Prefix) {
    return @($files | Where-Object { $_.path.StartsWith("payload/$Prefix/", [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { [ordered]@{ path = $_.path; sha256 = $_.sha256; size = $_.size } })
}
function Get-UpstreamVersion([string]$RepositoryPath, [string]$Commit) {
    $tag = & git -C $RepositoryPath describe --tags --exact-match $Commit 2>$null
    if ($LASTEXITCODE -eq 0 -and $tag) { return ([string]$tag).Trim() }
    return $Commit
}
$mesaReceipt = Get-Content -LiteralPath (Join-Path $MesaArtifact "source.json") -Raw | ConvertFrom-Json
$mesaX86Receipt = Get-Content -LiteralPath (Join-Path $MesaX86Artifact "source.json") -Raw | ConvertFrom-Json
if ($mesaReceipt.upstreamVersion -ne $mesaX86Receipt.upstreamVersion) {
    throw "Mesa x64 and x86 artifacts do not have the same upstream version."
}
$mesaFiles = @(Get-ManifestPayloadFiles "mesa" | Where-Object { $_.path -notlike "payload/mesa/x86/*" })
$mesaX86Files = Get-ManifestPayloadFiles "mesa/x86"
$driverPayloadFiles = Get-ManifestPayloadFiles "driver"
$openClPayloadFiles = Get-ManifestPayloadFiles "opencl"
$loaderPayloadFiles = Get-ManifestPayloadFiles "loaders"
$dxvkVersion = Get-UpstreamVersion (Join-Path $RepoRoot "dxvk-helios") $DxvkCommit
$vkd3dVersion = Get-UpstreamVersion (Join-Path $RepoRoot "vkd3d-proton-helios") $Vkd3dCommit

$manifest = [ordered]@{
    schemaVersion = 1
    productName = $metadata.HELIOS_PRODUCT
    publisher = $metadata.HELIOS_PUBLISHER
    packageId = $packageId
    version = $Version
    candidate = [ordered]@{
        candidateId = "$Version-$($candidateLock.sourceFingerprint.Substring(0, 16))-$Configuration"
        sourceFingerprint = $candidateLock.sourceFingerprint
        reservationRef = $candidateLock.reservationRef
        reservedSourceCommit = $candidateLock.sourceCommits.helios
    }
    architecture = "x64"
    configuration = $Configuration
    driverDate = $driverDateValue.ToString("yyyy-MM-dd")
    applicationArchitectures = @("x64", "x86")
    createdAtUtc = [DateTime]::UtcNow.ToString("o")
    source = [ordered]@{
        helios = $RepositoryCommit
        mesa = $MesaCommit
        dxvk = $DxvkCommit
        vkd3d = $Vkd3dCommit
        clvk = $ClvkCommit
        vulkanLoader = $VulkanLoaderCommit
        vulkanHeaders = $VulkanHeadersCommit
        openClLoader = $OpenClLoaderCommit
        openClHeaders = $OpenClHeadersCommit
    }
    signing = [ordered]@{
        mode = "test"
        subject = $subject
        thumbprint = $certificate.Thumbprint
        certificate = "certificate/helios-ci-test.cer"
    }
    components = [ordered]@{
        driver = [ordered]@{
            version = $Version
            direct3D = "DXVK D3D11 and vkd3d-proton D3D12 embedded WDDM UMDs"
            direct3D12DefaultEnabled = $true
            architectures = @("x64", "x86")
            preSigningSha256 = @($driverFiles | ForEach-Object { [ordered]@{ name = $_.name; architecture = $_.architecture; size = $_.size; sha256 = $_.sha256 } })
            payloadSha256 = $driverPayloadFiles
        }
        mesa = [ordered]@{
            version = [string]$mesaReceipt.upstreamVersion
            sourceCommit = $MesaCommit
            vulkan = "Venus"
            openGL = "Zink WGL ICD"
            architectures = @("x64", "x86")
            vulkanApiVersion = "1.4.352"
            payloadSha256 = @($mesaFiles + $mesaX86Files)
        }
        dxvk = [ordered]@{
            version = $dxvkVersion
            sourceCommit = $DxvkCommit
            embeddedIn = @("helios_umd.dll", "helios_umd32.dll")
            payloadSha256 = @($driverPayloadFiles | Where-Object { $_.path -match "helios_umd(32)?\.dll$" })
        }
        vkd3d = [ordered]@{
            version = $vkd3dVersion
            sourceCommit = $Vkd3dCommit
            embeddedIn = @("helios_umd12.dll", "helios_umd12_32.dll")
            payloadSha256 = @($driverPayloadFiles | Where-Object { $_.path -match "helios_umd12(_32)?\.dll$" })
        }
        openCl = [ordered]@{
            version = "git:$ClvkCommit"
            sourceCommit = $ClvkCommit
            implementation = "CLVK"
            onlineCompiler = $true
            architectures = @("x64")
            payloadSha256 = $openClPayloadFiles
        }
        loaders = [ordered]@{
            vulkanLoaderVersion = "git:$VulkanLoaderCommit"
            vulkanLoaderCommit = $VulkanLoaderCommit
            vulkanHeadersVersion = "git:$VulkanHeadersCommit"
            vulkanHeadersCommit = $VulkanHeadersCommit
            openClLoaderVersion = "git:$OpenClLoaderCommit"
            openClLoaderCommit = $OpenClLoaderCommit
            openClHeadersVersion = "git:$OpenClHeadersCommit"
            openClHeadersCommit = $OpenClHeadersCommit
            payloadSha256 = $loaderPayloadFiles
        }
        compatibility = [ordered]@{ davinciResolve = "App-local AMD ADL detection shim" }
    }
    files = $files
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $stagingRoot "manifest.json") -Encoding UTF8

# Finalize the self-contained installer. The Rust packer appends the whole
# payload folder (scripts, driver, Mesa, CLVK, loaders, certificate, manifest)
# to the skeleton, so the shipped artifact is one HeliosSetup.exe. The packer is
# a GUI-subsystem exe, so it must be waited on explicitly.
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
if (Test-Path -LiteralPath $finalDir) { throw "Closed package identity already exists: $finalDir" }
New-Item -ItemType Directory -Force -Path $finalDir | Out-Null
$selfContained = Join-Path $finalDir "HeliosSetup.exe"
$pack = Start-Process -FilePath $skeleton -ArgumentList @("--bundle", $stagingRoot, $selfContained) -Wait -PassThru
if ($pack.ExitCode -ne 0) {
    throw "The installer packer failed with exit code $($pack.ExitCode)."
}
if (-not (Test-Path -LiteralPath $selfContained -PathType Leaf)) {
    throw "The self-contained installer was not produced at $selfContained."
}
Copy-Item -LiteralPath (Join-Path $packageSource "README.md") -Destination $finalDir -Force

$zipPath = Join-Path $OutputDir "$packageId.zip"
if (Test-Path -LiteralPath $zipPath) { throw "Closed package archive already exists: $zipPath" }
Compress-Archive -LiteralPath $finalDir -DestinationPath $zipPath -CompressionLevel Optimal
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$zipHashPath = "$zipPath.sha256"
if (Test-Path -LiteralPath $zipHashPath) { throw "Package hash receipt already exists: $zipHashPath" }
Set-Content -LiteralPath $zipHashPath -Value "$zipHash  $([IO.Path]::GetFileName($zipPath))" -Encoding ascii
$zipIdentityPath = Join-Path $env:TEMP ("helios-package-identity-" + [guid]::NewGuid().ToString("N") + ".json")
try {
    [ordered]@{
        version = $Version
        component = "helios-package-archive"
        packageId = $packageId
        architecture = "x64+x86"
        configuration = $Configuration
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $zipIdentityPath -Encoding ascii
    & python (Join-Path $RepoRoot "tools\candidate_version.py") seal --identity-file $zipIdentityPath --artifact-file $zipPath --record-file "$zipPath.identity.json"
    if ($LASTEXITCODE -ne 0) { throw "Could not seal package archive identity." }
} finally {
    Remove-Item -LiteralPath $zipIdentityPath -Force -ErrorAction SilentlyContinue
}
Write-Host "Package: $zipPath"
Write-Host "SHA256: $zipHash"

# Separate symbols archive, produced only when the build actually emitted
# symbols. It is uploaded alongside the installer and, on a tagged release,
# published as its own asset.
if (Test-Path -LiteralPath $symbolsRoot -PathType Container) {
    $symbolsZip = Join-Path $OutputDir "$packageId-symbols.zip"
    if (Test-Path -LiteralPath $symbolsZip) { throw "Closed symbols identity already exists: $symbolsZip" }
    Compress-Archive -LiteralPath $symbolsRoot -DestinationPath $symbolsZip -CompressionLevel Optimal
    $symbolsHash = (Get-FileHash -LiteralPath $symbolsZip -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$symbolsZip.sha256" -Value "$symbolsHash  $([IO.Path]::GetFileName($symbolsZip))" -Encoding ascii
    Write-Host "Symbols: $symbolsZip"
}

$installerHash = (Get-FileHash -LiteralPath $selfContained -Algorithm SHA256).Hash.ToLowerInvariant()
$releaseManifest = [ordered]@{
    schemaVersion = 1
    packageId = $packageId
    candidateVersion = $Version
    configuration = $Configuration
    architectures = @("x64", "x86")
    source = [ordered]@{
        helios = $RepositoryCommit
        mesa = $MesaCommit
        dxvk = $DxvkCommit
        vkd3d = $Vkd3dCommit
        clvk = $ClvkCommit
        vulkanLoader = $VulkanLoaderCommit
        vulkanHeaders = $VulkanHeadersCommit
        openClLoader = $OpenClLoaderCommit
        openClHeaders = $OpenClHeadersCommit
        sourceFingerprint = $candidateLock.sourceFingerprint
    }
    driverDate = $driverDateValue.ToString("yyyy-MM-dd")
    artifacts = @(
        [ordered]@{ name = "HeliosSetup.exe"; size = (Get-Item -LiteralPath $selfContained).Length; sha256 = $installerHash },
        [ordered]@{ name = [IO.Path]::GetFileName($zipPath); size = (Get-Item -LiteralPath $zipPath).Length; sha256 = $zipHash }
    )
    components = $manifest.components
    packageFiles = $files
}
if (Test-Path -LiteralPath $releaseManifestPath) { throw "Release manifest identity already exists: $releaseManifestPath" }
$releaseManifest | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $releaseManifestPath -Encoding UTF8
Write-Host "Release manifest: $releaseManifestPath"
