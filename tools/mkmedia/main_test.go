package main

import (
	"bytes"
	"compress/flate"
	"encoding/binary"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	dir := t.TempDir()
	raw := []byte{0, 0, 255, 255, 0, 248, 224, 7, 31, 0, 0, 0, 255, 255, 0, 248}
	audio := []byte{128, 150, 200, 128}
	input := filepath.Join(dir, "frames")
	pcm := filepath.Join(dir, "audio")
	out := filepath.Join(dir, "media")
	os.WriteFile(input, raw, 0600)
	os.WriteFile(pcm, audio, 0600)
	old := os.Args
	defer func() { os.Args = old }()
	os.Args = []string{"mkmedia", input, pcm, "2", "2", "15", out}
	main()
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if string(data[:4]) != "TNV2" || binary.LittleEndian.Uint32(data[16:]) != 2 {
		t.Fatal("bad header")
	}
	for f := 0; f < 2; f++ {
		begin := 44 + int(binary.LittleEndian.Uint32(data[32+f*4:]))
		end := 44 + int(binary.LittleEndian.Uint32(data[36+f*4:]))
		reader := flate.NewReader(bytes.NewReader(data[begin:end]))
		decoded, err := io.ReadAll(reader)
		reader.Close()
		if err != nil || !bytes.Equal(decoded, raw[f*8:(f+1)*8]) {
			t.Fatal("frame round trip failed", f, err)
		}
	}
	if !bytes.Equal(data[len(data)-len(audio):], audio) {
		t.Fatal("PCM mismatch")
	}
}
