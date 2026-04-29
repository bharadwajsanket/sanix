#!/bin/bash

set -e

echo "Building..."

nasm -f bin boot.asm -o boot.bin
nasm -f bin stage2.asm -o stage2.bin

echo "Creating disk image..."

dd if=/dev/zero of=os.bin bs=512 count=2880 2>/dev/null
dd if=boot.bin of=os.bin conv=notrunc 2>/dev/null
dd if=stage2.bin of=os.bin bs=512 seek=1 conv=notrunc 2>/dev/null

echo "Running..."

qemu-system-x86_64 \
  -drive file=os.bin,format=raw,if=floppy \
  -boot a \
  -m 512