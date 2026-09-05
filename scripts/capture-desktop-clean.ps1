$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'build\clean-capture'
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item (Join-Path $root 'build\tanebi95.img') (Join-Path $out 'capture.img') -Force
$qemu='C:\Program Files\qemu\qemu-system-x86_64.exe'
$args=@('-name','"TANEBI 95 capture"','-machine','q35','-m','256M','-drive','"if=pflash,format=raw,readonly=on,file=C:\Program Files\qemu\share\edk2-x86_64-code.fd"','-drive',('"format=raw,file='+$out+'\capture.img"'),'-display','gtk,zoom-to-fit=on','-audiodev','none,id=muted','-monitor','tcp:127.0.0.1:45455,server=on,wait=off','-serial',('"file:'+ $out+'\serial.log"'))
$vm=Start-Process $qemu -ArgumentList $args -WindowStyle Minimized -PassThru
$c=$null; $encoder=$null
try {
    for($i=0;$i -lt 100;$i++) {
        if((Test-Path "$out\serial.log") -and ((Get-Content "$out\serial.log" -Raw) -match 'MOUSE_READY')) { break }
        Start-Sleep -Milliseconds 200
    }
    $c=[Net.Sockets.TcpClient]::new('127.0.0.1',45455)
    $stream=$c.GetStream(); $stream.ReadTimeout=5000
    $writer=[IO.StreamWriter]::new($stream); $writer.AutoFlush=$true
    function Wait-Prompt {
        $text=''; $buffer=[byte[]]::new(4096)
        while(-not $text.EndsWith('(qemu) ')) {
            $count=$stream.Read($buffer,0,$buffer.Length)
            if($count -eq 0){throw 'Monitor closed'}
            $text += [Text.Encoding]::ASCII.GetString($buffer,0,$count)
        }
    }
    Wait-Prompt
    function Send([string]$command) { $writer.WriteLine($command); Wait-Prompt }
    $psi=[Diagnostics.ProcessStartInfo]::new((Get-Command ffmpeg).Source)
    $psi.Arguments='-y -loglevel error -f image2pipe -vcodec ppm -framerate 10 -i - -an -c:v libx264 -preset fast -crf 12 -pix_fmt yuv420p "'+$out+'\desktop.mp4"'
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.RedirectStandardInput=$true
    $encoder=[Diagnostics.Process]::Start($psi)
    $points=@(
        @{F=0;X=640;Y=400}, @{F=20;X=1105;Y=133},
        @{F=35;X=1105;Y=133}, @{F=55;X=50;Y=780},
        @{F=70;X=50;Y=780}, @{F=85;X=110;Y=530},
        @{F=110;X=110;Y=530}, @{F=130;X=1105;Y=133},
        @{F=150;X=1105;Y=133}, @{F=170;X=60;Y=145},
        @{F=239;X=60;Y=145}
    )
    $clicks=@(22,57,87,132,172)
    $x=640; $y=400
    for($f=0;$f -lt 240;$f++) {
        $clock=[Diagnostics.Stopwatch]::StartNew()
        for($p=1;$p -lt $points.Count;$p++) {
            if($f -le $points[$p].F) {
                $a=$points[$p-1]; $b=$points[$p]; $t=($f-$a.F)/($b.F-$a.F)
                $nx=[int]($a.X+($b.X-$a.X)*$t); $ny=[int]($a.Y+($b.Y-$a.Y)*$t)
                if($nx -ne $x -or $ny -ne $y) {Send "mouse_move $($nx-$x) $($ny-$y)"}
                $x=$nx; $y=$ny; break
            }
        }
        if($clicks -contains $f){ Send 'mouse_button 1' }
        if($clicks -contains ($f-2)){ Send 'mouse_button 0' }
        Send ('screendump '+($out.Replace('\','/')+'/frame.ppm'))
        $bytes=[IO.File]::ReadAllBytes("$out\frame.ppm")
        $encoder.StandardInput.BaseStream.Write($bytes,0,$bytes.Length)
        $wait=100-$clock.ElapsedMilliseconds
        if($wait -gt 0){Start-Sleep -Milliseconds $wait}
    }
    $encoder.StandardInput.Close(); $encoder.WaitForExit()
    if($encoder.ExitCode -ne 0){throw 'Capture encoding failed'}
    Send 'mouse_button 0'
    $writer.WriteLine('quit')
    Write-Host "$out\desktop.mp4"
} finally {
    if($c){$c.Dispose()}
    if(-not $vm.HasExited){Stop-Process -Id $vm.Id}
}
