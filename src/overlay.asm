; overlay.asm - EZDRV: the resident half of the standard-layout overlay.
;
; This is the INT 13h handler an old BIOS never had. Installed before DOS
; starts (by the MBR loader, mbr.asm), it presents drive 80h to DOS with a
; translated 255 x 63 geometry so the whole disk fits under 1024 cylinders,
; and it services every request by talking LBA straight to the IDE task
; file - the same polled-PIO layer the CONFIG.SYS driver uses (ata.asm).
;
; Unlike EZ-Drive and friends it changes NOTHING on the medium: the MBR
; boot code lives in the 446 bytes LBA 0 already reserves, this body lives
; in the track-0 gap (sectors 2..62, unallocated on a standard layout),
; and the partition table stays at offset 0x1BE with ordinary type bytes
; and true LBA fields. A modern OS reads the disk with no help at all.
;
; The image is a flat binary with a tiny fixed header so the loader can
; find the entry points regardless of how the body is assembled:
;
;   [0]  dd  old_int13   - previous INT 13h vector (loader fills this in)
;   [4]  dw  isr         - runtime handler offset
;   [6]  dw  install     - one-shot init offset (loader far-calls it)
;   [8]  dd  old2f       - previous INT 2Fh vector (install fills this in)
;   [12] dw  isr2f       - INT 2Fh handler offset (loader /U restores it)
;
; Build: nasm -f bin -i src/ -dCPU8086 src/overlay.asm -o OVERLAY.BIN

%ifdef CPU8086
        cpu     8086
%else
        cpu     186
%endif
        org     0

%include "structs.inc"

FAKE_HEADS      equ 255         ; translated geometry presented to DOS
FAKE_SPT        equ 63          ; 1024 x 255 x 63 x 512 = 8.0 GB reach
FAKE_TRACK      equ FAKE_HEADS*FAKE_SPT

; ---------------------------------------------------------------------
; Fixed header
header:
old_int13:  dd 0                ; [0]  previous vector, filled by the loader
            dw isr              ; [4]  runtime handler
            dw install          ; [6]  one-shot init
old2f:      dd 0                ; [8]  previous INT 2Fh vector
            dw isr2f            ; [12] INT 2Fh handler (Windows broadcasts)

; ---------------------------------------------------------------------
; INT 13h handler.
;
; The awkward part of any INT 13h hook is returning a status: the caller
; reads CF and AH, so we cannot simply IRET. We save the full register
; file on entry, let each sub-handler write its results back into that
; saved image, then a common epilogue pops the image (restoring the
; results) and pokes CF into the stacked FLAGS before IRET.
isr:
        cmp     dl, 0x80                ; only our disk; everything else
        jne     .chain                  ; goes to the original BIOS

        push    ds
        push    es
        push    bp
        push    di
        push    si
        push    dx
        push    cx
        push    bx
        push    ax
        mov     bp, sp                  ; frame: [bp+0]=AX .. [bp+22]=FLAGS
        push    cs
        pop     ds                      ; our data segment

        cmp     byte [inited], 0
        jne     .ready
        call    install_near           ; near: we are already in this segment
.ready:
%ifdef TRACE
        ; log the request into the ring: func dl ch cl dh al 00 00
        mov     di, [ring_w]
        mov     al, [bp+1]
        mov     [ring+di], al           ; function (caller AH)
        mov     al, [bp+6]
        mov     [ring+di+1], al         ; caller DL
        mov     ax, [bp+4]
        mov     [ring+di+2], ax         ; caller CX
        mov     al, [bp+7]
        mov     [ring+di+4], al         ; caller DH
        mov     al, [bp+0]
        mov     [ring+di+5], al         ; caller AL (count)
        mov     word [ring+di+6], 0x9999 ; result placeholder
        mov     [ring_cur], di
        add     di, 8
        and     di, RING_MASK
        mov     [ring_w], di
