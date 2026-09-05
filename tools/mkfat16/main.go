package main

import (
	"encoding/binary"
	"fmt"
	"os"
)

const (
	sectorSize        = 512
	sectorsPerImage   = 131072
	sectorsPerCluster = 4
	reservedSectors   = 1
	fatCount          = 2
	sectorsPerFAT     = 128
	rootEntries       = 512
	rootSectors       = rootEntries * 32 / sectorSize
	dataStartSector   = reservedSectors + fatCount*sectorsPerFAT + rootSectors
	imageSize         = sectorSize * sectorsPerImage
)

type imageFile struct {
	name    string
	data    []byte
	cluster uint16
}

func main() {
	if len(os.Args) != 8 {
		fmt.Fprintln(os.Stderr, "usage: mkfat16 <BOOTX64.EFI> <KERNEL.EFI> <SHELL.EFI> <DOOM.EFI> <DOOM2.WAD> <STARTUP.NSH> <image.img>")
		os.Exit(2)
	}
	files := []imageFile{
		{name: "BOOTX64 EFI", data: mustRead(os.Args[1])},
		{name: "KERNEL  EFI", data: mustRead(os.Args[2])},
		{name: "SHELL   EFI", data: mustRead(os.Args[3])},
		{name: "DOOM    EFI", data: mustRead(os.Args[4])},
		{name: "DOOM2   WAD", data: mustRead(os.Args[5])},
		{name: "STARTUP NSH", data: mustRead(os.Args[6])},
	}
	image, err := makeImage(files)
	if err != nil {
		fatal(err)
	}
	if err := os.WriteFile(os.Args[7], image, 0o644); err != nil {
		fatal(err)
	}
}

func mustRead(path string) []byte {
	data, err := os.ReadFile(path)
	if err != nil {
		fatal(err)
	}
	return data
}

func makeImage(files []imageFile) ([]byte, error) {
	clusterBytes := sectorSize * sectorsPerCluster
	nextCluster := 4
	for index := range files {
		files[index].cluster = uint16(nextCluster)
		clusters := (len(files[index].data) + clusterBytes - 1) / clusterBytes
		if clusters == 0 {
			clusters = 1
		}
		nextCluster += clusters
	}
	maxClusters := (sectorsPerImage - dataStartSector) / sectorsPerCluster
	if nextCluster >= maxClusters+2 {
		return nil, fmt.Errorf("TANEBI payloads are too large for the FAT16 image")
	}

	image := make([]byte, imageSize)
	writeBootSector(image)
	fat := make([]uint16, sectorsPerFAT*sectorSize/2)
	fat[0], fat[1] = 0xfff8, 0xffff
	fat[2], fat[3] = 0xffff, 0xffff
	for _, file := range files {
		clusters := (len(file.data) + clusterBytes - 1) / clusterBytes
		if clusters == 0 {
			clusters = 1
		}
		for offset := 0; offset < clusters; offset++ {
			cluster := int(file.cluster) + offset
			if offset == clusters-1 {
				fat[cluster] = 0xffff
			} else {
				fat[cluster] = uint16(cluster + 1)
			}
		}
		copy(image[clusterOffset(int(file.cluster)):], file.data)
	}
	for copyIndex := 0; copyIndex < fatCount; copyIndex++ {
		offset := (reservedSectors + copyIndex*sectorsPerFAT) * sectorSize
		for index, value := range fat {
			binary.LittleEndian.PutUint16(image[offset+index*2:], value)
		}
	}

	rootOffset := (reservedSectors + fatCount*sectorsPerFAT) * sectorSize
	writeEntry(image[rootOffset:], "TANEBI 95  ", 0x08, 0, 0)
	writeEntry(image[rootOffset+32:], "EFI        ", 0x10, 2, 0)
	for index, file := range files[1:] {
		writeEntry(image[rootOffset+(index+2)*32:], file.name, 0x20, file.cluster, uint32(len(file.data)))
	}
	writeDirectory(image, 2, 0, "BOOT       ", 3, 0)
	writeDirectory(image, 3, 2, files[0].name, files[0].cluster, uint32(len(files[0].data)))
	return image, nil
}

func writeBootSector(image []byte) {
	copy(image[0:3], []byte{0xeb, 0x3c, 0x90})
	copy(image[3:11], []byte("TANEBI95"))
	binary.LittleEndian.PutUint16(image[11:], sectorSize)
	image[13] = sectorsPerCluster
	binary.LittleEndian.PutUint16(image[14:], reservedSectors)
	image[16] = fatCount
	binary.LittleEndian.PutUint16(image[17:], rootEntries)
	binary.LittleEndian.PutUint16(image[19:], 0)
	image[21] = 0xf8
	binary.LittleEndian.PutUint16(image[22:], sectorsPerFAT)
	binary.LittleEndian.PutUint16(image[24:], 63)
	binary.LittleEndian.PutUint16(image[26:], 255)
	binary.LittleEndian.PutUint32(image[28:], 0)
	binary.LittleEndian.PutUint32(image[32:], sectorsPerImage)
	image[36], image[38] = 0x80, 0x29
	binary.LittleEndian.PutUint32(image[39:], 0x95090402)
	copy(image[43:54], []byte("TANEBI 95  "))
	copy(image[54:62], []byte("FAT16   "))
	image[510], image[511] = 0x55, 0xaa
}

func writeDirectory(image []byte, cluster, parent uint16, childName string, childCluster uint16, childSize uint32) {
	offset := clusterOffset(int(cluster))
	writeEntry(image[offset:], ".          ", 0x10, cluster, 0)
	writeEntry(image[offset+32:], "..         ", 0x10, parent, 0)
	attribute := byte(0x10)
	if childSize > 0 {
		attribute = 0x20
	}
	writeEntry(image[offset+64:], childName, attribute, childCluster, childSize)
}

func writeEntry(target []byte, name string, attribute byte, cluster uint16, size uint32) {
	if len(name) != 11 {
		panic("FAT16 names must be exactly 11 bytes")
	}
	copy(target[:11], []byte(name))
	target[11] = attribute
	binary.LittleEndian.PutUint16(target[26:], cluster)
	binary.LittleEndian.PutUint32(target[28:], size)
}

func clusterOffset(cluster int) int {
	return (dataStartSector + (cluster-2)*sectorsPerCluster) * sectorSize
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
