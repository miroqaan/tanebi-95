[CmdletBinding()]
param([switch]$SkipQemu, [string]$LanguageRoot = '')
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if (-not $LanguageRoot) { $LanguageRoot = Join-Path (Split-Path -Parent $repositoryRoot) 'tanebi-lang' }
$buildRoot = Join-Path $repositoryRoot 'build'
$generated = Join-Path $buildRoot 'generated'
Push-Location $LanguageRoot
try {
    & go test ./...
    if ($LASTEXITCODE -ne 0) { throw 'TANEBI language regression failed.' }
} finally { Pop-Location }
Push-Location $repositoryRoot
try {
    & go test ./...
    if ($LASTEXITCODE -ne 0) { throw 'OS build-tool regression failed.' }
} finally { Pop-Location }
try {
    & (Join-Path $PSScriptRoot 'build-native.ps1') -QemuTest -LanguageRoot $LanguageRoot
    $sources = @('uefi','kernel','font','input','desktop','player','sound') | ForEach-Object { Join-Path $repositoryRoot "system\$_.tanebi" }
    $compiler = Join-Path $generated 'tanebi.exe'
    $mediaPath = Join-Path $buildRoot 'player-native.tmv'
    if (-not (Test-Path -LiteralPath $mediaPath)) { $mediaPath = Join-Path $generated 'empty-media.tmv' }
    & $compiler emit -target library -o (Join-Path $generated 'native-tests.rs') -asset "MEDIA=$mediaPath" @sources
    if ($LASTEXITCODE -ne 0) { throw 'TANEBI host-test code generation failed.' }
    $testBinary = Join-Path $generated 'native-host-tests.exe'
    & rustc --edition=2024 --test -C opt-level=2 (Join-Path $repositoryRoot 'tests\native_host.rs') -o $testBinary
    if ($LASTEXITCODE -ne 0) { throw 'Host regression compilation failed.' }
    & $testBinary --test-threads=1
    if ($LASTEXITCODE -ne 0) { throw 'TANEBI native regression failed.' }
    $mediaFixturesAvailable = $true
    foreach ($fixture in @('player.rgb565', 'player.u8', 'player-native.tmv')) {
        if (-not (Test-Path -LiteralPath (Join-Path $buildRoot $fixture))) { $mediaFixturesAvailable = $false }
    }
    if ($mediaFixturesAvailable) {
        & (Join-Path $repositoryRoot 'tools\mkmedia\test-native.ps1') -LanguageRoot $LanguageRoot
        if ($LASTEXITCODE -ne 0) { throw 'TANEBI native media regression failed.' }
    } else {
        Write-Host '[skip] Native media fixture regression: local RGB565, PCM and TNV3 files are required.'
    }
    $imagePath = Join-Path $buildRoot 'tanebi95.img'
    $imageBytes = [IO.File]::ReadAllBytes($imagePath)
    if ($imageBytes.Length -ne 67108864) { throw 'Unexpected FAT16 image size.' }
    if ($imageBytes[510] -ne 0x55 -or $imageBytes[511] -ne 0xaa) { throw 'Invalid FAT16 boot signature.' }
    $provenance = Get-Content -Raw -LiteralPath (Join-Path $buildRoot 'native-provenance.json') | ConvertFrom-Json
    if ($provenance.sourceLanguage -ne 'TANEBI' -or $provenance.handwrittenRustKernelUsed) { throw 'Wrong kernel provenance.' }
    Write-Host '[ok] Native TANEBI provenance and FAT16 image.'
    if (-not $SkipQemu) { & (Join-Path $PSScriptRoot 'run.ps1') -SkipBuild -HeadlessTest }
} finally {
    # 失敗時も終了専用テスト版を残さず、通常の対話OSへ戻す。
    & (Join-Path $PSScriptRoot 'build-native.ps1') -LanguageRoot $LanguageRoot
}
