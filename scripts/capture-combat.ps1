$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root 'build\qemu-combat-take.mp4'
$ffmpeg = (Get-Command ffmpeg).Source
$rec = Start-Process -FilePath $ffmpeg -ArgumentList @('-y','-hide_banner','-loglevel','error','-f','gdigrab','-framerate','30','-i','title=QEMU','-t','38','-vf','crop=1280:800:0:25','-an','-c:v','libx264','-preset','veryfast','-crf','12','-pix_fmt','yuv420p',$output) -WindowStyle Hidden -PassThru
$c = [Net.Sockets.TcpClient]::new('127.0.0.1',45454)
$w = [IO.StreamWriter]::new($c.GetStream()); $w.AutoFlush=$true
function Key([string]$key,[int]$count=1) {
    for($i=0;$i -lt $count;$i++) { $w.WriteLine("sendkey $key 40"); Start-Sleep -Milliseconds 90 }
}
Start-Sleep -Seconds 1
Key up 45
Key e 3
Key up 28
for($i=0;$i -lt 7;$i++) {
    Key spc 5
    Key left 3
    Key spc 5
    Key right 6
    Key spc 5
    Key left 3
}
$w.Dispose(); $c.Dispose()
$rec.WaitForExit()
Write-Output $output
