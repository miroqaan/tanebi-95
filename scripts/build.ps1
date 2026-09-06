[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')][string]$Profile = 'release',
    [switch]$QemuTest,
    [string]$LanguageRoot = '',
    [switch]$NoMedia
)
# 標準ビルドは system/*.tanebi をコンパイルする。
# kernel/src/*.rs と bootmgr/src/*.rs は旧実装の比較資料のみ。
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'build-native.ps1') -Profile $Profile -QemuTest:$QemuTest -LanguageRoot $LanguageRoot -NoMedia:$NoMedia
