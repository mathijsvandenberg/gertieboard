; =====================================================================
;  XTBIOS  -  a minimal IBM PC/XT-class ROM BIOS for an FPGA 5160 clone
;  Visual style inspired by the Philips P3105 BIOS boot screen.
;
;  - 8 KB image, organised at segment F000 offset E000 (phys FE000-FFFFF)
;  - Reset vector at F000:FFF0 -> POST
;  - Brings up: 8259 PIC, 8253 PIT (18.2Hz tick), 8255 PPI, 6845 CGA 80x25
;  - Installs IVT + handlers: INT 08,09,10,11,12,13,16,19,1A,1C,1E
;  - Boots the first sector of floppy A: (CHS 0/0/1) to 0000:7C00
;
;  Assemble (GNU binutils, no NASM needed):
;     as  --32 xtbios.s -o xtbios.o
;     ld  -m elf_i386 -Ttext=0xE000 --oformat=binary -e _post xtbios.o -o xtbios.bin
;  Result is exactly 8192 bytes -> place at physical FE000 in your ROM.
;
;  Hardware ports assumed (standard IBM 5160):
;     PIC   0x20/0x21          PIT  0x40-0x43      PPI  0x60-0x63
;     CGA   0x3D4/0x3D5 (CRTC) 0x3D8 mode 0x3D9 colour   video RAM B800:0
;     FDC   uPD765 0x3F0-0x3F7, DOR 0x3F2, DMA 8237 ch2 (0x04/0x05/0x0B/0x81)
; =====================================================================

bits 16
org 0x0000



; ---- equates -------------------------------------------------------
BDA equ 0x0040  ; BIOS data area segment
VID equ 0xB800  ; CGA text video segment
KBBUF equ 0x001E  ; kbd buffer start (offset in BDA)
KBEND equ 0x003E  ; kbd buffer end+1
EOI equ 0x20

; =====================================================================
;  POST entry  (jumped to from the reset vector at the top of ROM)
; =====================================================================
_post:
    cli
    cld
    mov ax, 0xF000            ; we execute in segment F000
    mov ds, ax                ; DS = ROM: needed for strings + CRTC table
    xor ax, ax
    mov ss, ax
    mov sp, 0x7C00            ; stack just under the boot area

; ---- video up + draw banner with INTERRUPTS OFF (first light) -------
;      done before any PIC/PIT/sti so the screen appears even if the
;      interrupt controller or timer is misbehaving.
    call vid_init             ; program 6845 / CGA, clear B800  (DS=ROM)
    mov ax, 0xB800
    mov es, ax
    xor al, al                ; row 0
    mov si, b_ver
    call putrow
    mov al, 1
    mov si, b_model
    call putrow
    mov al, 2
    mov si, b_copy
    call putrow
    mov al, 4
    mov si, b_hdr
    call putrow
    mov al, 5
    mov si, b_mem
    call putrow
    mov al, 6
    mov si, b_par
    call putrow
    mov al, 8
    mov si, b_drv
    call putrow
    mov al, 10
    mov si, b_boot
    call putrow

; ---- 8259 PIC (master, XT single mode) -----------------------------
    mov al, 0x13              ; ICW1: edge, single, ICW4 needed
    out 0x20, al
    mov al, 0x08              ; ICW2: IRQ0..7 -> INT 08..0F
    out 0x21, al
    mov al, 0x09              ; ICW4: 8086, buffered master
    out 0x21, al
    mov al, 0xFC              ; unmask IRQ0 (timer) + IRQ1 (kbd) only
    out 0x21, al

; ---- 8253 PIT ch0 = 18.2 Hz tick -----------------------------------
    mov al, 0x36              ; ch0, lo/hi, mode 3, binary
    out 0x43, al
    xor al, al
    out 0x40, al              ; divisor 0 -> 65536
    out 0x40, al
    mov al, 0x54              ; ch1, lo only, mode 2  (DRAM refresh)
    out 0x43, al
    mov al, 0x12
    out 0x41, al

; ---- 8255 PPI ------------------------------------------------------
    mov al, 0x99              ; PA in, PB out, PC in, mode 0
    out 0x63, al
    mov al, 0x0C              ; PB: kbd enabled, speaker off, gate2 off
    out 0x61, al

; ---- clear & init the BIOS data area -------------------------------
    mov ax, BDA
    mov es, ax
    xor di, di
    mov cx, 0x80              ; zero 256 bytes of BDA
    xor ax, ax
    rep stosw
    mov word [es:0x10], 0x0021     ; equipment: 1 floppy, 80x25 colour
    mov word [es:0x13], 640        ; base memory size in KB
    mov word [es:0x1A], KBBUF      ; kbd buffer head
    mov word [es:0x1C], KBBUF      ; kbd buffer tail
    mov word [es:0x80], KBBUF      ; buffer start
    mov word [es:0x82], KBEND      ; buffer end
    mov byte [es:0x49], 0x03       ; video mode 3
    mov word [es:0x4A], 80         ; columns
    mov word [es:0x4C], 0x1000     ; page size
    mov word [es:0x63], 0x03D4     ; CRTC port
    mov byte [es:0x65], 0x29       ; 3D8 mode reg shadow
    mov byte [es:0x66], 0x30       ; 3D9 colour reg shadow
    mov word [es:0x50], 0x0C00     ; text cursor at row 12 (below banner)