%endif
        ; Dispatch: reads and writes first - they are the hot path and
        ; pay for nothing else. The query/status functions each start
        ; with a verify2f call (see there), which is how the INT 2Fh
        ; chain position gets maintained without ever taxing an I/O.
        mov     ah, [bp+1]              ; requested function
        cmp     ah, 0x02
        je      .read
        cmp     ah, 0x03
        je      .write
        cmp     ah, 0x42
        je      .extread
        cmp     ah, 0x43
        je      .extwrite
        cmp     ah, 0x04
        je      .verify
        cmp     ah, 0x08
        je      .getparm
        cmp     ah, 0x48
        je      .extparm
        cmp     ah, 0x41
        je      .extchk
        cmp     ah, 0x15
        je      .gettype
        cmp     ah, 0x01
        je      .status
        cmp     ah, 0xE0                ; private: "are you there?"
        je      .present
        cmp     ah, 0xE1                ; private: Windows-unhook state
        je      .diag
        cmp     ah, 0x00
        je      .ok0
        cmp     ah, 0x09
        je      .ok0
        cmp     ah, 0x0C
        je      .ok0
        cmp     ah, 0x0D
        je      .ok0
        cmp     ah, 0x10
        je      .ok0
        cmp     ah, 0x11
        je      .ok0
        ; anything else: report invalid function
        mov     byte [bp+1], 0x01
        stc
        jmp     .done

.chain:
        jmp     far [cs:old_int13]

; --- CHS read / write ------------------------------------------------
.read:
        call    chs_to_lba
        mov     byte [rw_op], 0
        jmp     .chs_io
.write:
        call    chs_to_lba
        mov     byte [rw_op], 1
.chs_io:
        mov     ax, [bp+2]              ; caller BX
        mov     [rw_buf], ax
        mov     ax, [bp+14]             ; caller ES
        mov     [rw_buf+2], ax
        mov     cx, [bp+0]
        and     cx, 0x00FF              ; AL = sector count
        call    xfer_run
        jc      .io_err
        mov     [bp+0], al             ; AL = sectors transferred
        mov     byte [bp+1], 0
        clc
        jmp     .done
.io_err:
        mov     [bp+0], al
        call    bios_err_code          ; AL = BIOS status
        mov     [bp+1], al
        stc
        jmp     .done

; --- LBA read / write (INT 13h extensions) ---------------------------
.extread:
        xor     al, al
        jmp     .ext_io
.extwrite:
        mov     al, 1
.ext_io:
        mov     [rw_op], al
        mov     es, [bp+16]            ; caller DS
        mov     di, [bp+8]             ; caller SI -> disk address packet
        mov     ax, [es:di+8]          ; LBA, low 32 bits
        mov     [rw_lba], ax
        mov     ax, [es:di+10]
        mov     [rw_lba+2], ax
        mov     ax, [es:di+4]          ; transfer buffer off:seg
        mov     [rw_buf], ax
        mov     ax, [es:di+6]
        mov     [rw_buf+2], ax
        mov     cx, [es:di+2]          ; sector count
        push    es
        push    di
        call    xfer_run
        pop     di
        pop     es
        jc      .ext_err
        mov     [es:di+2], ax          ; report count actually moved
        mov     byte [bp+1], 0
        clc
        jmp     .done
.ext_err:
        mov     [es:di+2], ax
        call    bios_err_code
        mov     [bp+1], al
        stc
        jmp     .done

; --- AH=08 get drive parameters (translated geometry) ----------------
.getparm:
        call    verify2f
        mov     ax, [fake_cyls]
        dec     ax                     ; max cylinder = cyls - 1
        mov     ch, al                 ; CH = cyl bits 0..7
        mov     bl, ah                 ; cyl bits 8..9
        mov     cl, 6
        shl     bl, cl
        and     bl, 0xC0
        or      bl, FAKE_SPT           ; CL = cyl-hi | sectors
        mov     cl, bl
        mov     [bp+4], cx             ; CX
        mov     dh, FAKE_HEADS-1       ; max head
        ; DL = number of hard disks. This is how DOS learns that drive 81h
        ; exists, so report the BIOS's own count (BDA 40:75) - hardcoding 1
        ; made a slave disk vanish. Calls for other drives chain through
        ; untouched (see isr), the BIOS serves them as before. Floor at 1
        ; for setups whose CMOS says "none" about the disk we serve.
        xor     ax, ax
        mov     es, ax
        mov     dl, [es:0x475]
        or      dl, dl
        jnz     .cnt_ok
        mov     dl, 1
