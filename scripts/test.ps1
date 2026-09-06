[CmdletBinding()]
param([switch]$SkipQemu, [string]$LanguageRoot = '')
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'test-native.ps1') -SkipQemu:$SkipQemu -LanguageRoot $LanguageRoot