; ---- build the interrupt vector table ------------------------------
    xor ax, ax
    mov es, ax                ; ES = 0  (IVT)
    mov di, 0
    mov cx, 256
.fill_ivt:
    mov word [es:di],   _dummy_int
    mov word [es:di+2], 0xF000
    add di, 4
    loop .fill_ivt
    mov bx, 0x08*4
    mov word [es:bx], _int08
    mov bx, 0x09*4
    mov word [es:bx], _int09
    mov bx, 0x10*4
    mov word [es:bx], _int10
    mov bx, 0x11*4
    mov word [es:bx], _int11
    mov bx, 0x12*4
    mov word [es:bx], _int12
    mov bx, 0x13*4
    mov word [es:bx], _int13
    mov bx, 0x16*4
    mov word [es:bx], _int16
    mov bx, 0x19*4
    mov word [es:bx], _int19
    mov bx, 0x1A*4
    mov word [es:bx], _int1a
    mov bx, 0x1E*4
    mov word [es:bx],   _floppy_dpt
    mov word [es:bx+2], 0xF000

; ---- boot (disk read is polled, so interrupts stay off for now) -----
    mov ax, BDA
    mov ds, ax
    int 0x19                  ; bootstrap from floppy A:
; int 0x19 never returns on success
.post_hang:
    jmp .post_hang

; =====================================================================
;  Generic dummy interrupt
; =====================================================================
_dummy_int:
    iret

; =====================================================================
;  Video initialisation: program CRTC for 80x25, clear screen
; =====================================================================
vid_init:
    push ax
    push bx
    push cx
    push dx
    push si
    push es
    mov dx, 0x03D4
    xor bx, bx                ; register index 0
.vi_loop:
    mov al, bl
    out dx, al                ; select CRTC register
    inc dx                    ; 0x3D5 data
    mov si, crtc_80x25
    mov al, [si+bx]
    out dx, al
    dec dx
    inc bx
    cmp bx, 16
    jb .vi_loop
    mov dx, 0x03D8            ; mode control: 80x25 text, video on, blink
    mov al, 0x29
    out dx, al
    mov dx, 0x03D9            ; colour select
    mov al, 0x30
    out dx, al
; clear video memory to spaces, attr 0x07
    mov ax, VID
    mov es, ax
    xor di, di
    mov ax, 0x0720
    mov cx, 2000
    rep stosw
    pop es
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =====================================================================
;  putrow - write ASCIZ string at DS:SI to row AL of B800 (ES), attr 07
;           interrupt-free, used for the POST banner
; =====================================================================
putrow:
    push ax
    push si
    push di
    mov ah, 160
    mul ah                    ; ax = row * 160 (bytes per row)
    mov di, ax
.pr_l:
    lodsb
    test al, al
    jz .pr_d
    mov ah, 0x07
    mov [es:di], ax
    add di, 2
    jmp .pr_l
.pr_d:
    pop di
    pop si
    pop ax
    ret

; =====================================================================
;  puts  - print ASCIZ string at DS:SI via INT 10/0E
; =====================================================================
puts:
    push ax
    push bx
    push si
    push ds
    mov ax, 0xF000                 ; strings live in the ROM segment
    mov ds, ax
.ps_l:
    lodsb
    test al, al
    jz .ps_done
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    jmp .ps_l
.ps_done:
    pop ds
    pop si
    pop bx
    pop ax
    ret

; =====================================================================
;  put_dec - print unsigned AX in decimal via INT 10/0E
; =====================================================================
put_dec:
    push ax
    push bx
    push cx
    push dx
    mov bx, 10
    xor cx, cx
.pd_div:
    xor dx, dx
    div bx                    ; ax/10, dx=remainder
    push dx
    inc cx
    test ax, ax
    jnz .pd_div
.pd_out:
    pop dx
    mov al, dl
    add al, '0'
    mov ah, 0x0E
    mov bx, 7
    int 0x10
    loop .pd_out
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =====================================================================
;  INT 10h - video services (subset)
; =====================================================================
_int10:
    sti
    cmp ah, 0x00
    je v_setmode
    cmp ah, 0x01
    je v_curtype
    cmp ah, 0x02
    je v_setcur
    cmp ah, 0x03
    je v_getcur
    cmp ah, 0x06
    je v_scrollup
    cmp ah, 0x07
    je v_scrolldn
    cmp ah, 0x08
    je v_readch
    cmp ah, 0x09
    je v_writeca
    cmp ah, 0x0A
    je v_writec
    cmp ah, 0x0E
    je v_tty
    cmp ah, 0x0F
    je v_getmode
    iret

v_setmode:
    push ds
    push ax                        ; preserve mode in AL
    call vid_init
    pop ax
    push ax
    mov ax, BDA
    mov ds, ax
    pop ax
    mov byte [0x49], al        ; store video mode number
    mov word [0x50], 0         ; cursor home
    pop ds
    iret

