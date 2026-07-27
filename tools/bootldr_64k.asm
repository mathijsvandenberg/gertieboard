; bootldr_64k.asm  --  overlay bootloader, loads a FULL 64 KB BIOS to 0xF0000
;
; Same FDC/UART magic-cylinder protocol as the 8 KB loader, but pulls 128 sectors
; (64 KB) into the whole F-segment 0xF0000..0xFFFFF instead of 8 KB at 0xFE000.
; The F-segment is PSRAM-backed now, so this populates the entire 64 KB ROM area
; with real, distinct content (no mirroring) before handing off.
;
; The serial loader is tried FIRST, so a connected host always wins and BIOS
; development stays a rebuild-and-reboot away. If no host answers within a couple
; of seconds, the BIOS is instead read from the on-board SPI flash, which makes
; the machine standalone. The flash copy lives in the top 64 KB of the chip
; (0x1F0000..0x1FFFFF); the fixed disk is limited to 31 cylinders so DOS can
; never reach it.
;
; POST markers on port 0x80 (7-seg), read as a ladder:
;   1 entered / stack set   2 about to talk to FDC   3 Specify accepted
;   4 Read(128 sec) issued  5 first data byte         6 all 64 KB received
;   7 about to disable overlay + jump to loaded BIOS
;   A no serial host, falling back to flash   B 64 KB read from flash
;   EF flash holds no BIOS (no 0xEA at offset 0xFFF0) -- halted
;
; Assemble:  nasm -f bin bootldr_64k.asm -o bootldr.bin
;            python mkmif.py bootldr.bin bootldr.mif 1024

        BITS 16
        CPU 8086                  ; refuse anything newer. Without this NASM
                                  ; silently emits the 386 near form of a
                                  ; conditional jump whose target is out of short
                                  ; range -- and on an 8088 opcode 0F is POP CS,
                                  ; which vaporises execution unconditionally.
                                  ; That exact trap cost days in the BIOS already.
        ORG 0xFC00               ; 1 KB overlay window 0xFFC00..0xFFFFF

FDC_DOR    equ 0x3F2
FDC_MSR    equ 0x3F4
FDC_DATA   equ 0x3F5
OVL_CTRL   equ 0xE2
SPI_DATA   equ 0x98               ; flash.vhd byte engine
SPI_STAT   equ 0x99               ; bit 7 = BUSY
SPI_CTRL   equ 0x9A               ; bit 0 = /CS
BIOS_OFF   equ 0x1F               ; flash address 0x1F0000 = top 64 KB
BIOS_CYL   equ 0xFF
POST       equ 0x80

%macro MARK 1
        mov     al, %1
        out     POST, al
%endmacro

; ---------------------------------------------------------------------------
start:
        cli
        cld
        xor     ax, ax
        mov     ss, ax
        mov     sp, 0x7C00          ; stack in M9K low RAM
        MARK    1

        mov     dx, FDC_DOR
        mov     al, 0x04
        out     dx, al
        MARK    2

        mov     al, 0x03            ; Specify
        call    fdc_wr
        mov     al, 0xDF
        call    fdc_wr
        mov     al, 0x03            ; ND=1
        call    fdc_wr
        MARK    3

        mov     al, 0x46            ; Read Data
        call    fdc_wr
        mov     al, 0x00
        call    fdc_wr
        mov     al, BIOS_CYL        ; C = 0xFF
        call    fdc_wr
        mov     al, 0x00            ; H
        call    fdc_wr
        mov     al, 0x01            ; R = 1
        call    fdc_wr
        mov     al, 0x02            ; N = 2 (512-byte sectors)
        call    fdc_wr
        mov     al, 128             ; EOT = 128 sectors = 64 KB
        call    fdc_wr
        mov     al, 0x1B            ; GPL
        call    fdc_wr
        mov     al, 0xFF            ; DTL
        call    fdc_wr
        MARK    4

        mov     ax, 0xF000          ; load 64 KB at 0xF0000..0xFFFFF
        mov     es, ax
        xor     di, di

        call    fdc_rd_to           ; first byte, but do not wait forever
        jc      flash_load          ; nobody answered -> use the flash copy
        stosb
        MARK    5
        mov     cx, 0xFFFF          ; 65535 more  (+1 above = 65536 = 64 KB)
.rd:
        call    fdc_rd
        stosb
        loop    .rd
        MARK    6

.drain:
        mov     dx, FDC_MSR
        in      al, dx
        test    al, 0x10
        jz      .switch
        test    al, 0x80
        jz      .drain
        mov     dx, FDC_DATA
        in      al, dx
        jmp     .drain

.switch:
        ; Both load paths join here, so both can be measured identically:
        ; checksum the CODE REGION of the image now sitting in PSRAM -- the
        ; exact bytes about to run -- and show it on the 7-seg, high byte
        ; then low byte, about 1.5 s each. A serial boot and a flash boot
        ; showing the SAME pair means the same image reached memory, and any
        ; difference in behaviour is machine state; a different pair means
        ; the transfer corrupts, measured with no BIOS involved at all.
        ; The range is 0xC000..0xEFFF: code only, none of the BIOS's own
        ; runtime scratch, so the value is stable across boots.
        call    show_sum
        MARK    7
        mov     ax, 0x0060
        mov     es, ax
        xor     di, di
        push    cs
        pop     ds
        mov     si, trampoline
        mov     cx, tramp_end - trampoline
        rep     movsb
        jmp     0x0060:0x0000

