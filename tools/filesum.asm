; ============================================================================
;  filesum.asm  --  checksum a file, so "did the disk give me the right bytes"
;                   can be answered against a known-good number
;
;  USBPERF already has an integrity check, but it answers a narrower question
;  than it looks like it does: it reads a fixed region the same way every run
;  and checks the checksum does not CHANGE. That catches a read path that has
;  become unstable. It cannot catch one that is reliably wrong -- the same bad
;  bytes every time produce the same checksum, and the check passes.
;
;  This closes that gap by comparing against a value computed on the host, off
;  the original file, before it ever went near this machine. If the numbers
;  agree, every layer between the flash on the stick and DOS handed over the
;  right bytes, and a program misbehaving is a problem somewhere else. If they
;  disagree, nothing above the disk is worth debugging yet.
;
;      filesum C:\KEEN4\KEEN4C.EXE
;
;  The checksum is the Adler/Fletcher pair -- s1 accumulates the bytes, s2
;  accumulates s1 -- both 16-bit and allowed to wrap. Two adds per byte, so a
;  365 KB file takes a couple of seconds instead of the minute a bitwise CRC
;  would cost at 8 MHz. s2 is position-dependent, so unlike a plain sum it does
;  not forgive bytes that are right but in the wrong order, which is exactly
;  the failure a too-fast port read would produce.
;
;  The length is printed too, and is worth reading first: a short count means
;  the read stopped early, which is a different fault from a wrong byte.
;
;  Build:  nasm -f bin filesum.asm -o filesum.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

CHUNK   equ 16384               ; bytes per DOS read

start:
        cld
        mov  dx, msg_hdr
        call puts

; ---------------------------------------------------------------------------
; the filename, out of the command tail
        mov  si, 0x81
        mov  cl, [0x80]
        mov  ch, 0
        jcxz .none
.skip:  mov  al, [si]
        cmp  al, ' '
        jne  .got
        inc  si
        loop .skip
.none:  jmp  nofile             ; JCXZ and Jcc are short-only on an 8086, and
.got:                           ; nofile is well out of range -- trampoline
        mov  di, fname
.copy:  mov  al, [si]
        cmp  al, ' '
        je   .eos
        cmp  al, 13
        je   .eos
        mov  [di], al
        inc  di
        inc  si
        loop .copy
.eos:   mov  byte [di], 0
        cmp  di, fname
        jne  .haveit
        jmp  nofile
.haveit:

        mov  dx, fname
        call puts0

; ---------------------------------------------------------------------------
        mov  dx, fname
        mov  ax, 0x3D00         ; open for reading
        int  0x21
        jc   noopen
        mov  [handle], ax

.rd:
        mov  ah, 0x3F
        mov  bx, [handle]
        mov  cx, CHUNK
        mov  dx, buf
        int  0x21
        jc   readerr
        test ax, ax
        jz   .done

        add  [len], ax          ; 32-bit length
        adc  word [len+2], 0

        mov  cx, ax
        mov  si, buf
        mov  bx, [s1]
        mov  dx, [s2]
.b:     lodsb
        mov  ah, 0
        add  bx, ax             ; s1 += byte
        add  dx, bx             ; s2 += s1  -- this is what makes it positional
        loop .b
        mov  [s1], bx
        mov  [s2], dx
        jmp  short .rd

.done:
        mov  ah, 0x3E
        mov  bx, [handle]
        int  0x21

        mov  dx, msg_len
        call puts
        call putdec32
        mov  dx, msg_sum
        call puts
        mov  ax, [s1]
        call puthexw
        mov  dl, ' '
        call putch
        mov  ax, [s2]
        call puthexw
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_tail
        call puts
        jmp  short bye

nofile:
        mov  dx, msg_usage
        call puts
        jmp  short bye
noopen:
        mov  dx, msg_noopen
        call puts
        jmp  short bye
readerr:
        mov  dx, msg_readerr
        call puts
bye:
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
putch:  push ax
        push dx
        mov  dl, al
        mov  ah, 2
        int  0x21
        pop  dx
        pop  ax
        ret

puts:   push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

puts0:                          ; DS:DX = NUL-terminated
        push ax
        push si
        mov  si, dx
.p:     mov  al, [si]
        test al, al
        jz   .e
        call putch
        inc  si
        jmp  short .p
.e:     mov  dx, msg_crlf
        call puts
        pop  si
        pop  ax
        ret

puthexw:
        push ax
        mov  al, ah
        call puthexb
        pop  ax
        call puthexb
        ret
puthexb:
        push ax
        push bx
        push cx
        mov  bl, al
        mov  cl, 4
        shr  al, cl
        call .nib
        mov  al, bl
        call .nib
        pop  cx
        pop  bx
        pop  ax
        ret
.nib:   and  al, 0x0F
        cmp  al, 10
        jb   .n0
        add  al, 'A'-10
        jmp  short .n1
.n0:    add  al, '0'
.n1:    call putch
        ret

; putdec32 -- print [len] in decimal. A 32-bit divide by ten on an 8086 is two
; DIVs: the high half first, then the low half with the remainder still in DX.
putdec32:
        push ax
        push bx
        push cx
        push dx
        mov  ax, [len]
        mov  [tmp], ax
        mov  ax, [len+2]
        mov  [tmp+2], ax
        xor  cx, cx
        mov  bx, 10
.d1:
        mov  ax, [tmp+2]
        xor  dx, dx
        div  bx
        mov  [tmp+2], ax
        mov  ax, [tmp]
        div  bx                 ; DX still holds the high half's remainder
        mov  [tmp], ax
        push dx                 ; this digit
        inc  cx
        mov  ax, [tmp]
        or   ax, [tmp+2]
        jnz  .d1
.d2:    pop  ax
        add  al, '0'
        call putch
        loop .d2
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
handle  dw 0
s1      dw 0
s2      dw 0
len     dd 0
tmp     dd 0

msg_hdr db 'FILESUM - checksum a file against a known-good value',13,10,'$'
msg_usage db 13,10,'Usage:  filesum C:\KEEN4\KEEN4C.EXE',13,10,'$'
msg_noopen db 'Cannot open that file.',13,10,'$'
msg_readerr db 13,10,'READ FAILED part way through. The length above is how far it got.',13,10,'$'
msg_len db 13,10,'  length  : $'
msg_sum db ' bytes',13,10,'  checksum: $'
msg_tail db 13,10
        db 'Both numbers must match the host exactly. A wrong checksum with',13,10
        db 'the right length means the disk returned the wrong bytes, and',13,10
        db 'nothing above the disk is worth debugging until that is fixed.',13,10,'$'
msg_crlf db 13,10,'$'

fname   times 80 db 0
; The buffer is simply everything past the end of the image. DOS hands a .COM
; the whole 64 KB segment, the stack starts at the top of it, and CHUNK bytes
; from here comes nowhere near that -- so there is no reason to carry 16 KB of
; zeros around in the file.
buf:
