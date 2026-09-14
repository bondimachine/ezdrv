# EZDRV

**A modern take on the old EZ-Drive / OnTrack disk overlays — built for
removable media.** Like those classics, it lets a pre-LBA BIOS boot DOS
from a disk larger than 504MB. Unlike them, it is designed for the way
retro machines store things today — SD and CF cards behind IDE adapters
— so the same card pops out of the 486 and mounts on Windows, macOS or
Linux **without any extra drivers or tooling**: the on-disk layout stays
completely standard.

## The problem

The 504MB barrier is the intersection of two different limits. INT 13h
gives you 1024 cylinders, 256 heads and 63 sectors; the IDE task file
gives you 65536 cylinders, 16 heads and 255 sectors. You only get the
smaller of each: 1024 x 16 x 63 x 512 = 504MB.

The classic fix — EZ-Drive, OnTrack Disk Manager — is a *dynamic drive
overlay*: code loaded from the MBR before the OS, which hooks INT 13h
and presents a translated geometry with fewer cylinders and more heads.
It works, but the disk stops being an ordinary disk: those DDOs shift
the real partition table off LBA 0 (EZ-Drive keeps it in sector 1,
OnTrack offsets the whole disk by 63 sectors) and stamp proprietary
partition types (`0x54`, `0x55`). That was tolerable when a hard disk
lived and died inside one machine. It is exactly wrong for an SD or CF
card that shuttles between the retro box and a modern computer: plug an
EZ-Drive-style card into a card reader and the modern OS sees one
partition of unknown type `0x55` and nothing else — no files, no drag
and drop, no backups without special tooling.

## What EZDRV does differently

EZDRV is an overlay in the classic mould — INT 13h hooked before DOS
starts, requests served by polled PIO straight at the IDE task file —
but its on-disk footprint uses only space a standard layout already
reserves:

* the boot code lives in the 446 bytes of LBA 0 that every MBR sets
  aside for boot code;
* the ~2.5KB body lives in the track-0 gap (LBA 1 onward — sectors that
  are empty on any disk whose first partition starts at LBA 63);
* the partition table stays at offset 0x1BE with **ordinary type bytes**
  and true LBA fields. Nothing is shifted, translated or hidden.

It presents drive 80h as 255 heads x 63 sectors — the same translation
every post-1997 BIOS uses, and the same geometry a modern `fdisk`
already assumes — so the whole disk fits under 1024 cylinders and the
CHS fields in the partition table agree with what modern tools write.
Reach: 1024 x 255 x 63 x 512 = 8.0GB (LBA28 inside), which covers the
SD/CF card sizes a DOS machine can meaningfully use.

Verified end to end under QEMU against MS-DOS 6.22 (see Testing): a
blank 4.1GB disk brought up with stock FDISK and FORMAT, a 2GB bootable
C:, and the same image mounting on macOS as a plain `DOS_FAT_16` volume.

## Using it

### What you need

* `EZDRV.COM` and `GEO.COM` (`make`, needs nasm), copied onto a DOS boot
  floppy along with `FDISK.EXE` and `FORMAT.COM`.
* MS-DOS 5 or 6.x. FAT16 volumes max out at 2GB per drive letter — a DOS
  limit, not an overlay limit; make one partition per 2GB.

### Bringing up a blank disk, on the machine itself

```
A> EZDRV             hook the overlay: FDISK now sees the full disk
A> FDISK             create the partitions (primary + extended as usual)
A> EZDRV /W          stamp the MBR boot code + overlay body onto the disk
   ... FDISK reboots the machine; leave the floppy in ...
A> FORMAT C: /S      now through the overlay, from sector zero
A> FORMAT D:         (and any others)
   ... reboot without the floppy ...
C:\>                 MS-DOS, from the big disk
```

Two things make the middle of that sequence work:

* **The reboot between FDISK and FORMAT is mandatory.** DOS latches
  drive geometry once, at boot, before anything in CONFIG.SYS or
  AUTOEXEC can run. FDISK is happy with the freshly-hooked TSR because
  it calls INT 13h itself, but FORMAT works through DOS's own tables —
  so FORMAT must run under a DOS that *booted* with the hook live.
* **The stamped MBR boots the floppy through the overlay.** After
  `EZDRV /W`, booting from the hard disk installs the hook and then, if
  C: is not bootable yet, chains to the floppy — so the floppy-booted
  DOS sees the translated geometry from its first sector. (Set the BIOS
  boot order to the hard disk for this; it is also how EZ-Drive did it.)

