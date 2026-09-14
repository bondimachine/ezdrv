; ata.asm - polled PIO ATA/IDE layer (resident).
;
; Everything here goes straight at the task file; INT 13h is never used,
; which is the whole point: the BIOS is the thing that cannot see past
; cylinder 1023. Transfers are polled rather than interrupt driven so the
; driver does not have to steal IRQ14 from the BIOS, which is still
; servicing the boot partition on the same drive. Every command ends with
; a read of the real status register, which acknowledges the INTRQ the
; drive raised, so the BIOS's own IRQ14 handler stays happy.

; ---------------------------------------------------------------------
; Word-at-a-time data port moves. The 8086 build loses REP INSW/OUTSW;
; on ISA the I/O cycle dominates anyway, so the loop costs little.
%macro PIO_READ 0
%ifdef CPU8086
        mov     cx, SEC_SZ/2
%%l:    in      ax, dx
        stosw
        loop    %%l
%else
        mov     cx, SEC_SZ/2
        rep     insw
%endif
%endmacro

%macro PIO_WRITE 0
%ifdef CPU8086
        mov     cx, SEC_SZ/2
%%l:    lodsw
        out     dx, ax
        loop    %%l
%else
        mov     cx, SEC_SZ/2
        rep     outsw
%endif
%endmacro

; ---------------------------------------------------------------------
; Resident ATA state
ata_base:   dw ATA_PRIMARY              ; command block base
ata_ctl:    dw ATA_PRI_CTL              ; control block (alternate status)
ata_sel:    db 0xE0                     ; device register: LBA | master
ata_idsel:  db 0xA0                     ; device register for IDENTIFY
use_lba:    db 1                        ; 0 = address the drive in CHS
drv_spt:    dw 63                       ; native geometry, for the CHS path
drv_heads:  dw 16
drv_track:  dw 63*16                    ; spt * heads
ata_err:    db 0                        ; last error register, 0 = timeout

; ---------------------------------------------------------------------
; ata_delay: four alternate-status reads, the canonical 400 ns settle.
; Reading the *alternate* status has no side effects on INTRQ.
ata_delay:
        push    ax
        push    dx
        mov     dx, [cs:ata_ctl]
        in      al, dx
        in      al, dx
        in      al, dx
        in      al, dx
        pop     dx
        pop     ax
        ret

; ---------------------------------------------------------------------
; ata_wait_bsy: spin until BSY clears.
; In:  CX = timeout in BIOS ticks.
; Out: CF set on timeout. Clobbers AX.
ata_wait_bsy:
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ds
        mov     dx, [cs:ata_ctl]
        mov     si, cx                  ; tick budget
        mov     di, 4096                ; backstop if the timer is dead
        mov     ax, BDA_SEG
        mov     ds, ax
        mov     bx, [BDA_TICKS]
.round:
        mov     cx, 0x4000
.spin:
        in      al, dx
        test    al, ST_BSY
        jz      .ready
        loop    .spin
        mov     cx, [BDA_TICKS]
        sub     cx, bx                  ; unsigned, so midnight wrap is fine
        cmp     cx, si
        jae     .timeout
        dec     di
        jnz     .round
.timeout:
        stc
        jmp     .out
.ready:
        clc
.out:
        pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        ret

; ---------------------------------------------------------------------
; ata_select: point the task file at our drive and let it settle.
ata_select:
        push    ax
        push    dx
        mov     dx, [cs:ata_base]
        add     dx, ATA_DEVICE
        mov     al, [cs:ata_sel]
        out     dx, al
        pop     dx
        pop     ax
        jmp     ata_delay

; ---------------------------------------------------------------------
; ata_grab_err: latch the error register for the DOS error mapping.
ata_grab_err:
        push    dx
        mov     dx, [cs:ata_base]
        add     dx, ATA_ERROR
        in      al, dx
        or      al, al
        jnz     .have
        mov     al, 0xFF                ; error bit set but no reason given
.have:
        mov     [cs:ata_err], al
        pop     dx
        ret

; ---------------------------------------------------------------------
; ata_issue: program the task file for [rw_lba]/[rw_n] and start the
; command selected by [rw_op]. Out: CF set on timeout.
ata_issue:
        cmp     byte [use_lba], 0
        jne     .select
        call    lba_to_chs
.select:
        call    ata_select
        mov     cx, TICKS_IO
        call    ata_wait_bsy
        jc      .fail

        mov     dx, [ata_base]
        add     dx, ATA_COUNT
        mov     ax, [rw_n]
        out     dx, al                  ; 0 would mean 256; rw_n is 1..64

        cmp     byte [use_lba], 0
        je      .chs
        inc     dx                      ; ATA_LBA0
        mov     al, [rw_lba]
        out     dx, al
        inc     dx                      ; ATA_LBA1
        mov     al, [rw_lba+1]
        out     dx, al
        inc     dx                      ; ATA_LBA2
        mov     al, [rw_lba+2]
        out     dx, al
        inc     dx                      ; ATA_DEVICE
        mov     al, [rw_lba+3]
        and     al, 0x0F
        jmp     .device
