; w95sim.asm - W95SIM.COM: simulate the Windows startup and exit
; broadcasts (INT 2Fh AX=1605h / AX=1606h) against the resident overlay
; and report whether the INT 13h hook stayed put or stepped aside.
;
; Expected: the hook survives a Windows 3.x start always. It survives a
; Windows 9x start too UNLESS the BIOS underneath serves the identical
; 255x63 translation (QEMU: bios-chs-trans=lba) - then it unhooks on
; 1605h and re-hooks on the 1606h exit broadcast. On the pre-LBA
; machines the overlay exists for, every line must say "hooked".
;
; Build: nasm -f bin src/w95sim.asm -o W95SIM.COM

        cpu     8086
        org     0x100

start:
        mov     dx, m_banner
        call    puts
        call    diag
        mov     dx, m_start
        call    report

        mov     di, 0x030A              ; Windows 3.10, enhanced mode
        call    bcast_up
        mov     dx, m_w31
        call    report
        call    bcast_down

        mov     di, 0x0400              ; Windows 95
        call    bcast_up
        mov     dx, m_w95
        call    report

        call    bcast_down
        mov     dx, m_exit
        call    report

        mov     ax, 0x4C00
        int     0x21

; ---------------------------------------------------------------------
; bcast_up: INT 2Fh AX=1605h with the register image WIN.COM uses:
; ES:BX = DS:SI = 0000:0000, CX = 0, DX = 0 (enhanced-mode Windows),
; DI = version. bcast_down: the matching AX=1606h exit broadcast.
bcast_up:
        push    ds
        push    es
        push    bp
        mov     ax, 0x1605
        xor     bx, bx
        mov     es, bx
        xor     cx, cx
        xor     dx, dx
        xor     si, si
        mov     ds, si
        int     0x2F
        pop     bp
        pop     es
        pop     ds
        ret

bcast_down:
        push    ds
        push    es
        push    bp
        mov     ax, 0x1606
        xor     dx, dx                  ; enhanced-mode Windows exit
        int     0x2F
        pop     bp
        pop     es
        pop     ds
        ret

; ---------------------------------------------------------------------
; report: print the label in DX, then the overlay's presence.
report:
        call    puts
        mov     ah, 0xE0                ; overlay private presence check
        mov     bx, 0x1357
        mov     dl, 0x80
        int     0x13
        jc      .un
        cmp     ax, 0x4F4B              ; 'OK'
        jne     .un
        mov     dx, m_hooked
        jmp     puts
.un:
        mov     dx, m_unhooked
        jmp     puts

; diag: query the overlay's private AH=E1h state - AL = unhook gate,
; CH = first failing gate check, BX/DX = the raw AH=08 CX/DX seen from
; the BIOS underneath - probe the INT 2Fh chain, and print it all.
diag:
        mov     ah, 0xE1
        mov     dl, 0x80
        int     0x13
        jc      .none
        mov     [d_ax], ax
        mov     [d_bx], bx
        mov     [d_cx], cx
        mov     [d_dx], dx
        mov     dx, m_gate
        call    puts
        mov     ax, [d_ax]
        or      al, al
        mov     dx, m_open
        jnz     .g
        mov     dx, m_closed
.g:
        call    puts
        mov     dx, m_2f
        call    puts
        mov     ax, 0xE000              ; the overlay's chain probe
        mov     bx, 0x1357
        int     0x2F
        cmp     bx, 0x5A44
        mov     dx, m_placed
        je      .h
        mov     dx, m_pending
.h:
        call    puts
        mov     dx, m_step
        call    puts
        mov     ax, [d_cx]
        mov     dl, ah                  ; gate step as a digit
        add     dl, '0'
        mov     ah, 0x02
        int     0x21
        mov     dx, m_pcx
        call    puts
        mov     ax, [d_bx]
        call    hex4
        mov     dx, m_pdx
        call    puts
        mov     ax, [d_dx]
        call    hex4
        mov     dx, m_crlf
        jmp     puts
.none:
        ret

; hex4: print AX as four hex digits.
hex4:
        push    cx
        mov     cx, 4
.d:
        push    cx
        mov     cl, 4
        rol     ax, cl
        push    ax
        and     al, 0x0F
        add     al, '0'
        cmp     al, '9'
        jbe     .p
        add     al, 7
.p:
        mov     dl, al
        mov     ah, 0x02
        int     0x21
        pop     ax
        pop     cx
        loop    .d
        pop     cx
        ret

puts:
        mov     ah, 0x09
        int     0x21
        ret

; ---------------------------------------------------------------------
m_banner:   db 'W95SIM: INT 2Fh 1605h/1606h broadcast simulation', 13, 10, '$'
m_start:    db 'W95SIM: at start:           $'
m_w31:      db 'W95SIM: after Win3.1 start: $'
m_w95:      db 'W95SIM: after Win95 start:  $'
m_exit:     db 'W95SIM: after Windows exit: $'
m_hooked:   db 'hooked', 13, 10, '$'
m_unhooked: db 'UNHOOKED', 13, 10, '$'
m_gate:     db 'W95SIM: unhook gate:        $'
m_open:     db 'open (BIOS below matches)', 13, 10, '$'
m_closed:   db 'closed (hook is load-bearing)', 13, 10, '$'
m_2f:       db 'W95SIM: INT 2Fh hook:       $'
m_placed:   db 'placed', 13, 10, '$'
m_pending:  db 'pending', 13, 10, '$'
m_step:     db 'W95SIM: gate: step=$'
m_pcx:      db ' cx=$'
m_pdx:      db ' dx=$'
m_crlf:     db 13, 10, '$'
d_ax:       dw 0
d_bx:       dw 0
d_cx:       dw 0
d_dx:       dw 0
