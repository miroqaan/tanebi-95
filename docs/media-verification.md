# Native player verification

Verified on 2026-09-05 with Windows QEMU, q35, EDK2 and SB16.

- Native boot test reached `TANEBI95_BARE_METAL_OK` and the debug exit.
- Media is decoded after ExitBootServices. No host browser or video player is used.
- Local source: YouTube `low-pfQAI0A`, 16:14–16:44 excerpt; 640×360, 15 fps, 450 frames.
- Go packer round-trip test reconstructs both frames and PCM exactly.
- Mouse packet regression tests cover 262,144 delta combinations and overflow.
- Separate minimized VM recorded opening, play, unmute, pause, +5 seconds, resume, timeline seek, stop, close through real PS/2 input.
- Pause capture shows PLAY and a stopped timestamp. The cropped paused picture at 12.5/13.5 seconds has 69.9 dB PSNR (lossy recording noise only); playing pictures change.
- Serial log reports `TANEBI95_SB16_READY` and `TANEBI95_AUDIO_PLAY`.
- QEMU WAV output contains non-silent audio: mean -17.4 dB, peak -2.1 dB. Testing sent output to a WAV file, not speakers.
- Narrated introduction uses guest-only frame captures, synchronized click markers and 2560×1600 full-frame output. Host pointer is not captured.
- Smooth-pointer revision: guest-only capture is now 30 fps (720 desktop frames / 24 seconds), not 10 fps. Pending PS/2 input is drained before video work, and the pointer remains visible while a video frame is decoded offscreen.

Media payloads, WAV recordings and encoded videos remain in ignored `build/`. Only code is committed publicly. Use `prepare-media.ps1` with a locally supplied clip to reproduce the player payload.

Limitations: one built-in offline excerpt; no YouTube networking, generic MP4 decoder or file picker. Audio is 22,050 Hz unsigned 8-bit mono. Player is muted initially; UNMUTE enables output when QEMU uses a real audio backend.
