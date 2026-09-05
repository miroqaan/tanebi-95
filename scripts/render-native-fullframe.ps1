param([switch]$CleanInput)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root $(if($CleanInput){'build\native-clean'}else{'build\native-fullframe'})
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item C:\Windows\Fonts\YuGothR.ttc (Join-Path $out 'font.ttc') -Force
# Match the web introduction's full-bleed footage and brief orange chapter cards.
# Preserve the native 16:10 framebuffer without cropping the taskbar or stretching.
$scenes = @(
    @{File='tanebi95-native-final-raw.mp4'; Start=0; Duration=8; Crop=''; Title='01  TANEBI 95'; Text='タネビ95。QEMUでディスクから起動する、独自のネイティブOSです。ここからは実際の操作画面を紹介します。'},
    @{File='tanebi95-native-final-raw.mp4'; Start=8; Duration=10; Crop=''; Title='02  TANEBI Studio'; Text='スタジオには、タネビで書いた起動プログラムと、その実行結果を表示します。現在の結果はビルド時に生成したものです。'},
    @{File='tanebi95-native-final-raw.mp4'; Start=18; Duration=12; Crop=''; Title='03  デスクトップを操作'; Text='マウスでウィンドウを閉じ、左下のスタートメニューを開きます。大きく映した画面で、ポインターと操作の流れを追ってみてください。'},
    @{File='tanebi95-native-final-raw.mp4'; Start=30; Duration=9; Crop=''; Title='04  DOOMへ切り替え'; Text='メニューからドゥームを選ぶと、仮想マシンが再起動します。UEFI版のゲームを読み込み、フリードゥームのマップへ進みます。'},
    @{File='qemu-combat-take.mp4'; Start=8; Duration=30; Crop='crop=640:400:320:200,'; Title='05  DOOM — 実際の戦闘'; Text='ここからは実際の戦闘です。方向キーで移動と旋回、スペースで射撃、イーキーで扉を開きます。近づく敵を狙って反撃。体力や弾薬の変化も、画面下のステータスで確認できます。ゲーム音声はミュートして収録しています。'},
    @{File='tanebi95-native-final-raw.mp4'; Start=0; Duration=9; Crop=''; Title='06  次のステップ'; Text='現在は開発初期のネイティブOSです。ウェブ版にあった動画再生やネットワークは、まだ移植していません。小さな種火から、動く世界へ。'}
)
if($CleanInput) {
    $scenes=@(
        @{File='clean-capture\desktop.mp4';Start=0;Duration=10;Crop='';Title='01  デスクトップを操作';Text='タネビ95。これはQEMUで動くネイティブOSの実画面です。閉じるボタンをクリックし、スタートメニューからスタジオを開きます。オレンジの枠がクリックした場所です。';Clicks=@(@{T=2.2;X=1105;Y=133},@{T=5.7;X=50;Y=780},@{T=8.7;X=110;Y=530})},
        @{File='clean-capture\desktop.mp4';Start=10;Duration=14;Crop='';Title='02  TANEBI Studio';Text='ウィンドウを閉じ、今度はデスクトップのアイコンから開きます。スタジオに表示されるのは、ビルド時に実行したタネビのプログラムと結果です。マウスの動きと、実際に変わる画面をご覧ください。';Clicks=@(@{T=3.2;X=1105;Y=133},@{T=7.2;X=60;Y=145})},
        @{File='qemu-combat-take.mp4';Start=8;Duration=30;Crop='crop=640:400:320:200,';Title='03  DOOM — 実際の戦闘';Text='続いて、UEFI版ドゥームの実際の戦闘です。方向キーで移動と旋回、スペースで射撃、イーキーで扉を開きます。敵の攻撃に反撃しながら、体力と弾薬の変化にも注目してください。収録時のゲーム音声はミュートしています。'}
    )
}
for ($i=0; $i -lt $scenes.Count; $i++) {
    $scene=$scenes[$i]; $n=$i+1
    $audio=Join-Path $out "$n.mp3"
    & py -3.14 -m edge_tts --voice ja-JP-NanamiNeural --text $scene.Text --write-media $audio
    if ($LASTEXITCODE -ne 0) { throw 'Japanese narration failed' }
    $audioDuration=[double](& ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $audio)
    $duration=[math]::Max($scene.Duration,$audioDuration+0.4)
    [IO.File]::WriteAllText((Join-Path $out "$n.txt"),$scene.Title,[Text.UTF8Encoding]::new($false))
    $inputFile=Join-Path $root ('build\'+$scene.File)
    # Two-times integer scale for desktop text; four-times for original combat.
    $marks=''
    $speed=1.0
    if($CleanInput -and $scene.Clicks) {
        $speed=$duration/$scene.Duration
        $marks="setpts=$speed*PTS,"
    }
    foreach($click in $scene.Clicks) {
        $x=[math]::Max(0,$click.X-22); $y=[math]::Min(754,[math]::Max(0,$click.Y-22))
        $start=$click.T*$speed
        $end=$start+0.6
        $marks+="drawbox=x=${x}:y=${y}:w=44:h=44:color=0xffaa30:t=3:enable='between(t,$start,$end)',"
    }
    $vf=$scene.Crop+$marks+"scale=2560:1600:flags=neighbor,setsar=1,drawbox=x=1440:y=1260:w=1060:h=140:color=0x081226@0.88:t=fill:enable='lt(t,2.4)',drawbox=x=1440:y=1260:w=10:h=140:color=0xffaa30:t=fill:enable='lt(t,2.4)',drawtext=fontfile=font.ttc:textfile='$n.txt':fontcolor=white:fontsize=46:x=1480:y=1303:enable='lt(t,2.4)',tpad=stop_mode=clone:stop_duration=30"
    Push-Location $out
    try {
        & ffmpeg -y -hide_banner -loglevel error -ss $scene.Start -t $scene.Duration -i $inputFile -i $audio -vf $vf -af apad -t $duration -r 30 -c:v libx264 -preset fast -crf 14 -pix_fmt yuv420p -c:a aac -b:a 192k -ar 48000 "$n.mp4"
        if ($LASTEXITCODE -ne 0) { throw "Scene $n failed" }
    } finally { Pop-Location }
    Write-Host "Rendered scene $n/$($scenes.Count)"
}
$concat=Join-Path $out 'concat.txt'
[IO.File]::WriteAllLines($concat,(1..$scenes.Count | ForEach-Object {"file '$_.mp4'"}))
$output=Join-Path $root $(if($CleanInput){'build\TANEBI-95-native-ja-clean-clicks-1600p.mp4'}else{'build\TANEBI-95-native-ja-fullframe-1600p.mp4'})
& ffmpeg -y -hide_banner -loglevel error -f concat -safe 0 -i $concat -c copy -movflags +faststart $output
if ($LASTEXITCODE -ne 0) { throw 'Assembly failed' }
Write-Host $output
