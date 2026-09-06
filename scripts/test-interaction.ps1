[CmdletBinding()]
param([string]$OutputDirectory = '', [switch]$SkipDoom)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repositoryRoot ('build\native-qa-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$qemu = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$firmware = 'C:\Program Files\qemu\share\edk2-x86_64-code.fd'
$imagePath = Join-Path $repositoryRoot 'build\tanebi95.img'
$serialPath = Join-Path $OutputDirectory 'serial.log'
$audioPath = Join-Path $OutputDirectory 'audio.wav'
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$listener.Stop()
$qemuArgs = @('-name','TANEBI native regression','-machine','q35','-m','256M','-snapshot',
    '-drive',"if=pflash,format=raw,readonly=on,file=$firmware",'-drive',"format=raw,file=$imagePath",
    '-display','none','-audiodev',"wav,id=media,path=$audioPath",'-device','sb16,audiodev=media',
    '-monitor',"tcp:127.0.0.1:$port,server=on,wait=off",'-serial',"file:$serialPath")
$start = [Diagnostics.ProcessStartInfo]::new($qemu)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
foreach ($argument in $qemuArgs) { $start.ArgumentList.Add($argument) }
$vm = [Diagnostics.Process]::Start($start)
$client = $null
try {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt 45) {
        if ($vm.HasExited) { throw "QEMU stopped unexpectedly: $($vm.ExitCode)" }
        if ((Test-Path -LiteralPath $serialPath) -and ((Get-Content -LiteralPath $serialPath -Raw) -match 'TANEBI95_MOUSE_READY')) { break }
        Start-Sleep -Milliseconds 200
    }
    if ($clock.Elapsed.TotalSeconds -ge 45) { throw 'Interactive boot timed out.' }
    $client = [Net.Sockets.TcpClient]::new('127.0.0.1',$port)
    $stream = $client.GetStream()
    $stream.ReadTimeout = 6000
    $writer = [IO.StreamWriter]::new($stream)
    $writer.AutoFlush = $true
    function Wait-Monitor {
        $reply = ''
        $buffer = [byte[]]::new(8192)
        while (-not $reply.EndsWith('(qemu) ')) {
            $n = $stream.Read($buffer,0,$buffer.Length)
            if ($n -eq 0) { throw 'Monitor closed.' }
            $reply += [Text.Encoding]::ASCII.GetString($buffer,0,$n)
        }
        return $reply
    }
    [void](Wait-Monitor)
    function Send-Monitor([string]$Command) {
        $writer.WriteLine($Command)
        $reply = Wait-Monitor
        if ($reply -match 'unknown command|Error:') { throw $reply }
    }
    function Capture([string]$Name) {
        $ppm = (Join-Path $OutputDirectory "$Name.ppm").Replace('\','/')
        Send-Monitor ('screendump "' + $ppm + '"')
        & ffmpeg -y -v error -i $ppm -frames:v 1 (Join-Path $OutputDirectory "$Name.png")
        if ($LASTEXITCODE -ne 0) { throw 'Screenshot conversion failed.' }
    }
    Capture '01-desktop'
    $dimensions = & ffprobe -v error -show_entries stream=width,height -of json (Join-Path $OutputDirectory '01-desktop.png') | ConvertFrom-Json
    if ($dimensions.streams[0].width -ne 1280 -or $dimensions.streams[0].height -ne 800) { throw 'Expected 1280x800 for this interaction fixture.' }
    $script:mouseTestX = 640
    $script:mouseTestY = 400
    function Move-Mouse([int]$X,[int]$Y) {
        while ($script:mouseTestX -ne $X -or $script:mouseTestY -ne $Y) {
            $dx = [Math]::Clamp($X-$script:mouseTestX,-90,90)
            $dy = [Math]::Clamp($Y-$script:mouseTestY,-90,90)
            Send-Monitor "mouse_move $dx $dy"
            $script:mouseTestX += $dx
            $script:mouseTestY += $dy
            Start-Sleep -Milliseconds 30
        }
    }
    function Click([int]$X,[int]$Y) {
        Move-Mouse $X $Y
        Send-Monitor 'mouse_button 1'
        Start-Sleep -Milliseconds 100
        Send-Monitor 'mouse_button 0'
        Start-Sleep -Milliseconds 160
    }
    Click 50 780
    Capture '02-start-menu'
    Click 110 530
    Click 60 480
    Capture '03-player-paused'
    Click 600 681
    Click 190 681
    Start-Sleep -Seconds 2
    Capture '04-player-playing'
    if ((Get-Content -LiteralPath $serialPath -Raw) -notmatch 'TANEBI95_AUDIO_PLAY') { throw 'SB16 playback did not start.' }
    Click 865 681
    Start-Sleep -Milliseconds 700
    Capture '05-player-seek'
    Click 290 681
    Capture '06-player-stopped'
    Click 1123 68
    Capture '07-desktop-restored'
    if (-not $SkipDoom) {
        Click 60 310
        $doomWait = [Diagnostics.Stopwatch]::StartNew()
        while ($doomWait.Elapsed.TotalSeconds -lt 30) {
            if ((Get-Content -LiteralPath $serialPath -Raw) -match 'TANEBI95_BOOT_DOOM') { break }
            Start-Sleep -Milliseconds 200
        }
        if ($doomWait.Elapsed.TotalSeconds -ge 30) { throw 'Desktop icon did not trigger DOOM boot.' }
        $gameWait = [Diagnostics.Stopwatch]::StartNew()
        while ($gameWait.Elapsed.TotalSeconds -lt 30) {
            if ((Get-Content -LiteralPath $serialPath -Raw) -match 'D_MainLoop') { break }
            Start-Sleep -Milliseconds 200
        }
        if ($gameWait.Elapsed.TotalSeconds -ge 30) { throw 'UEFI DOOM did not reach its game loop.' }
        # 起動時の画面ワイプ完了後に操作し、入力がゲームへ届くことを確認する。
        Start-Sleep -Seconds 4
        Capture '08-doom-boot'
        Send-Monitor 'sendkey up 600'
        Start-Sleep -Milliseconds 800
        Send-Monitor 'sendkey left 300'
        Start-Sleep -Milliseconds 500
        # このUEFIポートはフレームごとにキー状態を消すため、短い入力を反復する。
        foreach ($shot in 1..10) {
            Send-Monitor 'sendkey spc 80'
            Start-Sleep -Milliseconds 250
        }
        Start-Sleep -Milliseconds 800
        Capture '09-doom-play'
    }
    $writer.WriteLine('quit')
    if (-not $vm.WaitForExit(5000)) { $vm.Kill(); $vm.WaitForExit() }
    Write-Host "[ok] QEMU interaction capture complete: $OutputDirectory"
    Write-Host 'Review the captured actual framebuffer PNGs and the silent-local audio WAV.'
} finally {
    if ($client) { $client.Dispose() }
    if (-not $vm.HasExited) { $vm.Kill(); $vm.WaitForExit() }
    $vm.Dispose()
}
