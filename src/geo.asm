; geo.asm - GEO.COM: report the geometry and reach of hard disk 80h as
; DOS/FDISK sees it once the overlay is loaded. Run it after EZDRV.
;   GEO > A:\OUT.TXT   (output goes through INT 21h, so redirection works)
; Build: nasm -f bin src/geo.asm -o GEO.COM

        cpu     8086
        org     0x100

MARKER      equ 2000000
M_CYL       equ MARKER / (255*63)
M_HEAD      equ (MARKER % (255*63)) / 63
M_SEC       equ (MARKER % 63) + 1

start:
        mov     ax, cs
        mov     [dap+6], ax

        mov     ah, 0x08                ; drive parameters
        mov     dl, 0x80
        int     0x13
        jc      .nogeo
        mov     [g_cx], cx
        mov     [g_dx], dx
        mov     dx, m_cyl
        call    puts
        mov     cx, [g_cx]
        mov     bl, cl
        mov     cl, 6
        shr     bl, cl
        xor     bh, bh
        mov     cl, 8
        mov     ax, bx
        shl     ax, cl
        mov     bl, ch
        xor     bh, bh
        add     ax, bx
        inc     ax
        call    putdec
        mov     dx, m_head
        call    puts
        mov     al, [g_dx+1]
        xor     ah, ah
        inc     ax
        call    putdec
        mov     dx, m_spt
        call    puts
        mov     ax, [g_cx]
        and     ax, 0x3F
        call    putdec
        mov     dx, m_drv               ; AH=08 DL = hard disk count: a
        call    puts                    ; slave must stay visible under
        mov     al, [g_dx]              ; the overlay
        xor     ah, ah
        call    putdec
        mov     dx, m_crlf
        call    puts

        mov     dx, m_far               ; AH=42 LBA read past the barrier
        call    puts
        mov     si, dap
        mov     ah, 0x42
        mov     dl, 0x80
        int     0x13
        mov     si, buf
        call    report
.chs:   mov     dx, m_chs               ; AH=02 CHS read past the barrier
        call    puts
        push    ds
        pop     es                      ; AH=02 buffer is ES:BX, and our
        mov     ax, 0x0201              ; AH=08 call left ES = 0
        mov     ch, M_CYL & 0xFF
        mov     cl, ((M_CYL >> 2) & 0xC0) | M_SEC
        mov     dh, M_HEAD
        mov     dl, 0x80
        mov     bx, buf2
        int     0x13
        mov     si, buf2
        call    report
        jmp     .fin
.nogeo: mov     dx, m_nogeo
        call    puts
.fin:   mov     ax, 0x4C00
        int     0x21

; report: after an INT 13h read (CF/AH as returned, SI -> buffer) print
;   OK                  read succeeded and the test-image marker is there
;   OK (no test marker) read succeeded; a real disk holds its own data
;                       there, so this is the expected answer outside QEMU
;   FAIL xx             read failed, xx = INT 13h status (hex)
report: jc      .bad
        call    chk
        jne     .nomark
        mov     dx, m_ok
        jmp     puts
.nomark:mov     dx, m_okraw
        jmp     puts
.bad:   push    ax
        mov     dx, m_failc
        call    puts
        pop     ax
        mov     al, ah
        call    puthex
        mov     dx, m_crlf
        jmp     puts

; puthex: AL as two hex digits.
puthex: push    ax
        mov     cl, 4
        shr     al, cl
        call    .dig
        pop     ax
.dig:   and     al, 0x0F
        cmp     al, 10
        sbb     al, 0x69
        das
        mov     dl, al
        mov     ah, 0x02
        int     0x21
        ret

chk:    push    es
        push    ds
        pop     es                      ; cmpsb compares DS:SI to ES:DI, and
        mov     di, sig                 ; ES is NOT ours here: our own AH=08
        mov     cx, 8                   ; call returned ES:DI = 0:0
        push    si
        repe    cmpsb
        pop     si
        pop     es
        ret
puts:   mov     ah, 0x09
        int     0x21
        ret
putdec: push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
.d:     xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     .d
.e:     pop     dx
        add     dl, '0'
        mov     ah, 0x02
        int     0x21
        loop    .e
        pop     dx
        pop     cx
        pop     bx
        ret

g_cx:   dw 0
g_dx:   dw 0
sig:    db 'OVLMARK!'
dap:    db 0x10, 0
        dw 1
        dw buf, 0
        dd MARKER
        dd 0
m_cyl:  db 'disk 80h: cyls=$'
m_head: db ' heads=$'
m_spt:  db ' spt=$'
m_drv:  db ' drives=$'
m_crlf: db 13,10,'$'
m_far:  db 'AH=42 LBA read past 504MB: $'
m_chs:  db 'AH=02 CHS read past 504MB: $'
m_ok:   db 'OK', 13,10,'$'
m_okraw:db 'OK (no test marker)', 13,10,'$'
m_failc:db 'FAIL $'
m_nogeo:db 'AH=08 failed', 13,10,'$'
        align 16
buf:    times 512 db 0
buf2:   times 512 db 0
