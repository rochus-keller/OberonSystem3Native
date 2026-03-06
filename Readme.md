### Oberon System 3 Multiboot Edition

This project modernizes the Kernel of Oberon System 3 (version 2.3.7) by migrating it from the original Oberon Boot Loader (OBL, written in assembler) to the Multiboot specification (handled in Oberon directly in the Kernel). By providing a modern C99-based toolchain and abstracting away legacy constraints, this project allows a historically significant operating system to be easily installed, configured, and booted in modern emulation environments like QEMU. 

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

### How to build

The scripts required to build the system, statically link the inner core modules, create and populate the AosFs drive and run the system on QEMU are found in the 
i386/build directory. The toolchain directory has first to be prepared with the op2, multibootlinker and aosfstool. Also an output and output/drive directory are 
assumed to run the scripts. Precompiled versions of the toolchain and the resulting system image are made available.
The buile_all.sh script depends on a Modules.txt file, the contens of which is generated using the "Show dependency order" dialog of the mentioned IDE. 


### Future Roadmap

- The immediate goal is to remove raw assembler code from all otherwise portable modules.
- The system will systematically reduce its reliance on hardware-specific SYSTEM module features.
- These architectural improvements will pave the way for porting the system to new target architectures like the Raspberry Pi.


