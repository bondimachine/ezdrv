; structs.inc - shared equates for the EZDRV overlay.
;
; Everything talks to the ATA/IDE disk with polled PIO on the task file,
; bypassing INT 13h entirely - the BIOS is the thing that cannot see past
; cylinder 1023.

%ifndef STRUCTS_INC
%define STRUCTS_INC

SEC_SZ          equ 512
MAX_CHUNK       equ 64          ; sectors per ATA command

; ATA register file, relative to the command block base (0x1F0 / 0x170)
ATA_DATA        equ 0
ATA_ERROR       equ 1           ; read
ATA_FEATURES    equ 1           ; write
ATA_COUNT       equ 2
ATA_LBA0        equ 3           ; sector number
ATA_LBA1        equ 4           ; cylinder low
ATA_LBA2        equ 5           ; cylinder high
ATA_DEVICE      equ 6           ; drive/head
ATA_STATUS      equ 7           ; read (clears pending INTRQ)
ATA_COMMAND     equ 7           ; write
; Control block (0x3F6 / 0x376) holds the alternate status register,
; which is identical to ATA_STATUS but does not acknowledge INTRQ.

ATA_PRIMARY     equ 0x1F0
ATA_PRI_CTL     equ 0x3F6
ATA_SECONDARY   equ 0x170
ATA_SEC_CTL     equ 0x376

; Status register bits
ST_BSY          equ 0x80
ST_DRDY         equ 0x40
ST_DF           equ 0x20
ST_DRQ          equ 0x08
ST_ERR          equ 0x01

; Error register bits
ER_UNC          equ 0x40        ; uncorrectable data error
ER_IDNF         equ 0x10        ; sector id not found
ER_ABRT         equ 0x04

; Commands
CMD_READ        equ 0x20
CMD_WRITE       equ 0x30
CMD_FLUSH       equ 0xE7
CMD_IDENTIFY    equ 0xEC

; IDENTIFY DEVICE result, byte offsets
ID_CONFIG       equ 0           ; word 0
ID_CYLS         equ 2           ; word 1
ID_HEADS        equ 6           ; word 3
ID_SPT          equ 12          ; word 6
ID_MODEL        equ 54          ; words 27-46, 40 bytes, byte swapped
ID_CAPS         equ 98          ; word 49, bit 9 = LBA supported
ID_LBA_SECS     equ 120         ; words 60-61, LBA28 sector count

; Timeouts, in BIOS timer ticks (18.2 Hz)
TICKS_IO        equ 182         ; 10 s for a data transfer
TICKS_RESET     equ 546         ; 30 s for spin-up

; BIOS data area
BDA_SEG         equ 0x40
BDA_TICKS       equ 0x6C

%endif ; STRUCTS_INC
