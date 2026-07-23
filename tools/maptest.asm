;-------------------------------------------------------------------------------
; psram_maptest.asm  --  PSRAM QPI timing finder with on-screen page map
;
; Builds as an 8 KB BIOS-style image (load to 0xFE000 exactly like Ruud/xtramtest,
; reset vector at 0xFFFF0 jumps to F000:E000). Runs entirely from M9K (code, stack
; in low RAM), so it always comes up on screen even when PSRAM is mistuned.
;
; What it does, for each CTRL value (SCK_DIV in {4,2,1} x RD_LAT in 0..7):
;   1. OUT 0xE4, ctrl                         (set PSRAM capture timing live)
;   2. write+read-back test every 4 KB page of PSRAM (0x08000..0x9FFFF)
;   3. paint a 16-wide map of pages to CGA text RAM at B800: green = pass,
;      red = fail, plus a status line  E4=xx DIV=x LAT=x FAIL=xxxx
;   4. if a setting passes ALL pages -> print FOUND E4=xx and halt on it
; If nothing passes, prints NONE and halts.
;
; Build:  nasm -f bin psram_maptest.asm -o psram_maptest.bin   (8192 bytes)
; Load :  serve it on the magic BIOS cylinder, same as the diagnostic ROMs.
;-------------------------------------------------------------------------------

[bits 16]
[org 0xE000]

VIDEO_SEG   equ 0B800h
PS_FIRST    equ 00800h          ; first PSRAM 4K-page segment (0x08000)
NUM_PAGES   equ 152             ; (0x9F000-0x08000)/0x1000 + 1
MAP_ROW0    equ 3
MAP_COL0    equ 8
TXT_ATTR    equ 1Fh             ; white on blue

; low-RAM scratch (DS = 0, all inside the 32 KB M9K window)
RESULT_OFS  equ 06000h          ; 152 result bytes
FAILCNT     equ 06100h          ; word
CURCTRL     equ 06102h          ; byte
CURDIV      equ 06103h          ; byte
CURLAT      equ 06104h          ; byte
DIVIDX      equ 06105h          ; byte

;-------------------------------------------------------------------------------
entry:
    cli
    cld
    xor ax, ax
    mov ss, ax
    mov sp, 7000h
    mov ds, ax                  ; DS = 0 for scratch (strings use CS override)

    call clear_screen
    mov ax, VIDEO_SEG
    mov es, ax
    mov di, (0*80+2)*2
    mov si, str_title
    call puts

    mov byte [DIVIDX], 0

.sweep_div:
    mov bl, [DIVIDX]
    cmp bl, 3
    jae near_none
    mov bh, 0
    mov al, [cs:div_tab + bx]
    mov [CURDIV], al
    mov byte [CURLAT], 0

.sweep_lat:
    mov al, [CURLAT]
    cmp al, 8
    jae .next_div
    ; ctrl = (lat<<3) | div
    mov cl, 3
    shl al, cl
    or  al, [CURDIV]
    mov [CURCTRL], al
    out 0E4h, al
    call short_delay

    call test_psram
    call draw_status
    call draw_map

    mov ax, [FAILCNT]
    or  ax, ax
    jz  found

    call vis_delay
    inc byte [CURLAT]
    jmp .sweep_lat

.next_div:
    inc byte [DIVIDX]
    jmp .sweep_div

near_none:
    mov ax, VIDEO_SEG
    mov es, ax
    mov di, (24*80+2)*2
    mov si, str_none
    call puts
.hn:
    jmp .hn

found:
    mov ax, VIDEO_SEG
    mov es, ax
    mov di, (24*80+2)*2
    mov si, str_found
    call puts
    mov al, [CURCTRL]
    call puthex_al
.hf:
    jmp .hf

;-------------------------------------------------------------------------------
; test_psram : test every 4 KB page; fill RESULT_OFS[] (0=pass,1=fail); FAILCNT
; uses ES as page segment.  DS must be 0 on entry.
;-------------------------------------------------------------------------------
test_psram:
    mov word [FAILCNT], 0
    xor si, si                  ; page index
    mov bx, PS_FIRST            ; page segment
.page:
    mov es, bx
    ; write 4 points
    mov byte [es:0x000], 0A5h
    mov byte [es:0x555], 5Ah
    mov byte [es:0xAAA], 0FFh
    mov al, bl                  ; page-dependent value
    mov byte [es:0xFFF], al
    ; read back
    xor dl, dl                  ; fail flag
    cmp byte [es:0x000], 0A5h
    je  .c1
    mov dl, 1
.c1:
    cmp byte [es:0x555], 5Ah
    je  .c2
    mov dl, 1
.c2:
    cmp byte [es:0xAAA], 0FFh
    je  .c3
    mov dl, 1
.c3:
    mov al, bl
    cmp byte [es:0xFFF], al
    je  .c4
    mov dl, 1
