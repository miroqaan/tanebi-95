#![no_main]
#![no_std]

use core::hint::spin_loop;
use core::mem::MaybeUninit;
use uefi::boot::{self, LoadImageSource};
use uefi::prelude::*;
use uefi::proto::BootPolicy;
use uefi::proto::device_path::{DevicePath, build};
use uefi::proto::loaded_image::LoadedImage;

const DOOM_MAGIC: u8 = 0xd5;

#[entry]
fn main() -> Status {
    uefi::helpers::init().unwrap();
    serial_init();

    let doom = read_cmos(0x38) == DOOM_MAGIC;
    if doom {
        write_cmos(0x38, 0);
        serial_write("TANEBI95_BOOT_DOOM\n");
    } else {
        serial_write("TANEBI95_BOOT_DESKTOP\n");
    }

    let path = if doom {
        cstr16!(r"\SHELL.EFI")
    } else {
        cstr16!(r"\KERNEL.EFI")
    };

    match launch(path) {
        Ok(()) => Status::SUCCESS,
        Err(status) => {
            serial_write("TANEBI95_BOOT_FAILURE\n");
            status
        }
    }
}

fn launch(path: &uefi::CStr16) -> Result<(), Status> {
    let image_handle = boot::image_handle();
    let device_handle = {
        let loaded = boot::open_protocol_exclusive::<LoadedImage>(image_handle)
            .map_err(|error| error.status())?;
        loaded.device().ok_or(Status::NOT_FOUND)?
    };
    let device_path = boot::open_protocol_exclusive::<DevicePath>(device_handle)
        .map_err(|error| error.status())?;

    let mut storage = [MaybeUninit::<u8>::uninit(); 1024];
    let mut builder = build::DevicePathBuilder::with_buf(&mut storage);
    for node in device_path.node_iter() {
        builder = builder.push(&node).map_err(|_| Status::BAD_BUFFER_SIZE)?;
    }
    builder = builder
        .push(&build::media::FilePath { path_name: path })
        .map_err(|_| Status::BAD_BUFFER_SIZE)?;
    let full_path = builder.finalize().map_err(|_| Status::BAD_BUFFER_SIZE)?;
    drop(device_path);

    let child = boot::load_image(
        image_handle,
        LoadImageSource::FromDevicePath {
            device_path: full_path,
            boot_policy: BootPolicy::ExactMatch,
        },
    )
    .map_err(|error| error.status())?;
    boot::start_image(child).map_err(|error| error.status())
}

fn read_cmos(index: u8) -> u8 {
    unsafe {
        outb(0x70, index | 0x80);
        inb(0x71)
    }
}

fn write_cmos(index: u8, value: u8) {
    unsafe {
        outb(0x70, index | 0x80);
        outb(0x71, value);
    }
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