v_curtype:
    push ds
    mov ax, BDA
    mov ds, ax
    mov [0x60], cx                 ; store cursor shape
    mov dx, [0x63]
    mov al, 0x0A
    out dx, al
    inc dx
    mov al, ch
    out dx, al
    dec dx
    mov al, 0x0B
    out dx, al
    inc dx
    mov al, cl
    out dx, al
    pop ds
    iret

v_setcur:
    push ds
    mov ax, BDA
    mov ds, ax
    mov [0x50], dx                 ; DH=row, DL=col
    call set_hw_cursor
    pop ds
    iret

v_getcur:
    push ds
    mov ax, BDA
    mov ds, ax
    mov dx, [0x50]
    mov cx, [0x60]
    pop ds
    iret

v_getmode:
    push ds
    mov ax, BDA
    mov ds, ax
    mov al, [0x49]
    mov ah, 80                     ; columns
    mov bh, 0
    pop ds
    iret

v_readch:                          ; returns AL=char, AH=attr at cursor
    push ds
    push es
    push dx
    mov ax, BDA
    mov ds, ax
    mov dx, [0x50]                 ; cursor row/col
    call cursor_off                ; DI = byte offset
    mov ax, VID
    mov es, ax
    mov ax, [es:di]               ; AL=char AH=attr
    pop dx
    pop es
    pop ds
    iret

v_writeca:                         ; AL=char BL=attr CX=count
    push ds
    push es
    push si
    mov dx, BDA
    mov ds, dx
    mov si, ax                     ; save char in si low
    mov dx, [0x50]
    call cursor_off                ; -> DI = byte offset
    mov dx, VID
    mov es, dx
    mov ax, si                     ; char back into AL
    mov ah, bl                     ; attribute
.wc_l:
    test cx, cx
    jz .wc_done
    mov [es:di], ax
    add di, 2
    dec cx
    jmp .wc_l
.wc_done:
    pop si
    pop es
    pop ds
    iret

v_writec:                          ; AL=char CX=count (keep attr)
    push ds
    push es
    push si
    mov dx, BDA
    mov ds, dx
    mov si, ax
    mov dx, [0x50]
    call cursor_off
    mov dx, VID
    mov es, dx
    mov ax, si                     ; char into AL
.wcc_l:
    test cx, cx
    jz .wcc_done
    mov [es:di], al                ; write char only
    add di, 2
    dec cx
    jmp .wcc_l
.wcc_done:
    pop si
    pop es
    pop ds
    iret

; ---- teletype output (AL=char) -------------------------------------
v_tty:
    push ds
    push es
    push bx
    push cx
    push dx
    push si
    mov si, ax                     ; save char
    mov dx, BDA
    mov ds, dx
    mov dx, [0x50]                 ; DH=row DL=col
    mov ax, si
    cmp al, 0x0D
    je .tt_cr
    cmp al, 0x0A
    je .tt_lf
    cmp al, 0x08
    je .tt_bs
    cmp al, 0x07
    je .tt_done                    ; bell: ignore
; printable: write at cursor
    push dx
    call cursor_off                ; DI = offset for DH/DL
    mov bx, VID
    mov es, bx
    mov ah, 0x07
    mov [es:di], ax
    pop dx
    inc dl                         ; advance column
    cmp dl, 80
    jb .tt_store
    mov dl, 0
    jmp .tt_newline
.tt_cr:
    mov dl, 0
    jmp .tt_store
.tt_lf:
    jmp .tt_newline
.tt_bs:
    cmp dl, 0
    je .tt_store
    dec dl
    jmp .tt_store
.tt_newline:
    inc dh
    cmp dh, 25
    jb .tt_store
    mov dh, 24
    mov [0x50], dx
    call scroll_one                ; scroll whole screen up 1
    mov dx, [0x50]
.tt_store:
    mov [0x50], dx
    call set_hw_cursor
.tt_done:
    pop si
    pop dx
    pop cx
    pop bx
    pop es
    pop ds
    iret

; ---- scroll window up (AL=lines BH=attr CH,CL=UL DH,DL=LR) ----------
; locals on the stack (SS), so DS/ES can point at video freely:
;   [bp-1]=top [bp-2]=left [bp-3]=bot [bp-4]=right
;   [bp-5]=lines [bp-6]=attr [bp-7]=row [bp-8]=width
v_scrollup:
    push bp
    mov bp, sp
    sub sp, 8
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es
    mov [bp-1], ch                 ; top
    mov [bp-2], cl                 ; left
    mov [bp-3], dh                 ; bottom
    mov [bp-4], dl                 ; right
    mov [bp-5], al                 ; line count (0 = clear)
    mov [bp-6], bh                 ; attribute
    mov al, dl
    sub al, cl
    inc al
    mov [bp-8], al                 ; width (columns)
    mov ax, VID
    mov ds, ax
    mov es, ax
    mov al, [bp-5]
    test al, al
    jz .su_clear
; --- scroll up AL lines, one line per pass ---
.su_pass:
    mov al, [bp-1]
    mov [bp-7], al                 ; row = top
.su_move:
    mov al, [bp-7]
    cmp al, [bp-3]                 ; row >= bottom -> stop moving
    jae .su_blanklast
    call row_off                   ; DI = (row,left) offset
    mov si, di
    add si, 160                    ; source = next row
    mov cl, [bp-8]
    xor ch, ch
    rep movsw
    inc byte [bp-7]
    jmp .su_move
