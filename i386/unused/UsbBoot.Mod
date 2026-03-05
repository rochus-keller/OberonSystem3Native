(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

(*
Native Oberon Usb boot support

Reference: http://www.usb.org

17.11.2000 cp first release
19.11.2000 cp fix: doing getSize instead of locking to test medium presence
*)

MODULE UsbBoot; (** non-portable **)  (** cp **)

IMPORT Kernel, Disks, Usb, UsbStorage, UsbUhci;

CONST

 MaxRetries = 30;
 ProbeIntervall = 1000; (* Intervall in ms, time between retries *)

PROCEDURE Init*();
VAR
 table : Disks.DeviceTable;
 RetryCounter : INTEGER;
 t : Kernel.MilliTimer;
 bootdev : Disks.Device;
 res, size, i : LONGINT; k : INTEGER;
BEGIN

 UsbUhci.Init; (* load chipset driver *)
 UsbStorage.Install; (* load usb storage (floppy, scsi) driver *)

 RetryCounter := 0;

 Kernel.WriteString("UsbBoot: Looking for disk drives..."); Kernel.WriteLn;

 LOOP
  Usb.Connect; (* Init devices on the bus (only not already connected devices) *)
  Disks.GetRegistered(table);

  IF table # NIL THEN
   FOR i := 0 TO LEN(table)-1 DO

    (* FIXME: Dont hardcode "USB" here, better read the string from the kernel config *)

    (* the .name field is 32 CHARs wide *)
    IF (table[i].name[0] = "U") & (table[i].name[1] = "S") & (table[i].name[2] = "B") THEN
     Kernel.WriteString("UsbBoot: device found: "); Kernel.WriteString(table[i].desc); Kernel.WriteLn;
     bootdev := table[i];
     bootdev.getSize(bootdev, size, res);
     IF (res = Disks.Ok) & (size # 0)THEN EXIT; END;
     Kernel.WriteString("UsbBoot: Device not ready."); Kernel.WriteLn;
    END;
   END;
  END;

  IF RetryCounter = MaxRetries THEN
   Kernel.WriteString("UsbBoot giving up. Sorry. Please restart the system."); Kernel.WriteLn;
   LOOP END;
  END;

  Kernel.WriteString("UsbBoot: No suitable disks found until now.");
  IF RetryCounter # 0 THEN Kernel.WriteString(" (retry "); Kernel.WriteInt(RetryCounter,0); Kernel.WriteString(")"); END;
  Kernel.WriteLn;
  INC(RetryCounter);
  Kernel.SetTimer(t, ProbeIntervall); REPEAT UNTIL Kernel.Expired(t); (* sleep a bit*)
 END;

 Kernel.WriteString("UsbBoot: I'll take this drive: "); Kernel.WriteString(bootdev.desc); Kernel.WriteLn;

 (* ENTER ADDITIONAL BOOT CODE HERE TO HANDLE bootdev *)

END Init;

BEGIN
 Init;
END UsbBoot.