.cnt_ok:
        mov     [bp+6], dx             ; DX
        ; ES:DI are left untouched: for hard disks AH=08 returns no DPT,
        ; and callers (IO.SYS among them) assume their ES survives.
        ; Clobbering it sent IO.SYS's later writes into segment 0 and hung
        ; the boot.
        mov     byte [bp+1], 0
        clc
        jmp     .done

; --- AH=15 get disk type ---------------------------------------------
.gettype:
        call    verify2f
        mov     byte [bp+1], 0x03      ; fixed disk present
        mov     ax, [total_lo]
        mov     [bp+6], ax             ; DX = sectors low
        mov     ax, [total_hi]
        mov     [bp+4], ax             ; CX = sectors high
        clc
        jmp     .done

; --- AH=41 extensions installation check -----------------------------
.extchk:
        call    verify2f
        mov     ax, [bp+2]             ; caller BX must be 0x55AA
        cmp     ax, 0x55AA
        jne     .badf
        mov     word [bp+2], 0xAA55    ; BX
        mov     word [bp+4], 0x0001    ; CX: bit0 = extended read/write
        mov     byte [bp+1], 0x21      ; version 2.1
        clc
        jmp     .done
.badf:
        mov     byte [bp+1], 0x01
        stc
        jmp     .done

; --- AH=48 get extended drive parameters -----------------------------
.extparm:
        call    verify2f
        mov     es, [bp+16]            ; caller DS
        mov     di, [bp+8]             ; caller SI -> result buffer
        mov     word [es:di+0], 0x1A   ; buffer size
        mov     word [es:di+2], 0      ; flags
        mov     ax, [fake_cyls]
        mov     [es:di+4], ax          ; cylinders
        mov     word [es:di+6], 0
        mov     word [es:di+8], FAKE_HEADS
        mov     word [es:di+10], 0
        mov     word [es:di+12], FAKE_SPT
        mov     word [es:di+14], 0
        mov     ax, [total_lo]         ; total sectors, 64-bit
        mov     [es:di+16], ax
        mov     ax, [total_hi]
        mov     [es:di+18], ax
        mov     word [es:di+20], 0
        mov     word [es:di+22], 0
        mov     word [es:di+24], SEC_SZ
        mov     byte [bp+1], 0
        clc
        jmp     .done

.present:
        call    verify2f
        mov     word [bp+0], 0x4F4B     ; AX = 'OK', signals we are resident
        clc
        jmp     .done
.diag:
        call    verify2f
        mov     al, [may_unhook]        ; AL: Win9x may unhook us
        xor     ah, ah                  ; (chain position: probe INT 2Fh
        mov     [bp+0], ax              ; AX=E000h BX=1357h instead)
        mov     al, [unhooked]          ; CL: currently stepped aside
        mov     ah, [gate_step]         ; CH: first gate check that failed
        mov     [bp+4], ax
        mov     ax, [p_cx]              ; BX: raw AH=08 CX from the BIOS
        mov     [bp+2], ax              ; underneath, DX: its DX
        mov     ax, [p_dx]
        mov     [bp+6], ax
        clc
        jmp     .done
.status:
        call    verify2f
        mov     al, [last_st]
        mov     [bp+1], al
        clc
        jmp     .done
.ok0:                                  ; reset & co: rare control calls,
        call    verify2f               ; another cheap place to re-verify
.verify:                               ; (but not AH=04: FORMAT hammers it)
        mov     byte [bp+1], 0
        clc
        ; fall through

.done:
%ifdef TRACE
        pushf                           ; keep CF for the real epilogue
        push    di
        push    ax
        mov     di, [ring_cur]
        mov     al, [bp+1]
        mov     [ring+di+6], al         ; result AH
        mov     al, 0
        jnc     .trace_ok
        mov     al, 1
.trace_ok:
        mov     [ring+di+7], al         ; result CF
        pop     ax
        pop     di
        popf