.su_blanklast:
    mov al, [bp-3]                 ; blank the bottom row
    call row_off
    mov ah, [bp-6]
    mov al, ' '
    mov cl, [bp-8]
    xor ch, ch
    rep stosw
    dec byte [bp-5]
    jnz .su_pass
    jmp .su_done
; --- clear whole window (rows top..bottom) ---
.su_clear:
    mov al, [bp-1]
    mov [bp-7], al                 ; row = top
.su_clrrow:
    mov al, [bp-7]
    cmp al, [bp-3]
    ja .su_done
    call row_off
    mov ah, [bp-6]
    mov al, ' '
    mov cl, [bp-8]
    xor ch, ch
    rep stosw
    inc byte [bp-7]
    jmp .su_clrrow
.su_done:
    pop es
    pop ds
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    mov sp, bp
    pop bp
    iret

; scroll-down: basic clone treats it as clear-window (AL=0) only
v_scrolldn:
    mov al, 0
    jmp v_scrollup

; row_off: DI = ((row=[bp-7 or al])*80 + left)*2     (uses AL as row)
row_off:
    push ax
    push bx
    mov ah, 80
    mul ah                         ; ax = row*80
    mov bl, [bp-2]                 ; left
    xor bh, bh
    add ax, bx
    shl ax, 1
    mov di, ax
    pop bx
    pop ax
    ret

; ---- helpers (DS must = BDA) ---------------------------------------
; cursor_off: DH=row DL=col -> DI = byte offset in B800
cursor_off:
    push ax
    mov al, dh
    mov ah, 80
    mul ah                         ; ax = row*80
    xor dh, dh
    add ax, dx                     ; + col
    shl ax, 1                      ; *2
    mov di, ax
    pop ax
    ret

; set_hw_cursor: from [0x50]
set_hw_cursor:
    push ax
    push bx
    push dx
    mov dx, [0x50]
    mov al, dh
    mov ah, 80
    mul ah
    xor dh, dh
    add ax, dx
    mov bx, ax                     ; linear position
    mov dx, [0x63]                 ; 0x3D4
    mov al, 0x0E
    out dx, al
    inc dx
    mov al, bh
    out dx, al
    dec dx
    mov al, 0x0F
    out dx, al
    inc dx
    mov al, bl
    out dx, al
    pop dx
    pop bx
    pop ax
    ret

; scroll_one: scroll the full 80x25 up one line, blank bottom row
scroll_one:
    push ax
    push cx
    push si
    push di
    push ds
    push es
    mov ax, VID
    mov ds, ax
    mov es, ax
    mov si, 160                    ; second row
    xor di, di
    mov cx, 80*24
    rep movsw
    mov ax, 0x0720                 ; blank last row
    mov cx, 80
    rep stosw
    pop es
    pop ds
    pop di
    pop si
    pop cx
    pop ax
    ret

; =====================================================================
;  INT 11h / 12h
; =====================================================================
_int11:
    push ds
    mov ax, BDA
    mov ds, ax
    mov ax, [0x10]
    pop ds
    iret

_int12:
    push ds
    mov ax, BDA
    mov ds, ax
    mov ax, [0x13]
    pop ds
    iret

; =====================================================================
;  INT 1Ah - time of day (tick counter)
; =====================================================================
_int1a:
    sti
    cmp ah, 0x00
    je .ta_get
    cmp ah, 0x01
    je .ta_set
    iret
.ta_get:
    push ds
    mov ax, BDA
    mov ds, ax
    mov al, [0x70]                ; overflow flag
    mov cx, [0x6E]               ; high word
    mov dx, [0x6C]               ; low word
    mov byte [0x70], 0
    pop ds
    iret
.ta_set:
    push ds
    mov ax, BDA
    mov ds, ax
    mov [0x6E], cx
    mov [0x6C], dx
    mov byte [0x70], 0
    pop ds
    iret

; =====================================================================
;  INT 08h - timer tick (IRQ0)
; =====================================================================
_int08:
    push ax
    push dx
    push ds
    mov ax, BDA
    mov ds, ax
    add word [0x6C], 1
    adc word [0x6E], 0
; midnight wrap at 0x001800B0 ticks (24h)
    mov ax, [0x6E]
    cmp ax, 0x0018
    jb .t8_motor
    mov dx, [0x6C]
    cmp dx, 0x00B0
    jb .t8_motor
    mov word [0x6C], 0
    mov word [0x6E], 0
    mov byte [0x70], 1
.t8_motor:
; floppy motor-off countdown
    mov al, [0x40]
    test al, al
    jz .t8_user
    dec al
    mov [0x40], al
    jnz .t8_user
    mov dx, 0x03F2               ; motors off, keep /reset + DMA
    mov al, 0x0C
    out dx, al
.t8_user:
    int 0x1C                      ; user tick hook
    mov al, EOI
    out 0x20, al
    pop ds
    pop dx
    pop ax
    iret

; =====================================================================
;  INT 09h - keyboard (IRQ1)
; =====================================================================
_int09:
    push ax
    push bx
    push ds
    mov ax, BDA
    mov ds, ax
    in al, 0x60                   ; scancode
    mov bl, al