.chs:
        inc     dx                      ; ATA_LBA0 = sector number
        mov     al, [chs_sec]
        out     dx, al
        inc     dx                      ; ATA_LBA1 = cylinder low
        mov     al, [chs_cyl]
        out     dx, al
        inc     dx                      ; ATA_LBA2 = cylinder high
        mov     al, [chs_cyl+1]
        out     dx, al
        inc     dx                      ; ATA_DEVICE
        mov     al, [chs_head]
        and     al, 0x0F
.device:
        or      al, [ata_sel]
        out     dx, al

        mov     dx, [ata_base]
        add     dx, ATA_COMMAND
        mov     al, CMD_READ
        cmp     byte [rw_op], 0
        je      .go
        mov     al, CMD_WRITE
.go:
        out     dx, al
        call    ata_delay
        clc
        ret
.fail:
        mov     byte [ata_err], 0       ; timeout
        stc
        ret

; ---------------------------------------------------------------------
; ata_wait_drq: wait for the drive to be ready with a data block.
; Out: CF set on error/timeout, with [ata_err] latched.
ata_wait_drq:
        mov     cx, TICKS_IO
        call    ata_wait_bsy
        jc      .timeout
        mov     dx, [ata_base]
        add     dx, ATA_STATUS          ; the real one: clears INTRQ
        in      al, dx
        test    al, ST_ERR|ST_DF
        jnz     .err
        test    al, ST_DRQ
        jz      .err
        clc
        ret
.err:
        call    ata_grab_err
        stc
        ret
.timeout:
        mov     byte [ata_err], 0
        stc
        ret

; ---------------------------------------------------------------------
; ata_chunk: one READ/WRITE SECTORS command of [rw_n] sectors starting at
; [rw_lba], moving data to/from [rw_buf]. [rw_buf] is advanced past the
; data. Out: CF set on failure, with [ata_err] latched (0 = timeout).
ata_chunk:
        push    bp
        call    ata_issue
        jc      .failed
        mov     bp, [rw_n]
.sector:
        call    ata_wait_drq
        jc      .failed
        call    norm_buf                ; keep offset+512 inside the segment
        cld
        cmp     byte [rw_op], 0
        jne     .write
        les     di, [rw_buf]
        mov     dx, [ata_base]
        PIO_READ
        jmp     .next
.write:
        push    ds
        lds     si, [rw_buf]
        mov     dx, [cs:ata_base]
        PIO_WRITE
        pop     ds
.next:
        add     word [rw_buf], SEC_SZ
        dec     bp
        jnz     .sector

        mov     cx, TICKS_IO
        call    ata_wait_bsy
        jc      .timeout
        mov     dx, [ata_base]
        add     dx, ATA_STATUS
        in      al, dx
        test    al, ST_ERR|ST_DF
        jnz     .status_err
        pop     bp
        clc
        ret
.status_err:
        call    ata_grab_err
        jmp     .failed
.timeout:
        mov     byte [ata_err], 0
.failed:
        pop     bp
        stc
        ret

; ---------------------------------------------------------------------
; ata_flush: ask the drive to commit its write cache. Pre-ATA-4 drives
; abort this command; that is harmless, so the result is ignored.
ata_flush:
        call    ata_select
        mov     cx, TICKS_IO
        call    ata_wait_bsy
        jc      .out
        mov     dx, [ata_base]
        add     dx, ATA_COMMAND
        mov     al, CMD_FLUSH
        out     dx, al
        call    ata_delay
        mov     cx, TICKS_IO
        call    ata_wait_bsy
        mov     dx, [ata_base]
        add     dx, ATA_STATUS
        in      al, dx                  ; acknowledge INTRQ either way
.out:
        ret

; ---------------------------------------------------------------------
; lba_to_chs: [rw_lba] -> [chs_cyl]/[chs_head]/[chs_sec] using the
; drive's native geometry. Only reached on pre-LBA drives, where the
; native cylinder count still fits a word.
lba_to_chs:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     ax, [rw_lba]
        mov     dx, [rw_lba+2]
        mov     bx, [drv_track]
        call    div32                   ; DX:AX = cylinder, CX = remainder
        mov     [chs_cyl], ax
        mov     ax, cx
        xor     dx, dx
        div     word [drv_spt]
        mov     [chs_head], al
        inc     dl                      ; sectors are numbered from 1
        mov     [chs_sec], dl
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ---------------------------------------------------------------------
; div32: DX:AX / BX -> DX:AX quotient, CX remainder. No overflow as long
; as the true quotient fits 32 bits, which it does here.
div32:
        push    si
        mov     cx, ax
        mov     ax, dx
        xor     dx, dx
        div     bx                      ; high half
        mov     si, ax
        mov     ax, cx
        div     bx                      ; low half, DX = remainder
        mov     cx, dx
        mov     dx, si
        pop     si
        ret

; ---------------------------------------------------------------------
; norm_buf: renormalise [rw_buf] so the offset is below 16. Sector moves
; then cannot run off the end of the segment, whatever DOS handed us.
norm_buf:
        push    ax
        push    cx
        mov     ax, [rw_buf]
        mov     cx, ax
        and     ax, 0x000F
        mov     [rw_buf], ax
        shr     cx, 1
        shr     cx, 1
        shr     cx, 1
        shr     cx, 1
        add     [rw_buf+2], cx
        pop     cx
        pop     ax
        ret
