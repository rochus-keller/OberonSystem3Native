MODULE SDDisks; (** non-portable *)
(**
 * ESP32-P4 SD/MMC card driver stub for Olimex ESP32-P4-PC.
 * Implements the Disks.Device interface for block read/write.
 *
 * This is a stub implementation; it provides a minimal device 
 * that returns errors on all transfers.
 *
 * The ESP32-P4 has an SD/MMC host controller (SDMMC) at a different
 * base address than the BCM2835 EMMC. The register interface is
 * also different (DWC MSHC compatible).
 *
 * (c) 2026 Rochus Keller <mailto:me@rochus-keller.ch>
 *
 * GNU General Public License Usage
 * This file may be used under the terms of the GNU General Public
 * License (GPL) versions 2.0 or 3.0 as published by the Free Software
 * Foundation and appearing in the file LICENSE.GPL included in
 * the packaging of this file. Please review the following information
 * to ensure GNU General Public Licensing requirements will be met:
 * http://www.fsf.org/licensing/licenses/info/GPLv2.html and
 * http://www.gnu.org/copyleft/gpl.html.
 *)

IMPORT SYSTEM, Kernel, Disks;

CONST
  Header = "SDDisks: ";
  BS = 512;  (** SD block size in bytes *)

TYPE
  Device = POINTER TO RECORD (Disks.DeviceDesc)
    cardSize: LONGINT;      (** device size in 512-byte blocks *)
    initialized: BOOLEAN;
  END;

VAR
  dev0: Device;

(** Transfer handler: read or write blocks.
    op: Disks.Read or Disks.Write
    block: logical block address
    num: number of blocks
    data: data buffer
    ofs: offset into data
    res: result code *)
PROCEDURE Transfer(d: Disks.Device; op, block, num: LONGINT;
                   VAR data: ARRAY OF CHAR; ofs: LONGINT; VAR res: LONGINT);
BEGIN
  (* Stub: always report error *)
  Kernel.WriteString(Header);
  Kernel.WriteString("Transfer not implemented (stub)");
  Kernel.WriteLn;
  res := Disks.Unsupported
END Transfer;

PROCEDURE GetSize(d: Disks.Device; VAR size, res: LONGINT);
VAR sd: Device;
BEGIN
  sd := d(Device);
  IF sd.initialized THEN
    size := sd.cardSize;
    res := Disks.Ok
  ELSE
    size := 0;
    res := Disks.Unsupported
  END
END GetSize;

PROCEDURE Handle(d: Disks.Device; VAR msg: Disks.Message; VAR res: LONGINT);
BEGIN
  res := Disks.Unsupported
END Handle;

PROCEDURE Init;
BEGIN
  NEW(dev0);
  Disks.InitDevice(dev0, "SD0");
  dev0.desc := "ESP32-P4 SD/MMC (stub)";
  dev0.cardSize := 0;
  dev0.initialized := FALSE;
  dev0.blockSize := BS;
  dev0.flags := {};
  dev0.transfer := Transfer;
  dev0.getSize := GetSize;
  dev0.handle := Handle;

  Kernel.WriteString(Header);
  Kernel.WriteString("stub driver loaded (no hardware)");
  Kernel.WriteLn;

  (* Do not register the device since we can't actually transfer data. *)
END Init;

BEGIN
  Init
END SDDisks.