%endif
        jc      .set_cf
        and     byte [bp+22], 0xFE     ; CF = 0 in stacked FLAGS
        jmp     .pop
.set_cf:
        or      byte [bp+22], 0x01     ; CF = 1
.pop:
        mov     al, [bp+1]
        mov     [last_st], al
        pop     ax
        pop     bx
        pop     cx
        pop     dx
        pop     si
        pop     di
        pop     bp
        pop     es
        pop     ds
        iret

; ---------------------------------------------------------------------
; INT 2Fh handler: watch Windows start (AX=1605h) and exit (AX=1606h).
;
; Windows 9x's protected-mode IDE driver reads the partition table from
; LBA 0 itself - which on this layout is simply a correct, standard
; table - but its IOS refuses protected mode ("MS-DOS compatibility
; mode") while an unknown real-mode INT 13h hook is present. So when
; Windows 4.00+ announces itself we step aside - but ONLY when install
; found an LBA-assist BIOS underneath serving the identical 255x63
; translation (may_unhook). The broadcast comes BEFORE Windows loads
; its VxDs through real-mode DOS, whose CHS geometry was latched
; through us at boot: on a genuinely old BIOS, removing the hook there
; would misaddress every sector from that moment on. On such machines
; the hook stays and Windows 9x runs in (correct, slower) compatibility
; mode instead.
;
; Windows 3.x (DI < 0400h) reflects all disk I/O to the real-mode hook
; and needs us live: never unhook for it. Its FastDisk "32-bit disk
; access" probe (WDCTRL validates the FDPT against the controller)
; rejects our translated geometry on its own, which is the safe outcome.
isr2f:
        cmp     ax, 0xE000              ; private installation check the
        je      .probe                  ; ISR uses to verify chain position
        cmp     ax, 0x1605
        je      .winup
        cmp     ax, 0x1606
        je      .windown
.chain:
        jmp     far [cs:old2f]

.probe:
        cmp     bx, 0x1357
        jne     .chain
        mov     al, 0xFF                ; multiplex "installed" convention
        mov     bx, 0x5A44              ; plus our signature
        iret

.winup:
        test    dl, 1                   ; bit 0 set: 286 DOS extender
        jnz     .chain                  ; (standard mode), not enhanced
        cmp     di, 0x0400              ; version < 4.00: Windows 3.x
        jb      .chain
        cmp     byte [cs:may_unhook], 0
        je      .chain
        push    ds
        push    ax
        xor     ax, ax
        mov     ds, ax
        mov     ax, cs                  ; unhook only from the top of the
        cmp     [0x4E], ax              ; chain: mid-chain surgery would
        jne     .updone                 ; drop whoever hooked above us
        cmp     word [0x4C], isr
        jne     .updone
        pushf
        cli
        mov     ax, word [cs:old_int13]
        mov     [0x4C], ax
        mov     ax, word [cs:old_int13+2]
        mov     [0x4E], ax
        popf
        mov     byte [cs:unhooked], 1
.updone:
        pop     ax
        pop     ds
        jmp     .chain

.windown:
        cmp     byte [cs:unhooked], 0
        je      .chain
        push    ds
        push    ax
        xor     ax, ax
        mov     ds, ax
        mov     ax, [0x4C]              ; anything that hooked INT 13h
        mov     word [cs:old_int13], ax ; while Windows ran now chains
        mov     ax, [0x4E]              ; below us again
        mov     word [cs:old_int13+2], ax
        pushf
        cli
        mov     word [0x4C], isr
        mov     ax, cs
        mov     [0x4E], ax
        popf
        mov     byte [cs:unhooked], 0
        pop     ax
        pop     ds
        jmp     .chain

iret_stub:
        iret

; ---------------------------------------------------------------------
; verify2f: keep isr2f in the INT 2Fh chain. Called from the ISR's
; query/status handlers (AH=00/01/08/15/41/48 and the private E0/E1) -
; never from a read, write or verify, so the I/O hot path pays nothing.
; Those are the right trigger: geometry and status queries are exactly
; what FDISK, SMARTDRV, our own tools and Windows' startup issue before
; anything interesting happens, while a missed broadcast at worst
; leaves Win9x in compatibility mode - never corruption.
;
; Why maintenance is needed at all: DOS overwrites the INT 2Fh vector
; during boot - several times, and its boot-time handlers RETIRE. The
; check: vector is ours, or the chain head we already verified - done.
; Otherwise probe the chain with our private installation check
; (AX=E000h): if isr2f answers we are merely chained under someone -
; remember that head and stand down; only when genuinely unreachable
; take the top again. Taking only-when-unreachable makes chain loops
; impossible.
;
; The capture is also zone-gated (hard-won lesson): DOS's SYSINIT runs
; a TRANSIENT copy of itself at the top of conventional memory -
; directly below our carve - with INT 2Fh hooked from there, and frees
; it when boot completes. Capturing it as old2f dangled our chain into
; dead memory and crashed the first INT 2Fh call after boot. So only a
; handler that can outlive boot (low memory, or ROM/HMA) is accepted
; as a chain target; the band just under the carve merely defers the
; re-take to a later query.
;
; Clobbers AX/BX/CX/DX/ES; callers read their inputs from the stack
; frame afterwards. DS = CS (the ISR set it).
verify2f:
%ifdef NO_RETAKE
        ret
%else
        xor     ax, ax
        mov     es, ax
        mov     ax, [es:0xBC]           ; current INT 2Fh vector
        mov     dx, [es:0xBE]
        mov     bx, cs
        cmp     dx, bx
        jne     .notus
        cmp     ax, isr2f
        je      .done                   ; ours: nothing to do
.notus:
        cmp     ax, [last2f]            ; the chain head we last verified
        jne     .changed                ; still reaches us?
        cmp     dx, [last2f+2]
        je      .done
.changed:
        mov     cx, ax
        or      cx, dx
        jz      .take                   ; empty vector: unreachable
        push    ax
        push    dx
        mov     ax, 0xE000              ; probe: does the chain reach us?
        mov     bx, 0x1357
        int     0x2F
        cmp     bx, 0x5A44              ; isr2f's signature answer
        pop     dx
        pop     ax
        jne     .take
        mov     [last2f], ax            ; chained under someone: fine,
        mov     [last2f+2], dx          ; remember that chain head
        ret
.take:
        cmp     dx, 0xF000              ; ROM / HMA: permanent, take it
        jae     .zone_ok
        mov     bx, cs
        sub     bx, 0x2000              ; 128KB band below our carve:
        cmp     dx, bx                  ; SYSINIT's transient zone -
        jae     .done                   ; wait for a later query
.zone_ok:
        mov     cx, ax
        or      cx, dx
        jnz     .save
        mov     ax, iret_stub           ; empty vector: chain to an IRET
        mov     dx, cs
.save:
        mov     [old2f], ax
        mov     [old2f+2], dx
        pushf
        cli
        mov     word [es:0xBC], isr2f
        mov     [es:0xBE], cs
        popf
.done:
        ret
%endif

; ---------------------------------------------------------------------
; chs_to_lba: read the caller's CHS from the saved frame ([bp+4]=CX,
; [bp+6]=DX) and store the translated LBA in [rw_lba].
;   lba = (cyl * FAKE_HEADS + head) * FAKE_SPT + (sector - 1)
chs_to_lba:
        mov     cx, [bp+4]             ; CH=cyl low, CL=cyl hi|sector
        mov     dx, [bp+6]             ; DH=head
        mov     al, cl
        and     al, 0x3F               ; sector 1..63
        mov     [c_sec], al
        mov     al, ch                 ; AL = cylinder bits 0..7
        mov     ah, cl                 ; AH = cylinder bits 8..9 (in bits 6..7)
        and     ah, 0xC0
        mov     cl, 6
        shr     ah, cl                 ; AH = cylinder bits 8..9
        mov     [c_cyl], ax            ; AX = AL | (AH<<8) = full cylinder
        mov     [c_head], dh

        ; T = cyl * FAKE_HEADS + head
        mov     ax, [c_cyl]
        mov     bx, FAKE_HEADS
        mul     bx                     ; DX:AX = cyl * 255
        mov     bl, [c_head]
        xor     bh, bh
        add     ax, bx
        adc     dx, 0                  ; DX:AX = T (fits, < ~261120)

        ; lba = T * FAKE_SPT + (sector - 1)
        mov     bx, FAKE_SPT
        mov     cx, dx                 ; save T high
        mul     bx                     ; DX:AX = Tlow * 63
        mov     [rw_lba], ax
        mov     [rw_lba+2], dx
        mov     ax, cx                 ; Thigh * 63 (Thigh <= 4)
        mul     bx
        add     [rw_lba+2], ax         ; high contribution
        mov     al, [c_sec]
        dec     al
        xor     ah, ah
        add     [rw_lba], ax
        adc     word [rw_lba+2], 0
        ret

