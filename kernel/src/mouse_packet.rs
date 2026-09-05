// PS/2 motion is a signed 9-bit value. The sign is in the header, not
// bit 7 of the following byte: +200 must not turn into -56.
pub fn motion(packet: [u8; 3]) -> (isize, isize) {
    let [header, x, y] = packet;
    let dx = if header & 0x40 != 0 {
        0
    } else {
        x as isize - if header & 0x10 != 0 { 256 } else { 0 }
    };
    let dy = if header & 0x80 != 0 {
        0
    } else {
        y as isize - if header & 0x20 != 0 { 256 } else { 0 }
    };
    (dx, dy)
}

#[cfg(test)]
mod tests {
    use super::motion;
    #[test]
    fn all_nine_bit_deltas() {
        for x in -256isize..=255 {
            for y in -256isize..=255 {
                let h = 8 | if x < 0 { 16 } else { 0 } | if y < 0 { 32 } else { 0 };
                assert_eq!(motion([h, x as u8, y as u8]), (x, y));
            }
        }
    }
    #[test]
    fn overflow_is_ignored_per_axis() {
        assert_eq!(motion([0x48, 200, 10]), (0, 10));
        assert_eq!(motion([0x88, 200, 10]), (200, 0));
        assert_eq!(motion([0xc9, 255, 255]), (0, 0));
    }
}
