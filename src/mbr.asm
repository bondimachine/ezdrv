; mbr.asm - EZDRV master boot record: loads the overlay body, installs
; the INT 13h hook, then chains to the active partition exactly like a
; stock MBR would.
;
; This replaces only the boot-code area (bytes 0..445) of LBA 0. The
; partition table at 0x1BE and the 0xAA55 signature are left untouched by
; the installer, so the on-disk layout stays completely standard.
;
; The BIOS loads us at 0x7C00. We relocate to 0x0600 (the classic spot,
; freeing 0x7C00 for the partition boot sector we will chain to), read the
; body from the track-0 gap into memory carved off the top of the 640KB
; region, hook INT 13h, and jump into the active partition's boot sector -
; whose own INT 13h calls now go through the overlay.
;
; BODY_SECS and RESERVE_KB are supplied at assembly time by the installer,
; which knows how big OVERLAY.BIN turned out to be:
;   nasm -f bin -dBODY_SECS=n -dRESERVE_KB=k src/mbr.asm -o MBR.BIN

        cpu     8086
        org     0x0600

%ifndef BODY_SECS
%define BODY_SECS 8
%endif
%ifndef RESERVE_KB
%define RESERVE_KB 4
%endif

RELOC       equ 0x0600
LOAD        equ 0x7C00
BODY_ISR    equ 4                       ; header word offsets in the body
BODY_INST   equ 6

start:
        cli
        xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, LOAD
        ; relocate this sector 0x7C00 -> 0x0600 (position-independent up
        ; to the far jump, which lands in the relocated copy)
        mov     si, LOAD
        mov     di, RELOC
        mov     cx, 256
        cld
        rep     movsw
        jmp     0:main

main:
        sti
        mov     [drive], dl

        ; carve RESERVE_KB off the top of conventional memory (BDA 40:13)
        mov     ax, 0x40
        mov     es, ax
        mov     ax, [es:0x13]
        sub     ax, RESERVE_KB
        mov     [es:0x13], ax
        mov     cl, 6
        shl     ax, cl                  ; KB -> paragraph (segment) base
        mov     [ovl_seg], ax

        ; read the body from sectors 2..(1+BODY_SECS) into ovl_seg:0
        mov     es, ax
        xor     bx, bx
        mov     ah, 0x02
        mov     al, BODY_SECS
        mov     ch, 0                   ; cylinder 0
        mov     cl, 2                   ; sector 2 (right after the MBR)
        mov     dh, 0                   ; head 0
        mov     dl, [drive]
        int     0x13
        jc      fail_body

        ; save the previous INT 13h vector into the body header
        xor     ax, ax
        mov     es, ax
        mov     ax, [es:0x4C]
        mov     dx, [es:0x4E]
        mov     es, [ovl_seg]
        mov     [es:0], ax
        mov     [es:2], dx

        ; point INT 13h at the body's ISR
        mov     ax, [es:BODY_ISR]
        mov     dx, [ovl_seg]
        xor     bx, bx
        mov     es, bx
        cli
        mov     [es:0x4C], ax
        mov     [es:0x4E], dx
        sti

        ; one-shot init: far-call the body's install routine
        mov     es, [ovl_seg]
        mov     ax, [es:BODY_INST]
        mov     [callvec], ax
        mov     ax, [ovl_seg]
        mov     [callvec+2], ax
        call    far [callvec]

        ; find the active partition
        mov     si, RELOC + 0x1BE
        mov     cx, 4
.find:
        cmp     byte [si], 0x80
        je      .found
        add     si, 16
        loop    .find
        jmp     short try_floppy        ; nothing bootable here yet
.found:
        ; read its boot sector to 0x7C00 through the (now hooked) BIOS,
        ; using the CHS in the entry - which the installer wrote in the
        ; same 255x63 geometry the overlay presents, so it resolves to
        ; the right LBA.
        mov     dh, [si+1]              ; head
        mov     cx, [si+2]              ; CL=sector|cyl-hi, CH=cyl-low
        mov     dl, [drive]
        xor     bx, bx
        mov     es, bx                  ; install left ES on the body segment
        mov     bx, LOAD
        mov     ax, 0x0201
        int     0x13
        jc      try_floppy
        cmp     word [LOAD+510], 0xAA55
        jne     try_floppy

        ; hand off: DS:SI -> active entry, DL = drive (stock convention)
        mov     dl, [drive]
        jmp     0:LOAD

; ---------------------------------------------------------------------
; try_floppy: no bootable hard-disk partition (a disk mid-setup: FDISK
; run but FORMAT /S still pending). Do what EZ-Drive did - chain to the
; floppy WITH the INT 13h hook already live, so the DOS that boots from
; A: sees the translated geometry from its very first sector and builds
; its drive tables consistently. Without this there is no way to FORMAT
; a big C:, because a floppy-booted DOS would have latched the BIOS's
; untranslated geometry before any TSR could load.
try_floppy:
        mov     si, msg_flop
        call    print
        xor     bx, bx
        mov     es, bx                  ; install left ES on the body seg
        mov     cx, 3                   ; floppies deserve a few tries
.retry:
        push    cx
        xor     ax, ax                  ; reset the floppy system
        xor     dx, dx
        int     0x13
        mov     bx, LOAD
        mov     ax, 0x0201
        mov     cx, 0x0001
        xor     dx, dx                  ; head 0, drive A:
        int     0x13
        pop     cx
        jc      .again
        cmp     word [LOAD+510], 0xAA55
        je      boot_floppy
.again:
        loop    .retry
        mov     si, msg_none
fail_msg:
        call    print
        cli
        hlt
        jmp     $

boot_floppy:
        xor     dx, dx                  ; DL = 0: booted from A:
        jmp     0:LOAD

fail_body:
        mov     si, msg_body
        jmp     fail_msg

; print: DS:SI -> $-less, NUL-terminated string, via BIOS teletype.
print:
        lodsb
        or      al, al
        jz      .out
        mov     ah, 0x0E
        mov     bx, 0x0007
        int     0x10
        jmp     print
.out:
        ret

drive:      db 0
ovl_seg:    dw 0
callvec:    dd 0
msg_body:   db 13, 10, 'EZDRV: body load error', 13, 10, 0
msg_flop:   db 13, 10, 'EZDRV: C: not bootable, trying A:', 13, 10, 0
msg_none:   db 13, 10, 'EZDRV: no boot device', 13, 10, 0

        times 446-($-$$) db 0           ; boot code area ends at 0x1BE
        ; partition table + signature are written by the installer
