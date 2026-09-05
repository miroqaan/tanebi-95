// Pack decoded RGB565 frames and unsigned mono PCM for the no_std player.
package main

import (
	"bytes"
	"compress/flate"
	"encoding/binary"
	"fmt"
	"os"
	"strconv"
)

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
	if w < 1 || h < 1 || fps < 1 || len(raw)%(w*h*2) != 0 {
		panic("invalid frames")
	}
	count := len(raw) / (w * h * 2)
	var payload bytes.Buffer
	offsets := make([]uint32, count+1)
	for f := 0; f < count; f++ {
		offsets[f] = uint32(payload.Len())
		frame := raw[f*w*h*2 : (f+1)*w*h*2]
		compressor, _ := flate.NewWriter(&payload, flate.BestCompression)
		compressor.Write(frame)
		compressor.Close()
	}
	offsets[count] = uint32(payload.Len())
	var out bytes.Buffer
	out.WriteString("TNV2")
	for _, v := range []uint32{uint32(w), uint32(h), uint32(fps), uint32(count), uint32(len(audio)), 974, 22050} {
		binary.Write(&out, binary.LittleEndian, v)
	}
	binary.Write(&out, binary.LittleEndian, offsets)
	out.Write(payload.Bytes())
	out.Write(audio)
	if err := os.WriteFile(os.Args[6], out.Bytes(), 0644); err != nil {
		panic(err)
	}
	fmt.Printf("%dx%d, %d frames @ %d fps, %d bytes\n", w, h, count, fps, out.Len())
}
