; loader.asm - EZDRV.COM: load the overlay from the DOS command line, or
; write it permanently onto the hard disk.
;
;   EZDRV          install the overlay as a TSR (INT 13h hook) right now.
;                  Run this from a boot floppy BEFORE FDISK/FORMAT so those
;                  tools see the full translated 255x63 geometry and lay the
;                  disk out for the whole capacity.
;
;   EZDRV /W       write the overlay onto hard disk 80h - the boot-code area
;                  of the MBR plus the body in the track-0 gap - leaving the
;                  partition table intact. After this the disk self-loads the
;                  overlay at every boot; the TSR is no longer needed.
;
;   EZDRV /U       remove the TSR installed by a previous "EZDRV".
;
; The same OVERLAY.BIN body serves all three: the TSR hooks it in RAM, /W
; writes it to disk for the MBR loader to bring up next boot. Typical bring-
; up of a fresh disk:
;
;   A> EZDRV            (hook overlay so FDISK sees the big geometry)
;   A> FDISK            (create C: and D:, up to 2GB each)
;   A> EZDRV /W         (stamp the overlay onto the disk)
;   ... reboot from the hard disk, floppy still in: the stamped MBR
;   installs the hook and chains to A:, so this DOS boots translated ...
;   A> FORMAT C: /S     (make C: bootable)
;   A> FORMAT D:
;   ... reboot without the floppy: MS-DOS boots from C: ...
;
; Build: nasm -f bin -i build/ src/loader.asm -o EZDRV.COM
;   (needs build/MBR.BIN and build/OVERLAY.BIN)

        cpu     8086
        org     0x100

BODY_ISR    equ 4                       ; body header word offsets
BODY_INST   equ 6
BODY_OLD2F  equ 8                       ; saved INT 2Fh vector (dword)
HDD         equ 0x80

; The embedded images go first, paragraph-aligned, so that body_seg:0 is
; the body origin and - crucially - every code/data label below them has a
; fixed offset. (With the incbins at the end, their presence perturbed the
; -f bin label pass and mis-encoded references to data defined after the
; code.)
        jmp     start
        align 16
mbrimg:     incbin "MBR.BIN"
        align 16
body:       incbin "OVERLAY.BIN"
body_end:

BODY_SECS   equ (body_end - body + 511) / 512

start:
        cld
        ; --- parse the command tail at 0x81 for a switch ------------
        mov     si, 0x81
.scan:
        lodsb
        cmp     al, 0x0D
        je      do_tsr
        cmp     al, '/'
        je      .sw
        cmp     al, '-'
        je      .sw
        or      al, al
        jz      do_tsr
        jmp     .scan
.sw:
        lodsb
        and     al, 0xDF                ; upper-case
        cmp     al, 'W'
        je      do_write
        cmp     al, 'U'
        je      do_uninstall
        ; unknown switch: fall through to help
        mov     dx, m_usage
        jmp     die

; =====================================================================
; Install the overlay as a resident INT 13h hook.
do_tsr:
        call    is_present
        jnc     .already

        ; body_seg = CS + (body offset / 16). `body` is paragraph-aligned in
        ; the COM image, so body_seg:0 is the body's origin.
        mov     bx, body
        mov     cl, 4
        shr     bx, cl
        mov     ax, cs
        add     ax, bx
        mov     [body_seg], ax

        ; save the current INT 13h vector into the body header [0]
        xor     bx, bx
        mov     es, bx
        mov     ax, [es:0x4C]
        mov     dx, [es:0x4E]
        mov     es, [body_seg]
        mov     [es:0], ax
        mov     [es:2], dx

        ; point INT 13h at body_seg:isr
        mov     ax, [es:BODY_ISR]
        mov     dx, [body_seg]
        xor     bx, bx
        mov     es, bx
        cli
        mov     [es:0x4C], ax
        mov     [es:0x4E], dx
        sti

        ; one-shot init
        mov     es, [body_seg]
        mov     ax, [es:BODY_INST]
        mov     [callvec], ax
        mov     ax, [body_seg]
        mov     [callvec+2], ax
        call    far [callvec]

        mov     dx, m_installed
        mov     ah, 0x09
        int     0x21

        ; self-test: read the marker at LBA 2,000,000 through the hook and
        ; verify it, so a broken install is reported rather than silent.
        mov     ax, cs
        mov     [st_dap+6], ax
        mov     si, st_dap
        mov     ah, 0x42
        mov     dl, HDD
        int     0x13
        jc      .stfail
        push    ds
        pop     es                      ; ES is still body_seg from the
        mov     si, st_buf              ; install sequence; cmpsb needs it
        mov     di, st_sig              ; back on our own segment
        mov     cx, 8
        repe    cmpsb
        jne     .stfail
        mov     dx, m_stok
        jmp     .stprint
