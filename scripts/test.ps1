[CmdletBinding()]
param([switch]$SkipQemu)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $repositoryRoot 'build'

& (Join-Path $PSScriptRoot 'build.ps1') -Profile release -QemuTest

$efi = Join-Path $buildRoot 'esp\EFI\BOOT\BOOTX64.EFI'
$image = Join-Path $buildRoot 'tanebi95.img'
$manifest = Join-Path $buildRoot 'system.manifest'

if ((Get-Item -LiteralPath $efi).Length -lt 4096) { throw 'UEFI executable is unexpectedly small.' }
$imageBytes = [System.IO.File]::ReadAllBytes($image)
if ($imageBytes.Length -ne 33554432) { throw "Unexpected image size: $($imageBytes.Length)" }
if ($imageBytes[510] -ne 0x55 -or $imageBytes[511] -ne 0xAA) { throw 'FAT boot signature is missing.' }
if (-not ((Get-Content -Raw -LiteralPath $manifest) -match 'STATUS=TANEBI BOOT SCRIPT OK')) {
    throw 'TANEBI boot manifest was not generated.'
}
Write-Host '[ok] TANEBI manifest, UEFI PE, and FAT16 image validated.'

if ($SkipQemu) { return }
& (Join-Path $PSScriptRoot 'run.ps1') -SkipBuild -HeadlessTest