; acknowledge XT keyboard (pulse PB7)
    in al, 0x61
    mov ah, al
    or al, 0x80
    out 0x61, al
    mov al, ah
    out 0x61, al
; --- handle shift/ctrl/alt make & break ---
    mov al, bl
    cmp al, 0x2A
    je .k_shift_on
    cmp al, 0x36
    je .k_shift_on
    cmp al, 0xAA
    je .k_shift_off
    cmp al, 0xB6
    je .k_shift_off
    cmp al, 0x1D
    je .k_ctrl_on
    cmp al, 0x9D
    je .k_ctrl_off
    cmp al, 0x38
    je .k_alt_on
    cmp al, 0xB8
    je .k_alt_off
    test al, 0x80                ; ignore all other break codes
    jnz .k_eoi
; Ctrl+Alt+Del -> reboot
    cmp al, 0x53
    jne .k_translate
    mov ah, [0x17]
    and ah, 0x0C                ; ctrl(4)+alt(8)
    cmp ah, 0x0C
    je _reboot
.k_translate:
    cmp al, 0x53
    ja .k_eoi                   ; beyond table
    mov bh, 0
    mov bl, al
    mov ah, [0x17]
    test ah, 0x03              ; shift?
    jnz .k_shifted
    mov al, [bx + scancode_lc]
    jmp .k_have
.k_shifted:
    mov al, [bx + scancode_uc]
.k_have:
    test al, al
    jz .k_eoi                   ; no ascii
    mov ah, bl                  ; scancode in ah
    call kb_put
    jmp .k_eoi
.k_shift_on:
    or byte [0x17], 0x03
    jmp .k_eoi
.k_shift_off:
    and byte [0x17], 0xFC
    jmp .k_eoi
.k_ctrl_on:
    or byte [0x17], 0x04
    jmp .k_eoi
.k_ctrl_off:
    and byte [0x17], 0xFB
    jmp .k_eoi
.k_alt_on:
    or byte [0x17], 0x08
    jmp .k_eoi
.k_alt_off:
    and byte [0x17], 0xF7
.k_eoi:
    mov al, EOI
    out 0x20, al
    pop ds
    pop bx
    pop ax
    iret

; kb_put: AX = (scancode<<8 | ascii) into ring buffer  (DS=BDA)
kb_put:
    push bx
    push si
    mov bx, [0x1C]              ; tail
    mov si, bx
    add si, 2
    cmp si, KBEND
    jb .kp_nowrap
    mov si, KBBUF
.kp_nowrap:
    cmp si, [0x1A]             ; head ?  buffer full -> drop
    je .kp_full
    mov [bx], ax               ; store key
    mov [0x1C], si            ; advance tail
.kp_full:
    pop si
    pop bx
    ret

; =====================================================================
;  INT 16h - keyboard services
; =====================================================================
_int16:
    sti
    cmp ah, 0x00
    je .kb_read
    cmp ah, 0x01
    je .kb_peek
    cmp ah, 0x02
    je .kb_flags
    iret
.kb_read:
    push ds
    push bx
    mov bx, BDA
    mov ds, bx
.kr_wait:
    cli
    mov bx, [0x1A]             ; head
    cmp bx, [0x1C]            ; tail
    jne .kr_get
    sti
    hlt
    jmp .kr_wait
.kr_get:
    mov ax, [bx]              ; the key
    add bx, 2
    cmp bx, KBEND
    jb .kr_nw
    mov bx, KBBUF
.kr_nw:
    mov [0x1A], bx
    sti
    pop bx
    pop ds
    iret
.kb_peek:
    push ds
    push bx
    push bp
    mov bp, sp
    mov bx, BDA
    mov ds, bx
    mov bx, [0x1A]
    cmp bx, [0x1C]
    je .kp_empty
    mov ax, [bx]
    and word [bp+10], 0xFFBF     ; clear ZF in caller flags
    pop bp
    pop bx
    pop ds
    iret
.kp_empty:
    or word [bp+10], 0x40        ; set ZF
    pop bp
    pop bx
    pop ds
    iret
.kb_flags:
    push ds
    mov ax, BDA
    mov ds, ax
    mov al, [0x17]
    pop ds
    iret

; =====================================================================
;  INT 13h - diskette services (uPD765 + 8237 DMA)
; =====================================================================
_int13:
    sti
    cmp ah, 0x00
    je d_reset
    cmp ah, 0x01
    je d_status
    cmp ah, 0x02
    je d_read
    cmp ah, 0x04
    je d_verify
    cmp ah, 0x08
    je d_params
    cmp ah, 0x15
    je d_dtype
; unsupported function
    push ds
    mov ax, BDA
    mov ds, ax
    mov byte [0x41], 0x01
    pop ds
    mov ah, 0x01
    stc
    retf 2

d_reset:
    push ds
    push dx
    mov ax, BDA
    mov ds, ax
    mov byte [0x41], 0