.c4:
    mov di, si
    mov [RESULT_OFS + di], dl   ; DS=0
    or  dl, dl
    jz  .next
    inc word [FAILCNT]
.next:
    add bx, 0100h               ; next 4 KB page
    inc si
    cmp si, NUM_PAGES
    jb  .page
    ret

;-------------------------------------------------------------------------------
; draw_map : colour one 2-wide cell per page from RESULT_OFS[].  ES set here.
;-------------------------------------------------------------------------------
draw_map:
    mov ax, VIDEO_SEG
    mov es, ax
    xor si, si
.cell:
    ; row = si/16, col = si mod 16
    mov ax, si
    mov bl, 16
    div bl                      ; al=row, ah=col
    mov bl, al                  ; row
    mov bh, ah                  ; col
    ; di = ((MAP_ROW0+row)*80 + MAP_COL0 + col*2) * 2
    mov al, bl
    add al, MAP_ROW0
    xor ah, ah
    mov cx, 80
    mul cx                      ; ax = (MAP_ROW0+row)*80
    mov dl, bh
    xor dh, dh
    shl dx, 1                   ; col*2
    add ax, dx
    add ax, MAP_COL0
    shl ax, 1                   ; bytes
    mov di, ax
    ; colour from result
    mov bx, si
    mov al, [RESULT_OFS + bx]   ; DS=0
    or  al, al
    jz  .pass
    mov ax, 04020h              ; red bg, space
    jmp .put
.pass:
    mov ax, 02020h              ; green bg, space
.put:
    stosw
    stosw                       ; 2 columns wide
    inc si
    cmp si, NUM_PAGES
    jb  .cell
    ret

;-------------------------------------------------------------------------------
; draw_status : "E4=xx  DIV=x LAT=x  FAIL=xxxx" on row 1.  ES set here.
;-------------------------------------------------------------------------------
draw_status:
    mov ax, VIDEO_SEG
    mov es, ax
    mov di, (1*80+2)*2
    mov si, str_e4
    call puts
    mov al, [CURCTRL]
    call puthex_al
    mov si, str_div
    call puts
    mov al, [CURDIV]
    add al, '0'
    mov ah, TXT_ATTR
    stosw
    mov si, str_lat
    call puts
    mov al, [CURLAT]
    add al, '0'
    mov ah, TXT_ATTR
    stosw
    mov si, str_fail
    call puts
    mov ax, [FAILCNT]
    call puthex_ax
    ret

;-------------------------------------------------------------------------------
; helpers
;-------------------------------------------------------------------------------
; puts : CS:SI = 0-terminated string -> ES:DI, attr TXT_ATTR
puts:
    mov al, [cs:si]
    or  al, al
    jz  .done
    mov ah, TXT_ATTR
    stosw
    inc si
    jmp puts
.done:
    ret

; puthex_ax : AX -> 4 hex chars at ES:DI
puthex_ax:
    push ax
    mov al, ah
    call puthex_al
    pop ax
    call puthex_al
    ret

; puthex_al : AL -> 2 hex chars at ES:DI (attr TXT_ATTR)
puthex_al:
    push bx
    mov bl, al
    mov al, bl
    shr al, 4
    call ph_nib
    mov al, bl
    call ph_nib
    pop bx
    ret
ph_nib:
    and al, 0Fh
    cmp al, 9
    jbe .d
    add al, 'A'-10
    jmp .e
.d:
    add al, '0'
.e:
    mov ah, TXT_ATTR
    stosw
    ret

clear_screen:
    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    mov ax, 1720h               ; space, white on blue
    mov cx, 2000
    rep stosw
    ret

vis_delay:
    push cx
    push dx
    mov dx, 12
.o:
    xor cx, cx
.i:
    loop .i
    dec dx
    jnz .o
    pop dx
    pop cx
    ret

short_delay:
    push cx
    xor cx, cx
.s:
    loop .s
    pop cx
    ret

;-------------------------------------------------------------------------------
; data
;-------------------------------------------------------------------------------
div_tab     db 4, 2, 1
str_title   db 'PSRAM QPI TIMING FINDER  (green=pass red=fail)', 0
str_e4      db 'E4=', 0
str_div     db '  DIV=', 0
str_lat     db ' LAT=', 0
str_fail    db '  FAIL=', 0
str_found   db 'FOUND - set E4=', 0
str_none    db 'NONE PASSED - lower SCK further / check SIO-SCK signal integrity', 0

;-------------------------------------------------------------------------------
; reset vector at 0xFFFF0 (image offset 0x1FF0) + pad to 8 KB
;-------------------------------------------------------------------------------
times (0x1FF0 - ($ - $$)) db 0
reset_vec:
    jmp 0F000h:0E000h
times (0x2000 - ($ - $$)) db 0
