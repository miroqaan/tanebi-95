[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$Profile = 'release',
    [switch]$QemuTest,
    [string]$TanebiVersion = 'v0.1.0'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$kernelManifest = Join-Path $repositoryRoot 'kernel\Cargo.toml'
$buildRoot = Join-Path $repositoryRoot 'build'
$manifestOutput = Join-Path $buildRoot 'system.manifest'
$efiBootRoot = Join-Path $buildRoot 'esp\EFI\BOOT'
$imageOutput = Join-Path $buildRoot 'tanebi95.img'

function Resolve-Tool([string]$Name, [string[]]$Candidates) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($candidate in $Candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw "Required tool '$Name' was not found."
}

$go = Resolve-Tool 'go' @(
    (Join-Path $env:USERPROFILE 'sdk\go1.27.1\bin\go.exe'),
    'C:\Program Files\Go\bin\go.exe'
)
$cargo = Resolve-Tool 'cargo' @((Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'))
$rustup = Resolve-Tool 'rustup' @((Join-Path $env:USERPROFILE '.cargo\bin\rustup.exe'))

New-Item -ItemType Directory -Force -Path $buildRoot, $efiBootRoot | Out-Null

Write-Host 'Executing TANEBI boot program...'
$systemScript = Join-Path $repositoryRoot 'system.tanebi'
Push-Location $repositoryRoot
try {
    $tanebiCommand = "github.com/miroqaan/tanebi-lang/cmd/tanebi@$TanebiVersion"
    $manifestLines = & $go run $tanebiCommand $systemScript
    if ($LASTEXITCODE -ne 0) { throw 'TANEBI boot program failed.' }
}
finally {
    Pop-Location
}
[System.IO.File]::WriteAllLines($manifestOutput, $manifestLines, [System.Text.UTF8Encoding]::new($false))

Write-Host 'Building the Rust UEFI kernel...'
& $rustup target add x86_64-unknown-uefi
if ($LASTEXITCODE -ne 0) { throw 'Rust UEFI target installation failed.' }
$env:TANEBI_SYSTEM_MANIFEST = $manifestOutput
$cargoArgs = @('build', '--manifest-path', $kernelManifest, '--target', 'x86_64-unknown-uefi')
if ($Profile -eq 'release') { $cargoArgs += '--release' }
if ($QemuTest) { $cargoArgs += @('--features', 'qemu-test-exit') }
& $cargo @cargoArgs
if ($LASTEXITCODE -ne 0) { throw 'TANEBI 95 kernel build failed.' }

$kernelEfi = Join-Path $repositoryRoot "kernel\target\x86_64-unknown-uefi\$Profile\tanebi95-kernel.efi"
$bootEfi = Join-Path $efiBootRoot 'BOOTX64.EFI'
Copy-Item -LiteralPath $kernelEfi -Destination $bootEfi -Force

Write-Host 'Creating bootable FAT16 disk image...'
Push-Location $repositoryRoot
try {
    & $go run ./tools/mkfat16 $bootEfi $imageOutput
    if ($LASTEXITCODE -ne 0) { throw 'FAT16 image creation failed.' }
}
finally {
    Pop-Location
}

Write-Host "UEFI loader: $bootEfi"
Write-Host "Boot image: $imageOutput"