trampoline:
        mov     dx, OVL_CTRL
        mov     al, 1
        out     dx, al              ; disable overlay -> F-seg now reads loaded BIOS
        jmp     0xF000:0xFFF0       ; loaded BIOS reset vector
tramp_end:

; --- read one FDC byte, giving up after roughly two seconds (CF=1) ----------
; Only the FIRST byte is read this way. If a host is there it answers at once,
; and the rest of the transfer uses the unbounded fdc_rd; if none is, we must be
; able to give up, or a standalone board would simply hang here forever.
fdc_rd_to:
        push    dx
        push    cx
        push    bx
        mov     bx, 4
.o:     xor     cx, cx
.i:     mov     dx, FDC_MSR
        in      al, dx
        and     al, 0xC0
        cmp     al, 0xC0
        je      .got
        loop    .i
        dec     bx
        jnz     .o
        stc
        jmp     short .out
.got:   mov     dx, FDC_DATA
        in      al, dx
        clc
.out:   pop     bx
        pop     cx
        pop     dx
        ret

; --- exchange one SPI byte: AL out -> AL in --------------------------------
spi_x:
        out     SPI_DATA, al
        ; The status read must not overtake the write. flash.vhd latches the
        ; transmit on the FALLING edge of the write strobe and only then raises
        ; BUSY; an immediately following IN can sample the status BEFORE that,
        ; see BUSY=0, and hand back the PREVIOUS byte -- shifting the whole image
        ; by one and producing exactly the garbled BIOS this produced. The BIOS's
        ; own copy of this loop only works because it happens to have two
        ; instructions in between. Make the gap explicit rather than accidental.
        jmp     short $+2
        jmp     short $+2
.w:     in      al, SPI_STAT
        test    al, 0x80
        jnz     .w
        in      al, SPI_DATA
        ret

; --- load the 64 KB BIOS image from flash 0x1F0000 -> 0xF0000 --------------
; Read in 512-byte commands, NOT one 64 KB burst.
;
; This used to hold /CS low and stream the whole image in a single READ. The
; chip is specified to allow that, and it appeared to work -- the image loaded,
; the reset vector was intact, POST ran. But roughly a sixth of the bytes came
; back wrong, so the BIOS misbehaved in ways that looked like anything except a
; bad read: a signature register that would not match, a drive that reported no
; status, a screen of debris.
;
; tools/spidump.com settled it by doing the identical read both ways from DOS:
; streamed, 11256 of 65536 bytes differed; chunked into 512-byte commands, zero.
; Same port, same command, same byte-exchange, same comparison -- the only
; variable was the length of the burst.
;
; So: one command per 512 bytes, /CS released between them. The extra cost is
; four command bytes per sector, about 1.6 ms over the whole image.
flash_load:
        MARK    0xA
        mov     ax, 0xF000
        mov     es, ax
        xor     di, di
.fl_cmd:
        xor     al, al
        out     SPI_CTRL, al        ; /CS low
        mov     al, 0x03            ; READ
        call    spi_x
        mov     al, BIOS_OFF        ; addr[23:16]
        call    spi_x
        mov     ax, di
        mov     al, ah              ; addr[15:8] = DI >> 8
        call    spi_x
        xor     al, al              ; addr[7:0]: always a 512-byte boundary
        call    spi_x
        mov     cx, 512
.fl:    mov     al, 0xFF
        call    spi_x
        stosb
        loop    .fl
        mov     al, 1
        out     SPI_CTRL, al        ; /CS high
        test    di, di              ; DI wraps to 0 after exactly 64 KB
        jnz     .fl_cmd
        MARK    0xB
        ; A blank chip reads 0xFF everywhere, which would "boot" into nothing.
        ; The reset vector must start with a far jump, so check for it and stop
        ; with a visible code rather than running off into erased flash.
        cmp     byte [es:0xFFF0], 0xEA
        jne     .nobios             ; short branch + near jmp: both 8086-legal
        jmp     start.switch        ; shared hand-off path
.nobios:
        MARK    0xEF
.hang:  jmp     .hang

; --- sum ES:C000..EFFF, display on the 7-seg: high byte, low byte ---------
show_sum:
        mov     si, 0xC000
        mov     cx, 0x3000
        xor     bp, bp
        xor     ah, ah              ; AH stays 0: lodsb writes only AL
.ss:    es      lodsb
        add     bp, ax
        loop    .ss
        mov     ax, bp
        xchg    al, ah              ; high byte first
        call    show_byte
        mov     ax, bp              ; then the low byte
        call    show_byte
        ret
show_byte:
        out     POST, al
        mov     bx, 2               ; ~0.45 s at 5 MHz: long enough to read
.sb:    xor     cx, cx
.sd:    loop    .sd
        dec     bx
        jnz     .sb
        ret

fdc_wr:
        push    dx
        mov     ah, al
.ww:
        mov     dx, FDC_MSR
        in      al, dx
        and     al, 0xC0
        cmp     al, 0x80
        jne     .ww
        mov     dx, FDC_DATA
        mov     al, ah
        out     dx, al
        pop     dx
        ret

fdc_rd:
        push    dx
.rr:
        mov     dx, FDC_MSR
        in      al, dx
        and     al, 0xC0
        cmp     al, 0xC0
        jne     .rr
        mov     dx, FDC_DATA
        in      al, dx
        pop     dx
        ret

        times (0xFFF0 - 0xFC00) - ($ - $$) db 0x90
reset_vector:
        jmp     0xF000:0xFC00
        times (0x10000 - 0xFFF0) - ($ - reset_vector) db 0xFF
