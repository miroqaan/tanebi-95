use crate::{BLACK, Color, DARK, FrameBuffer, NAVY, SILVER, TEAL, WHITE};

static DATA: &[u8] = include_bytes!(env!("TANEBI_MEDIA"));
struct DecodeBuffer(core::cell::UnsafeCell<[u8; 640 * 360 * 2]>);
// Only the single polling CPU uses this buffer; interrupts never access it.
unsafe impl Sync for DecodeBuffer {}
static DECODE: DecodeBuffer = DecodeBuffer(core::cell::UnsafeCell::new([0; 640 * 360 * 2]));
struct BackBuffer(core::cell::UnsafeCell<[u8; 1920 * 1200 * 4]>);
unsafe impl Sync for BackBuffer {}
static BACK: BackBuffer = BackBuffer(core::cell::UnsafeCell::new([0; 1920 * 1200 * 4]));
fn u32_at(p: usize) -> usize {
    DATA.get(p..p + 4)
        .map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]) as usize)
        .unwrap_or(0)
}
pub fn ticks() -> u64 {
    unsafe { core::arch::x86_64::_rdtsc() }
}
fn frames() -> usize {
    u32_at(16)
}
fn fps() -> usize {
    u32_at(12).max(1)
}
pub fn valid() -> bool {
    DATA.get(..4) == Some(b"TNV2")
        && u32_at(4) == 640
        && u32_at(8) == 360
        && frames() > 0
        && 32 + (frames() + 1) * 4 + u32_at(32 + frames() * 4) + u32_at(20) == DATA.len()
}
pub fn audio() -> &'static [u8] {
    if !valid() {
        return &[];
    }
    &DATA[DATA.len() - u32_at(20)..]
}

