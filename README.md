# TANEBI 95

> A spark becomes a world.

[TANEBI](https://github.com/miroqaan/tanebi-lang) を使い、ブラウザーではなく x86-64 UEFI 環境で直接起動する自作 OS プロジェクトです。Rust の `no_std` カーネルが GOP からフレームバッファーのアドレスを取得し、`ExitBootServices` でファームウェアのブートサービスを終了した後、1990 年代風のデスクトップを直接描画します。

![TANEBI 95 のネイティブデスクトップ](docs/tanebi95-native.png)

## 特徴

- 64 MiB の FAT16 x86-64 UEFI 起動イメージ
- `ExitBootServices` 後のベアメタル実行
- GOP フレームバッファーへの直接描画
- PS/2 I/O ポート経由のキーボード・マウス入力とソフトウェアカーソル
- TANEBI スクリプトから生成する決定論的な起動マニフェスト
- TANEBI Studio、スタートメニュー、電源画面
- DOOM ARENA：再起動して UEFI DOOM と Freedoom Phase 2 を実行

## ビルド

```powershell
.\scripts\build.ps1
```

生成されるファイル：

- `build/esp/EFI/BOOT/BOOTX64.EFI`
- `build/tanebi95.img` — 64 MiB の FAT16 UEFI 起動イメージ

## 起動と操作

QEMU と x86-64 EDK2 ファームウェアが必要です。

```powershell
.\scripts\run.ps1
```

キーボード：

- `S`：スタートメニュー
- `T`：TANEBI Studio ウィンドウを開く／閉じる
- `Esc`：電源画面
- `D`：DOOM ARENA に再起動
- `V`：ネイティブメディアプレーヤーを開く（`Space`：再生／一時停止）

DOOM では方向キーで移動・旋回し、`Space` で射撃、`E` でドアを開きます。
ゲーム音声は現在無効です。
標準の 1280×800 モードでは、元の 320×200 画面を整数倍の 4 倍に拡大して全画面に表示します。
このモードが使えない場合は、現在の画面に収まる最大の整数倍率を使用します。ゲームの表示領域は、ステータスバーを残した最大サイズが既定です。

マウス：

- デスクトップの `TANEBI STUDIO` アイコンをクリック
- `START` ボタンとスタートメニューの項目をクリック
- Studio ウィンドウの閉じるボタンをクリック

現在の入力は PS/2 の相対座標方式です。QEMU 画面をクリックしてマウスをキャプチャーした後、ゲスト内のポインターを基準に操作します。
高速な移動も、パケットヘッダーの符号ビットを含む 9 ビット値として処理し、オーバーフローが示された軸は無視します。
ウィンドウを最小化してバックグラウンドで実行するには、`scripts/run.ps1 -SkipBuild -Background -MonitorPort 45454` を使います。画面を表示しないのは `HeadlessTest` のみです。

## 現在の実装範囲

DOOM はカーネル内のプロセスではありません。デスクトップが CMOS に起動先の選択値を書き込んで再起動すると、ブートマネージャーが EDK II Shell と UEFI DOOM を実行します。デスクトップもゲームも QEMU 仮想マシン内で動作します。ゲームを終了し、QEMU を起動し直すとデスクトップに戻ります。

ネイティブ版の Studio は、ビルド時に生成した TANEBI の実行結果を表示します。メディアプレーヤーは、ビルドに組み込んだローカル動画を再生します。インターネットや YouTube からの直接ストリーミング、一般的な MP4 ファイルの読み込みは、まだサポートしていません。

### ネイティブメディアプレーヤー

デスクトップの `MEDIA PLAYER` またはスタートメニューから開きます。再生／一時停止、停止、5 秒戻る／進む、シークバー、ミュート切り替えに対応しています。初期状態はミュートです。通常の QEMU 実行では `UNMUTE` で音声を有効にし、最小化して行うテストではスピーカーに出力しません。

映像は 640×360、RGB565、15 fps でフレームごとに DEFLATE 圧縮して保存し、カーネルが直接展開・描画します。音声は 22,050 Hz の符号なし 8 ビット・モノラル PCM を、SB16/ISA DMA のダブルバッファーで出力します。ファームウェアのブートサービス終了後も再生でき、ブラウザーやホスト側のプレーヤーは使用しません。

[指定の動画](https://www.youtube.com/watch?v=low-pfQAI0A&t=974s) の 16:14–16:44 の区間は、ローカルビルドにのみ組み込んでいます。第三者の映像・音源、およびそれらを組み込んだカーネルイメージは、この公開リポジトリにはコミットしません。新しくチェックアウトした環境では、動画を用意するまで `NO MEDIA` と表示されます。

```powershell
# 該当する 30 秒の動画ファイルをローカルに用意した場合
.\scripts\prepare-media.ps1 -SourceVideo .\build\player-source.mp4
.\scripts\build.ps1
# スピーカーに出力せず、PCM 出力をファイルで検証
.\scripts\run.ps1 -SkipBuild -Background -AudioLog build\media-audio.wav
```

`scripts/capture-desktop-clean.ps1 -Media` は、最小化した別の VM で内部フレームバッファーのみを撮影します。`scripts/render-native-fullframe.ps1 -Media` は、実際のクリック位置の表示と日本語解説を含む 2560×1600 の紹介動画を作成します。

このバージョンは、実際に UEFI から起動してファームウェアのブートサービスを終了するベアメタル Stage 1 です。その後はフレームバッファーメモリーへ直接描画し、キーボードのスキャンコードを PS/2 I/O ポートから読み取ります。

ビルド時に公開モジュール `github.com/miroqaan/tanebi-lang/cmd/tanebi@v0.1.0` が `system.tanebi` を実行し、その決定論的な結果をカーネルに組み込みます。TANEBI 自体を Ring 3 プロセスとして実行する機能は、ページテーブル・システムコール・プロセスローダーの実装後に取り組む予定です。

## 検証

```powershell
.\scripts\test.ps1
```

テストでは、PS/2 の移動値 262,144 通りとオーバーフロー処理、TANEBI マニフェスト、UEFI PE、FAT16 構造を検査し、QEMU 上で `ExitBootServices` 後のベアメタル動作を示すマーカーまで確認します。

## プロジェクト構成

```text
kernel/          Rust no_std UEFI カーネルとフレームバッファーデスクトップ
scripts/         ビルド、QEMU 起動、ネイティブ起動テスト
tools/mkfat16/   決定論的な FAT16 イメージビルダー
system.tanebi    TANEBI 起動プログラム
docs/            検証済みのネイティブ画面キャプチャー
```

本プロジェクトは独自のデスクトップであり、Microsoft Windows 95、その互換レイヤー、またはそのエミュレーターではありません。Microsoft のコード、商標画像、アセットは含みません。