; ---------------------------------------------------------------------
; xfer_run: move CX sectors, [rw_lba]/[rw_op]/[rw_buf] already set.
; Splits into MAX_CHUNK commands. Out: AX = sectors moved, CF on error.
xfer_run:
        push    si
        xor     si, si
.loop:
        or      cx, cx
        jz      .ok
        mov     ax, cx
        cmp     ax, MAX_CHUNK
        jbe     .n
        mov     ax, MAX_CHUNK
.n:     mov     [rw_n], ax
        push    cx
        push    si
        call    ata_chunk              ; advances [rw_buf]; CF on error
        pop     si
        pop     cx
        jc      .err
        mov     ax, [rw_n]
        add     si, ax
        sub     cx, ax
        add     [rw_lba], ax
        adc     word [rw_lba+2], 0
        jmp     .loop
.ok:
        mov     ax, si
        pop     si
        clc
        ret
.err:
        mov     ax, si
        pop     si
        stc
        ret

; ---------------------------------------------------------------------
; bios_err_code: [ata_err] (0 = timeout) -> AL = INT 13h status byte.
bios_err_code:
        mov     al, [ata_err]
        or      al, al
        jz      .timeout
        test    al, ER_UNC
        jnz     .ecc
        test    al, ER_IDNF
        jnz     .notfound
        test    al, ER_ABRT
        jnz     .notfound
        mov     al, 0x0C               ; general
        ret
