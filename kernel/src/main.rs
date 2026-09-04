#![no_main]
#![no_std]

mod font;

use core::hint::spin_loop;
use core::ptr::write_volatile;
use uefi::boot;
use uefi::prelude::*;
use uefi::proto::console::gop::{GraphicsOutput, PixelFormat};

const MANIFEST: &str = include_str!(env!("TANEBI_SYSTEM_MANIFEST"));

#[derive(Clone, Copy)]
struct Color(u8, u8, u8);

const TEAL: Color = Color(0, 128, 128);
const SILVER: Color = Color(192, 192, 192);
const WHITE: Color = Color(255, 255, 255);
const BLACK: Color = Color(0, 0, 0);
const NAVY: Color = Color(0, 0, 128);
const DARK: Color = Color(64, 64, 64);
const GRAY: Color = Color(128, 128, 128);
const YELLOW: Color = Color(255, 222, 64);
const RED: Color = Color(196, 36, 48);

struct FrameBuffer {
    base: *mut u8,
    size: usize,
    width: usize,
    height: usize,
    stride: usize,
    rgb: bool,
}

impl FrameBuffer {
    fn pixel(&mut self, x: usize, y: usize, color: Color) {
        if x >= self.width || y >= self.height {
            return;
        }
        let offset = (y * self.stride + x) * 4;
        if offset + 3 >= self.size {
            return;
        }
        let Color(red, green, blue) = color;
        let bytes = if self.rgb {
            [red, green, blue, 0]
        } else {
            [blue, green, red, 0]
        };
        unsafe {
            write_volatile(self.base.add(offset), bytes[0]);
            write_volatile(self.base.add(offset + 1), bytes[1]);
            write_volatile(self.base.add(offset + 2), bytes[2]);
            write_volatile(self.base.add(offset + 3), bytes[3]);
        }
    }

    fn fill_rect(&mut self, x: usize, y: usize, width: usize, height: usize, color: Color) {
        let x_end = x.saturating_add(width).min(self.width);
        let y_end = y.saturating_add(height).min(self.height);
        for py in y..y_end {
            for px in x..x_end {
                self.pixel(px, py, color);
            }
        }
    }

    fn line_h(&mut self, x: usize, y: usize, width: usize, color: Color) {
        self.fill_rect(x, y, width, 1, color);
    }

    fn line_v(&mut self, x: usize, y: usize, height: usize, color: Color) {
        self.fill_rect(x, y, 1, height, color);
    }

    fn bevel(&mut self, x: usize, y: usize, width: usize, height: usize, raised: bool) {
        if width < 2 || height < 2 {
            return;
        }
        let (light, shadow) = if raised { (WHITE, DARK) } else { (DARK, WHITE) };
        self.line_h(x, y, width, light);
        self.line_v(x, y, height, light);
        self.line_h(x, y + height - 1, width, shadow);
        self.line_v(x + width - 1, y, height, shadow);
        self.line_h(x + 1, y + height - 2, width - 2, BLACK);
        self.line_v(x + width - 2, y + 1, height - 2, BLACK);
    }

    fn text(&mut self, x: usize, y: usize, value: &str, color: Color, scale: usize) {
        let mut cursor = x;
        for byte in value.bytes() {
            if byte == b'\n' {
                cursor = x;
                continue;
            }
            let glyph = font::glyph(byte);
            for (row, bits) in glyph.iter().enumerate() {
                for column in 0..font::WIDTH {
                    if bits & (1 << (font::WIDTH - 1 - column)) != 0 {
                        self.fill_rect(
                            cursor + column * scale,
                            y + row * scale,
                            scale,
                            scale,
                            color,
                        );
                    }
                }
            }
            cursor += (font::WIDTH + 1) * scale;
        }
    }
}

#[derive(Clone, Copy)]
struct DesktopState {
    start_open: bool,
    studio_open: bool,
    power_open: bool,
}

