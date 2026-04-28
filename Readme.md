### Oberon System 3 Multiboot Edition

This project modernizes the Kernel of Oberon System 3 (version 2.3.7) by migrating it from the original Oberon Boot Loader (OBL, written in assembler) to the Multiboot specification (handled in Oberon directly in the Kernel). By providing a modern C99-based toolchain and abstracting away legacy constraints, this project allows a historically significant operating system to be easily installed, configured, and booted in modern emulation environments like QEMU, as well as on native ARM-based single-board computers.

### Historical Context and Significance

Niklaus Wirth and Jürg Gutknecht designed Oberon in the late 1980s as a lean, unified programming language and operating system. By the mid-1990s, Oberon System 3 introduced the Gadgets component framework, offering a sophisticated graphical user interface and highly integrated development experience. While elegantly designed, the original system was tightly coupled to specific bare-metal hardware. 

Because the original environment can no longer run on modern PCs, preserving and evolving the system requires decoupling it from legacy bootloaders. This project breathes new life into System 3 by making it highly accessible to compiler enthusiasts, researchers, and systems programmers. Instead of wrestling with obsolete hardware, developers can explore a fully functional Oberon environment using standard virtual machines and a portable cross-compilation toolchain working on current operating systems.

### System Features

- Bootable via Multiboot; OBL assembler and Oberon0 no longer required.
- System tracing through the Host Console.
- Configuration strings are passed via the Multiboot information record and parsed directly by the kernel.
- A dedicated tool creates AosFs volumes and populates them with all necessary runtime files.
- There is a custom IDE with colored syntax, cross-referencing, and semantic navigation which runs on all current operating systems, available at https://github.com/rochus-keller/activeoberon/.

Here is a screenshot of the IDE and the running system.