.stfail:
        mov     dx, m_stbad
.stprint:
        mov     ah, 0x09
        int     0x21

        ; stay resident through end of the body
        mov     dx, body_end
        add     dx, 15
        mov     cl, 4
        shr     dx, cl
        mov     ax, 0x3100
        int     0x21
.already:
        mov     dx, m_already
        jmp     die

; =====================================================================
; Write the overlay permanently onto hard disk 80h.
do_write:
        ; read the current MBR (LBA 0) so we can keep its partition table
        mov     ax, 0x0201
        mov     cx, 0x0001              ; cyl 0, sector 1
        xor     dh, dh
        mov     dl, HDD
        mov     bx, sector
        int     0x13
        jc      .err
        cmp     word [sector+510], 0xAA55
        je      .splice
        ; no signature yet (blank disk): start from a clean sector
        xor     ax, ax
        mov     di, sector
        mov     cx, 256
        rep     stosw
        mov     word [sector+510], 0xAA55
.splice:
        ; overlay our boot code onto bytes 0..445, keep the table at 0x1BE
        mov     si, mbrimg
        mov     di, sector
        mov     cx, 446
        rep     movsb
        ; write LBA 0 back
        mov     ax, 0x0301
        mov     cx, 0x0001
        xor     dh, dh
        mov     dl, HDD
        mov     bx, sector
        int     0x13
        jc      .err

        ; write the body to the track-0 gap, starting at CHS sector 2 (LBA 1)
        mov     ax, 0x0300 | BODY_SECS
        mov     cx, 0x0002              ; cyl 0, sector 2
        xor     dh, dh
        mov     dl, HDD
        mov     bx, body
        int     0x13
        jc      .err

        mov     dx, m_written
        jmp     die
.err:
        mov     dx, m_diskerr
        jmp     die

; =====================================================================
do_uninstall:
        call    is_present
        jc      .notthere
        ; the live INT 13h segment is our body; it saved the old vector at
        ; offset 0. Restore it. (Safe only if we are the top hook, which we
        ; are unless something chained after us.)
        xor     bx, bx
        mov     es, bx
        mov     bx, [es:0x4E]           ; current handler segment = body_seg
        mov     es, bx
        mov     ax, [es:0]              ; saved old offset
        mov     dx, [es:2]              ; saved old segment
        mov     si, [es:BODY_OLD2F]     ; saved INT 2Fh chain, in case the
        mov     di, [es:BODY_OLD2F+2]   ; body holds that vector too
        push    bx                      ; body segment
        xor     bx, bx
        mov     es, bx
        cli
        mov     [es:0x4C], ax
        mov     [es:0x4E], dx
        sti
        pop     bx
        ; restore INT 2Fh too if it still points into the body
        mov     ax, [es:0xBE]
        cmp     ax, bx
        jne     .no2f
        cli
        mov     [es:0xBC], si
        mov     [es:0xBE], di
        sti
.no2f:
        mov     dx, m_removed
        jmp     die
.notthere:
        mov     dx, m_notthere
        jmp     die

; =====================================================================
; is_present: CF clear if the overlay is already hooked.
is_present:
        mov     ah, 0xE0
        mov     bx, 0x1357
        mov     dl, HDD
        int     0x13
        jc      .no
        cmp     ax, 0x4F4B             ; 'OK'
        jne     .no
        clc
        ret
.no:
        stc
        ret

; die: print DX string ($-terminated) and exit.
die:
        mov     ah, 0x09
        int     0x21
        mov     ax, 0x4C00
        int     0x21

; ---------------------------------------------------------------------
body_seg:   dw 0
callvec:    dd 0

m_installed: db 'EZDRV: overlay hooked; run FDISK/FORMAT now.', 13,10,'$'
m_already:   db 'EZDRV: already installed.', 13,10,'$'
m_written:   db 'EZDRV: written to disk 80h. Reboot from the hard disk.', 13,10,'$'
m_removed:   db 'EZDRV: TSR removed.', 13,10,'$'
m_notthere:  db 'EZDRV: not installed.', 13,10,'$'
m_diskerr:   db 'EZDRV: disk 80h error.', 13,10,'$'
m_usage:     db 'Usage: EZDRV [/W write to disk] [/U uninstall]', 13,10,'$'


m_stok:      db 'EZDRV: self-test read past 504MB: OK', 13,10,'$'
m_stbad:     db 'EZDRV: self-test read past 504MB: FAILED', 13,10,'$'
st_sig:      db 'OVLMARK!'
st_dap:      db 0x10, 0
             dw 1
             dw st_buf, 0
             dd 2000000
             dd 0

; a 512-byte scratch sector for the read-modify-write of the MBR
        align 16
sector:     times 512 db 0
st_buf:     times 512 db 0