.ecc:
        mov     al, 0x10               ; uncorrectable data error
        ret
.notfound:
        mov     al, 0x04               ; sector not found
        ret
.timeout:
        mov     al, 0x80               ; timeout / not ready
        ret

; ---------------------------------------------------------------------
; The ATA layer (and its PIO_READ/PIO_WRITE macros) must be in scope
; before ovl_identify below uses them.
%include "ata.asm"

; ---------------------------------------------------------------------
; install: far entry for the MBR/loader (they call across segments).
; install_near: the same work, near-callable from the ISR (same segment).
install:
        call    install_near
        retf
install_near:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es
        push    ds
        push    cs
        pop     ds

        cmp     byte [inited], 0
        jne     .out

        call    ata_reset
        call    ovl_identify

        ; fake_cyls = total_sectors / (FAKE_HEADS * FAKE_SPT), clamped 1024
        mov     ax, [total_lo]
        mov     dx, [total_hi]
        mov     bx, FAKE_TRACK
        call    div32                  ; DX:AX = quotient
        or      dx, dx
        jnz     .clamp
        cmp     ax, 1024
        jbe     .store
.clamp:
        mov     ax, 1024
.store:
        mov     [fake_cyls], ax

        ; Point INT 41h (drive 80h fixed disk parameter table) at our
        ; translated FDPT. IO.SYS reads the FDPT directly and hangs at
        ; boot if it contradicts what AH=08 reports - the same reason
        ; every classic DDO carries its own parameter table.
        mov     [fdpt_cyls], ax
        mov     ax, [i_pcyls]
        mov     [fdpt_pcyl], ax
        mov     [fdpt_land], ax
        mov     al, [drv_heads]
        mov     [fdpt_phds], al
        mov     al, [drv_spt]
        mov     [fdpt_pspt], al
        ; checksum: whole 16 bytes must sum to zero
        mov     byte [fdpt_sum], 0
        mov     si, fdpt
        mov     cx, 15
        xor     ax, ax