![Oberon System and IDE](http://software.rochus-keller.ch/screenshot_oberon_system_and_ide.png)

### The C99 Toolchain

- A standalone C99 version of the OP2 Oberon compiler is available at https://github.com/rochus-keller/op2/.
- The OP2 compiler runs on any platform that provides a C99 compiler and the Boehm Garbage Collector.
- This compiler was transpiled directly from the original Oberon sources using the custom transpiler available at https://github.com/rochus-keller/activeoberon/.
- A new C99 version of the Oberon BootLinker also creates the multiboot header and code which sets up an initial stack to call the Kernel.

### Recent Milestones

- Assembler code was removed from all portable modules (replaced by regular Oberon or `SYSTEM` calls).
- Modules dependent on hardware-specific `SYSTEM` calls have been moved to the i386 (and arm32) directories.
- ARMv7 Architecture Support: The system has successfully been migrated to ARMv7. The full system natively boots and works as expected on QEMU 10.2 emulating the `raspi2b` machine, as well as **the physical Raspberry Pi Model 3b and Zero 2** (see below). 

![Oberon System on QEMU ARMv7](http://software.rochus-keller.ch/FullSystemArm_2026-04-01_20-14-38.png)

### Status on 2026-04-28

The system now also works on the [Raspberry Pi Zero 2](https://www.raspberrypi.com/products/raspberry-pi-zero-2-w/)! What initially seemed harmless turned out, once again, to be a weeks-long ordeal. According to the trace log, the keyboard and mouse were detected. But the mouse cursor wouldn’t move. Over time, it became clear that a whole cascade of new problems needed to be resolved. Although the Zero 2 essentially has the same hardware architecture as the 3b, there were several significant differences. Every attempt to fix the USB stack seemed to lead nowhere. After several iterations of diagnostics it finally became clear that there were actually several separate bugs hiding behind the same symptom, each one masking the other.

The first culprit was in UsbDriver.Mod; the Pi Zero 2 W talks to USB devices directly, without the LAN9514 hub that had quietly papered over timing and speed-detection problems on the Pi 3B; important inspiration came from the Linux and Ultibo dwc2 drivers. Once the driver was taught to handle low-speed interrupt endpoints properly and to detect port speed dynamically, valid mouse data finally started flowing; yet the cursor still didn't move. The real villain turned out to be DisplayLinear.Mod. On the Zero 2 W's 512 MB of RAM, the GPU places the framebuffer squarely inside the CPU's cacheable memory region, so every cursor update was dutifully written into cache but never seen by the system. A targeted MMU remap to mark those pages non-cacheable was the solution; and the cursor finally came to life. The keyboard worked as well, and I also added a few additional Lenovo product IDs for the trackpoint. 

Unfortunately these changes seem to impact the performance on QEMU, where keystrokes and mouse clicks seem to vanish in times; I will investigate this, but I think it is more important that it now runs on all targeted boards.


### Status on 2026-04-10

Finally it works on the [Raspberry Pi 3b](https://www.raspberrypi.com/products/raspberry-pi-3-model-b/)! See the screenshot below. Basically after three total redesigns of the USB driver. There were also some issues in Usb.Mod which made the hub throwing a stall, and a lot more issues in the bit and timing fiddling of the driver. When the mouse and key events eventually got through, a lot of timing optimizations were necessary. Relying on the standard OS tick was too coarse for USB 2.0 Hub microframes. The driver now bypasses the OS timer and directly reads the BCM2837's 1MHz hardware timer to execute exact 125µs and 20µs micro-waits during active transactions. To keep the OS running smoothly, macro-timing is now handled asynchronously. When a device responds with a NAK, the driver records the target nextPoll time and immediately yields back to the OS. However, the actual micro-sequence of fetching data from the Hub is executed synchronously to guarantee atomic completion. By default, the Oberon USB stack kills a device if an interrupt poll returns an error. The driver now safely absorbs these transient hardware errors, seamlessly resetting the pacing timer and trying again on the next polling cycle, preventing the keyboard or mouse from suddenly "dying" during fast typing. 

I was also able to add support for the trackpoint integrated with my Lenovo keyboard which required a (portable) change to UsbMouse.Mod. Some additional modifications assured compatibility with the old 128 MB SD cards of which I still have many on stock and which are very well suited for the Oberon system ;-) I also found that forcing the driver to 16 bit color makes the system feel much more fluid on the raspi than the default 32 bits. In addition, the kernel now handles traps similarly to the i386 system, i.e. it restores the processor context after an exception, using a dedicated trap stack to prevent stack overflows and UI deadlocks during trap reporting.

Finally, I made tests on the rpi zero 2; according to the log the system works, but I had issues with the hdmi mini adapter. I will follow-up on this later.

![Oberon System on Raspi 3b](http://software.rochus-keller.ch/OberonSystem3_on_Raspi3.jpg)

### Status on 2026-04-06

After several days of debugging directly on the rpi 3b hardware via Jtag, the SD card and display drivers work. There were many surprises, starting from the completely
different ATAGS string (which required a format and parser refactoring), unexpected alignment and cache handling requirements, different semihosting operators (finally
adding plain UART which even works much faster) and configuration syntax changes. The USB driver though is a completely different leage. The usual timing issues were
managable, even the PHY, gating and clock issues. It eventually also turned out that the hub cannot be operated at full speed, only at high speed, which required
the implementation of split transactions to correctly communicate with connected mouse/keyboard only running at full speed. But so far I still didn't manage to make it work.
The DWC2 controller is ready, the hub with 5 ports is detected, but the setup of the connected devices continues to fail. Now that my Easter break is over, I have to move on to something else and put this project on hold. Maybe I’ll come up with the right idea next week, or maybe someone else will give the driver a try (which would be very welcome).

Here is my setup at the moment when the display started working:

![Debugging Setup](http://software.rochus-keller.ch/Raspi3bJtagSetup.jpg)

### How to build

The scripts required to build the system, statically link the inner core modules, create and populate the AosFs drive and run the system on QEMU are found in the 
`i386/build` directory. The toolchain directory has first to be prepared with the `op2`, `multibootlinker` and `aosfstool`. Also an `output` and `output/drive` directory are 
assumed to run the scripts. Precompiled versions of the toolchain and the resulting system image are made available.
The `build_all.sh` script depends on a `Modules.txt` file, the contents of which is generated using the "Show dependency order" dialog of the mentioned IDE. 

For the ARM version of the system see the `arm32/build` directory. There is also a tool running on Linux to flash an SD card for the Raspi.

### Roadmap

- Work in progress: testing applications
- Check feasibility of migration to Olimex A20-OLinuXino and Beaglebone Black
- Migrate network driver
- Future: migrate the system to the RISC-V based ESP32-P4 architecture, particularly targeting the [new Olimex board](https://www.olimex.com/Products/IoT/ESP32-P4/ESP32-P4-PC/open-source-hardware).

