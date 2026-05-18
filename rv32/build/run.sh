qemu-system-riscv32 \
  -machine virt -m 256M \
  -kernel ../output/image.bin \
  -append ";;BootVol=SYS AosFS SD0#0;AosFS=OFSDiskVolumes.New OFSAosFiles.NewFS;MT=;MP=;MB=-3;DMASize=14800H;TraceModules=1;Display=;DDriver=DisplayLinear;DMode=;TracePort=1;" \
  -semihosting-config enable=on,target=native \
  -bios none \
  -serial stdio \
  -drive file=../output/drive.img,format=raw