`GEO` shows what DOS is seeing at any point — geometry per INT 13h AH=08
plus a read probe past the barrier:

```
A> GEO
disk 80h: cyls=540 heads=255 spt=63
AH=42 LBA read past 504MB: OK
AH=02 CHS read past 504MB: OK
```

`EZDRV /U` removes the resident hook again; `EZDRV` a second time says
"already installed" rather than double-hooking.

### Preparing the disk on a modern machine instead

Because the layout is standard, you can also do everything except the
DOS system transfer from the host: partition with `fdisk`/Disk Utility
in 255x63 geometry (what they do anyway), `mkfs.vfat -F 16` the volumes,
and stamp the overlay by writing `MBR.BIN` into bytes 0..445 of LBA 0
and `OVERLAY.BIN` from LBA 1 (`tools/mkoverlaydisk.py` shows the exact
splicing). Then boot the old machine from a floppy through the stamped
MBR and `SYS C:` to make it bootable.

### Reading the card on a modern machine

Nothing to do — that is the point. Pop the SD/CF card into a reader:
the partitions are plain FAT16 at their true LBAs. macOS auto-mounts
them; Linux mounts them with `mount -t vfat`; Windows assigns letters.
The overlay body in the track-0 gap is invisible to all of them, and
copying files back and forth from the modern side is just file
management.

### What can go wrong

* `FDISK /MBR`, or any OS installer writing its own boot loader, wipes
  the hook (not your data — the table and volumes stay intact and remain
  readable everywhere). Re-run `EZDRV /W` from a floppy to restore it.
* The track-0 gap is also where GRUB and friends keep their stage 1.5 —
  don't dual-boot Linux from the same disk.
* A disk moved to a machine whose BIOS already translates (255x63) needs
  no overlay at all — the layout is exactly what that BIOS expects.

## Windows

* **Windows 3.x** runs through the hook as-is: Enhanced mode reflects
  all disk I/O to the real-mode INT 13h chain, exactly as it did over
  the classic DDOs. Its optional "32-bit disk access" (WDCTRL) validates
  the disk parameter table against the controller and correctly refuses
  on translated disks, so that checkbox stays off — the safe outcome.
* **Windows 95/98** bypasses INT 13h with its own protected-mode IDE
  driver, which reads the partition table straight from LBA 0 — and on
  this layout that table is simply a correct, standard table. The only
  obstacle is Win9x's IOS flagging any unknown real-mode INT 13h hook
  "unsafe" and dropping to MS-DOS Compatibility Mode.
* So the overlay watches the Windows startup broadcast (INT 2Fh
  AX=1605h) and, when Windows 4.00+ starts, **unhooks itself** to leave
  IOS a clean chain — but only when it found at install time that the
  BIOS underneath serves the identical 255x63 translation (the card
  moved to a newer, LBA-assist machine; unhooking there changes nothing
  DOS depends on). On a genuinely pre-LBA BIOS the hook is load-bearing:
  the broadcast arrives *before* Windows loads its VxDs through
  real-mode DOS, whose geometry was latched through the overlay at boot,
  so unhooking would misaddress every sector from that moment on. There
  the hook stays and Win9x runs in (correct, slower) compatibility mode.
  On the Windows exit broadcast (AX=1606h) the hook comes back.
  `W95SIM.COM` simulates the broadcasts so you can see which way a given
  machine behaves before ever starting real Windows on it.

## Building

```sh
make                    # EZDRV.COM + GEO.COM (80186+, uses REP INSW/OUTSW)
make CPU=8086           # XT-class build, moves the data port word by word
```

`EZDRV.COM` embeds both halves: `MBR.BIN` (446 bytes) and `OVERLAY.BIN`
(~2.5KB, 5 sectors in the gap, ~4KB resident carved from the top of
conventional memory).

## Testing

All tests boot real MS-DOS 6.22 under QEMU with `bios-chs-trans=none`,
so SeaBIOS reports the old 1024-cylinder geometry and the 504MB barrier
is genuinely present.

```sh
make test         # boot path: a pre-stamped disk boots itself, and the
                  # chained boot code reads/writes a marker at LBA
                  # 2,000,000 via AH=42, AH=02 and AH=43 - all past the
                  # barrier - then the image is mounted on macOS
make tsr-test     # EZDRV.COM as a TSR under DOS: geometry flips from
                  # 1023x16x63 to 540x255x63, reads past the barrier OK;
                  # then W95SIM simulates the Windows start/exit
                  # broadcasts - run twice: on the old BIOS the hook must
                  # survive a Win95 start, on an LBA-assist BIOS
                  # (bios-chs-trans=lba) it must step aside and re-hook
                  # when Windows exits
make e2e          # the full bring-up above, automated: blank 4.1GB disk,
                  # EZDRV + real FDISK driven by keystrokes creates the
                  # 2047MB primary, EZDRV /W stamps the disk, reboot ->
                  # floppy-through-overlay -> FORMAT C: /S runs 0-100%
                  # and transfers the system, reboot -> MS-DOS boots from
                  # C: to a prompt, then macOS mounts the 2.0GiB FAT16
                  # volume and lists IO.SYS/MSDOS.SYS/COMMAND.COM
```

