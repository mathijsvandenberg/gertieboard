; bootldr.asm  --  reset-time bootloader for the FPGA XT
;
; Lives in the 256-byte boot ROM overlaid at 0xFFF00..0xFFFFF (ROM_EN=1 at reset).
; Reset vector 0xFFFF0 far-jumps here. Instead of a private UART, we drive the
; EXISTING floppy controller in PIO mode and read the BIOS image from a reserved
; "magic" cylinder (C=0xFF). The host's floppy server recognises that cylinder
; and streams the 32 KB BIOS image back over the FDC's own UART. The bytes are
; written into PSRAM at 0xF8000..0xFFFFF, then we disable the overlay (OUT 0xE2)
; and jump into the freshly-loaded BIOS via a low-RAM trampoline.
;
; Assemble:
;   nasm -f bin bootldr.asm -o bootldr.bin
;   python mkmif.py bootldr.bin bootldr.mif 256
;
; FDC is read in NON-DMA mode (Specify ND=1) so the bootloader needs no 8237.

        BITS 16
        CPU  8086               ; mandatory: see docs/gotchas.md
        ORG 0xFF00                 ; CS=F000 at runtime -> physical 0xFFF00

FDC_DOR    equ 0x3F2
FDC_MSR    equ 0x3F4
FDC_DATA   equ 0x3F5
OVL_CTRL   equ 0xE2                ; bit0=1 -> disable ROM overlay
BIOS_CYL   equ 0xFF                ; reserved cylinder = "fetch BIOS image"

; ---------------------------------------------------------------------------
start:
        cli
        cld
        xor     ax, ax
        mov     ss, ax
        mov     sp, 0x7C00         ; stack in low PSRAM

        mov     dx, FDC_DOR        ; FDC out of reset, drive 0, no IRQ
        mov     al, 0x04
        out     dx, al

        ; --- Specify, ND=1 (non-DMA / PIO) ---
        mov     al, 0x03
        call    fdc_wr
        mov     al, 0xDF           ; SRT/HUT (don't-care for us)
        call    fdc_wr
        mov     al, 0x03           ; HLT<<1 | ND(=1)
        call    fdc_wr

        ; --- Read Data: C=BIOS_CYL, H=0, R=1, N=2(512), EOT=64 (=32 KB) ---
        mov     al, 0x46           ; Read Data (MFM)
        call    fdc_wr
        mov     al, 0x00           ; (head<<2)|drive
        call    fdc_wr
        mov     al, BIOS_CYL       ; C  (magic)
        call    fdc_wr
        mov     al, 0x00           ; H
        call    fdc_wr
        mov     al, 0x01           ; R  (first sector)
        call    fdc_wr
        mov     al, 0x02           ; N = 512
        call    fdc_wr
        mov     al, 64             ; EOT -> sectors 1..64 = 32 KB
        call    fdc_wr
        mov     al, 0x1B           ; GPL
        call    fdc_wr
        mov     al, 0xFF           ; DTL
        call    fdc_wr

        ; --- PIO transfer 32768 bytes -> F800:0000 ---
        mov     ax, 0xF800
        mov     es, ax
        xor     di, di
        mov     cx, 0x8000
.rd:
        call    fdc_rd
        stosb                      ; ES:[DI++] <- AL  (write-through to PSRAM)
        loop    .rd

        ; --- drain result phase (read 0x3F5 until CB clears) ---
.drain:
        mov     dx, FDC_MSR
        in      al, dx
        test    al, 0x10           ; CB still set?
        jz      .switch
        test    al, 0x80           ; RQM?
        jz      .drain
        mov     dx, FDC_DATA
        in      al, dx
        jmp     .drain

        ; --- copy a tiny trampoline to 0060:0000 and run it from PSRAM ---
.switch:
        mov     ax, 0x0060
        mov     es, ax
        xor     di, di
        push    cs
        pop     ds
        mov     si, trampoline
        mov     cx, tramp_end - trampoline
        rep     movsb
        jmp     0x0060:0x0000

; trampoline runs from low RAM (never overlaid) so disabling the overlay is safe
trampoline:
        mov     dx, OVL_CTRL
        mov     al, 1
        out     dx, al             ; ROM_EN <- 0  (0xFFFF0 is PSRAM now)
        jmp     0xF000:0xFFF0      ; loaded BIOS reset vector
tramp_end:

; --- write AL to FDC data register when RQM=1 & DIO=0 ---
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

; --- read AL from FDC data register when RQM=1 & DIO=1 ---
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

; ---------------------------------------------------------------------------
        times (0xFFF0 - 0xFF00) - ($ - $$) db 0x90
reset_vector:                      ; physical 0xFFFF0
        jmp     0xF000:0xFF00      ; cold-start far jump to 'start'
        times (0x10000 - 0xFFF0) - ($ - reset_vector) db 0xFF
