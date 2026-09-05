$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'build\native-video'
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item -LiteralPath 'C:\Windows\Fonts\YuGothR.ttc' -Destination (Join-Path $out 'meiryo.ttc') -Force
$scenes=@(
 @{File='tanebi95-native-final-raw.mp4';Start=18;Duration=14;Title='TANEBI 95 — ネイティブOS';Text='タネビ95。QEMUの仮想マシンで、ディスクイメージから起動する独自のOSです。画面の描画とマウス操作を、実際の実行画面で紹介します。';Doom=$false},
 @{File='tanebi95-native-final-raw.mp4';Start=28;Duration=14;Title='デスクトップからゲームへ';Text='スタートメニューとデスクトップをクリックして操作します。ドゥームを選ぶと再起動し、UEFI版のゲームへ切り替わります。';Doom=$false},
 @{File='qemu-combat-take.mp4';Start=8;Duration=30;Title='DOOM × Freedoom — 実プレイ';Text='フリードゥームのマップで実際にプレイしています。方向キーで移動と旋回、スペースで射撃、イーキーで扉を開きます。敵が接近して攻撃し、こちらも反撃します。弾薬や体力もゲームの進行に合わせて変わります。収録時のゲーム音声はミュートしています。';Doom=$true},
 @{File='tanebi95-native-final-raw.mp4';Start=0;Duration=14;Title='現在の実装と、これから';Text='現在は初期段階のOSです。スタジオにはビルド時の実行結果を表示します。動画再生やネットワークは、今後の実装です。小さな種火から、動く世界へ。';Doom=$false}
)
for($i=0;$i -lt $scenes.Count;$i++) {
 $s=$scenes[$i]; $n=$i+1
 $audio=Join-Path $out "$n.mp3"
 py -3.14 -m edge_tts --voice ja-JP-NanamiNeural --text $s.Text --write-media $audio
 if($LASTEXITCODE -ne 0){throw 'TTS failed'}
 $ad=[double](& ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $audio)
 $duration=[math]::Max($s.Duration,$ad+0.5)
 $title=Join-Path $out "$n.txt"
 [IO.File]::WriteAllText($title,$s.Title,[Text.UTF8Encoding]::new($false))
 $inputFile=Join-Path $root ('build\'+$s.File)
 $vf=if($s.Doom){'crop=640:400:320:200,scale=1280:800:flags=neighbor'}else{'scale=1280:800:flags=neighbor'}
 $vf+=",pad=1920:1080:320:130:color=0x101b27,drawtext=fontfile=meiryo.ttc:textfile='$n.txt':fontcolor=white:fontsize=42:x=(w-tw)/2:y=45,tpad=stop_mode=clone:stop_duration=20"
 Push-Location $out
 try { & ffmpeg -y -hide_banner -loglevel error -ss $s.Start -t $s.Duration -i $inputFile -i $audio -vf $vf -af apad -t $duration -r 30 -c:v libx264 -preset fast -crf 15 -pix_fmt yuv420p -c:a aac -b:a 192k "$n.mp4" } finally {Pop-Location}
 if($LASTEXITCODE -ne 0){throw 'Render failed'}
}
[IO.File]::WriteAllLines((Join-Path $out 'concat.txt'),@("file '1.mp4'","file '2.mp4'","file '3.mp4'","file '4.mp4'"))
& ffmpeg -y -hide_banner -loglevel error -f concat -safe 0 -i (Join-Path $out 'concat.txt') -c copy -movflags +faststart (Join-Path $root 'build\TANEBI-95-native-ja-1080p.mp4')
if($LASTEXITCODE -ne 0){throw 'Concat failed'}