The e2e test needs the retail MS-DOS 6.22 Disk 1 image (path at the top
of `test/run-fdisk-e2e.py`); it builds the boot floppies from it on the
fly. Individual phases can be re-run with
`python3 test/run-fdisk-e2e.py --phase 1|1b|2|3|host`.

## Two BIOS interfaces, not one (hard-won lessons)

Hooking INT 13h is not enough. DOS-era software reads hard-disk geometry
through **two** channels, and both must agree:

* `INT 13h AH=08h` — the overlay answers with the translated geometry.
* the **fixed disk parameter table** pointed to by interrupt vector
  **41h** (drive 80h). IO.SYS reads it directly at boot. The overlay
  publishes a Phoenix *translated* FDPT (signature `0xA0`, logical +
  physical geometry, whole-table checksum) and repoints INT 41h at it,
  exactly as the classic DDOs did.

Three more traps that cost real debugging time, recorded so they stay
fixed: `AH=08h` must **preserve the caller's ES:DI** for hard disks
(zeroing them corrupts callers that assume ES survives — IO.SYS hangs at
boot); any test code that verifies buffers with `cmpsb` must set ES
explicitly, because ES is not guaranteed across BIOS calls; and an
MBR-resident hook **cannot keep INT 2Fh by simply re-grabbing the
vector** — DOS overwrites it several times during boot, and SYSINIT
runs a *transient* copy of itself at the top of conventional memory
(directly below the overlay's carve) whose INT 2Fh handler retires when
boot completes. Capturing that as a chain target dangles a pointer into
freed memory and crashes the first INT 2Fh call after boot. The overlay
instead re-verifies its chain position only on the query/status INT 13h
functions (AH=00/01/08/15/41/48 — what FDISK, SMARTDRV, our tools and
Windows' own startup issue anyway), using a private INT 2Fh
installation check (AX=E000h) and re-taking the top only when genuinely
unreachable, never accepting a handler from the transient zone. Reads
and writes pay nothing at all (see `verify2f` in `src/overlay.asm`).

## Limitations

* **PIO only, no DMA.** Roughly 1–3 MB/s on real ISA hardware. The 2GB
  format in the e2e test completes in under a minute under QEMU.
* **LBA28** and a 1024x255x63 window: 8GB reach. CHS-only drives are
  addressed through their native geometry instead.
* **The overlay serves the primary master only** as drive 80h (the
  loader's `/W` and the hook both assume it). A slave the BIOS already
  handles stays fully visible: calls for any other drive chain to the
  BIOS untouched, and AH=08 reports the BIOS's drive count from the BDA
  (hardcoding 1 there is how an overlay makes drive 81h vanish — the
  count in DL is how DOS discovers it). *Translating* a second large
  disk would need a second FDPT (INT 46h), DL=81h dispatch and slave
  ATA addressing — not implemented.
* **No ATAPI.** Hard disks only.
* FAT16/2GB per volume under MS-DOS 6.x — a DOS limit. DOS 7.1 (Win95
  OSR2+) would allow FAT32 through the same overlay, untested.

## Layout

```
src/structs.inc     equates: ATA registers, IDENTIFY fields, timeouts
src/ata.asm         polled PIO ATA layer (issue, wait, chunked transfer)
src/overlay.asm     the resident body: INT 13h handler, geometry
                    translation, FDPT, install
src/mbr.asm         MBR boot code: load body, hook, chain to C: or A:
src/loader.asm      EZDRV.COM: TSR install / write-to-disk / uninstall
src/geo.asm         GEO.COM: geometry + past-the-barrier read diagnostic
src/w95sim.asm      W95SIM.COM: simulate the Windows INT 2Fh broadcasts
src/testvbr.asm     test boot sector used by `make test`
tools/mkoverlaydisk.py  builds a stamped test disk image
test/run-overlay-boot.py   boot-path test
test/run-tsr-test.py       TSR test
test/run-fdisk-e2e.py      full FDISK/FORMAT/boot bring-up test
```
