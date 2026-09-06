// Host assertions for generated TANEBI code, not an OS implementation.
// Generate build/player-integration-check.rs with tanebi emit -target library first.
#[path = "../../build/player-integration-check.rs"]
mod native;

fn main() {
    let root = std::path::PathBuf::from(std::env::args().nth(1).expect("repository directory"));
    let raw = std::fs::read(root.join("build/player.rgb565")).expect("RGB565 source fixture");
    let pcm = std::fs::read(root.join("build/player.u8")).expect("PCM source fixture");
    let started = std::time::Instant::now();
    unsafe {
        native::tn_player_media_init();
        assert!(native::tn_MEDIA_VALID);
        let count = native::tn_MEDIA_FRAMES as usize;
        let size = (native::tn_MEDIA_WIDTH * native::tn_MEDIA_HEIGHT * 2) as usize;
        assert_eq!(raw.len(), count * size);
        for frame in 0..count {
            native::tn_PLAYER_POSITION = frame as u64;
            assert!(native::tn_player_decode(), "decode frame {frame}");
            let decoded = std::slice::from_raw_parts(core::ptr::addr_of!(native::tn_MEDIA_DECODE.0).cast::<u8>(), size);
            assert_eq!(decoded, &raw[frame * size..(frame + 1) * size], "frame {frame}");
        }
        // Random access never depends on a previously decoded frame.
        for frame in [count - 1, 0, count / 2, 1] {
            native::tn_PLAYER_POSITION = frame as u64;
            assert!(native::tn_player_decode());
            let decoded = std::slice::from_raw_parts(core::ptr::addr_of!(native::tn_MEDIA_DECODE.0).cast::<u8>(), size);
            assert_eq!(decoded, &raw[frame * size..(frame + 1) * size]);
        }
        // A failed decode must invalidate a previously successful cache entry.
        // Alter expected dimensions, never the immutable embedded asset bytes.
        native::tn_PLAYER_POSITION = 0;
        assert!(native::tn_player_decode());
        assert_eq!(native::tn_MEDIA_DECODED as usize, 0);
        let original_width = native::tn_MEDIA_WIDTH;
        native::tn_MEDIA_WIDTH = original_width + 1;
        native::tn_PLAYER_POSITION = 1;
        assert!(!native::tn_player_decode());
        assert_eq!(native::tn_MEDIA_DECODED as usize, usize::MAX);
        native::tn_MEDIA_WIDTH = original_width;
        native::tn_PLAYER_POSITION = 0;
        assert!(native::tn_player_decode());
        let recovered = std::slice::from_raw_parts(core::ptr::addr_of!(native::tn_MEDIA_DECODE.0).cast::<u8>(), size);
        assert_eq!(recovered, &raw[..size], "a failed frame must not poison the previous cached frame");
        let audio = std::slice::from_raw_parts(native::tn_MEDIA_AUDIO_BASE as *const u8, native::tn_MEDIA_AUDIO_LENGTH as usize);
        assert_eq!(audio, pcm);
        let mut dma = vec![0u8; 65536];
        native::tn_DMA_BASE = dma.as_mut_ptr() as u64;
        native::tn_SOUND_NEXT = 0;
        native::tn_sound_fill(0);
        native::tn_sound_fill(1);
        assert_eq!(&dma[..], &pcm[..65536]);
        native::tn_SOUND_NEXT = pcm.len() as u64 - 7;
        native::tn_sound_fill(0);
        assert_eq!(&dma[..7], &pcm[pcm.len() - 7..]);
        assert!(dma[7..32768].iter().all(|&sample| sample == 128));

        // Click routing, pause, seek bounds and stop preserve the original UI.
        native::tn_FB_WIDTH = 1280;
        native::tn_FB_HEIGHT = 800;
        native::tn_FB_STRIDE = 1280;
        native::tn_FB_RGB = 0;
        native::tn_PLAYER_POSITION = 0;
        native::tn_player_show();
        assert!(native::tn_player_click(190, 681));
        assert!(native::tn_PLAYER_PLAYING);
        native::tn_player_click(190, 681);
        assert!(!native::tn_PLAYER_PLAYING);
        native::tn_player_click(495, 681);
        assert_eq!(native::tn_PLAYER_POSITION as usize, 5 * native::tn_MEDIA_FPS as usize);
        native::tn_player_click(400, 681);
        assert_eq!(native::tn_PLAYER_POSITION as usize, 0);
        native::tn_player_click(1123, 681);
        assert!(native::tn_PLAYER_POSITION < native::tn_MEDIA_FRAMES);
        native::tn_player_click(290, 681);
        assert_eq!(native::tn_PLAYER_POSITION as usize, 0);
        assert!(!native::tn_PLAYER_PLAYING);

        let mut screen = vec![0u8; 1280 * 800 * 4];
        native::tn_FB_BASE = screen.as_mut_ptr() as u64;
        native::tn_FB_SIZE = screen.len() as u64;
        native::tn_draw_to_screen();
        native::tn_player_palette_init();
        native::tn_player_draw();
        native::tn_MOUSE_X = 640;
        native::tn_MOUSE_Y = 400;
        native::tn_toggle_cursor();
        let snapshot = screen.clone();
        native::tn_player_draw_live();
        assert_eq!(screen, snapshot, "live redraw preserves the visible cursor and complete frame");
        native::tn_player_click(1123, 68);
        assert!(!native::tn_PLAYER_OPEN);
        assert!(!native::tn_PLAYER_PLAYING);
        println!("TANEBI: {count} exact frame decodes, random seek, failed-decode cache recovery, identical PCM, DMA tails, player controls and cursor-safe live blit passed in {:?}", started.elapsed());
    }
}