; pulse the FDC reset via DOR
    mov dx, 0x03F2
    xor al, al                   ; /reset low = reset asserted
    out dx, al
    call io_delay
    mov al, 0x1C                 ; /reset high, DMA en, motor A, drive 0
    out dx, al
    call io_delay
    call fdc_specify
    call fdc_recal
    pop dx
    pop ds
    xor ah, ah
    clc
    retf 2

d_status:
    push ds
    mov ax, BDA
    mov ds, ax
    mov ah, [0x41]
    pop ds
    test ah, ah
    jz .dst_ok
    stc
    retf 2
.dst_ok:
    clc
    retf 2

d_verify:
    xor ah, ah
    clc
    retf 2

d_dtype:
    mov ah, 0x01                 ; floppy, no change-line support
    clc
    retf 2

d_params:
    push ds
    mov dx, BDA
    mov ds, dx
    mov ch, 79                   ; max cylinder (1.44M = 0..79)
    mov cl, 18                   ; sectors/track
    mov dh, 1                    ; max head
    mov dl, 1                    ; number of drives
    mov ax, 0xF000
    mov es, ax
    mov di, _floppy_dpt
    pop ds
    xor ah, ah
    clc
    retf 2

; ---- d_read : read sectors via uPD765 + 8237 DMA ------------------
; in: AL=count CH=cyl CL=sector(b0-5)+cylhi(b6-7) DH=head DL=drive ES:BX=buf
; scratch in BDA: 0x90 count,0x91 drive,0x92 head,0x93 cyl,0x94 sector,
;                 0x95 hd/drv sel, 0x96 off(w), 0x98 seg(w),
;                 0x9A page, 0x9C physlow(w), 0x9E cnt-1(w)
d_read:
    push ds
    push es
    push si
    push bx
    push cx
    push dx
    push ax
; ---- stash all incoming params into BDA scratch ----
    mov si, ax                    ; save AX (count)
    mov ax, BDA
    mov ds, ax
    mov ax, si
    mov [0x90], al                ; count
    mov [0x91], dl                ; drive
    mov [0x92], dh                ; head
    mov [0x93], ch                ; cylinder (low 8)
    mov al, cl
    and al, 0x3F
    mov [0x94], al                ; sector
    mov [0x96], bx                ; buffer offset
    mov [0x98], es               ; buffer segment
    mov byte [0x41], 0
; hd/drv select byte = (head<<2)|(drive&1)
    mov al, [0x92]
    shl al, 1
    shl al, 1
    mov bl, [0x91]
    and bl, 0x01
    or al, bl
    mov [0x95], al
; ---- motor + specify ----
    call motor_on
    call fdc_specify
; ---- compute 20-bit physical address ----
    mov ax, [0x98]               ; segment
    mov bx, ax
    mov cl, 4
    shl ax, cl                   ; (seg<<4) low 16
    mov cl, 12
    shr bx, cl                   ; page base = seg>>12
    add ax, [0x96]               ; + offset -> phys low 16, CF=carry
    adc bx, 0                    ; page += carry
    mov [0x9C], ax               ; phys low 16
    mov [0x9A], bl               ; page (bits16-19)
; ---- byte count - 1 ----
    xor ax, ax
    mov al, [0x90]
    mov cl, 9
    shl ax, cl                   ; *512
    dec ax
    mov [0x9E], ax               ; count-1
; ---- program DMA channel 2 (read = write-to-memory) ----
    cli
    mov al, 0x06
    out 0x0A, al                 ; mask ch2
    xor al, al
    out 0x0C, al                 ; clear byte-ptr flip-flop
    mov al, 0x46
    out 0x0B, al                 ; mode: single/inc/write/ch2
    mov al, [0x9C]
    out 0x04, al                 ; addr low
    mov al, [0x9D]
    out 0x04, al                 ; addr high
    mov al, [0x9A]
    out 0x81, al                 ; page register ch2
    xor al, al
    out 0x0C, al
    mov al, [0x9E]
    out 0x05, al                 ; count low
    mov al, [0x9F]
    out 0x05, al                 ; count high
    mov al, 0x02
    out 0x0A, al                 ; unmask ch2
    sti
; ---- seek to cylinder ----
    mov al, 0x0F
    call fdc_out
    mov al, [0x95]
    call fdc_out                 ; hd/drv
    mov al, [0x93]
    call fdc_out                 ; cylinder
    call fdc_wait_seek
; ---- read data ----
    mov al, 0x46                 ; MFM read
    call fdc_out
    mov al, [0x95]
    call fdc_out                 ; hd/drv
    mov al, [0x93]
    call fdc_out                 ; cylinder
    mov al, [0x92]
    call fdc_out                 ; head
    mov al, [0x94]
    call fdc_out                 ; sector
    mov al, 0x02
    call fdc_out                 ; N=2 (512)
    mov al, [0x94]
    mov bl, [0x90]
    add al, bl
    dec al
    call fdc_out                 ; EOT = sector + count - 1
    mov al, 0x1B
    call fdc_out                 ; GPL
    mov al, 0xFF
    call fdc_out                 ; DTL