.sum:   add     al, [si]
        inc     si
        loop    .sum
        neg     al
        mov     [fdpt_sum], al
        xor     ax, ax
        mov     es, ax
        mov     word [es:0x104], fdpt
        mov     [es:0x106], cs

%ifndef NO_2F
        ; hook INT 2Fh for the Windows start/exit broadcasts (isr2f)
        mov     ax, [es:0xBC]
        mov     [old2f], ax
        mov     ax, [es:0xBE]
        mov     [old2f+2], ax
        or      ax, [old2f]
        jnz     .keep2f
        mov     word [old2f], iret_stub ; empty vector: chain to an IRET
        mov     [old2f+2], cs
.keep2f:
        pushf
        cli
        mov     word [es:0xBC], isr2f
        mov     [es:0xBE], cs
        popf
%endif

%ifndef NO_PROBE
        ; May the hook step aside when Windows 9x starts (see isr2f)?
        ; Only if the BIOS underneath already serves the identical
        ; translation - same heads and sectors, at least as many
        ; cylinders, INT 13h extensions for AH=42 users - so that
        ; unhooking changes nothing DOS depends on. On the pre-LBA
        ; machines this overlay exists for, the probe fails and the
        ; hook stays for good.
        push    bp                      ; some BIOSes trash BP in AH=08
        mov     si, 1                   ; gate_step: which check failed
        mov     ah, 0x08
        mov     dl, 0x80
        pushf
        call    far [old_int13]
        mov     [p_cx], cx              ; keep the raw answer for AH=E1
        mov     [p_dx], dx
        jc      .gate_no
        inc     si
        cmp     dh, FAKE_HEADS-1
        jne     .gate_no
        inc     si
        mov     al, cl
        and     al, 0x3F
        cmp     al, FAKE_SPT
        jne     .gate_no
        inc     si
        mov     al, ch                  ; cylinders = 10-bit max cyl + 1
        mov     ah, cl
        mov     cl, 6
        shr     ah, cl
        inc     ax
        inc     ax                      ; plus one cylinder of tolerance:
                                        ; a BIOS that clips capacity to
                                        ; whole physical cylinders lands
                                        ; one logical cylinder below our
                                        ; IDENTIFY-based count. CHS access
                                        ; there after an unhook fails with
                                        ; an error, never a misaddress.
        cmp     ax, [fake_cyls]
        jb      .gate_no
        inc     si
        mov     ah, 0x41
        mov     bx, 0x55AA
        mov     dl, 0x80
        pushf
        call    far [old_int13]
        jc      .gate_no
        inc     si
        cmp     bx, 0xAA55
        jne     .gate_no
        mov     byte [may_unhook], 1
        xor     si, si                  ; 0: all checks passed
.gate_no:
        mov     ax, si
        mov     [gate_step], al
        pop     bp
%endif

        mov     byte [inited], 1
.out:
        pop     ds
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ---------------------------------------------------------------------
; ata_reset: software-reset the channel to a known state. SeaBIOS may have
; left the drive in LBA48 or an odd mode; a reset makes our LBA28 commands
; behave the same as they do from a cold boot.
ata_reset:
        push    ax
        push    cx
        push    dx
        mov     dx, [ata_ctl]
        mov     al, 0x04                ; assert SRST
        out     dx, al
        call    ata_delay
        xor     al, al                  ; deassert SRST, interrupts enabled
        out     dx, al
        call    ata_delay
        mov     cx, TICKS_RESET
        call    ata_wait_bsy
        pop     dx
        pop     cx
        pop     ax
        ret

