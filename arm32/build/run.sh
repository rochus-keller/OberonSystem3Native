qemu-system-arm \
  -machine raspi2b \
  -kernel ../output/image.bin \
  -append ";;BootVol=SYS AosFS SD0#0;AosFS=OFSDiskVolumes.New OFSAosFiles.NewFS;MT=;MP=;MB=-3;DMASize=14800H;TraceModules=1;Display=;DDriver=DisplayLinear;DMode=;TracePort=1;Qemu=1;" \
  -semihosting-config enable=on,target=native \
  -serial stdio \
  -usb -device usb-kbd -device usb-mouse \
  -drive file=../output/drive.img,format=raw,if=sd
  
# NOTE: Display=Displays. searches for Displays.Display.Obj; Display= searches for Display.Obj
