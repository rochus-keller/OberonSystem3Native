#!/bin/bash

set -e

# copy all source files to the drive staging
cp ../../rootfs/* ../output/drive
cp ../*.Mod ../output/drive
cp ../../portable/*.Mod ../output/drive

# Path to the list of modules
MODULES_FILE="Modules.txt"

# Loop through each line in the file
while IFS= read -r name || [[ -n "$name" ]]; do
    # Execute the command with the path prefix
    ../toolchain/op2 "../output/drive/$name"
done < "$MODULES_FILE"

../toolchain/multibootlinker --multiboot --enable-stack --base 10000 --autofix Kernel Disks PCI ATADisks OFS Files Modules OFSAosFiles OFSCacheVolumes OFSBoot OFSDiskVolumes

mv *.Obj ../output/drive
mv image.bin ../output

./add_files.sh ../output/drive.img ../output/drive

