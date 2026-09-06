param([string]$LanguageRoot)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $LanguageRoot) { $LanguageRoot = Join-Path (Split-Path -Parent $root) 'tanebi-lang' }
$go = (Get-Command go -ErrorAction SilentlyContinue).Source
if (-not $go) { $go = Join-Path $env:USERPROFILE 'sdk\go1.27.1\bin\go.exe' }
$media = Join-Path $root 'build\player-native.tmv'
foreach ($name in @('player-native.tmv', 'player.rgb565', 'player.u8')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root ('build\' + $name)))) {
        throw "Local test fixture missing: $name. Prepare the source clip before this optional test."
    }
}
$generated = Join-Path $root 'build\player-integration-check.rs'
$sources = @('uefi', 'kernel', 'font', 'desktop', 'input', 'player', 'sound') | ForEach-Object {
    Join-Path $root ('system\' + $_ + '.tanebi')
}
Push-Location $LanguageRoot
try {
    & $go run ./cmd/tanebi emit -target library -asset "MEDIA=$media" -define TEST=0 -o $generated @sources
    if ($LASTEXITCODE -ne 0) { throw 'TANEBI host-library compilation failed.' }
} finally { Pop-Location }
$exe = Join-Path $root 'build\native-player-tests.exe'
& rustc --edition=2024 -C opt-level=2 (Join-Path $PSScriptRoot 'native_player_test.rs') -o $exe
if ($LASTEXITCODE -ne 0) { throw 'Host assertion harness compilation failed.' }
& $exe $root
if ($LASTEXITCODE -ne 0) { throw 'Native TANEBI player assertions failed.' }