; ovl_identify: IDENTIFY DEVICE, fill total sectors and LBA addressing.
; On any failure it assumes a large LBA drive so the overlay still works.
ovl_identify:
        mov     byte [use_lba], 1
        mov     byte [ata_sel], 0xE0            ; LBA, master
        mov     dx, [ata_base]
        add     dx, ATA_DEVICE
        mov     al, 0xA0
        out     dx, al
        call    ata_delay
        mov     cx, TICKS_IO
        call    ata_wait_bsy
        jc      .fail
        mov     dx, [ata_base]
        add     dx, ATA_COMMAND
        mov     al, CMD_IDENTIFY
        out     dx, al
        call    ata_delay
        mov     dx, [ata_ctl]
        in      al, dx
        or      al, al
        jz      .fail                  ; nothing on the bus
        mov     cx, TICKS_IO
        call    ata_wait_bsy
        jc      .fail
        mov     dx, [ata_base]
        add     dx, ATA_STATUS
        in      al, dx
        test    al, ST_ERR
        jnz     .fail
        test    al, ST_DRQ
        jz      .fail
        push    cs
        pop     es
        mov     di, id_buf
        mov     dx, [ata_base]
        cld
        PIO_READ
        mov     ax, [id_buf+ID_LBA_SECS]
        mov     dx, [id_buf+ID_LBA_SECS+2]
        mov     cx, ax
        or      cx, dx
        jz      .fail                  ; drive reports zero LBA capacity
        mov     [total_lo], ax
        mov     [total_hi], dx
        mov     ax, [id_buf+ID_CYLS]
        mov     [i_pcyls], ax
        mov     ax, [id_buf+ID_HEADS]
        mov     [drv_heads], ax
        mov     ax, [id_buf+ID_SPT]
        mov     [drv_spt], ax
        ret
.fail:
        mov     word [total_lo], 0x0000
        mov     word [total_hi], 0x00FF        ; ~8GB, so fake_cyls clamps
        mov     word [i_pcyls], 16383          ; ATA's classic capacity cap
        mov     word [drv_heads], 16
        mov     word [drv_spt], 63
        ret

; ---------------------------------------------------------------------
; Resident data
inited:     db 0
last_st:    db 0
may_unhook: db 0                        ; BIOS underneath serves our exact
                                        ; translation: Win9x may unhook us
unhooked:   db 0                        ; INT 13h stepped aside (Windows up)
last2f:     dd 0                        ; INT 2Fh vector last verified to
                                        ; still chain back to isr2f
gate_step:  db 0                        ; diagnostic: gate check that failed
p_cx:       dw 0                        ; diagnostic: raw AH=08 CX/DX from
p_dx:       dw 0                        ; the BIOS underneath
fake_cyls:  dw 0
i_pcyls:    dw 0                        ; physical cylinders (IDENTIFY)

; Phoenix translated fixed disk parameter table, published through INT
; 41h by install. IO.SYS validates this layout (the 0xA0 signature and
; the zero checksum) when the head count exceeds a classic table's
; range; a classic-format FDPT with 255 heads hangs MS-DOS 6.22 at boot.
fdpt:
fdpt_cyls:  dw 0                        ; +0  logical cylinders
            db FAKE_HEADS               ; +2  logical heads
            db 0xA0                     ; +3  translated-FDPT signature
fdpt_pspt:  db 0                        ; +4  physical sectors/track
            dw 0xFFFF                   ; +5  write precomp: none
            db 0                        ; +7  reserved
            db 0xC8                     ; +8  control: translated, >8 heads
fdpt_pcyl:  dw 0                        ; +9  physical cylinders
fdpt_phds:  db 0                        ; +11 physical heads
fdpt_land:  dw 0                        ; +12 landing zone
            db FAKE_SPT                 ; +14 logical sectors/track
fdpt_sum:   db 0                        ; +15 checksum: table sums to 0
total_lo:   dw 0
total_hi:   dw 0

rw_lba:     dd 0
rw_buf:     dd 0
rw_n:       dw 0
rw_op:      db 0
chs_cyl:    dw 0                        ; used only by ata.asm's CHS path
chs_head:   db 0
chs_sec:    db 0

c_cyl:      dw 0                        ; chs_to_lba scratch
c_head:     db 0
c_sec:      db 0

id_buf:     times SEC_SZ db 0

%ifdef TRACE
RING_MASK   equ 0x1FF                   ; 64 entries x 8 bytes
ring_magic: db 'RINGRING'
ring_w:     dw 0
ring_cur:   dw 0
ring:       times 512 db 0
%endif
