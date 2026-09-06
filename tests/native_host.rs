#![allow(static_mut_refs)]
// Test harness only: the implementation is generated from TANEBI.
#[path = "../build/generated/native-tests.rs"]
mod native;

#[test]
fn ps2_nine_bit_motion_and_overflow_exhaustive() {
    unsafe {
        for header in 0u64..256 {
            for value in 0u64..256 {
                for (sign, overflow) in [(0x10, 0x40), (0x20, 0x80)] {
                    let expected = if header & overflow != 0 { 0 }
                        else if header & sign != 0 { value as i64 - 256 }
                        else { value as i64 };
                    let magnitude = native::tn_mouse_motion_magnitude(header, value, sign, overflow);
                    let negative = native::tn_mouse_motion_negative(header, sign, overflow);
                    let actual = if negative { -(magnitude as i64) } else { magnitude as i64 };
                    assert_eq!(actual, expected, "header={header} value={value} sign={sign}");
                }
            }
        }
        assert_eq!(native::tn_mouse_apply_axis(10, 1280, 256, true), 0);
        assert_eq!(native::tn_mouse_apply_axis(1270, 1280, 255, false), 1279);
        assert_eq!(native::tn_mouse_apply_axis(4, 0, 200, false), 0);
    }
}

#[test]
fn framebuffer_clips_and_cursor_xor_restores_every_byte() {
    unsafe {
        let width = 640u64;
        let height = 480u64;
        let stride = width + 8;
        let size = (stride * height * 4) as usize;
        let mut storage = vec![0xa5u8; size + 128];
        native::tn_FB_BASE = storage.as_mut_ptr().add(64) as u64;
        native::tn_FB_SIZE = size as u64;
        native::tn_FB_WIDTH = width;
        native::tn_FB_HEIGHT = height;
        native::tn_FB_STRIDE = stride;
        native::tn_FB_RGB = 0;
        native::tn_draw_to_screen();
        native::tn_fill_rect(630, 470, u64::MAX, u64::MAX, 0x123456);
        native::tn_pixel(width, 0, 0xffffff);
        native::tn_pixel(0, height, 0xffffff);
        assert!(storage[..64].iter().all(|b| *b == 0xa5));
        assert!(storage[size + 64..].iter().all(|b| *b == 0xa5));
        for y in 0..height as usize {
            let padding = 64 + (y * stride as usize + width as usize) * 4;
            assert!(storage[padding..padding + 32].iter().all(|b| *b == 0xa5));
        }
        let before = storage.clone();
        native::tn_toggle_cursor_at(637, 477);
        native::tn_toggle_cursor_at(637, 477);
        assert_eq!(storage, before);
        native::tn_FB_BASE = 0;
        native::tn_DRAW_BASE = 0;
    }
}

#[test]
fn native_demo_is_computed_not_a_manifest_string() {
    unsafe { assert_eq!(native::tn_studio_demo(), 3); }
}
