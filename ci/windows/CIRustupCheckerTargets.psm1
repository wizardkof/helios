Set-StrictMode -Version Latest
function Get-CIRustupCheckerTargets {
    param([Parameter(Mandatory)][string]$ReceiptDir)
    @(
        [pscustomobject]@{name='native';script='Assert-CIToolchain.ps1';parameters=@{ReceiptDir=(Join-Path $ReceiptDir 'checker-native')};dir=(Join-Path $ReceiptDir 'checker-native');receipt='toolchain.json'},
        [pscustomobject]@{name='driver';script='Assert-ComponentToolchain.ps1';parameters=@{Component='driver';ReceiptDir=(Join-Path $ReceiptDir 'checker-driver')};dir=(Join-Path $ReceiptDir 'checker-driver');receipt='pre-producer-tools.json'},
        [pscustomobject]@{name='package-pre';script='Assert-ComponentToolchain.ps1';parameters=@{Component='package';Phase='pre';ReceiptDir=(Join-Path $ReceiptDir 'checker-package-pre')};dir=(Join-Path $ReceiptDir 'checker-package-pre');receipt='pre-producer-tools.json'},
        [pscustomobject]@{name='package-post';script='Assert-ComponentToolchain.ps1';parameters=@{Component='package';Phase='post';ReceiptDir=(Join-Path $ReceiptDir 'checker-package-post')};dir=(Join-Path $ReceiptDir 'checker-package-post');receipt='post-producer-tools.json'}
    )
}
Export-ModuleMember -Function Get-CIRustupCheckerTargets