#[derive(Clone, Copy)]
pub struct Player {
    pub open: bool,
    pub playing: bool,
    pub muted: bool,
    pub position: usize,
    pub revision: u64,
    pub hz: u64,
    epoch: u64,
    start: usize,
}
impl Player {
    pub fn new(hz: u64) -> Self {
        Self {
            open: false,
            playing: false,
            muted: true,
            position: 0,
            revision: 0,
            hz,
            epoch: 0,
            start: 0,
        }
    }
    pub fn show(&mut self) {
        self.open = true;
        self.revision += 1;
    }
    pub fn toggle(&mut self) {
        if !valid() {
            return;
        }
        if self.position + 1 >= frames() {
            self.position = 0
        }
        self.playing = !self.playing;
        self.anchor();
    }
    fn anchor(&mut self) {
        self.start = self.position;
        self.epoch = ticks();
        self.revision += 1;
    }
    pub fn close(&mut self) {
        self.open = false;
        self.playing = false;
        self.anchor();
    }
    pub fn update(&mut self) -> bool {
        if !self.open || !self.playing || self.hz == 0 {
            return false;
        }
        let next = self.start
            + ((ticks().wrapping_sub(self.epoch) as u128 * fps() as u128 / self.hz as u128)
                as usize);
        let ended = next >= frames();
        if ended {
            self.playing = false;
            self.revision += 1;
        }
        let next = next.min(frames().saturating_sub(1));
        let changed = ended || next != self.position;
        self.position = next;
        changed
    }
    pub fn sample(&self) -> usize {
        self.position * 22050 / fps()
    }
    pub fn geometry(frame: &FrameBuffer) -> (usize, usize, usize, usize) {
        let w = 1000.min(frame.width.saturating_sub(80));
        let h = (w - 32) * 9 / 16 + 112;
        (
            (frame.width - w) / 2,
            frame.height.saturating_sub(h + 42) / 2,
            w,
            h,
        )
    }
    pub fn click(&mut self, frame: &FrameBuffer, px: usize, py: usize) -> bool {
        if !self.open {
            return false;
        }
        let (x, y, w, h) = Self::geometry(frame);
        if !(x..x + w).contains(&px) || !(y..y + h).contains(&py) {
            return false;
        }
        if (x + w - 28..x + w - 6).contains(&px) && (y + 6..y + 28).contains(&py) {
            self.close();
            return true;
        }
        let controls = y + h - 40;
        if (controls..controls + 28).contains(&py) {
            if (x + 12..x + 106).contains(&px) {
                self.toggle();
            } else if (x + 114..x + 204).contains(&px) {
                self.position = 0;
                self.playing = false;
                self.anchor();
            } else if (x + 212..x + 302).contains(&px) {
                self.position = self.position.saturating_sub(5 * fps());
                self.anchor();
            } else if (x + 310..x + 400).contains(&px) {
                self.position = (self.position + 5 * fps()).min(frames().saturating_sub(1));
                self.anchor();
            } else if (x + 408..x + 514).contains(&px) {
                self.muted = !self.muted;
                self.revision += 1;
            } else if (x + 530..x + w - 16).contains(&px) {
                self.position =
                    ((px - x - 530) * frames() / (w - 546)).min(frames().saturating_sub(1));
                self.anchor();
            }
        }
        true
    }
    pub fn draw(&self, frame: &mut FrameBuffer) {
        if !self.open {
            return;
        }
        let size = frame.width * frame.height * 4;
        if size > 1920 * 1200 * 4 {
            return;
        }
        let base = BACK.0.get().cast::<u8>();
        let mut back = FrameBuffer {
            base,
            size,
            width: frame.width,
            height: frame.height,
            stride: frame.width,
            rgb: frame.rgb,
        };
        self.draw_buffer(&mut back);
        let (x, y, w, h) = Self::geometry(frame);
        // Present the finished window only; decoding and clears are never visible.
        for row in y..(y + h).min(frame.height) {
            let dest = (row * frame.stride + x) * 4;
            let bytes = w.min(frame.width - x) * 4;
            if dest + bytes <= frame.size {
                unsafe {
                    core::ptr::copy_nonoverlapping(
                        base.add((row * frame.width + x) * 4),
                        frame.base.add(dest),
                        bytes,
                    )
                }
            }
        }
    }
    fn draw_buffer(&self, frame: &mut FrameBuffer) {
        if !self.open {
            return;
        }
        let (x, y, w, h) = Self::geometry(frame);
        frame.fill_rect(x, y, w, h, SILVER);
        frame.bevel(x, y, w, h, true);
        frame.fill_rect(x + 4, y + 4, w - 8, 26, NAVY);
        frame.text(x + 14, y + 12, "TANEBI MEDIA PLAYER - NATIVE", WHITE, 1);
        frame.fill_rect(x + w - 28, y + 6, 22, 22, SILVER);
        frame.bevel(x + w - 28, y + 6, 22, 22, true);
        frame.text(x + w - 21, y + 13, "X", BLACK, 1);
        frame.text(
            x + 16,
            y + 38,
            "YOUTUBE: low-pfQAI0A | OFFLINE EXCERPT 16:14 - 16:44",
            BLACK,
            1,
        );
        let (vx, vy, vw, vh) = (x + 16, y + 54, w - 32, (w - 32) * 9 / 16);
        frame.fill_rect(vx, vy, vw, vh, BLACK);
        if valid() {
            let mw = u32_at(4);
            let mh = u32_at(8);
            let base = 32 + (frames() + 1) * 4;
            let pos = base + u32_at(32 + self.position * 4);
            let end = base + u32_at(36 + self.position * 4);
            let decoded = unsafe { &mut *DECODE.0.get() };
            let mut decoder = miniz_oxide::inflate::core::DecompressorOxide::new();
            if pos > end || end > DATA.len() {
                return;
            }
            let (status, _, written) = miniz_oxide::inflate::core::decompress(
                &mut decoder,
                &DATA[pos..end],
                decoded,
                0,
                4,
            );
            if status != miniz_oxide::inflate::TINFLStatus::Done || written != mw * mh * 2 {
                return;
            }
            for pixel in 0..mw * mh {
                let c = u16::from_le_bytes([decoded[pixel * 2], decoded[pixel * 2 + 1]]);
                let color = Color(
                    (((c >> 11) & 31) * 255 / 31) as u8,
                    (((c >> 5) & 63) * 255 / 63) as u8,
                    ((c & 31) * 255 / 31) as u8,
                );
                let row = pixel / mw;
                let col = pixel % mw;
                let n = 1;
                let left = col * vw / mw;
                let top = row * vh / mh;
                frame.fill_rect(
                    vx + left,
                    vy + top,
                    (col + n) * vw / mw - left,
                    (row + 1) * vh / mh - top,
                    color,
                );
            }
        } else {
            frame.text(
                vx + 20,
                vy + 30,
                "NO MEDIA - RUN PREPARE-MEDIA.PS1",
                WHITE,
                2,
            );
        }
        let cy = y + h - 40;
        for (offset, bw, label) in [
            (12, 94, if self.playing { "PAUSE" } else { "PLAY" }),
            (114, 90, "STOP"),
            (212, 90, "-5 SEC"),
            (310, 90, "+5 SEC"),
            (408, 106, if self.muted { "UNMUTE" } else { "MUTE" }),
        ] {
            frame.fill_rect(x + offset, cy, bw, 28, SILVER);
            frame.bevel(x + offset, cy, bw, 28, true);
            frame.text(x + offset + 12, cy + 10, label, BLACK, 1);
        }
        let track = w - 546;
        frame.fill_rect(x + 530, cy + 8, track, 12, DARK);
        frame.fill_rect(
            x + 530,
            cy + 8,
            track * self.position / frames().max(1),
            12,
            TEAL,
        );
        let seconds = 974 + self.position / fps();
        let time = [
            b'0' + (seconds / 60 / 10) as u8,
            b'0' + (seconds / 60 % 10) as u8,
            b':',
            b'0' + (seconds % 60 / 10) as u8,
            b'0' + (seconds % 10) as u8,
        ];
        if let Ok(s) = core::str::from_utf8(&time) {
            frame.text(x + w - 80, y + 38, s, NAVY, 1);
        }
    }
}