; ---- result phase ----
    call fdc_results             ; -> [0x41]
    mov dl, [0x41]
    mov dh, [0x90]               ; sectors read = requested (assumed)
    pop ax                       ; discard saved AX
    pop cx                       ; (saved DX) -> discard
    pop cx                       ; saved CX -> discard
    pop bx                       ; saved BX
    pop si                       ; saved SI
    pop es
    pop ds
    mov ah, dl                   ; status
    mov al, dh                   ; count
    test ah, ah
    jnz .dr_err
    clc
    retf 2
.dr_err:
    stc
    retf 2

; ---- FDC low-level helpers -----------------------------------------
; fdc_out: send AL as a command/parameter byte (wait RQM=1,DIO=0)
fdc_out:
    push ax
    push cx
    push dx
    mov ah, al                  ; stash byte to send in AH
    mov dx, 0x03F4               ; MSR
    mov cx, 0x4000
.fo_wait:
    in al, dx
    and al, 0xC0
    cmp al, 0x80                ; RQM=1, DIO=0 -> ready for write
    je .fo_send
    loop .fo_wait
    jmp .fo_to
.fo_send:
    mov dx, 0x03F5
    mov al, ah
    out dx, al
.fo_to:
    pop dx
    pop cx
    pop ax
    ret

; fdc_in: read one data byte into AL (wait RQM=1,DIO=1)
fdc_in:
    push cx
    push dx
    mov dx, 0x03F4
    mov cx, 0x4000
.fi_wait:
    in al, dx
    and al, 0xC0
    cmp al, 0xC0
    je .fi_rd
    loop .fi_wait
    xor al, al
    jmp .fi_done
.fi_rd:
    mov dx, 0x03F5
    in al, dx
.fi_done:
    pop dx
    pop cx
    ret

; fdc_results: read 7 result bytes, evaluate ST0/ST1 -> BDA[0x41]
fdc_results:
    push bx
    push cx
    push dx
    push ds
    mov ax, BDA
    mov ds, ax
; wait until command/result available
    mov cx, 0x8000
.fr_busy:
    mov dx, 0x03F4
    in al, dx
    test al, 0x10              ; CB still busy?
    jnz .fr_read
    loop .fr_busy
.fr_read:
    call fdc_in
    mov bl, al                 ; ST0
    call fdc_in
    mov bh, al                 ; ST1
    call fdc_in                ; ST2
    call fdc_in                ; C
    call fdc_in                ; H
    call fdc_in                ; R
    call fdc_in                ; N
; evaluate
    mov al, bl
    and al, 0xC0              ; IC bits
    jz .fr_ok
    mov byte [0x41], 0x20     ; general failure
    jmp .fr_done
.fr_ok:
    mov byte [0x41], 0
.fr_done:
    pop ds
    pop dx
    pop cx
    pop bx
    ret

; fdc_specify: SRT/HUT/HLT, non-DMA=0
fdc_specify:
    mov al, 0x03
    call fdc_out
    mov al, 0xDF
    call fdc_out
    mov al, 0x02
    call fdc_out
    ret

; fdc_recal: recalibrate drive 0 to track 0
fdc_recal:
    mov al, 0x07
    call fdc_out
    xor al, al
    call fdc_out
    call fdc_wait_seek
    ret

; fdc_wait_seek: poll MSR until drive-busy clears, then sense int status
fdc_wait_seek:
    push cx
    push dx
    mov cx, 0x8000
.ws_l:
    mov dx, 0x03F4
    in al, dx
    test al, 0x0F              ; any drive busy?
    jz .ws_sense
    loop .ws_l
.ws_sense:
    mov al, 0x08              ; sense interrupt status
    call fdc_out
    call fdc_in               ; ST0
    call fdc_in               ; PCN
    pop dx
    pop cx
    ret

; motor_on: select drive 0, motor on, set motor-off timeout
motor_on:
    push dx
    push ds
    mov ax, BDA
    mov ds, ax
    mov dx, 0x03F2
    mov al, 0x1C              ; motor A on, drive 0, DMA en, /reset hi
    out dx, al
    mov byte [0x40], 0x25     ; ~2s motor-off countdown
    pop ds
; crude spin-up delay
    mov cx, 0x2000
.mo_d:
    call io_delay
    loop .mo_d
    pop dx
    ret

io_delay:
    push ax
    in al, 0x80              ; ~1us I/O delay on real HW
    pop ax
    ret

; =====================================================================
;  INT 19h - bootstrap loader  (boot floppy A:)
; =====================================================================
_int19:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
.boot_try:
; reset disk
    xor ax, ax
    xor dx, dx                ; drive 0 = A:
    int 0x13
; read boot sector: 1 sector, C0 H0 S1 -> 0000:7C00
    mov ax, 0x0201           ; AH=02 read, AL=1 sector
    mov cx, 0x0001           ; cyl 0, sector 1
    xor dh, dh               ; head 0
    xor dl, dl               ; drive A:
    mov bx, 0x7C00
    xor di, di
    mov es, di
    int 0x13
    jc .boot_fail
; check signature 0xAA55
    mov ax, [0x7DFE]
    cmp ax, 0xAA55
    jne .boot_fail
; read OK -> now enable interrupts and launch the boot sector
    mov dl, 0                ; boot drive in DL
    xor ax, ax
    mov ds, ax
    sti
    db 0xEA              ; jmp 0000:7C00
    dw 0x7C00
    dw 0x0000
