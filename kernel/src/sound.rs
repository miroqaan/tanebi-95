// Minimal SB16 unsigned 8-bit mono playback. Polling DMA keeps IRQs out of
// the early kernel; two halves are replenished only after DMA consumed them.
use crate::{inb, outb, player};
pub struct Sound {
    base: *mut u8,
    ready: bool,
    active: bool,
    revision: u64,
    next: usize,
    half: usize,
}
impl Sound {
    pub fn reserve() -> Self {
        let base = uefi::boot::allocate_pages(
            uefi::boot::AllocateType::MaxAddress(0x00ff_ffff),
            uefi::boot::MemoryType::LOADER_DATA,
            32,
        )
        .map(|p| ((p.as_ptr() as usize + 65535) & !65535) as *mut u8)
        .unwrap_or(core::ptr::null_mut());
        Self {
            base,
            ready: false,
            active: false,
            revision: u64::MAX,
            next: 0,
            half: 0,
        }
    }
    fn command(&self, value: u8) {
        for _ in 0..100000 {
            if unsafe { inb(0x22c) } & 0x80 == 0 {
                unsafe { outb(0x22c, value) };
                return;
            }
        }
    }
    pub fn init(&mut self, hz: u64) {
        if self.base.is_null() {
            return;
        }
        unsafe {
            outb(0x21, inb(0x21) | 0x20);
            outb(0x226, 1)
        }
        let end = player::ticks() + hz / 1000;
        while player::ticks() < end {
            core::hint::spin_loop()
        }
        unsafe { outb(0x226, 0) }
        for _ in 0..100000 {
            if unsafe { inb(0x22e) } & 0x80 != 0 && unsafe { inb(0x22a) } == 0xaa {
                self.ready = true;
                break;
            }
        }
        if self.ready {
            unsafe {
                outb(0x224, 0x22);
                outb(0x225, 0xff);
                outb(0x224, 0x04);
                outb(0x225, 0xff)
            }
            crate::serial_write("TANEBI95_SB16_READY\n");
        }
    }
    fn fill(&mut self, half: usize) {
        let audio = player::audio();
        for i in 0..32768 {
            let sample = audio.get(self.next + i).copied().unwrap_or(128);
            unsafe { core::ptr::write_volatile(self.base.add(half * 32768 + i), sample) }
        }
        self.next += 32768;
    }
    fn stop(&mut self) {
        self.command(0xd0);
        self.command(0xd3);
        unsafe { outb(0x0a, 5) };
        self.active = false;
    }
    pub fn service(&mut self, p: &player::Player) {
        if !self.ready {
            return;
        }
        if self.revision != p.revision {
            self.revision = p.revision;
            self.stop();
            if p.open && p.playing && !p.muted {
                self.next = p.sample();
                self.fill(0);
                self.fill(1);
                self.half = 0;
                let addr = self.base as usize;
                unsafe {
                    outb(0x0c, 0);
                    outb(0x0b, 0x59);
                    outb(0x02, addr as u8);
                    outb(0x02, (addr >> 8) as u8);
                    outb(0x83, (addr >> 16) as u8);
                    outb(0x0c, 0);
                    outb(0x03, 0xff);
                    outb(0x03, 0xff);
                    outb(0x0a, 1);
                }
                self.command(0x41);
                self.command((22050 >> 8) as u8);
                self.command(22050u16 as u8);
                self.command(0xd1);
                self.command(0xc6);
                self.command(0);
                self.command(0xff);
                self.command(0x7f);
                self.active = true;
                crate::serial_write("TANEBI95_AUDIO_PLAY\n");
            }
        }
        if self.active {
            unsafe { outb(0x0c, 0) };
            let low = unsafe { inb(0x03) } as usize;
            let high = unsafe { inb(0x03) } as usize;
            let half = (65535 - (low | (high << 8))) / 32768;
            if half != self.half {
                self.fill(self.half);
                self.half = half;
            }
            let _ = unsafe { inb(0x22e) };
        }
    }
}
