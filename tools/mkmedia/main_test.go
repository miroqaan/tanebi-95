package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math/rand"
	"testing"
)

// Independent bounded reference decoder matching system/player.tanebi.
func decodeFrame(data []byte, size int) ([]byte, error) {
	if len(data) < 1 {
		return nil, fmt.Errorf("missing frame mode")
	}
	mode, at := data[0], 1
	out := make([]byte, 0, size)
	if mode == 0 {
		out = append(out, data[1:]...)
	} else if mode == 1 {
		for at < len(data) {
			if at+2 > len(data) {
				return nil, fmt.Errorf("truncated RLE tag")
			}
			tag := int(binary.LittleEndian.Uint16(data[at:]))
			at += 2
			count := (tag & 32767) + 1
			if len(out)+count*2 > size {
				return nil, fmt.Errorf("RLE output overflow")
			}
			if tag&32768 != 0 {
				if at+2 > len(data) {
					return nil, fmt.Errorf("truncated RLE pixel")
				}
				for n := 0; n < count; n++ {
					out = append(out, data[at:at+2]...)
				}
				at += 2
			} else {
				if at+count*2 > len(data) {
					return nil, fmt.Errorf("truncated RLE literals")
				}
				out = append(out, data[at:at+count*2]...)
				at += count * 2
			}
		}
	} else if mode == 2 {
		length := func(n int) (int, error) {
			if n == 15 {
				for {
					if at >= len(data) {
						return 0, fmt.Errorf("truncated LZ length")
					}
					b := int(data[at])
					at++
					n += b
					if b != 255 {
						break
					}
				}
			}
			return n, nil
		}
		for at < len(data) {
			token := int(data[at])
			at++
			literals, err := length(token >> 4)
			if err != nil || at+literals > len(data) || len(out)+literals > size {
				return nil, fmt.Errorf("invalid LZ literal length")
			}
			out = append(out, data[at:at+literals]...)
			at += literals
			if at == len(data) {
				break
			}
			if at+2 > len(data) {
				return nil, fmt.Errorf("truncated LZ distance")
			}
			distance := int(binary.LittleEndian.Uint16(data[at:]))
			at += 2
			count, err := length(token & 15)
			count += 4
			if err != nil || distance == 0 || distance > len(out) || len(out)+count > size {
				return nil, fmt.Errorf("invalid LZ match")
			}
			for n := 0; n < count; n++ {
				out = append(out, out[len(out)-distance])
			}
		}
	} else {
		return nil, fmt.Errorf("unknown codec")
	}
	if len(out) != size {
		return nil, fmt.Errorf("decoded %d bytes, expected %d", len(out), size)
	}
	return out, nil
}

func TestCodecs(t *testing.T) {
	rng := rand.New(rand.NewSource(95))
	for _, size := range []int{2, 4, 6, 28, 30, 32, 256, 65536, 460800} {
		for kind := 0; kind < 3; kind++ {
			raw := make([]byte, size)
			for n := range raw {
				if kind == 0 {
					raw[n] = byte(rng.Intn(256))
				} else if kind == 1 {
					raw[n] = byte((n / 1024) % 8)
				} else {
					raw[n] = byte(n % 7)
				}
			}
			for _, encoded := range [][]byte{append([]byte{0}, raw...), encodeRLE(raw), encodeLZ(raw)} {
				decoded, err := decodeFrame(encoded, size)
				if err != nil || !bytes.Equal(decoded, raw) {
					t.Fatalf("codec %d size %d pattern %d: %v", encoded[0], size, kind, err)
				}
			}
		}
	}
}

func TestRoundTrip(t *testing.T) {
	raw := []byte{0, 0, 255, 255, 0, 248, 224, 7, 31, 0, 0, 0, 255, 255, 0, 248}
	audio := []byte{128, 150, 200, 128}
	data, err := pack(raw, audio, 2, 2, 15)
	if err != nil {
		t.Fatal(err)
	}
	if string(data[:4]) != "TNV3" || binary.LittleEndian.Uint32(data[16:]) != 2 {
		t.Fatal("bad header")
	}
	for f := 0; f < 2; f++ {
		begin := 44 + int(binary.LittleEndian.Uint32(data[32+f*4:]))
		end := 44 + int(binary.LittleEndian.Uint32(data[36+f*4:]))
		decoded, err := decodeFrame(data[begin:end], 8)
		if err != nil || !bytes.Equal(decoded, raw[f*8:(f+1)*8]) {
			t.Fatal("frame round trip failed", f, err)
		}
	}
	if !bytes.Equal(data[len(data)-len(audio):], audio) {
		t.Fatal("PCM mismatch")
	}
}

func TestRejectMalformedFrames(t *testing.T) {
	for _, data := range [][]byte{nil, {3}, {0, 1}, {1, 255}, {1, 255, 255, 0, 0}, {2, 240}, {2, 0, 0, 0}, {2, 0, 1, 0}} {
		if _, err := decodeFrame(data, 16); err == nil {
			t.Fatalf("accepted malformed block %v", data)
		}
	}
}
