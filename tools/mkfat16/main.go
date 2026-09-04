package main

import (
	"encoding/binary"
	"fmt"
	"os"
)

const (
	sectorSize        = 512
	sectorsPerImage   = 65536
	sectorsPerCluster = 4
	reservedSectors   = 1
	fatCount          = 2
	sectorsPerFAT     = 64
	rootEntries       = 512
	rootSectors       = rootEntries * 32 / sectorSize
	dataStartSector   = reservedSectors + fatCount*sectorsPerFAT + rootSectors
	imageSize         = sectorSize * sectorsPerImage
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: mkfat16 <BOOTX64.EFI> <image.img>")
		os.Exit(2)
	}
	payload, err := os.ReadFile(os.Args[1])
	if err != nil {
		fatal(err)
	}
	image, err := makeImage(payload)
	if err != nil {
		fatal(err)
	}
	if err := os.WriteFile(os.Args[2], image, 0o644); err != nil {
		fatal(err)
	}
}

func makeImage(payload []byte) ([]byte, error) {
	clusterBytes := sectorSize * sectorsPerCluster
	fileClusters := (len(payload) + clusterBytes - 1) / clusterBytes
	lastCluster := 3 + fileClusters
	maxClusters := (sectorsPerImage - dataStartSector) / sectorsPerCluster
	if lastCluster >= maxClusters {
		return nil, fmt.Errorf("EFI payload is too large for image")
	}

	image := make([]byte, imageSize)
	writeBootSector(image)
	fat := make([]uint16, sectorsPerFAT*sectorSize/2)
	fat[0], fat[1] = 0xfff8, 0xffff
	fat[2], fat[3] = 0xffff, 0xffff
	for cluster := 4; cluster <= lastCluster; cluster++ {
		if cluster == lastCluster {
			fat[cluster] = 0xffff
		} else {
			fat[cluster] = uint16(cluster + 1)
		}
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
	writeDirectory(image, 2, 0, "BOOT       ", 3)
	writeDirectory(image, 3, 2, "BOOTX64 EFI", 4)
	copy(image[clusterOffset(4):], payload)
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
	binary.LittleEndian.PutUint32(image[39:], 0x95090401)
	copy(image[43:54], []byte("TANEBI 95  "))
	copy(image[54:62], []byte("FAT16   "))
	image[510], image[511] = 0x55, 0xaa
}

func writeDirectory(image []byte, cluster, parent uint16, childName string, childCluster uint16) {
	offset := clusterOffset(int(cluster))
	writeEntry(image[offset:], ".          ", 0x10, cluster, 0)
	writeEntry(image[offset+32:], "..         ", 0x10, parent, 0)
	attribute := byte(0x10)
	size := uint32(0)
	if childName == "BOOTX64 EFI" {
		attribute = 0x20
		childCluster = 4
		size = uint32(lenFromData(image))
	}
	writeEntry(image[offset+64:], childName, attribute, childCluster, size)
}

func lenFromData(_ []byte) int {
	info, err := os.Stat(os.Args[1])
	if err != nil {
		fatal(err)
	}
	return int(info.Size())
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
