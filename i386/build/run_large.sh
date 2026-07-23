qemu-system-i386 \
  -kernel ../output/image.bin \
  -append "BootVol=SYS AosFS IDE0;AosFS=OFSDiskVolumes.New OFSAosFiles.NewFS;MT=;MP=;MB=-3;DMASize=14800H;TraceModules=1;Display=;DDriver=DisplayLinear;DMode=00000147H;TraceConsole=1;" \
  -debugcon stdio \
  -netdev user,id=mynet0 \
  -device ne2k_pci,netdev=mynet0 \
  -audiodev driver=pa,id=pa1 \
  -device sb16,audiodev=pa1 \
  -drive file=../output/drive.img,format=raw 
  
# NOTE: Display=Displays. searches for Displays.Display.Obj; Display= searches for Display.Obj