fn manifest_value(key: &str, fallback: &'static str) -> &'static str {
    for line in MANIFEST.lines() {
        if let Some((name, value)) = line.split_once('=')
            && name == key
        {
            return value;
        }
    }
    fallback
}

fn draw_flame(frame: &mut FrameBuffer, x: usize, y: usize, scale: usize) {
    let shape = [
        0b00100u8, 0b01100, 0b01110, 0b11110, 0b11111, 0b11111, 0b01110, 0b00100,
    ];
    for (row, bits) in shape.iter().enumerate() {
        for column in 0..5 {
            if bits & (1 << (4 - column)) != 0 {
                let color = if row > 4 { YELLOW } else { RED };
                frame.fill_rect(x + column * scale, y + row * scale, scale, scale, color);
            }
        }
    }
}

fn draw_computer(frame: &mut FrameBuffer, x: usize, y: usize) {
    frame.fill_rect(x, y, 38, 29, SILVER);
    frame.bevel(x, y, 38, 29, true);
    frame.fill_rect(x + 5, y + 5, 28, 17, NAVY);
    frame.fill_rect(x + 12, y + 30, 14, 4, SILVER);
    frame.fill_rect(x + 7, y + 34, 24, 4, SILVER);
}

fn draw_folder(frame: &mut FrameBuffer, x: usize, y: usize) {
    frame.fill_rect(x + 3, y + 7, 16, 6, YELLOW);
    frame.fill_rect(x, y + 12, 40, 26, YELLOW);
    frame.bevel(x, y + 12, 40, 26, true);
}

fn draw_desktop_icon(frame: &mut FrameBuffer, x: usize, y: usize, label: &str, folder: bool) {
    if folder {
        draw_folder(frame, x + 10, y);
    } else {
        draw_computer(frame, x + 10, y);
    }
    frame.text(x, y + 45, label, WHITE, 1);
}

fn draw_window(frame: &mut FrameBuffer, state: DesktopState) {
    if !state.studio_open {
        return;
    }
    let width = (frame.width * 3 / 4)
        .max(520)
        .min(frame.width.saturating_sub(80));
    let height = (frame.height * 2 / 3)
        .max(330)
        .min(frame.height.saturating_sub(100));
    let x = (frame.width - width) / 2;
    let y = (frame.height - height) / 2 - 16;
    frame.fill_rect(x, y, width, height, SILVER);
    frame.bevel(x, y, width, height, true);
    frame.fill_rect(x + 4, y + 4, width - 8, 26, NAVY);
    draw_flame(frame, x + 9, y + 7, 2);
    frame.text(x + 31, y + 10, "TANEBI STUDIO - NATIVE", WHITE, 1);
    for (offset, symbol) in [(0, "_"), (23, "#"), (46, "X")] {
        let bx = x + width - 70 + offset;
        frame.fill_rect(bx, y + 7, 19, 19, SILVER);
        frame.bevel(bx, y + 7, 19, 19, true);
        frame.text(bx + 6, y + 12, symbol, BLACK, 1);
    }
    frame.text(x + 12, y + 40, "FILE  EDIT  RUN  HELP", BLACK, 1);
    frame.line_h(x + 5, y + 55, width - 10, WHITE);
    frame.line_h(x + 5, y + 56, width - 10, GRAY);

    let pane_y = y + 66;
    let pane_h = height.saturating_sub(105);
    let left_w = width * 56 / 100;
    frame.fill_rect(x + 10, pane_y, left_w - 15, pane_h, WHITE);
    frame.bevel(x + 9, pane_y - 1, left_w - 13, pane_h + 2, false);
    frame.fill_rect(x + left_w, pane_y, width - left_w - 10, pane_h, BLACK);
    frame.bevel(
        x + left_w - 1,
        pane_y - 1,
        width - left_w - 8,
        pane_h + 2,
        false,
    );

    let code_x = x + 20;
    let mut code_y = pane_y + 15;
    for line in [
        "# TANEBI BOOT PROGRAM",
        "LET FLAME = 3",
        "",
        "REPEAT FLAME {",
        "  PRINT \"WORLD AWAKENS\"",
        "}",
        "",
        "IF FLAME == 3 {",
        "  PRINT \"BOOT OK\"",
        "}",
    ] {
        frame.text(
            code_x,
            code_y,
            line,
            if line.starts_with('#') { TEAL } else { BLACK },
            1,
        );
        code_y += 15;
    }

    let output_x = x + left_w + 10;
    let mut output_y = pane_y + 15;
    for line in [
        "TANEBI OUTPUT",
        "",
        "WORLD AWAKENS",
        "WORLD AWAKENS",
        "WORLD AWAKENS",
        "BOOT OK",
        "",
        "RUNTIME: NATIVE",
        "HOST: RUST UEFI",
        "SCRIPT: TANEBI",
    ] {
        frame.text(
            output_x,
            output_y,
            line,
            if line == "BOOT OK" { YELLOW } else { WHITE },
            1,
        );
        output_y += 15;
    }

    frame.fill_rect(x + 8, y + height - 30, width - 16, 20, SILVER);
    frame.bevel(x + 8, y + height - 30, width - 16, 20, false);
    frame.text(
        x + 16,
        y + height - 24,
        manifest_value("STATUS", "TANEBI BOOT OK"),
        BLACK,
        1,
    );
}

fn draw_start_menu(frame: &mut FrameBuffer) {
    let taskbar_y = frame.height.saturating_sub(42);
    let width = 260usize.min(frame.width / 2);
    let height = 250usize.min(taskbar_y.saturating_sub(20));
    let y = taskbar_y.saturating_sub(height);
    frame.fill_rect(4, y, width, height, SILVER);
    frame.bevel(4, y, width, height, true);
    frame.fill_rect(8, y + 4, 34, height - 8, NAVY);
    frame.text(18, y + height - 18, "95", WHITE, 2);
    let mut item_y = y + 18;
    for item in [
        "TANEBI STUDIO",
        "MY COMPUTER",
        "DOCUMENTS",
        "REBOOT",
        "SHUT DOWN",
    ] {
        if item == "TANEBI STUDIO" {
            frame.fill_rect(48, item_y - 7, width - 56, 26, NAVY);
            frame.text(58, item_y, item, WHITE, 1);
        } else {
            frame.text(58, item_y, item, BLACK, 1);
        }
        item_y += 40;
    }
}

fn draw_power(frame: &mut FrameBuffer) {
    let width = 500usize.min(frame.width.saturating_sub(40));
    let height = 180usize.min(frame.height.saturating_sub(60));
    let x = (frame.width - width) / 2;
    let y = (frame.height - height) / 2;
    frame.fill_rect(x, y, width, height, SILVER);
    frame.bevel(x, y, width, height, true);
    frame.fill_rect(x + 4, y + 4, width - 8, 25, NAVY);
    frame.text(x + 12, y + 11, "SHUT DOWN TANEBI 95", WHITE, 1);
    draw_flame(frame, x + 28, y + 55, 4);
    frame.text(x + 95, y + 60, "IT IS NOW SAFE TO TURN OFF", BLACK, 1);
    frame.text(x + 95, y + 80, "YOUR TANEBI COMPUTER.", BLACK, 1);
    frame.text(x + 95, y + 112, "PRESS ESC TO RETURN", NAVY, 1);
}

fn render(frame: &mut FrameBuffer, state: DesktopState) {
    frame.fill_rect(0, 0, frame.width, frame.height, TEAL);
    draw_desktop_icon(
        frame,
        28,
        28,
        manifest_value("COMPUTER", "MY COMPUTER"),
        false,
    );
    draw_desktop_icon(frame, 28, 115, "TANEBI STUDIO", false);
    draw_desktop_icon(
        frame,
        28,
        202,
        manifest_value("DOCUMENTS", "DOCUMENTS"),
        true,
    );
    draw_desktop_icon(frame, 28, 289, "RECYCLE BIN", false);
    draw_window(frame, state);

    let taskbar_y = frame.height.saturating_sub(42);
    frame.fill_rect(0, taskbar_y, frame.width, 42, SILVER);
    frame.line_h(0, taskbar_y, frame.width, WHITE);
    frame.fill_rect(5, taskbar_y + 6, 102, 31, SILVER);
    frame.bevel(5, taskbar_y + 6, 102, 31, !state.start_open);
    draw_flame(frame, 11, taskbar_y + 10, 2);
    frame.text(35, taskbar_y + 16, "START", BLACK, 1);
    if state.studio_open {
        frame.fill_rect(116, taskbar_y + 6, 230, 31, SILVER);
        frame.bevel(116, taskbar_y + 6, 230, 31, false);
        frame.text(128, taskbar_y + 16, "TANEBI STUDIO", BLACK, 1);
    }
    let clock_x = frame.width.saturating_sub(100);
    frame.fill_rect(clock_x, taskbar_y + 6, 94, 31, SILVER);
    frame.bevel(clock_x, taskbar_y + 6, 94, 31, false);
    frame.text(clock_x + 24, taskbar_y + 16, "09:04", BLACK, 1);

    frame.text(
        frame.width.saturating_sub(250),
        18,
        manifest_value("SYSTEM", "TANEBI 95"),
        WHITE,
        2,
    );
    frame.text(
        frame.width.saturating_sub(250),
        43,
        manifest_value("MOTTO", "A SPARK BECOMES A WORLD"),
        WHITE,
        1,
    );
    frame.text(
        26,
        taskbar_y.saturating_sub(22),
        "S: START   T: STUDIO   ESC: POWER",
        WHITE,
        1,
    );

    if state.start_open {
        draw_start_menu(frame);
    }
    if state.power_open {
        draw_power(frame);
    }
}

#[entry]
fn main() -> Status {
    uefi::helpers::init().unwrap();
    serial_init();
    serial_write("TANEBI95_UEFI_ENTERED\n");

    let handle = match boot::get_handle_for_protocol::<GraphicsOutput>() {
        Ok(handle) => handle,
        Err(_) => return Status::UNSUPPORTED,
    };
    let mut gop = match boot::open_protocol_exclusive::<GraphicsOutput>(handle) {
        Ok(gop) => gop,
        Err(_) => return Status::UNSUPPORTED,
    };
    let info = gop.current_mode_info();
    let (width, height) = info.resolution();
    let rgb = match info.pixel_format() {
        PixelFormat::Rgb => true,
        PixelFormat::Bgr => false,
        _ => return Status::UNSUPPORTED,
    };
    let stride = info.stride();
    let (base, size) = {
        let mut raw = gop.frame_buffer();
        (raw.as_mut_ptr(), raw.size())
    };
    let mut frame = FrameBuffer {
        base,
        size,
        width,
        height,
        stride,
        rgb,
    };
    #[allow(unused_mut)]
    let mut state = DesktopState {
        start_open: false,
        studio_open: true,
        power_open: false,
    };
    render(&mut frame, state);
    serial_write("TANEBI_MANIFEST_OK\n");
    serial_write("TANEBI95_FRAMEBUFFER_OK\n");

    // Release every firmware protocol before the operating-system handoff.
    // Beyond this point, TANEBI 95 owns execution and uses only hardware I/O.
    drop(gop);
    let _memory_map = unsafe { boot::exit_boot_services(None) };
    render(&mut frame, state);
    serial_write("TANEBI95_BARE_METAL_OK\n");

    #[cfg(feature = "qemu-test-exit")]
    {
        serial_write("TANEBI95_NATIVE_OK\n");
        qemu_exit();
        loop {
            spin_loop();
        }
    }

    #[cfg(not(feature = "qemu-test-exit"))]
    loop {
        if unsafe { inb(0x64) } & 0x01 == 0 {
            spin_loop();
            continue;
        }
        let scan_code = unsafe { inb(0x60) };
        if scan_code & 0x80 != 0 {
            continue;
        }
        match scan_code {
            0x1f => {
                state.start_open = !state.start_open;
                state.power_open = false;
            }
            0x14 => {
                state.studio_open = !state.studio_open;
                state.start_open = false;
                state.power_open = false;
            }
            0x01 => {
                state.power_open = !state.power_open;
                state.start_open = false;
            }
            _ => continue,
        }
        render(&mut frame, state);
    }

    #[allow(unreachable_code)]
    Status::SUCCESS
}

fn serial_init() {
    unsafe {
        outb(0x3f9, 0x00);
        outb(0x3fb, 0x80);
        outb(0x3f8, 0x03);
        outb(0x3f9, 0x00);
        outb(0x3fb, 0x03);
        outb(0x3fa, 0xc7);
        outb(0x3fc, 0x0b);
    }
}

fn serial_write(text: &str) {
    for byte in text.bytes() {
        unsafe {
            while inb(0x3fd) & 0x20 == 0 {
                spin_loop();
            }
            outb(0x3f8, byte);
        }
    }
}

#[cfg(feature = "qemu-test-exit")]
fn qemu_exit() {
    unsafe { outb(0xf4, 0x10) }
}

#[inline]
unsafe fn outb(port: u16, value: u8) {
    unsafe {
        core::arch::asm!("out dx, al", in("dx") port, in("al") value, options(nomem, nostack, preserves_flags));
    }
}

#[inline]
unsafe fn inb(port: u16) -> u8 {
    let value: u8;
    unsafe {
        core::arch::asm!("in al, dx", out("al") value, in("dx") port, options(nomem, nostack, preserves_flags));
    }
    value
}
