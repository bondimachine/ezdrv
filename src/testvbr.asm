; testvbr.asm - a stand-in partition boot sector for exercising the
; overlay in the real boot path, without needing a bootable DOS.
;
; The MBR chains here (DL=80h, loaded at 0x7C00) after installing the
; overlay hook. We then drive INT 13h - which now goes through the overlay
; - at a marker sector well past the 504MB barrier, three ways:
;
;   AH=42h  LBA read           read the marker
;   AH=02h  CHS read           read it again via translated 255x63 CHS
;   AH=43h  LBA write          stamp a verdict the host can check
;
; A real BIOS could do none of these to this sector (LBA beyond its reach,
; cylinder beyond 1023, no extensions). If the verdict reads back PASS on
; the host, the overlay carried every one of them.
;
; Build: nasm -f bin -dMARKER_LBA=n src/testvbr.asm -o TESTVBR.BIN

        cpu     8086
        org     0x7C00

%ifndef MARKER_LBA
%define MARKER_LBA 2000000
%endif

FAKE_HEADS  equ 255
FAKE_SPT    equ 63
FAKE_TRACK  equ FAKE_HEADS*FAKE_SPT

M_CYL       equ MARKER_LBA / FAKE_TRACK
M_HEAD      equ (MARKER_LBA % FAKE_TRACK) / FAKE_SPT
M_SEC       equ (MARKER_LBA % FAKE_SPT) + 1

BUF1        equ 0x8000              ; LBA-read landing buffer
BUF2        equ 0x8200              ; CHS-read landing buffer
WBUF        equ 0x8400              ; verdict sector image (RAM scratch)

start:
        cli
        xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, 0x7C00
        sti

        mov     si, m_banner
        call    print

        ; --- AH=42h : LBA read of the marker -------------------------
        mov     si, dap
        mov     ah, 0x42
        mov     dl, 0x80
        int     0x13
        jc      .lba_bad
        mov     si, BUF1
        mov     di, sig
        call    cmp8
        jne     .lba_bad
        mov     si, m_lba_ok
        call    print
        jmp     .chs
.lba_bad:
        mov     si, m_lba_bad
        call    print
        mov     byte [passed], 0

.chs:
        ; --- AH=02h : translated-CHS read of the same marker ---------
        mov     ax, 0x0201
        mov     ch, M_CYL & 0xFF
        mov     cl, ((M_CYL >> 2) & 0xC0) | M_SEC
        mov     dh, M_HEAD
        mov     dl, 0x80
        mov     bx, BUF2
        int     0x13
        jc      .chs_bad
        mov     si, BUF2
        mov     di, sig
        call    cmp8
        jne     .chs_bad
        mov     si, m_chs_ok
        call    print
        jmp     .verdict
.chs_bad:
        mov     si, m_chs_bad
        call    print
        mov     byte [passed], 0

.verdict:
        ; --- AH=43h : write the verdict where the host can read it ----
        mov     si, verdict_pass
        cmp     byte [passed], 0
        jne     .have
        mov     si, verdict_fail
.have:
        mov     di, WBUF
        mov     cx, 8
        cld
        rep     movsb
        mov     si, wdap
        mov     ah, 0x43
        mov     al, 0
        mov     dl, 0x80
        int     0x13

        mov     si, m_done
        call    print
        cli
        hlt
        jmp     $

; cmp8: compare 8 bytes at DS:SI with DS:DI. ZF set if equal.
cmp8:
        mov     cx, 8
        push    si
        push    di
        repe    cmpsb
        pop     di
        pop     si
        ret

; print: DS:SI NUL-terminated string via BIOS teletype.
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

sig:            db 'OVLMARK!'
verdict_pass:   db 'OVLPASS!'
verdict_fail:   db 'OVLFAIL!'
passed:         db 1

; INT 13h disk address packets
dap:            db 0x10, 0
                dw 1                    ; sectors
                dw BUF1, 0              ; buffer off:seg
                dd MARKER_LBA
                dd 0
wdap:           db 0x10, 0
                dw 1
                dw WBUF, 0
                dd MARKER_LBA + 1
                dd 0

m_banner:   db 13, 10, 'EZDRV boot test: chained via overlay', 13, 10, 0
m_lba_ok:   db '  AH=42 LBA read past 504MB: OK', 13, 10, 0
m_lba_bad:  db '  AH=42 LBA read past 504MB: FAIL', 13, 10, 0
m_chs_ok:   db '  AH=02 CHS read past 504MB: OK', 13, 10, 0
m_chs_bad:  db '  AH=02 CHS read past 504MB: FAIL', 13, 10, 0
m_done:     db '  verdict written to marker+1', 13, 10, 0

        times 510-($-$$) db 0
        dw 0xAA55
