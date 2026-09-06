// TNV3 independently seekable RGB565 frames and unsigned mono PCM.
// Frame modes: raw pixels (0), pixel RLE (1), byte-LZ (2, LZ4 token layout).
package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"os"
	"strconv"
)

func put16(dst []byte, value int) []byte {
	return append(dst, byte(value), byte(value>>8))
}

// High bit selects a repeated pixel; low 15 bits are count minus one.
func encodeRLE(frame []byte) []byte {
	result := []byte{1}
	pixels := len(frame) / 2
	value := func(p int) uint16 { return binary.LittleEndian.Uint16(frame[p*2:]) }
	for at := 0; at < pixels; {
		run := 1
		for at+run < pixels && run < 32768 && value(at+run) == value(at) {
			run++
		}
		if run >= 3 {
			result = put16(result, 0x8000|(run-1))
			result = put16(result, int(value(at)))
			at += run
			continue
		}
		start := at
		at += run
		for at < pixels && at-start < 32768 {
			if at+2 < pixels && value(at) == value(at+1) && value(at) == value(at+2) {
				break
			}
			at++
		}
		result = put16(result, at-start-1)
		result = append(result, frame[start*2:at*2]...)
	}
	return result
}

func appendLength(dst []byte, length int) []byte {
	for length >= 255 {
		dst = append(dst, 255)
		length -= 255
	}
	return append(dst, byte(length))
}

func hash4(data []byte, at int) uint32 {
	return (binary.LittleEndian.Uint32(data[at:]) * 2654435761) >> 16
}

func encodeLZ(frame []byte) []byte {
	result := []byte{2}
	var latest [65536]int
	anchor, at := 0, 0
	for at+4 <= len(frame) {
		hash := hash4(frame, at)
		previous := latest[hash] - 1
		latest[hash] = at + 1
		if previous < 0 || at-previous > 65535 || !bytes.Equal(frame[previous:previous+4], frame[at:at+4]) {
			at++
			continue
		}
		end := at + 4
		for end < len(frame) && frame[previous+end-at] == frame[end] {
			end++
		}
		literalLength, matchLength := at-anchor, end-at-4
		token := min(literalLength, 15)<<4 | min(matchLength, 15)
		result = append(result, byte(token))
		if literalLength >= 15 {
			result = appendLength(result, literalLength-15)
		}
		result = append(result, frame[anchor:at]...)
		result = put16(result, at-previous)
		if matchLength >= 15 {
			result = appendLength(result, matchLength-15)
		}
		for update := at + 1; update < end && update+4 <= len(frame); update++ {
			latest[hash4(frame, update)] = update + 1
		}
		at, anchor = end, end
	}
	if anchor < len(frame) || len(result) == 1 {
		literalLength := len(frame) - anchor
		result = append(result, byte(min(literalLength, 15)<<4))
		if literalLength >= 15 {
			result = appendLength(result, literalLength-15)
		}
		result = append(result, frame[anchor:]...)
	}
	return result
}

func pack(raw, audio []byte, width, height, fps int) ([]byte, error) {
	if width < 1 || width > 640 || height < 1 || height > 360 || fps < 1 || fps > 60 || len(raw) == 0 || len(raw)%(width*height*2) != 0 {
		return nil, fmt.Errorf("invalid frames")
	}
	if len(audio) == 0 {
		return nil, fmt.Errorf("empty PCM audio")
	}
	count := len(raw) / (width * height * 2)
	var payload bytes.Buffer
	offsets := make([]uint32, count+1)
	var rleBytes, lzBytes int
	var modes [3]int
	for f := 0; f < count; f++ {
		offsets[f] = uint32(payload.Len())
		frame := raw[f*width*height*2 : (f+1)*width*height*2]
		rle, lz := encodeRLE(frame), encodeLZ(frame)
		rleBytes += len(rle)
		lzBytes += len(lz)
		best := rle
		if len(lz) < len(best) {
			best = lz
		}
		if len(frame)+1 < len(best) {
			payload.WriteByte(0)
			payload.Write(frame)
			modes[0]++
		} else {
			payload.Write(best)
			modes[best[0]]++
		}
	}
	offsets[count] = uint32(payload.Len())
	var out bytes.Buffer
	out.WriteString("TNV3")
	for _, v := range []uint32{uint32(width), uint32(height), uint32(fps), uint32(count), uint32(len(audio)), 974, 22050} {
		binary.Write(&out, binary.LittleEndian, v)
	}
	binary.Write(&out, binary.LittleEndian, offsets)
	out.Write(payload.Bytes())
	out.Write(audio)
	if out.Len() > 40*1024*1024 {
		return nil, fmt.Errorf("packed media %d bytes exceeds the 40 MiB asset budget", out.Len())
	}
	fmt.Printf("TNV3 %dx%d, %d frames @ %d fps, %d bytes; raw/RLE/LZ frames %d/%d/%d; RLE-only %d bytes, LZ-only %d bytes\n", width, height, count, fps, out.Len(), modes[0], modes[1], modes[2], rleBytes, lzBytes)
	return out.Bytes(), nil
}

func main() {
	if len(os.Args) != 7 {
		panic("usage: mkmedia frames.rgb565 audio.u8 width height fps output.tmv")
	}
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	audio, err := os.ReadFile(os.Args[2])
	if err != nil {
		panic(err)
	}
	w, _ := strconv.Atoi(os.Args[3])
	h, _ := strconv.Atoi(os.Args[4])
	fps, _ := strconv.Atoi(os.Args[5])
	data, err := pack(raw, audio, w, h, fps)
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(os.Args[6], data, 0644); err != nil {
		panic(err)
	}
}
