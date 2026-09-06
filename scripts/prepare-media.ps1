param(
    [Parameter(Mandatory=$true)][string]$SourceVideo,
    [double]$Start = 0,
    [ValidateRange(1,30)][int]$Duration = 30
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'build'
New-Item -ItemType Directory -Force $out | Out-Null
$source=(Resolve-Path -LiteralPath $SourceVideo).Path
& ffmpeg -y -loglevel error -ss $Start -i $source -t $Duration -vf 'fps=15,scale=640:360:flags=area' -pix_fmt rgb565le -f rawvideo "$out\player.rgb565"
if($LASTEXITCODE -ne 0){throw 'Video conversion failed'}
& ffmpeg -y -loglevel error -ss $Start -i $source -t $Duration -vn -ac 1 -ar 22050 -f u8 "$out\player.u8"
if($LASTEXITCODE -ne 0){throw 'Audio conversion failed (input must have audio)'}
$go=(Get-Command go -ErrorAction SilentlyContinue).Source
if(-not $go){$go=Join-Path $env:USERPROFILE 'sdk\go1.27.1\bin\go.exe'}
Push-Location $root
try {
    & $go run ./tools/mkmedia "$out\player.rgb565" "$out\player.u8" 640 360 15 "$out\player-native.tmv"
    if($LASTEXITCODE -ne 0){throw 'Media packing failed'}
} finally {Pop-Location}
Write-Host 'TNV3 local clip prepared (native TANEBI raw/RLE/LZ decoder). Run scripts/build.ps1 to embed it in the OS.'