.boot_fail:
    mov si, msg_bootfail
    call puts19
    mov si, msg_reboot
    call puts19
.bf_hang:
    jmp .bf_hang

; puts19: print ASCIZ at CS:SI (DS may be 0)
puts19:
    push ax
    push bx
    push si
    push ds
    mov ax, 0xF000
    mov ds, ax
.p19:
    lodsb
    test al, al
    jz .p19d
    mov ah, 0x0E
    mov bx, 7
    int 0x10
    jmp .p19
.p19d:
    pop ds
    pop si
    pop bx
    pop ax
    ret

; =====================================================================
;  Reboot
; =====================================================================
_reboot:
    cli
    db 0xEA              ; jmp F000:FFF0 (reset entry)
    dw 0xFFF0
    dw 0xF000

; =====================================================================
;  Data tables and strings
; =====================================================================
crtc_80x25:
    db 0x71,0x50,0x5A,0x0A,0x1F,0x06,0x19,0x1C
    db 0x02,0x07,0x06,0x07,0x00,0x00,0x00,0x00

; Floppy disk parameter table (pointed to by INT 1E)
_floppy_dpt:
    db 0xDF,0x02,0x25,0x02,18,0x1B,0xFF,0x54,0xF6,0x0F,0x08

; ---- US scancode set-1 -> ASCII (lower / upper), index = scancode -----
; entries 0x00 .. 0x53
scancode_lc:
    db 0x00,0x1B,'1','2','3','4','5','6'          ; 00-07
    db '7','8','9','0','-','=',0x08,0x09          ; 08-0F
    db 'q','w','e','r','t','y','u','i'            ; 10-17
    db 'o','p','[',']',0x0D,0x00,'a','s'          ; 18-1F
    db 'd','f','g','h','j','k','l',';'            ; 20-27
    db 0x27,'`',0x00,0x5C,'z','x','c','v'         ; 28-2F
    db 'b','n','m',',','.','/',0x00,'*'           ; 30-37
    db 0x00,' ',0x00,0x00,0x00,0x00,0x00,0x00     ; 38-3F
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,'7'     ; 40-47
    db '8','9','-','4','5','6','+','1'            ; 48-4F
    db '2','3','0','.'                            ; 50-53
scancode_uc:
    db 0x00,0x1B,'!','@','#','$','%','^'          ; 00-07
    db '&','*','(',')','_','+',0x08,0x09          ; 08-0F
    db 'Q','W','E','R','T','Y','U','I'            ; 10-17
    db 'O','P','{','}',0x0D,0x00,'A','S'          ; 18-1F
    db 'D','F','G','H','J','K','L',':'            ; 20-27
    db '"','~',0x00,'|','Z','X','C','V'           ; 28-2F
    db 'B','N','M','<','>','?',0x00,'*'           ; 30-37
    db 0x00,' ',0x00,0x00,0x00,0x00,0x00,0x00     ; 38-3F
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,'7'     ; 40-47
    db '8','9','-','4','5','6','+','1'            ; 48-4F
    db '2','3','0','.'                            ; 50-53

; ---- boot screen strings (Philips P3105 visual style) ---------------
; ---- banner shown directly to video during POST (no CRLF) ----------
b_ver: db "Philips ROM BIOS Version 1.00", 0
b_model: db "P3105 BIOS  (FPGA PC/XT clone)", 0
b_copy: db "(C) 2026", 0
b_hdr: db "                     Total  Base Extra", 0
b_mem: db "System Memory Found:   640   640     0 Kbytes", 0
b_par: db "Parity Checking Enabled", 0
b_drv: db "Using 5.25", 34, " 360K as Drive A:", 0
b_boot: db "Booting...", 0

msg_ver: db "Philips ROM BIOS Version 1.00", 13, 10, 0
msg_model: db "P3105 BIOS  (FPGA PC/XT clone)", 13, 10, 0
msg_copy: db "(C) 2026", 13, 10, 13, 10, 0
msg_memhdr: db "                     Total  Base Extra", 13, 10, 0
msg_memfound: db "System Memory Found:   ", 0
msg_3sp: db "   ", 0
msg_extra0: db "     0 Kbytes", 13, 10, 0
msg_parity: db "Parity Checking Enabled", 13, 10, 13, 10, 0
msg_drive: db "Using 5.25", 34, " 360K as Drive A:", 13, 10, 13, 10, 0
msg_boot: db "Booting...", 13, 10, 0
msg_bootfail: db 13, 10, "Boot Error.", 13, 10, 0
msg_reboot: db "Press Ctrl-Alt-Del to Reboot ... ", 13, 10, 0

; =====================================================================
;  Tail of ROM:  reset vector, date, model byte, checksum
;  Placed by the linker via the .reset section at 0xFFF0.
; =====================================================================
times 0xFFF0 - ($ - $$) db 0
_reset:
    db 0xEA                ; jmp F000:_post   (FFF0-FFF4)
    dw _post
    dw 0xF000
    db "06/19/26"  ; 8-byte date     (FFF5-FFFC)
    db 0x00                ; pad             (FFFD)
    db 0xFE                ; model byte = PC/XT (FFFE)
    db 0x00                ; checksum / pad  (FFFF)
