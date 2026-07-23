; bootldr_64k.asm  --  overlay bootloader, loads a FULL 64 KB BIOS to 0xF0000
;
; Same FDC/UART magic-cylinder protocol as the 8 KB loader, but pulls 128 sectors
; (64 KB) into the whole F-segment 0xF0000..0xFFFFF instead of 8 KB at 0xFE000.
; The F-segment is PSRAM-backed now, so this populates the entire 64 KB ROM area
; with real, distinct content (no mirroring) before handing off.
;
; POST markers on port 0x80 (7-seg), read as a ladder:
;   1 entered / stack set   2 about to talk to FDC   3 Specify accepted
;   4 Read(128 sec) issued  5 first data byte         6 all 64 KB received
;   7 about to disable overlay + jump to loaded BIOS
;
; Assemble:  nasm -f bin bootldr_64k.asm -o bootldr.bin
;            python mkrom.py bootldr.bin bootrom.vhd 256

        BITS 16
        ORG 0xFF00

FDC_DOR    equ 0x3F2
FDC_MSR    equ 0x3F4
FDC_DATA   equ 0x3F5
OVL_CTRL   equ 0xE2
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

        call    fdc_rd              ; first byte alone, for the marker
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

        times (0xFFF0 - 0xFF00) - ($ - $$) db 0x90
reset_vector:
        jmp     0xF000:0xFF00
        times (0x10000 - 0xFFF0) - ($ - reset_vector) db 0xFF
