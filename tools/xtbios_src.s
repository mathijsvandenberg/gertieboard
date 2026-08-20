## =====================================================================
##  XTBIOS  -  a minimal IBM PC/XT-class ROM BIOS for an FPGA 5160 clone
##  Visual style inspired by the Philips P3105 BIOS boot screen.
##
##  - 8 KB image, organised at segment F000 offset E000 (phys FE000-FFFFF)
##  - Reset vector at F000:FFF0 -> POST
##  - Brings up: 8259 PIC, 8253 PIT (18.2Hz tick), 8255 PPI, 6845 CGA 80x25
##  - Installs IVT + handlers: INT 08,09,10,11,12,13,15,16,19,1A,1C,1E
##  - Boots the first sector of floppy A: (CHS 0/0/1) to 0000:7C00
##
##  Assemble (GNU binutils, no NASM needed):
##     as  --32 xtbios.s -o xtbios.o
##     ld  -m elf_i386 -Ttext=0xE000 --oformat=binary -e _post xtbios.o -o xtbios.bin
##  Result is exactly 8192 bytes -> place at physical FE000 in your ROM.
##
##  Hardware ports assumed (standard IBM 5160):
##     PIC   0x20/0x21          PIT  0x40-0x43      PPI  0x60-0x63
##     CGA   0x3D4/0x3D5 (CRTC) 0x3D8 mode 0x3D9 colour   video RAM B800:0
##     FDC   uPD765 0x3F0-0x3F7, DOR 0x3F2, DMA 8237 ch2 (0x04/0x05/0x0B/0x81)
## =====================================================================

.code16
## Target a real 8088, so the assembler REFUSES anything newer instead of
## silently upgrading. This matters: a conditional jump whose target is out of
## short range was quietly emitted as the 386 form 0F 84 (JZ rel16), and on an
## 8088 opcode 0F is POP CS -- it popped garbage into CS and execution vanished,
## unconditionally, on every call. Days of "impossible" behaviour came from that.
.arch i8086
.intel_syntax noprefix
.text

## ---- equates -------------------------------------------------------
.equ BDA,        0x0040      # BIOS data area segment
.equ VID,        0xB800      # CGA text video segment
.equ EGAVID,     0xA000      # EGA bit-plane window (mode 0Dh)
.equ KBBUF,      0x001E      # kbd buffer start (offset in BDA)
.equ KBEND,      0x003E      # kbd buffer end+1
.equ EOI,        0x20

## =====================================================================
##  POST entry  (jumped to from the reset vector at the top of ROM)
## =====================================================================
_post:
    cli
    cld
    mov ax, 0xF000          # we execute in segment F000
    mov ds, ax              # DS = ROM: needed for strings + CRTC table
    xor ax, ax
    mov ss, ax
    mov sp, 0x7C00          # stack just under the boot area

## ---- video up + draw banner with INTERRUPTS OFF (first light) -------
##      done before any PIC/PIT/sti so the screen appears even if the
##      interrupt controller or timer is misbehaving.
    call vid_init           # program 6845 / CGA, clear B800  (DS=ROM)
    mov ax, 0xB800
    mov es, ax
    # Clear the screen first. POST paints at absolute rows and never scrolls,
    # but the boot-failure path prints through the teletype, which DOES -- so
    # a machine that fails to boot, scrolls, and is reset leaves the next POST
    # painting over a shifted copy of the last one. The flash-boot "garbage"
    # photographs were partly this: several failed passes overlaid. Every
    # screen now shows exactly one boot, in true order.
    xor di, di
    mov ax, 0x0720          # space on the standard attribute
    mov cx, 2000            # 80 x 25
    cld
    rep stosw
    xor al, al              # row 0
    mov si, offset b_ver
    call putrow
    mov al, 1
    mov si, offset b_model
    call putrow
    mov al, 2
    mov si, offset b_copy
    call putrow

    # Release and commit, at the right of the model line. The Philips banner
    # above names the machine being imitated; this names what is actually
    # running, which has twice been the thing nobody could establish.
    push es
    push ds
    push di
    mov ax, VID
    mov es, ax
    mov di, 1*160 + 2*44
    push cs
    pop ds
    mov si, offset b_rel
    call dbg_str
    mov si, offset b_git
    call dbg_str
    pop di
    pop ds
    pop es
    # Sum the code region NOW, before any device is probed, and paint it at
    # the top right. On a flash boot this is the first thing that tells the
    # truth: if it reads the same value as a serial boot, the loaded image is
    # intact and any strangeness below is state, not corruption -- and it
    # appears even if a wedged device stalls the rest of POST. The region
    # stops at u_cbw: everything past it is runtime scratch, which BIOSFLASH
    # legitimately copies mid-life.
    # (This block once popped one register more than it pushed. POST painted
    # the checksum and then crashed on its own corrupted stack -- the "number
    # appears, then everything resets" symptom. Pushes and pops below are
    # strictly symmetric; keep them that way.)
    push ax
    push bx
    push cx
    push si
    push di
    push es
    push ds
    mov ax, VID
    mov es, ax
    mov di, 0*160 + 2*66
    push cs
    pop ds
    mov si, offset b_sum
    call dbg_str
    mov si, 0xC000
    mov cx, offset _rt_start
    sub cx, 0xC000
    xor ax, ax
    xor bx, bx
.psum:
    mov bl, [si]
    add ax, bx
    inc si
    loop .psum
    push ds
    mov bx, BDA
    mov ds, bx
    mov [0xB8], ax               # published for BIOSFLASH's pre-write check
    mov bx, offset _rt_start
    sub bx, 0xC000
    mov [0xBA], bx
    mov bx, offset u_fast        # where 186BOOST.COM finds the boost flag
    mov [0xBC], bx
    pop ds
    mov byte ptr cs:[u_fast], 0  # 8086-safe path until something asks for more
    push ax
    mov al, ah
    call dbg_byte
    pop ax
    call dbg_byte
    pop ds
    pop es
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    mov al, 4
    mov si, offset b_hdr
    call putrow
    mov al, 5
    mov si, offset b_mem
    call putrow
    mov al, 6
    mov si, offset b_par
    call putrow

    # ---- can this CPU execute INSB? -------------------------------------
    # Not which part -- that cannot be known. A CPU carries no identifying
    # register, and its speed grade is a marking on the package. The only
    # honest question is what the thing can DO, and the only answer worth
    # having is about the exact instruction we intend to use.
    #
    # An earlier version asked instead whether the CPU masks a shift count to
    # five bits, on the theory that a V20 behaves like an 80186 there. It does
    # not: NEC kept the 8086's quirks and only ADDED instructions, so a V20
    # answers that question exactly like an 8088 and the fast path was never
    # taken on the very CPU that supports it. Inferring a capability from an
    # unrelated behaviour was the mistake; this asks directly.
    #
    # The probe rests on a documented 8086 property: opcodes 60-6F decode as
    # aliases of 70-7F, the conditional jumps. So the byte 6C is INSB on a V20
    # or 80186, and JZ rel8 on an 8088. One byte against two -- which is what
    # makes a direct test possible, once the byte counts are made to line up:
    #
    #   6C 06   V20:  INSB, then PUSH ES        8088: JZ +6, taken (ZF=1)
    #   07      V20:  POP ES                    8088: jumped over
    #   43      V20:  INC BX                    8088: jumped over
    #   90 x4   V20:  NOP                       8088: jumped over
    #
    # Six bytes skipped, six bytes of displacement, so both CPUs resume at the
    # same instruction and the stack balances on either path. Every byte is
    # harmless whichever way it is decoded, and BX says which happened.
    #
    # INSB needs somewhere to put its byte: ES:DI points at u_buf, which is
    # scratch, and DX at the diagnostic window, which has no side effects.
    push es
    push di
    push dx
    push bx
    cld
    push cs
    pop es
    mov di, offset u_buf         # a scratch byte to receive the read
    mov dx, 0xEF                 # reading the diag window changes nothing
    xor bx, bx
    xor ax, ax                   # ZF = 1, and nothing below disturbs it
    .byte 0x6C, 0x06             # INSB + PUSH ES   |   JZ +6
    .byte 0x07                   # POP ES     -- V20 only
    .byte 0x43                   # INC BX     -- V20 only
    .byte 0x90, 0x90, 0x90, 0x90 # NOP        -- V20 only
    mov si, offset b_cpu86
    test bx, bx
    jz .cpu_slow                 # jumped over it: no INSB on this CPU
    mov byte ptr cs:[u_fast], 1  # it executed: take the fast disk path
    mov si, offset b_cpu186
.cpu_slow:
    pop bx
    pop dx
    pop di
    pop es
.cpu_report:
    push si
    mov al, 7
    mov si, offset b_cpu
    call putrow
    pop si
    push es
    mov ax, VID
    mov es, ax
    mov di, 7*160 + 2*21
    call dbg_str
    pop es

## ---- the system clock, row 11 --------------------------------------
##  MEASURED, not declared. See cpu_speed for why that distinction earned its
##  keep: a stale bitstream reported a speed the machine was not running at,
##  and a constant would have agreed with it.
    call cpu_speed               # AX = MHz x 100
    call fmt_mhz                 # -> mhz_buf as "N.NN"
    mov al, 11
    mov si, offset b_clk
    call putrow
    push es
    push ds
    mov ax, VID
    mov es, ax
    mov di, 11*160 + 2*21        # just past "System clock set to: Turbo "
    push cs
    pop ds
    mov si, offset mhz_buf
    call dbg_str
    mov si, offset b_mhz
    call dbg_str
    pop ds
    pop es

## ---- 8259 PIC (master, XT single mode) -----------------------------
    mov al, 0x13            # ICW1: edge, single, ICW4 needed
    out 0x20, al
    mov al, 0x08            # ICW2: IRQ0..7 -> INT 08..0F
    out 0x21, al
    mov al, 0x09            # ICW4: 8086, buffered master
    out 0x21, al
    mov al, 0xFC            # unmask IRQ0 (timer) + IRQ1 (kbd) only
    out 0x21, al

## ---- 8253 PIT ch0 = 18.2 Hz tick -----------------------------------
    mov al, 0x36            # ch0, lo/hi, mode 3, binary
    out 0x43, al
    xor al, al
    out 0x40, al            # divisor 0 -> 65536
    out 0x40, al
    mov al, 0x54            # ch1, lo only, mode 2  (DRAM refresh)
    out 0x43, al
    mov al, 0x12
    out 0x41, al

## ---- 8255 PPI ------------------------------------------------------
    mov al, 0x99            # PA in, PB out, PC in, mode 0
    out 0x63, al
    mov al, 0x0C            # PB: kbd enabled, speaker off, gate2 off
    out 0x61, al

## ---- clear & init the BIOS data area -------------------------------
    mov ax, BDA
    mov es, ax
    xor di, di
    mov cx, 0x80            # zero 256 bytes of BDA
    xor ax, ax
    rep stosw
    # bits 7:6 = (floppy count - 1), bit 0 = floppies present, bits 5:4 = 10
    # for 80x25 colour. Two drives now: A: over serial, B: on the SPI flash.
    mov word ptr es:[0x10], 0x0061   # equipment: 2 floppies, 80x25 colour
    # Full 640 KB. The fixed-disk block buffer used to live at 0x9E000 and cost
    # 8 KB of this; it now sits in on-chip M9K at 0xE0000 (see HDBUF_SEG), which
    # DOS never sees. Keep this in step with b_mem below.
    mov word ptr es:[0x13], 640      # base memory size in KB
    # Fixed disks: 0 until the USB mass-storage stack lands and enumeration
    # actually succeeds. Advertising a disk that is not there is what broke the
    # boot once already -- see hd_int13 and docs/gotchas.md.
    mov byte ptr es:[0x75], 0        # set below, only if USB enumeration works
    mov byte ptr es:[0xE0], 0        # B: present flag, set by hd_detect below
    mov byte ptr es:[0xC0], 0        # USB enumeration stage
    mov byte ptr es:[0xC1], 0        # USB disk present
    mov byte ptr es:[0xDB], 0        # BUSY stall count
    mov byte ptr es:[0xD5], 0        # 1 once the stall state has been latched
    mov word ptr es:[0x1A], KBBUF    # kbd buffer head
    mov word ptr es:[0x1C], KBBUF    # kbd buffer tail
    mov word ptr es:[0x80], KBBUF    # buffer start
    mov word ptr es:[0x82], KBEND    # buffer end
    # Keyboard status flags 3 and 4. These MUST be deterministic: DOS 4 and
    # later, KEYB.COM and anything enhanced-keyboard-aware read 0x96 for the
    # "last code was E0/E1" and right-ctrl/right-alt bits, and 0x97 for the
    # lock LEDs. The floppy handler used to keep its buffer pointer at 0x96,
    # so after any disk access these held whatever offset was last read from
    # -- phantom modifier keys, but only on the DOS versions that look.
    mov byte ptr es:[0x96], 0
    mov byte ptr es:[0x97], 0
    mov byte ptr es:[0x49], 0x03     # video mode 3
    mov word ptr es:[0x4A], 80       # columns
    mov word ptr es:[0x4C], 0x1000   # page size
    mov word ptr es:[0x63], 0x03D4   # CRTC port
    mov byte ptr es:[0x65], 0x29     # 3D8 mode reg shadow
    mov byte ptr es:[0x66], 0x30     # 3D9 colour reg shadow
    mov word ptr es:[0x50], 0x0C00   # text cursor at row 12 (below banner)
    mov byte ptr es:[0xB0], 79        # default INT13/AH=08 geometry (1.44M)
    mov byte ptr es:[0xB1], 18        #   until the boot read detects the BPB
    mov byte ptr es:[0xB2], 1

## ---- build the interrupt vector table ------------------------------
    xor ax, ax
    mov es, ax              # ES = 0  (IVT)
    mov di, 0
    mov cx, 256
.fill_ivt:
    mov word ptr es:[di],   offset _dummy_int
    mov word ptr es:[di+2], 0xF000
    add di, 4
    loop .fill_ivt
    mov bx, 0x08*4
    mov word ptr es:[bx], offset _int08
    mov bx, 0x09*4
    mov word ptr es:[bx], offset _int09
    mov bx, 0x10*4
    mov word ptr es:[bx], offset _int10
    mov bx, 0x11*4
    mov word ptr es:[bx], offset _int11
    mov bx, 0x12*4
    mov word ptr es:[bx], offset _int12
    mov bx, 0x13*4
    mov word ptr es:[bx], offset _int13
    mov bx, 0x15*4
    mov word ptr es:[bx], offset _int15
    mov bx, 0x16*4
    mov word ptr es:[bx], offset _int16
    mov bx, 0x19*4
    mov word ptr es:[bx], offset _int19
    mov bx, 0x1A*4
    mov word ptr es:[bx], offset _int1a
    mov bx, 0x1E*4
    mov word ptr es:[bx],   offset _floppy_dpt
    mov word ptr es:[bx+2], 0xF000

    ## INT 43h -- the 8x8 GRAPHICS FONT, and this vector is not optional.
    ##
    ## It is read in two directions, and both matter:
    ##
    ##  * software that plots its own text in a graphics mode reads it to find
    ##    the glyphs. Every vector starts out pointing at _dummy_int, so what
    ##    such a program had been reading was a bare IRET, and the glyph bitmaps
    ##    were whatever BIOS code bytes happened to follow it.
    ##
    ##  * WE read it, in g_render, whenever the mode is 0Dh -- because on an EGA
    ##    this vector, not the ROM, is what names the character generator. That
    ##    also lets a program hand us a glyph we do not have by re-aiming the
    ##    vector for the duration of one INT 10h call, which is exactly how
    ##    King's Quest draws its inverse-video text. See g_render.
    ##
    ## Only the offset is written: the fill above already left 0xF000 in the
    ## segment half. INT 1Fh stays null on purpose -- it is the CGA-era upper-128
    ## table, and a stock machine has none.
    mov bx, 0x43*4
    mov word ptr es:[bx],   offset font8x8

## ---- diskette A:: is the serial host actually serving an image? --------
##  A: is a link to a host program, not a drive, so the only honest test is to
##  read a sector and see whether the data ever arrives. A timeout is a normal
##  outcome here -- it is precisely what NOT READY means -- and it costs the
##  bounded ~2.5 s only when nothing is listening. The result is recorded so
##  INT 19h can skip A: instead of paying that wait a second time.
    call fd_detect

## ---- fixed disk: identify the SPI flash and report its size ---------
    mov ax, BDA
    mov ds, ax
    call hd_detect

## ---- a USB floppy on USB1 takes B: away from the SPI flash -----------
##  Enumerated AFTER hd_detect and reported over the top of its line, rather
##  than by teaching hd_detect about USB. hd_detect works and drives the flash
##  path; the cheapest correct change is to leave it alone and repaint row 9.
##  Failure is silent: uf_pres stays 0, B: remains the flash, and the machine
##  behaves exactly as it did before this code existed.
    call uf_enum
    cmp byte ptr cs:[uf_pres], 0
    je .post_nouf
    call uf_ready
    call uf_report
    jmp short .post_ufdone
.post_nouf:
.post_ufdone:

## ---- USB mass storage: enumerate, and advertise C: only if it worked ----
##  Enumeration is allowed to fail. If it does, BDA 40:75 stays 0, INT 13h
##  answers "invalid drive" for DL >= 0x80, INT 19h skips C: in the boot order,
##  and the machine behaves exactly like one with no fixed disk. BDA 0xC0 keeps
##  the stage it reached so USBHD.COM can say WHERE it stopped.
    call u_enum
    call usb_report
    mov ax, BDA
    mov es, ax
    mov al, es:[0xC1]
    mov es:[0x75], al               # 1 = C: exists, 0 = it does not

## ---- boot (disk read is polled, so interrupts stay off for now) -----
##  "Booting..." goes on LAST, under the device lines. It used to be painted
##  with the banner, before the drives had reported, so it appeared wedged
##  between drive B: and the hard disk.
    push es
    mov ax, VID
    mov es, ax
    mov al, 12
    push cs
    pop ds
    mov si, offset b_boot
    call putrow
    pop es
    mov ax, BDA
    mov ds, ax
    int 0x19                # bootstrap from floppy A:
    # int 0x19 never returns on success
.post_hang:
    jmp .post_hang

## =====================================================================
##  Generic dummy interrupt
## =====================================================================
_dummy_int:
    iret

## =====================================================================
##  Video initialisation: program CRTC for 80x25, clear screen
## =====================================================================
vid_init:
    push ax
    push bx
    push cx
    push dx
    push si
    push es
    push ds
    ## DS MUST BE THE ROM SEGMENT for the crtc_80x25 lookup below.
    ##
    ## POST calls this with DS already 0xF000 and it worked; INT 10h AH=0 calls
    ## it with whatever DS the application had, and read the table out of the
    ## caller's data segment. That was invisible for as long as the CRTC was
    ## write-only and vga.vhd ignored every value -- writing rubbish to a
    ## register nobody reads looks exactly like writing the right thing.
    ##
    ## It stopped being invisible when crtc6845 arrived: R10/R11 are the cursor
    ## shape now, so a mode set from an application gave the cursor whatever
    ## happened to lie at that offset in its data segment.
    mov ax, cs
    mov ds, ax
    mov dx, 0x03D4
    xor bx, bx              # register index 0
.vi_loop:
    mov al, bl
    out dx, al              # select CRTC register
    inc dx                  # 0x3D5 data
    mov si, offset crtc_80x25
    mov al, [si+bx]
    out dx, al
    dec dx
    inc bx
    cmp bx, 16
    jb .vi_loop
    mov dx, 0x03D8          # mode control: 80x25 text, video on, blink
    mov al, 0x29
    out dx, al
    mov dx, 0x03D9          # colour select
    mov al, 0x30
    out dx, al
    # clear video memory to spaces, attr 0x07
    mov ax, VID
    mov es, ax
    xor di, di
    mov ax, 0x0720
    mov cx, 2000
    rep stosw
    pop ds
    pop es
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

## =====================================================================
##  EGA support -- mode 0Dh, 320x200 in 16 colours.
##
##  Four bit planes of 8 KB at 0xA0000, with the plane chosen by register
##  rather than by address. See docs/modules/vga.md.
##
##  gc_out / seq_out take AH = index, AL = value.
## =====================================================================
gc_out:
    push dx
    push ax
    mov dx, 0x03CE
    mov al, ah
    out dx, al
    pop ax
    mov dx, 0x03CF
    out dx, al
    pop dx
    ret

seq_out:
    push dx
    push ax
    mov dx, 0x03C4
    mov al, ah
    out dx, al
    pop ax
    mov dx, 0x03C5
    out dx, al
    pop dx
    ret

## ega_off -- put the Graphics Controller's Miscellaneous register back to
## alphanumeric with the window at 0xB8000.
##
## EVERY non-EGA mode set must do this. GC 6 is what decides whether this card
## is showing bit planes or a CGA page, so a mode 3 that leaves it at 0x05
## returns a machine that has cleared a text screen nobody is looking at while
## the display carries on scanning four planes of whatever the game left there.
ega_off:
    push ax
    mov ax, 0x060E
    call gc_out
    pop ax
    ret

## ega_pal -- load the sixteen default palette registers.
##
## The attribute controller has ONE port for index and data, alternating, and
## the flip-flop that says which is next is reset by READING 0x3DA. That read is
## not optional and not a workaround: it is how every EGA program resynchronises
## before touching the palette, because it cannot know which half of the
## alternation the previous program left behind.
ega_pal:
    push ax
    push bx
    push dx
    push si
    push ds
    mov ax, cs
    mov ds, ax
    mov si, offset ega_pal_def
    xor bx, bx                   # BH too: the lookup below is [si+bx], not [si+bl]
.epal:
    mov dx, 0x03DA
    in  al, dx                   # resets the index/data flip-flop
    mov dx, 0x03C0
    mov al, bl
    out dx, al                   # index
    mov al, [si+bx]
    out dx, al                   # data, same port
    inc bl
    cmp bl, 16
    jb .epal
    pop ds
    pop si
    pop dx
    pop bx
    pop ax
    ret

## ega_init -- everything except clearing the planes, which v_setmode does so it
## can honour the caller's "do not clear" bit.
ega_init:
    push ax
    mov ax, 0x020F               # SEQ 2  map mask = all four planes
    call seq_out
    mov ax, 0x0000               # GC 0   set/reset
    call gc_out
    mov ax, 0x0100               # GC 1   enable set/reset = off
    call gc_out
    mov ax, 0x0200               # GC 2   colour compare
    call gc_out
    mov ax, 0x0300               # GC 3   rotate 0, function = replace
    call gc_out
    mov ax, 0x0400               # GC 4   read map = plane 0
    call gc_out
    mov ax, 0x0500               # GC 5   write mode 0, read mode 0
    call gc_out
    mov ax, 0x070F               # GC 7   colour don't care
    call gc_out
    mov ax, 0x08FF               # GC 8   bit mask = every bit
    call gc_out
    mov ax, 0x0605               # GC 6   graphics, 0xA0000 -- LAST: it switches
    call gc_out

    ## CRTC: start address zero, and the row stride the mode expects.
    ##
    ## The Offset register (0x13) is the width of a LOGICAL line in words, and
    ## 0x14 -- 20 words, 40 bytes -- is exactly the 320 pixels mode 0Dh shows.
    ## Software that scrolls makes it BIGGER than the display on purpose and
    ## moves the start address through the margin, so this is a default rather
    ## than a constant. vga.vhd reads whatever ends up here.
    mov dx, 0x03D4
    mov al, 0x0C                 # start address high
    out dx, al
    inc dx
    xor al, al
    out dx, al
    dec dx
    mov al, 0x0D                 # start address low
    out dx, al
    inc dx
    xor al, al
    out dx, al
    dec dx
    mov al, 0x13                 # offset / logical line width
    out dx, al
    inc dx
    mov al, 0x14
    out dx, al

    call ega_pal
    pop ax
    ret

## =====================================================================
##  putrow - write ASCIZ string at DS:SI to row AL of B800 (ES), attr 07
##           interrupt-free, used for the POST banner
## =====================================================================
putrow:
    push ax
    push si
    push di
    mov ah, 160
    mul ah                  # ax = row * 160 (bytes per row)
    mov di, ax
.pr_l:
    lodsb
    test al, al
    jz .pr_d
    mov ah, 0x07
    mov es:[di], ax
    add di, 2
    jmp .pr_l
.pr_d:
    pop di
    pop si
    pop ax
    ret

## =====================================================================
##  puts  - print ASCIZ string at DS:SI via INT 10/0E
## =====================================================================
puts:
    push ax
    push bx
    push si
    push ds
    mov ax, 0xF000               # strings live in the ROM segment
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

## =====================================================================
##  put_dec - print unsigned AX in decimal via INT 10/0E
## =====================================================================
put_dec:
    push ax
    push bx
    push cx
    push dx
    mov bx, 10
    xor cx, cx
.pd_div:
    xor dx, dx
    div bx                  # ax/10, dx=remainder
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

## =====================================================================
##  INT 10h - video services (subset)
## =====================================================================
_int10:
    sti
    cmp ah, 0x0E                 # teletype first (most common)
    jne .i10_n0e
    jmp v_tty
.i10_n0e:
    cmp ah, 0x00
    jne .i10_n00
    jmp v_setmode
.i10_n00:
    cmp ah, 0x01
    jne .i10_n01
    jmp v_curtype
.i10_n01:
    cmp ah, 0x02
    jne .i10_n02
    jmp v_setcur
.i10_n02:
    cmp ah, 0x03
    jne .i10_n03
    jmp v_getcur
.i10_n03:
    cmp ah, 0x06
    jne .i10_n06
    jmp v_scrollup
.i10_n06:
    cmp ah, 0x07
    jne .i10_n07
    jmp v_scrolldn
.i10_n07:
    cmp ah, 0x08
    jne .i10_n08
    jmp v_readch
.i10_n08:
    cmp ah, 0x09
    jne .i10_n09
    jmp v_writeca
.i10_n09:
    cmp ah, 0x0A
    jne .i10_n0a
    jmp v_writec
.i10_n0a:
    cmp ah, 0x0F
    jne .i10_n0f
    jmp v_getmode
.i10_n0f:
    cmp ah, 0x0B
    jne .i10_n0b
    jmp v_palette
.i10_n0b:
    cmp ah, 0x12
    jne .i10_done
    jmp v_alt_select
.i10_done:
    iret

## AH=12h, BL=10h: return EGA information.
##
## This is the call software uses to decide an EGA is fitted, and the test is
## not the values -- it is that BL comes back CHANGED from the 0x10 that was
## passed in. A machine with no EGA leaves it alone. Keen 4 and King's Quest
## both ask this before offering their EGA modes.
##
## BL = 0 claims 64 KB, the smallest EGA ever shipped, and this is now an
## UNDERSTATEMENT rather than the overstatement it used to be: the planes moved
## to SDRAM and a plane is 64 KB, so the board really has 256 KB and could
## answer BL = 3.
##
## It does not, because memory size is not the only thing this call decides. A
## game told 256 KB may reasonably choose mode 10h -- 640x350 -- and only mode
## 0Dh exists here, so the honest answer buys nothing and costs the software
## that works today. Nothing is waiting on the larger number either: Keen 4 does
## not consult it, which is precisely why it was already using three pages while
## being told it had room for one.
v_alt_select:
    cmp bl, 0x10
    jne .as_done
    mov bh, 0                    # 0 = colour display attached (0x3Dx)
    mov bl, 0                    # 64 KB of display memory
    mov ch, 0                    # feature connector bits
    mov cl, 0x09                 # configuration switches, as an IBM EGA
.as_done:
    iret

## AH=00: set video mode.  AL = mode (bit 7 set = don't clear video RAM):
##   0..3 -> 80x25 colour text (40-col modes render as 80-col)
##   4/5  -> 320x200 4-colour graphics       6 -> 640x200 2-colour
## Working set: CH/CL = 3D8/3D9 values, SI = columns, DI = page size.
v_setmode:
    push ds
    push es
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bh, al                   # BH keeps bit 7 (no-clear flag)
    and al, 0x7F
    mov bl, al                   # BL = mode number for the BDA
    cmp al, 4
    jb .sm_text
    cmp al, 6
    jbe .sm_gfx
    cmp al, 0x0D
    je .sm_ega
    ## Anything else -- including EGA modes 0Eh, 0Fh and 10h -- falls through to
    ## text. Those need 64 KB, 128 KB and 112 KB of display memory against the
    ## 32 KB that fits here, so there is nothing better to do than fail where it
    ## can be seen. A game that asks for one gets a text screen rather than a
    ## plausible-looking wrong picture.
.sm_text:
    call ega_off                 # GC 6 back to alphanumeric at 0xB8000
    call vid_init                # CRTC + 3D8/3D9 + clear to spaces
    mov ch, 0x29                 # 3D8: 80x25 text, video on, blink
    mov cl, 0x30                 # 3D9
    mov si, 80
    mov di, 0x1000               # page size 4 KB
    jmp .sm_bda
.sm_gfx:
    call ega_off                 # CGA graphics is still the CGA window
    mov ch, 0x2A                 # mode 4: graphics + video enable
    mov cl, 0x30                 # palette 1 (cyan/magenta/white), intensity
    mov si, 40
    cmp al, 5
    jb .sm_prog
    mov ch, 0x2E                 # mode 5: + b/w bit (cyan/red/white)
    je .sm_prog
    mov ch, 0x1E                 # mode 6: 640x200 1 bpp
    mov cl, 0x3F                 # white foreground
    mov si, 80
.sm_prog:
    mov dx, 0x03D8               # video off while clearing
    mov al, ch
    and al, 0xF7
    out dx, al
    test bh, 0x80                # bit 7 set -> keep VRAM contents
    jnz .sm_nc
    push cx
    cld
    mov ax, VID
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 0x2000               # clear the full 16 KB page
    rep stosw
    pop cx
.sm_nc:
    mov dx, 0x03D8
    mov al, ch
    out dx, al
    mov dx, 0x03D9
    mov al, cl
    out dx, al
    mov di, 0x4000               # page size 16 KB
    jmp .sm_bda

## Mode 0Dh -- 320x200x16, four planes at 0xA0000.
.sm_ega:
    call ega_init
    test bh, 0x80                # bit 7 set -> keep the planes as they are
    jnz .sm_ega_nc
    push cx
    cld
    mov ax, EGAVID
    mov es, ax
    xor di, di
    xor ax, ax
    ## 8000 bytes clears all FOUR planes at once: the map mask is 0x0F, the
    ## write mode is 0 and the bit mask is every bit, so one store reaches every
    ## plane at that offset. This is 32 KB of screen cleared by 4000 words.
    mov cx, 4000
    rep stosw
    pop cx
.sm_ega_nc:
    mov ch, 0x29                 # 3D8/3D9 shadows: EGA does not use them, but
    mov cl, 0x30                 # the BDA is read by software that assumes CGA
    mov si, 40                   # 40 bytes of 8 pixels across
    mov di, 0x2000               # 8 KB per plane
.sm_bda:
    mov ax, BDA
    mov ds, ax
    mov [0x49], bl               # video mode number
    mov [0x4A], si               # columns
    mov [0x4C], di               # page size
    mov [0x65], ch               # 3D8 shadow
    mov [0x66], cl               # 3D9 shadow
    mov word ptr [0x50], 0       # cursor home
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    pop es
    pop ds
    iret

## AH=0B: set CGA colour-select register (0x3D9)
##   BH=0: background/border colour + intensity = BL(4:0)
##   BH=1: palette = BL bit 0 (0 green/red/brown, 1 cyan/magenta/white)
v_palette:
    push ds
    push ax
    push bx
    push dx
    mov ax, BDA
    mov ds, ax
    mov al, [0x66]               # current 3D9 shadow
    test bh, bh
    jnz .pal_sel
    and al, 0xE0                 # replace bits 4:0
    and bl, 0x1F
    or  al, bl
    jmp .pal_out
.pal_sel:
    and al, 0xDF                 # bit 5 = palette select
    test bl, 0x01
    jz .pal_out
    or  al, 0x20
.pal_out:
    mov [0x66], al
    mov dx, 0x03D9
    out dx, al
    pop dx
    pop bx
    pop ax
    pop ds
    iret

v_curtype:
    push ds
    push ax
    push dx
    mov ax, BDA
    mov ds, ax
    mov [0x60], cx               # store cursor shape
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
    pop dx
    pop ax
    pop ds
    iret

v_setcur:
    push ds
    push ax
    mov ax, BDA
    mov ds, ax
    mov [0x50], dx               # DH=row, DL=col
    call set_hw_cursor
    pop ax
    pop ds
    iret

v_getcur:
    push ds
    push ax
    mov ax, BDA
    mov ds, ax
    mov dx, [0x50]
    mov cx, [0x60]
    pop ax
    pop ds
    iret

v_getmode:
    push ds
    mov ax, BDA
    mov ds, ax
    mov al, [0x49]
    mov ah, [0x4A]               # columns from BDA (80 text/mode 6, 40 gfx)
    mov bh, 0
    pop ds
    iret

v_readch:                        # returns AL=char, AH=attr at cursor
    push ds
    push es
    push dx
    push di
    mov ax, BDA
    mov ds, ax
    mov dx, [0x50]               # cursor row/col
    call cursor_off              # DI = byte offset
    mov ax, VID
    mov es, ax
    mov ax, es:[di]             # AL=char AH=attr
    pop di
    pop dx
    pop es
    pop ds
    iret

v_writeca:                       # AL=char BL=attr CX=count
    push ax
    push cx
    push dx
    push di
    push ds
    push es
    push si
    mov dx, BDA
    mov ds, dx
    cmp byte ptr [0x49], 4       # graphics mode? -> glyph renderer
    jb .wc_text
    call g_repeat
    jmp .wc_done
.wc_text:
    mov si, ax                   # save char in si low
    mov dx, [0x50]
    call cursor_off              # -> DI = byte offset
    mov dx, VID
    mov es, dx
    mov ax, si                   # char back into AL
    mov ah, bl                   # attribute
.wc_l:
    test cx, cx
    jz .wc_done
    mov es:[di], ax
    add di, 2
    dec cx
    jmp .wc_l
.wc_done:
    pop si
    pop es
    pop ds
    pop di
    pop dx
    pop cx
    pop ax
    iret

v_writec:                        # AL=char CX=count (keep attr)
    push ax
    push cx
    push dx
    push di
    push ds
    push es
    push si
    mov dx, BDA
    mov ds, dx
    cmp byte ptr [0x49], 4       # graphics mode? -> glyph renderer
    jb .wcc_text
    call g_repeat
    jmp .wcc_done
.wcc_text:
    mov si, ax
    mov dx, [0x50]
    call cursor_off
    mov dx, VID
    mov es, dx
    mov ax, si                   # char into AL
.wcc_l:
    test cx, cx
    jz .wcc_done
    mov es:[di], al              # write char only
    add di, 2
    dec cx
    jmp .wcc_l
.wcc_done:
    pop si
    pop es
    pop ds
    pop di
    pop dx
    pop cx
    pop ax
    iret

## ---- teletype output (AL=char) -------------------------------------
v_tty:
    push ax
    push ds
    push es
    push bx
    push cx
    push dx
    push si
    push di
    mov si, ax                   # save char
    mov dx, BDA
    mov ds, dx
    cmp byte ptr [0x49], 4       # CGA graphics mode? -> glyph renderer
    jae g_tty_body
    mov dx, [0x50]               # DH=row DL=col
    mov ax, si
    cmp al, 0x0D
    je .tt_cr
    cmp al, 0x0A
    je .tt_lf
    cmp al, 0x08
    je .tt_bs
    cmp al, 0x07
    je .tt_done                  # bell: ignore
    # printable: write at cursor
    push dx
    call cursor_off              # DI = offset for DH/DL
    mov bx, VID
    mov es, bx
    mov ah, 0x07
    mov es:[di], ax
    pop dx
    inc dl                       # advance column
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
    call scroll_one              # scroll whole screen up 1
    mov dx, [0x50]
.tt_store:
    mov [0x50], dx
    call set_hw_cursor
.tt_done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop es
    pop ds
    pop ax
    iret

## =====================================================================
##  Graphics-mode teletype  (CGA modes 4/5/6)
##
##  INT 10h/0E normally writes char+attribute pairs to B8000, which only
##  means anything in TEXT mode; in a graphics mode that painted 8-pixel
##  garbage per character (e.g. SOPWITH's on-screen text). Here we render
##  an 8x8 glyph into the graphics framebuffer instead.
##
##  Font  : 256 x 8 bytes at font8x8 (squashed from the 8x16 hw font).
##  Colour: foreground = 3 (brightest CGA colour), background = 0.
##  Modes : 4/5 = 320x200 2bpp (40 cols), 6 = 640x200 1bpp (80 cols),
##          both using the even/odd 0x0000 / 0x2000 scanline interleave.
##  Entered from v_tty with DS=BDA and SI's low byte = the character; it
##  shares v_tty's register-restore tail at .tt_done.
## =====================================================================
g_tty_body:
    mov dx, [0x50]               # DH=row DL=col
    mov ax, si
    cmp al, 0x0D
    je .g_cr
    cmp al, 0x0A
    je .g_lf
    cmp al, 0x08
    je .g_bs
    cmp al, 0x07
    je .g_ret                    # bell: ignore
    mov bh, bl                   # BH = colour (BL, as INT 10h AH=0Eh passes it)
    call g_render                # draw glyph AL at (DH,DL); preserves DX
    call g_width                 # AH = columns for this mode
    inc dl
    cmp dl, ah
    jb .g_st
    mov dl, 0
    jmp .g_nl
.g_cr:
    mov dl, 0
    jmp .g_st
.g_lf:
    jmp .g_nl
.g_bs:
    cmp dl, 0
    je .g_st
    dec dl
    jmp .g_st
.g_nl:
    inc dh
    cmp dh, 25
    jb .g_st
    mov dh, 24
    mov [0x50], dx
    call g_scroll
    mov dx, [0x50]
.g_st:
    mov [0x50], dx
.g_ret:
    jmp .tt_done

## ---------------------------------------------------------------------
##  g_repeat -- draw AL, CX times, from the cursor, in a graphics mode.
##
##  AH=09 and AH=0A replicate a character across the screen without moving the
##  cursor. In a text mode that is a run of words stored into the buffer, which
##  is what both handlers did unconditionally -- and in a graphics mode those
##  words ARE pixels, so the result was a rectangle of scattered dots wherever
##  a program drew text. King's Quest puts its scrolling text on screen this
##  way, which is how it surfaced; AH=0E had been diverted to the renderer
##  since the SOPWITH work, but these two never were.
##
##  Entry: DS = BDA, AL = character, CX = count. The cursor is NOT advanced --
##  these calls do not move it, which is the whole reason a program uses them
##  to paint a field rather than the teletype call.
##
##  Entry: DS=BDA, AL=char, CX=count.
## ---------------------------------------------------------------------
g_repeat:
    push ax
    push bx
    push cx
    push dx
    mov bh, bl                   # BH = the COLOUR, which BL is about to lose
    mov bl, al                   # g_render wants the character in AL, and AL
    mov dx, [0x50]               # is needed for the width, so park it in BL
    call g_width                 # AH = columns for this mode
.gr_l:
    test cx, cx
    jz .gr_done
    mov al, bl
    call g_render                # preserves AX and DX
    inc dl
    cmp dl, ah
    jb .gr_next
    mov dl, 0                    # wrap to the next row, as a real BIOS does
    inc dh
    cmp dh, 25
    jae .gr_done                 # off the bottom: stop rather than scroll --
.gr_next:                        # these calls must not disturb the display
    dec cx
    jmp .gr_l
.gr_done:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

## ---------------------------------------------------------------------
##  g_scrollwin -- AH=06 for a graphics mode: scroll or clear a character
##  window by whole 8-pixel rows, moving pixels rather than character cells.
##
##  Entered from v_scrollup with its locals already unpacked and its registers
##  already saved, so it shares that routine's exit at .su_done.
##      [bp-1] top   [bp-2] left  [bp-3] bottom  [bp-4] right
##      [bp-5] rows to scroll, 0 = clear the window
##      [bp-8] width in columns
##
##  Geometry: a character row is 8 display lines; a scanline is 80 bytes in
##  both modes; and a character cell is 2 bytes at 2 bits per pixel (mode 4/5)
##  or 1 byte at 1 bit per pixel (mode 6). Even display lines live at B800:0000
##  and odd ones at B800:2000, so a row spans both banks.
##
##  Blanks are cleared to zero rather than to the attribute in BH: in a
##  graphics mode that register is a colour, and the callers that matter here
##  want the background.
## ---------------------------------------------------------------------
g_scrollwin:
    mov ax, VID
    mov ds, ax
    mov es, ax
    push ds
    mov ax, BDA
    mov ds, ax
    mov al, [0x49]
    pop ds
    mov bl, 2                    # bytes per character cell
    cmp al, 6
    jne .gsw_bpc
    mov bl, 1
.gsw_bpc:
    mov al, [bp-2]               # left column -> byte offset
    mul bl
    mov [bp-7], al               # x0, in bytes
    mov al, [bp-8]               # width in columns -> width in bytes
    mul bl
    mov bh, al                   # BH = bytes to move per scanline
    mov al, [bp-5]
    test al, al
    jz .gsw_clear

.gsw_pass:
    mov al, [bp-1]               # row = top
.gsw_move:
    cmp al, [bp-3]
    jae .gsw_last
    push ax
    mov ah, al
    inc ah                       # source row = destination + 1
    call g_rowmove
    pop ax
    inc al
    jmp .gsw_move
.gsw_last:
    call g_rowclear              # the row vacated at the bottom
    dec byte ptr [bp-5]
    jnz .gsw_pass
    jmp .su_done

.gsw_clear:
    mov al, [bp-1]
.gsw_clrrow:
    cmp al, [bp-3]
    ja .su_done
    call g_rowclear
    inc al
    jmp .gsw_clrrow

## g_rowmove: copy character row AH over character row AL.
##   BH = bytes per scanline to move, [bp-7] = x offset. ES=DS=VID.
g_rowmove:
    push ax
    push cx
    push si
    push di
    push bx
    mov cl, 3
    shl al, cl                   # display line = row * 8
    shl ah, cl
    mov bl, 8                    # eight lines to a character row
.grm_line:
    push ax
    call g_lineoff               # AL -> DI
    mov di, si
    pop ax
    push ax
    mov al, ah
    call g_lineoff               # source line -> SI
    pop ax
    mov cl, bh
    xor ch, ch
    rep movsb
    inc al
    inc ah
    dec bl
    jnz .grm_line
    pop bx
    pop di
    pop si
    pop cx
    pop ax
    ret

## g_rowclear: zero character row AL. BH = bytes per scanline, [bp-7] = x.
g_rowclear:
    push ax
    push cx
    push si
    push di
    push bx
    mov cl, 3
    shl al, cl                   # display line = row * 8
    mov bl, 8
.grc_line:
    call g_lineoff               # SI = offset of line AL; preserves AX
    mov di, si
    mov cl, bh
    xor ch, ch
    push ax                      # AL is the line number AND the fill value,
    xor al, al                   # so it has to be saved across the store
    rep stosb
    pop ax
    inc al
    dec bl
    jnz .grc_line
    pop bx
    pop di
    pop si
    pop cx
    pop ax
    ret

## g_lineoff: SI = the byte offset of display line AL, column [bp-7].
##   Even lines are at 0x0000 and odd ones at 0x2000; both banks are 80 bytes
##   per line. This is the CGA interleave, not a quirk of this BIOS.
g_lineoff:
    push ax
    push dx
    mov dl, al
    and dl, 1                    # bank
    shr al, 1                    # line within the bank
    mov dh, 80
    mul dh                       # AX = line * 80
    test dl, dl
    jz .glo_even
    add ax, 0x2000
.glo_even:
    mov si, ax
    mov al, [bp-7]
    xor ah, ah
    add si, ax
    pop dx
    pop ax
    ret

## g_width: AH = text columns for the current graphics mode (DS=BDA)
g_width:
    mov ah, 40
    cmp byte ptr [0x49], 6
    jne .gw_d
    mov ah, 80
.gw_d:
    ret

## g_render: draw the 8x8 glyph for AL at cursor (DH=row, DL=col).
## DS=BDA on entry; DX (the cursor) is preserved for the caller.
g_render:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    push ds
    mov ch, [0x49]               # CH = video mode (while DS=BDA)
    push bx                      # BH = the colour; the lookup below needs BX,
                                 # so it is popped back by each renderer
    mov bl, al                   # BL = the character
    xor bh, bh

    ## ---------------------------------------------------------------
    ##  WHERE THE GLYPH LIVES. Two different rules, and which one applies
    ##  depends on the mode -- this is not a detail, it is the whole of
    ##  why King's Quest had no text.
    ##
    ##  CGA (modes 4/5/6): a real PC carries only characters 0..127 in the
    ##  BIOS. The upper 128 are a USER table addressed by INT 1Fh, which
    ##  DOS leaves at 0000:0000 unless something like GRAFTABL installs
    ##  one -- so on a stock machine a code above 127 draws NOTHING.
    ##
    ##  EGA (mode 0Dh): there is no such split. INT 43h points at the
    ##  character generator for the current mode and the BIOS indexes it
    ##  by char*8 for ALL 256 codes. INT 1Fh does not come into it.
    ##
    ##  Applying the CGA rule to mode 0Dh is what made King's Quest
    ##  invisible, and the mechanism is worth writing down because nothing
    ##  about it is guessable from the outside. Decrypting and
    ##  disassembling its interpreter (2026-08-07) settled it: AGI draws
    ##  every character with INT 10h AH=09h and never touches A0000
    ##  itself. Its attribute builder returns 0x8F -- bit 7 set -- for any
    ##  text on a NON-ZERO BACKGROUND, i.e. the whole message window and
    ##  the status bar, and it renders that inverse video by INVERTING THE
    ##  GLYPH BITMAP rather than by an attribute. To get that private
    ##  glyph to us it copies the ROM one from a hardcoded F000:FA6E into
    ##  its own 8-byte buffer, modifies it, substitutes CHARACTER CODE
    ##  0x80, and points INT 43h at (buffer - 0x400) so that 0x80*8 lands
    ##  back on the buffer. It restores the vector immediately after.
    ##
    ##  So EVERY character of an in-game text window arrives here as 0x80.
    ##  Sending those to INT 1Fh drew blank8 and lost all of it; before
    ##  that they indexed font8x8+0x400 and came out as a C-cedilla, which
    ##  is where "it pads with 0x80" came from -- those cells were never
    ##  padding, they were the text.
    ##
    ##  The glyph's segment goes on the stack here and is popped into DS
    ##  by whichever renderer runs below. DS (the BDA) is free to clobber:
    ##  the video mode was taken out of it above and the cursor is in DX.
    ## ---------------------------------------------------------------
    cmp ch, 0x0D
    jne .r_cga_font
    xor ax, ax
    mov ds, ax
    mov ax, [0x10C]              # INT 43h vector: offset
    mov di, [0x10E]              #                 segment
    mov si, di
    or  si, ax
    jz  .r_cga_font              # null: no generator named -> use the ROM font
    mov si, bx
    shl si, 1
    shl si, 1
    shl si, 1                    # SI = char*8, all 256 codes
    add si, ax
    push di                      # ...wherever INT 43h points, which POST aimed
    jmp .r_seg                   # at font8x8 and a program may re-aim per call

.r_cga_font:
    cmp bl, 0x80
    jae .r_high
    mov si, bx
    shl si, 1
    shl si, 1
    shl si, 1                    # SI = char*8
    add si, offset font8x8
    push cs                      # ...in ROM
    jmp .r_seg

.r_high:
    xor si, si
    mov ds, si
    mov si, [0x7C]               # INT 1Fh vector: offset
    mov ax, [0x7E]               #                 segment
    mov di, ax
    or  di, si
    jz  .r_none                  # nobody installed one -> draw nothing
    sub bl, 0x80
    shl bx, 1
    shl bx, 1
    shl bx, 1
    add si, bx
    push ax                      # ...in the user's table
    jmp .r_seg
.r_none:
    mov si, offset blank8
    push cs

.r_seg:
    cmp ch, 0x0D
    je .r_ega                    # EGA is planar and lives somewhere else
    xor ax, ax
    mov al, dl                   # col
    cmp ch, 6
    je .r_col
    shl ax, 1                    # modes 4/5: 2 bytes per 8-px cell
.r_col:
    mov di, ax                   # DI = byte offset of column within a line
    xor ax, ax
    mov al, dh                   # row
    shl ax, 1
    shl ax, 1                    # row*4 = first bank-line of this text row
    mov bx, 80
    mul bx                       # AX = row*4*80  (DX high = 0)
    add ax, di
    mov dx, ax                   # DX = running framebuffer offset
    mov ax, VID
    mov es, ax
    pop ds                       # glyph segment, pushed at .r_seg above
    pop bx                       # and the colour. The CGA renderer below still
                                 # hardcodes foreground 3, as it always has --
                                 # this pop is here to balance the stack.
    xor cl, cl                   # CL = glyph row 0..7  (CH = mode preserved)
.r_row:
    mov di, dx
    test cl, 1
    jz .r_b0
    add di, 0x2000               # odd scanline -> bank 1
.r_b0:
    lodsb                        # AL = glyph row byte (DS:SI, DS=CS)
    cmp ch, 6
    je .r_one
    mov ah, al                   # 2bpp: expand 8 px -> 16 bits, fg colour 3
    shr al, 1                    # four single-bit shifts: `shr al,4` is 80186+,
    shr al, 1                    # and CL is already the glyph-row counter here
    shr al, 1
    shr al, 1
    call spread                  # AL = spread16[high nibble]
    mov es:[di], al
    mov al, ah
    and al, 0x0f
    call spread                  # AL = spread16[low nibble]
    mov es:[di+1], al
    jmp .r_adv
.r_one:
    mov es:[di], al              # 1bpp: byte straight through (mode 6)
.r_adv:
    test cl, 1
    jz .r_ni
    add dx, 80                   # next bank-line after every 2 glyph rows
.r_ni:
    inc cl
    cmp cl, 8
    jb .r_row
    jmp .r_done

## ---------------------------------------------------------------------
##  EGA mode 0Dh. Planar, at 0xA0000, and none of the CGA arithmetic above
##  applies: no even/odd bank interleave, 40 bytes to a scanline, and an
##  8-pixel character cell is ONE byte in each of four planes.
##
##  Falling through to the CGA path -- which is what happened before this
##  existed, because 0x0D is neither 6 nor below 4 -- wrote 2bpp pixel pairs
##  into 0xB8000 with a bank interleave. Every character came out as garbage
##  in the shape of a character, in the place a character belonged.
##
##  ONE PASS, because white on black needs no colour arithmetic: with the map
##  mask open to all four planes, the glyph byte goes to every plane at once,
##  so a set bit becomes 1111 (white) and a clear bit 0000 (black). Colours
##  other than 15 would need the cell cleared first and then the glyph written
##  through a map mask of just that colour's planes -- two passes. The CGA path
##  hardcodes its foreground too, for the same reason.
## ---------------------------------------------------------------------
.r_ega:
    xor ax, ax
    mov al, dh                   # row
    mov bl, dl                   # col -- taken BEFORE the MUL below, which
    xor bh, bh                   # returns into DX and would destroy it
    push bx
    mov bx, 320                  # 8 scanlines x 40 bytes = one text row
    mul bx
    pop bx
    add ax, bx
    mov di, ax                   # DI = the cell's byte offset
    mov ax, EGAVID
    mov es, ax
    pop ds                       # glyph segment, pushed at .r_seg above
    pop bx                       # BH = the colour byte INT 10h was given
    cld

    ## THE COLOUR IS BL FROM INT 10h, and bit 7 of it means XOR.
    ##
    ## This used to write the glyph to all four planes and call it white on
    ## black. King's Quest draws its status bar as a white strip and then puts
    ## BLACK text on it -- so white-on-black rendered white text on a white bar
    ## and the score line was simply invisible.
    ##
    ## Black on white is not expressible as "foreground here, background there".
    ## It is done by XOR: flip the set pixels against whatever is already on the
    ## screen, leave the clear ones alone. On a white bar that turns 15 into 0.
    mov al, bh
    and al, 0x0F                 # AL = colour
    test bh, 0x80
    jnz .re_xor

    ## Opaque: clear the cell on every plane, then paint the glyph through a
    ## map mask of just this colour's planes. Two passes, no latches needed.
    push ax
    mov ax, 0x020F               # map mask: every plane
    call seq_out
    mov ax, 0x0100               # enable set/reset off
    call gc_out
    mov ax, 0x0300               # function = replace
    call gc_out
    mov ax, 0x08FF               # bit mask = every bit
    call gc_out
    push di
    mov cx, 8
.re_clr:
    mov byte ptr es:[di], 0
    add di, 40
    loop .re_clr
    pop di
    pop ax                       # colour back
    mov ah, 0x02
    call seq_out                 # map mask = this colour's planes only
    mov cx, 8
.re_row:
    lodsb                        # AL = one glyph row
    mov es:[di], al
    add di, 40
    loop .re_row
    mov ax, 0x020F               # leave the map mask open again
    call seq_out
    jmp .r_done

.re_xor:
    ## The function-select ALU does the flipping: set/reset supplies the colour,
    ## the bit mask supplies the glyph, and each write is preceded by a READ to
    ## load the latches -- masked-out bits come back from them, so without the
    ## read the rest of the cell would be whatever was latched last.
    mov ah, 0x00
    call gc_out                  # GC 0: set/reset = the colour
    mov ax, 0x010F               # GC 1: enable set/reset on all four planes
    call gc_out
    mov ax, 0x0318               # GC 3: function select = XOR
    call gc_out
    mov ax, 0x020F               # map mask: every plane
    call seq_out
    mov cx, 8
.rx_row:
    lodsb                        # AL = one glyph row
    mov ah, 0x08
    call gc_out                  # bit mask = the glyph
    mov al, es:[di]              # read  -> latches
    mov es:[di], al              # write -> set/reset supplies the data
    add di, 40
    loop .rx_row
    mov ax, 0x08FF               # put the graphics controller back
    call gc_out
    mov ax, 0x0100
    call gc_out
    mov ax, 0x0300
    call gc_out

.r_done:
    pop ds
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

## spread: AL = 0..15 -> the matching 2-bpp byte.
##
## This was an XLATB, which reads DS:BX -- and DS now holds the GLYPH's segment,
## which for characters 128..255 is whatever table INT 1Fh points at rather than
## this ROM. Reading the expansion table through CS explicitly keeps DS free for
## the glyph, and costs a call per nibble on a path that is already writing to
## video memory a byte at a time.
spread:
    push bx
    mov bl, al
    xor bh, bh
    add bx, offset spread16
    mov al, cs:[bx]
    pop bx
    ret

## g_scroll: scroll the graphics screen up one 8-pixel text row. Each
## interleave bank moves up 4 lines (= 8 display lines); the gap is cleared.
g_scroll:
    push ax
    push cx
    push si
    push di
    push ds
    push es
    mov ax, VID
    mov ds, ax
    mov es, ax
    cld
    mov si, 320                  # bank 0: lines 4..99 -> 0..95
    xor di, di
    mov cx, 3840                 # 96*80/2 words
    rep movsw
    mov di, 7680                 # clear bank 0 lines 96..99
    xor ax, ax
    mov cx, 160
    rep stosw
    mov si, 0x2320               # bank 1 = 0x2000 + 320
    mov di, 0x2000
    mov cx, 3840
    rep movsw
    mov di, 0x2000 + 7680
    xor ax, ax
    mov cx, 160
    rep stosw
    pop es
    pop ds
    pop di
    pop si
    pop cx
    pop ax
    ret

## spread16[n] doubles each of the low 4 bits of n into a 2-bpp byte, so
## an 8-pixel glyph nibble becomes 4 CGA pixels of colour 3 (set) / 0.
spread16:
    .byte 0x00,0x03,0x0C,0x0F,0x30,0x33,0x3C,0x3F
    .byte 0xC0,0xC3,0xCC,0xCF,0xF0,0xF3,0xFC,0xFF
    .align 2
# Eight zero bytes: the glyph drawn for codes 128..255 when no INT 1Fh table
# is installed, which is what a real machine shows.
blank8:
    .byte 0,0,0,0,0,0,0,0

font8x8:
    .incbin "font8x8.bin"

## ---- scroll window up (AL=lines BH=attr CH,CL=UL DH,DL=LR) ----------
## locals on the stack (SS), so DS/ES can point at video freely:
##   [bp-1]=top [bp-2]=left [bp-3]=bot [bp-4]=right
##   [bp-5]=lines [bp-6]=attr [bp-7]=row [bp-8]=width
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
    cld                          # rep movsw/stosw must run forward
    mov [bp-1], ch               # top
    mov [bp-2], cl               # left
    mov [bp-3], dh               # bottom
    mov [bp-4], dl               # right
    mov [bp-5], al               # line count (0 = clear)
    mov [bp-6], bh               # attribute
    # A graphics mode has no character cells to move. This handler shifts
    # char+attr WORDS around B8000, which in mode 4 is moving pixels two bits
    # at a time in units of four -- it scrambles the picture. King's Quest
    # calls AH=06 nine times per run to manage its text window, which was
    # enough to visibly corrupt the screen.
    push ds
    push ax
    mov ax, BDA
    mov ds, ax
    cmp byte ptr [0x49], 4
    pop ax
    pop ds
    jb .su_text
    jmp g_scrollwin
.su_text:
    mov al, dl
    sub al, cl
    inc al
    mov [bp-8], al               # width (columns)
    mov ax, VID
    mov ds, ax
    mov es, ax
    mov al, [bp-5]
    test al, al
    jz .su_clear
## --- scroll up AL lines, one line per pass ---
.su_pass:
    mov al, [bp-1]
    mov [bp-7], al               # row = top
.su_move:
    mov al, [bp-7]
    cmp al, [bp-3]               # row >= bottom -> stop moving
    jae .su_blanklast
    call row_off                 # DI = (row,left) offset
    mov si, di
    add si, 160                  # source = next row
    mov cl, [bp-8]
    xor ch, ch
    rep movsw
    inc byte ptr [bp-7]
    jmp .su_move
.su_blanklast:
    mov al, [bp-3]               # blank the bottom row
    call row_off
    mov ah, [bp-6]
    mov al, ' '
    mov cl, [bp-8]
    xor ch, ch
    rep stosw
    dec byte ptr [bp-5]
    jnz .su_pass
    jmp .su_done
## --- clear whole window (rows top..bottom) ---
.su_clear:
    mov al, [bp-1]
    mov [bp-7], al               # row = top
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
    inc byte ptr [bp-7]
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

## scroll-down: basic clone treats it as clear-window (AL=0) only
v_scrolldn:
    mov al, 0
    jmp v_scrollup

## row_off: DI = ((row=[bp-7 or al])*80 + left)*2     (uses AL as row)
row_off:
    push ax
    push bx
    mov ah, 80
    mul ah                       # ax = row*80
    mov bl, [bp-2]               # left
    xor bh, bh
    add ax, bx
    shl ax, 1
    mov di, ax
    pop bx
    pop ax
    ret

## ---- helpers (DS must = BDA) ---------------------------------------
# cursor_off: DH=row DL=col -> DI = byte offset in B800
cursor_off:
    push ax
    mov al, dh
    mov ah, 80
    mul ah                       # ax = row*80
    xor dh, dh
    add ax, dx                   # + col
    shl ax, 1                    # *2
    mov di, ax
    pop ax
    ret

# set_hw_cursor: from [0x50]
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
    mov bx, ax                   # linear position
    mov dx, [0x63]               # 0x3D4
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

# scroll_one: scroll the full 80x25 up one line, blank bottom row
scroll_one:
    push ax
    push cx
    push si
    push di
    push ds
    push es
    cld                          # rep movsw/stosw must run forward
    mov ax, VID
    mov ds, ax
    mov es, ax
    mov si, 160                  # second row
    xor di, di
    mov cx, 80*24
    rep movsw
    mov ax, 0x0720               # blank last row
    mov cx, 80
    rep stosw
    pop es
    pop ds
    pop di
    pop si
    pop cx
    pop ax
    ret

## =====================================================================
##  cpu_speed -- the CPU clock, MEASURED, in hundredths of a MHz
##
##  The reference is PIT channel 2. That matters: the PIT is clocked from c2,
##  a PLL output that is NOT derived from c0, so the ruler stays still while
##  the thing being measured changes. Channel 2 is used rather than 0 because
##  it is otherwise idle here and its gate is under our control at port 0x61;
##  the speaker data bit is left LOW so none of this is audible.
##
##  THE LOOP MUST RUN FROM M9K, and now it does so in place. An 8088-class CPU
##  is fetch-bound -- most of what it spends is waiting for instruction bytes --
##  so a loop timed out of PSRAM would measure the memory rather than the clock:
##  PSRAM latency is fixed in NANOSECONDS, so it eats a growing share of each
##  cycle as the clock rises and the reading stops being proportional to
##  anything. This used to be worked around by copying the loop to 0x0500 and
##  far-calling it, back when low RAM was the only M9K. The BIOS itself is M9K
##  now, so the loop simply runs where it sits.
##
##  Interrupts are off across the measurement, so nothing steals cycles from
##  the count. POST has not enabled them yet, but this does not assume that.
##
##  CAL_CPI IS A CALIBRATION CONSTANT, not a derivation. It is the clocks one
##  LOOP iteration costs, which depends on the CPU rather than on anything this
##  code can compute. Set it by running a build whose rate is known exactly --
##  50/10 = 5 MHz is the obvious one -- and scaling until the display agrees.
##  Guessing it from a timing table would make the number look authoritative
##  while being wrong, which is worse than not showing one.
## =====================================================================
.equ CAL_ITER,   4096
.equ CAL_CPI,    17              # clocks per LOOP iteration, MEASURED
.equ CAL_CLOCKS, CAL_ITER * CAL_CPI
.equ CAL_NUM,    CAL_CLOCKS * 119   # 119 ~= 1190500/10000, the c2 rate

cpu_speed:
    push bx
    push cx
    push dx
    push si
    push di
    push es
    push ds
    pushf
    cli

    in al, 0x61                  # gate 2 on, speaker data off = silent
    and al, 0xFD
    or al, 0x01
    out 0x61, al
    mov al, 0xB0                 # ch2, lo/hi, mode 0, binary
    out 0x43, al
    mov al, 0xFF                 # full 16-bit count; it free-runs downward
    out 0x42, al
    out 0x42, al

    call pit2_read
    mov si, ax                   # start count

    mov cx, CAL_ITER
    call cal_code                # in place: this segment is M9K now

    call pit2_read
    mov bx, si
    sub bx, ax                   # counts DOWN, so start - end
    cmp bx, 256                  # too small to divide by, or the PIT is dead
    jb .cs_bad

    mov dx, CAL_NUM >> 16
    mov ax, CAL_NUM & 0xFFFF
    div bx                       # AX = MHz x 100
    jmp short .cs_out
.cs_bad:
    xor ax, ax                   # 0.00 -- visibly wrong rather than plausible
.cs_out:
    popf
    pop ds
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

## pit2_read: AX = the current channel-2 count, via the latch command
pit2_read:
    push bx
    mov al, 0x80                 # latch counter 2
    out 0x43, al
    in al, 0x42
    mov bl, al
    in al, 0x42
    mov bh, al
    mov ax, bx
    pop bx
    ret

## The calibration loop. Two bytes of loop plus a near return.
cal_code:
    .byte 0xE2, 0xFE             # loop $
    ret

## fmt_mhz -- AX = MHz x 100 -> mhz_buf as "N.NN", NUL terminated
fmt_mhz:
    push ax
    push bx
    push cx
    push dx
    push di
    push es
    push cs
    pop es
    mov di, offset mhz_buf
    xor dx, dx
    mov bx, 100
    div bx
    push dx                      # hundredths
    xor dx, dx
    mov bx, 10
    div bx                       # AX = tens, DX = units
    test al, al
    jz .fm_units                 # no leading zero on a one-digit speed
    add al, 0x30
    stosb
.fm_units:
    mov al, dl
    add al, 0x30
    stosb
    mov al, 0x2E                 # '.'
    stosb
    pop ax
    xor dx, dx
    mov bx, 10
    div bx
    add al, 0x30
    stosb
    mov al, dl
    add al, 0x30
    stosb
    xor al, al
    stosb
    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

##  mhz_buf lives in .rtdata now -- POST writes the measured clock string into
##  it, so a byte of it inside the checksummed range made a serial boot and a
##  flash boot disagree by a constant. See the section for the whole story.

## =====================================================================
##  INT 11h / 12h
## =====================================================================
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

## =====================================================================
##  INT 15h - system services
##
##  This used to be one of the vectors left pointing at _dummy_int, and a bare
##  IRET is the worst possible answer to give here. IRET reloads the flags from
##  the stack, so CF comes back exactly as the CALLER left it -- normally clear,
##  which every caller reads as "no error" -- and AX comes back holding the
##  function number that was passed in. The call is not refused, it is never
##  answered, and nothing in the return distinguishes the two.
##
##  MEM reporting tens of megabytes of extended memory came from precisely
##  that: it asks with AH=88h, gets its own 0x88 back as a size in KB, and
##  prints 34816 KB of memory this board does not have. Games do the same thing
##  with other functions and then wait for a result that will never arrive.
##
##  So: answer 88h honestly, and refuse everything else the way a real BIOS
##  does -- CF=1 and AH=86h, the code that means "function not supported".
##  AH=C0h stays refused deliberately: this machine is an XT, and DOS falls back
##  to the model byte at F000:FFFE, which is already correct.
##
##  CF is returned by editing the flags image the INT pushed rather than with
##  STC/RETF 2. RETF 2 would return with the CURRENT interrupt-enable state, and
##  INT cleared IF on the way in -- so a caller that had interrupts on would get
##  them back off. Rewriting the saved word leaves every other flag, and IF in
##  particular, exactly as the caller had it.
## =====================================================================
_int15:
    push bp
    mov bp, sp                   # [bp+2]=IP  [bp+4]=CS  [bp+6]=FLAGS
    cmp ah, 0x88
    je .i15_extmem
    mov ah, 0x86                 # not supported
    or word ptr [bp+6], 0x0001   # CF = 1
    pop bp
    iret
.i15_extmem:
    # There is no memory above 1 MB on this board. AH is cleared too: callers
    # read it as a status byte, and leaving 0x88 there is the same lie in a
    # smaller place.
    xor ax, ax
    and word ptr [bp+6], 0xFFFE  # CF = 0
    pop bp
    iret

## =====================================================================
##  INT 1Ah - time of day (tick counter)
## =====================================================================
_int1a:
    # note: no sti here - the tick count words must be read with
    # interrupts off or INT 08 can update them between the two reads
    cmp ah, 0x00
    je .ta_get
    cmp ah, 0x01
    je .ta_set
    cmp ah, 0x02
    je .ta_rdtime               # read "RTC" time  -> fixed value
    cmp ah, 0x04
    je .ta_rddate               # read "RTC" date  -> fixed value
    cmp ah, 0x03
    je .ta_wrok                 # set time: accept and ignore
    cmp ah, 0x05
    je .ta_wrok                 # set date: accept and ignore
    iret

## ---- Fake real-time clock -------------------------------------------
## The XT has no CMOS RTC, so DOS would fall back to asking for the date
## and time at every boot. Answering INT 1A/02 and /04 with a valid BCD
## value makes DOS take it and move on. DOS only reads the clock once at
## startup and then keeps time from the INT 08 tick, so a constant here is
## enough - the clock still runs forward normally afterwards.
## CF MUST be returned clear ("RTC present"), which means clearing it in
## the FLAGS image on the stack, not just with clc.
##
## Edit RTC_* below to change the power-on date/time.
.equ RTC_HOUR,  0x19            # BCD 19
.equ RTC_MIN,   0x00            # BCD 00
.equ RTC_SEC,   0x00            # BCD 00
.equ RTC_CENT,  0x20            # BCD century 20
.equ RTC_YEAR,  0x26            # BCD year 26   -> 2026
.equ RTC_MONTH, 0x07            # BCD month 07  -> July
.equ RTC_DAY,   0x30            # BCD day 30

.ta_rdtime:
    push bp
    mov bp, sp                  # [bp+0]=BP [bp+2]=IP [bp+4]=CS [bp+6]=FLAGS
    and word ptr [bp+6], 0xFFFE # CF = 0
    pop bp
    mov ch, RTC_HOUR
    mov cl, RTC_MIN
    mov dh, RTC_SEC
    mov dl, 0                   # no daylight-saving
    iret

.ta_rddate:
    push bp
    mov bp, sp
    and word ptr [bp+6], 0xFFFE # CF = 0
    pop bp
    mov ch, RTC_CENT
    mov cl, RTC_YEAR
    mov dh, RTC_MONTH
    mov dl, RTC_DAY
    iret

.ta_wrok:
    push bp
    mov bp, sp
    and word ptr [bp+6], 0xFFFE # CF = 0: pretend the write succeeded
    pop bp
    iret
.ta_get:
    push ds
    mov ax, BDA
    mov ds, ax
    mov al, [0x70]              # overflow flag
    mov cx, [0x6E]             # high word
    mov dx, [0x6C]             # low word
    mov byte ptr [0x70], 0
    pop ds
    iret
.ta_set:
    push ds
    mov ax, BDA
    mov ds, ax
    mov [0x6E], cx
    mov [0x6C], dx
    mov byte ptr [0x70], 0
    pop ds
    iret

## =====================================================================
##  INT 08h - timer tick (IRQ0)
## =====================================================================
_int08:
    push ax
    push dx
    push ds
    mov ax, BDA
    mov ds, ax
    add word ptr [0x6C], 1
    adc word ptr [0x6E], 0
    # midnight wrap at 0x001800B0 ticks (24h)
    mov ax, [0x6E]
    cmp ax, 0x0018
    jb .t8_motor
    mov dx, [0x6C]
    cmp dx, 0x00B0
    jb .t8_motor
    mov word ptr [0x6C], 0
    mov word ptr [0x6E], 0
    mov byte ptr [0x70], 1
.t8_motor:
    # floppy motor-off countdown
    mov al, [0x40]
    test al, al
    jz .t8_user
    dec al
    mov [0x40], al
    jnz .t8_user
    mov dx, 0x03F2             # motors off, keep /reset + DMA
    mov al, 0x0C
    out dx, al
.t8_user:
    int 0x1C                    # user tick hook
    mov al, EOI
    out 0x20, al
    pop ds
    pop dx
    pop ax
    iret

## =====================================================================
##  INT 09h - keyboard (IRQ1)
## =====================================================================
_int09:
    push ax
    push bx
    push ds
    mov ax, BDA
    mov ds, ax
    in al, 0x60                 # scancode
    mov bl, al
    # acknowledge XT keyboard (pulse PB7)
    in al, 0x61
    mov ah, al
    or al, 0x80
    out 0x61, al
    mov al, ah
    out 0x61, al
    # --- E0 prefix ------------------------------------------------------
    # An extended key's second byte REUSES ordinary scancodes -- up arrow is
    # E0 48, and 0x48 on its own is numpad 8 -- so the prefix has to be known
    # before anything below decides what a code means. Dropping it (0xE0 is
    # past the end of the table) is why the arrow keys typed digits.
    mov al, bl
    cmp al, 0xE0
    jne .k_notpfx
    or byte ptr [0x96], 0x02     # flags 3 bit 1: "last code was E0". KEYB and
    jmp .k_eoi                   # other layout drivers read this too.
.k_notpfx:
    test byte ptr [0x96], 0x02
    jz .k_plain
    and byte ptr [0x96], 0xFD    # consume it
    jmp .k_ext
.k_plain:
    # --- handle shift/ctrl/alt make & break ---
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
    test al, 0x80              # ignore all other break codes
    jnz .k_eoi
    # Ctrl+Alt+Del -> reboot
    cmp al, 0x53
    jne .k_translate
    mov ah, [0x17]
    and ah, 0x0C              # ctrl(4)+alt(8)
    cmp ah, 0x0C
    jne .k_translate
    jmp _reboot
.k_translate:
    cmp al, 0x53
    ja .k_eoi                 # beyond table
    mov bh, 0
    mov bl, al
    mov ah, [0x17]
    test ah, 0x03            # shift?
    jnz .k_shifted
    mov al, cs:[bx + scancode_lc - 0]
    jmp .k_have
.k_shifted:
    mov al, cs:[bx + scancode_uc - 0]
.k_have:
    test al, al
    jz .k_eoi                 # no ascii
    mov ah, bl                # scancode in ah
    call kb_put
    jmp .k_eoi
.k_shift_on:
    or byte ptr [0x17], 0x03
    jmp .k_eoi
.k_shift_off:
    and byte ptr [0x17], 0xFC
    jmp .k_eoi
.k_ctrl_on:
    or byte ptr [0x17], 0x04
    jmp .k_eoi
.k_ctrl_off:
    and byte ptr [0x17], 0xFB
    jmp .k_eoi
.k_alt_on:
    or byte ptr [0x17], 0x08
    jmp .k_eoi
.k_alt_off:
    and byte ptr [0x17], 0xF7
.k_eoi:
    mov al, EOI
    out 0x20, al
    pop ds
    pop bx
    pop ax
    iret

## Extended keys, reached only with the E0 prefix consumed. DS = BDA.
.k_ext:
    # A keyboard brackets the navigation keys with FAKE shift codes when Num
    # Lock is on (E0 2A ... E0 AA). Taken for real shift presses they corrupt
    # the shift state on every arrow keypress, so they are discarded here.
    cmp al, 0x2A
    je .k_eoi
    cmp al, 0xAA
    je .k_eoi
    cmp al, 0x36
    je .k_eoi
    cmp al, 0xB6
    je .k_eoi
    # Right ctrl and right alt drive the same 40:17 bits as the left ones, and
    # additionally the right-hand bits of flags 3 -- which is how a layout
    # driver tells AltGr from a plain Alt.
    cmp al, 0x1D
    jne .k_ext_n1d
    or byte ptr [0x17], 0x04
    or byte ptr [0x96], 0x04
    jmp .k_eoi
.k_ext_n1d:
    cmp al, 0x9D
    jne .k_ext_n9d
    and byte ptr [0x17], 0xFB
    and byte ptr [0x96], 0xFB
    jmp .k_eoi
.k_ext_n9d:
    cmp al, 0x38
    jne .k_ext_n38
    or byte ptr [0x17], 0x08
    or byte ptr [0x96], 0x08
    jmp .k_eoi
.k_ext_n38:
    cmp al, 0xB8
    jne .k_ext_nb8
    and byte ptr [0x17], 0xF7
    and byte ptr [0x96], 0xF7
    jmp .k_eoi
.k_ext_nb8:
    test al, 0x80
    jnz .k_eoi                   # any other extended break code
    # Ctrl+Alt+Del from the dedicated Delete key, not just the numpad one
    cmp al, 0x53
    jne .k_ext_key
    mov ah, [0x17]
    and ah, 0x0C
    cmp ah, 0x0C
    jne .k_ext_key
    jmp _reboot
.k_ext_key:
    cmp al, 0x1C                 # numpad Enter is a real Return ...
    jne .k_ext_slash
    mov ah, 0x1C
    mov al, 0x0D
    call kb_put
    jmp .k_eoi
.k_ext_slash:
    cmp al, 0x35                 # ... and the grey slash a real '/'
    jne .k_ext_nav
    mov ah, 0x35
    mov al, '/'
    call kb_put
    jmp .k_eoi
.k_ext_nav:
    # Arrows, Home/End, PgUp/PgDn, Insert, Delete: reported the way every PC
    # BIOS reports an extended key -- ASCII 0, scancode in AH -- so software
    # recognises them as navigation instead of reading the numpad digit that
    # shares the code.
    mov ah, al
    xor al, al
    call kb_put
    jmp .k_eoi

# kb_put: AX = (scancode<<8 | ascii) into ring buffer  (DS=BDA)
kb_put:
    push bx
    push si
    mov bx, [0x1C]            # tail
    mov si, bx
    add si, 2
    cmp si, KBEND
    jb .kp_nowrap
    mov si, KBBUF
.kp_nowrap:
    cmp si, [0x1A]           # head ?  buffer full -> drop
    je .kp_full
    mov [bx], ax             # store key
    mov [0x1C], si          # advance tail
    pop si
    pop bx
    clc                      # CF answers "did it land", for INT 16h AH=05
    ret
.kp_full:
    pop si
    pop bx
    stc
    ret

## =====================================================================
##  INT 16h - keyboard services
## =====================================================================
_int16:
    sti
    cmp ah, 0x00
    je .kb_read
    cmp ah, 0x01
    je .kb_peek
    cmp ah, 0x02
    je .kb_flags
    # ---- enhanced (101/102-key) keyboard functions --------------------
    # DOS 3.x/4.x call AH=00/01/02, but DOS 5 and 6 (and many later games,
    # e.g. SOPWITH) prefer the enhanced calls AH=10/11/12. Falling through
    # to a bare iret left the CALLER's flags on the stack, so AH=11's "is a
    # key ready?" answered with a garbage ZF and the keyboard looked dead
    # on DOS 5/6 while working fine on DOS 3/4.
    #
    # We have a plain XT keyboard, so there are no extra F11/F12 or grey-key
    # codes to report: mapping the enhanced calls onto the classic ones is
    # the usual XT-BIOS approach and is what the callers actually need.
    cmp ah, 0x10
    je .kb_read                 # read enhanced keystroke   -> as AH=00
    cmp ah, 0x11
    je .kb_peek                 # check enhanced keystroke  -> as AH=01
    cmp ah, 0x12
    je .kb_flags_ext            # enhanced shift status: AH is REAL data
    cmp ah, 0x05
    je .kb_push                 # push a keystroke
    iret
.kb_read:
    push ds
    push bx
    mov bx, BDA
    mov ds, bx
.kr_wait:
    cli
    mov bx, [0x1A]           # head
    cmp bx, [0x1C]          # tail
    jne .kr_get
    sti
    hlt
    jmp .kr_wait
.kr_get:
    mov ax, [bx]            # the key
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
    and word ptr [bp+10], 0xFFBF   # clear ZF in caller flags
    pop bp
    pop bx
    pop ds
    iret
.kp_empty:
    or word ptr [bp+10], 0x40      # set ZF
    pop bp
    pop bx
    pop ds
    iret
## AH=05: place a keystroke in the buffer. Layout drivers and command-line
## recall use this to inject translated or replayed keys. Unimplemented, it
## fell through to a bare iret: the key vanished and AL never answered.
##   entry  CH = scancode, CL = ASCII     exit  AL = 0 stored, 1 buffer full
.kb_push:
    push ds
    push bx
    mov bx, BDA
    mov ds, bx
    mov ah, ch
    mov al, cl
    call kb_put
    mov al, 0
    jnc .kbp_out
    mov al, 1
.kbp_out:
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

## AH=12 returns shift state in AL *and* extended modifiers in AH. AH=02
## leaves AH alone because nothing reads it there -- but for AH=12 it is the
## answer, and falling through to the AH=02 code returned the caller's own
## AH = 0x12. That is bit 1 and bit 4: "left Alt held" and "Scroll Lock held".
## Every program using the enhanced call saw Alt permanently down and read
## ordinary typing as menu shortcuts. DOS 3.3 never calls AH=12, which is
## exactly why it was the one boot disk that behaved.
.kb_flags_ext:
    push ds
    mov ax, BDA
    mov ds, ax
    mov al, [0x17]
    pop ds
    mov ah, 0
    test al, 0x04                # this keyboard has no left/right split, so
    jz .kfx_noctrl               # report ctrl and alt as the LEFT ones
    or ah, 0x01
.kfx_noctrl:
    test al, 0x08
    jz .kfx_noalt
    or ah, 0x02
.kfx_noalt:
    iret

## =====================================================================
##  INT 13h - diskette services (uPD765 + 8237 DMA)
## =====================================================================
## HD_ENABLE routes DL >= 0x80 to the SPI fixed disk.
##
## Set to 0 while bisecting a boot failure. Before the fixed disk existed, this
## handler ignored DL completely and every call went to the floppy, so ANY DL
## worked. With the hook in, DL suddenly matters: if the boot sector or IBMBIO
## ever calls INT 13h with the top bit set -- deliberately, or because DL simply
## was not initialised -- the request is now diverted to a blank flash instead of
## the floppy, which is exactly the kind of thing that stops a boot part way.
## Flipping this to 0 removes that possibility without removing the disk code.
.equ HD_ENABLE, 1

##  HD_DRIVE must be defined BEFORE _int13 references it, a few lines below.
##  GNU as treats a symbol used ahead of its .equ as a forward LABEL reference,
##  so "cmp dl, HD_DRIVE" silently assembled as "cmp dl, [0x0001]" -- a compare
##  against memory instead of an immediate. It never matched, so every B: call
##  fell through to the serial floppy and B: showed A:'s contents. The source
##  looked perfectly correct; only the encoding was wrong.
.equ HD_DRIVE,  0x01     # drive B: -- the flash-backed second floppy
##  Geometry lives up here rather than beside the INT 13h code because
##  hd_detect, further down but assembled earlier, needs HD_KB for its POST
##  line -- and a .equ used above its definition assembles as a memory operand.
.equ HD_SPT,    18
.equ HD_HEADS,  2
.equ HD_CYLS,   80       # REPORTED: a standard 1.44 MB floppy, 80x2x18
.equ HD_PHYS_SECTORS, 4096      # the chip really holds 4096 sectors (2 MB)
.equ HD_KB,     (HD_CYLS*HD_HEADS*HD_SPT)/2   # 1440 KB -- what B: holds
## HD_DEBUG: report fixed-disk activity on the port-0x80 7-segment display, so a
## hang shows WHICH INT 13h function DOS asked for. 0xAn = function n entered,
## 0xBn = it returned. If the display stops on 0xAn we hung inside that call; if
## it reaches 0xBn the call completed and the trouble is after it.
.equ HD_DEBUG, 0

##  Drive map:
##    DL = 0x00   A:  floppy served over the serial link by the host loader
##    DL = 0x01   B:  floppy backed by the on-board SPI flash  (hd_int13 below)
##    DL >= 0x80  C:  USB mass storage -- not implemented yet, so it answers
##                    "invalid drive" and DOS skips it, exactly as a machine
##                    with no fixed disk should. BDA 40:75 stays 0 until the
##                    USB stack lands and enumeration actually succeeds.
_int13:
    sti
    test dl, 0x80
    jnz .i13_fixed
.if HD_ENABLE
    cmp dl, HD_DRIVE             # B: -> the flash-backed floppy
    je .i13_flashfd
.endif
    jmp .i13_floppy
.i13_fixed:
    jmp usb_int13
.if HD_ENABLE
.i13_flashfd:
    ## B: is the USB FLOPPY when one was found at POST, and the SPI flash
    ## otherwise. Decided once, at POST, and never re-examined: a program
    ## holding a BPB across a call must not find B: has become a different
    ## device underneath it.
    cmp byte ptr cs:[uf_pres], 0
    je .i13_spi
    jmp uf_int13
.i13_spi:
    jmp hd_int13
.endif
.i13_floppy:
    cmp ah, 0x02                 # read (most common) first
    jne .i13_n02
    jmp d_read
.i13_n02:
    cmp ah, 0x03                 # write
    jne .i13_n03
    jmp d_write
.i13_n03:
    cmp ah, 0x00
    jne .i13_n00
    jmp d_reset
.i13_n00:
    cmp ah, 0x01
    jne .i13_n01
    jmp d_status
.i13_n01:
    cmp ah, 0x04
    jne .i13_n04
    jmp d_verify
.i13_n04:
    cmp ah, 0x08
    jne .i13_n08
    jmp d_params
.i13_n08:
    cmp ah, 0x15
    jne .i13_bad
    jmp d_dtype
.i13_bad:
    # unsupported function
    push ds
    mov ax, BDA
    mov ds, ax
    mov byte ptr [0x41], 0x01
    pop ds
    mov ah, 0x01
    stc
    retf 2

d_reset:
    push ds
    push dx
    mov ax, BDA
    mov ds, ax
    mov byte ptr [0x41], 0
    call fdc_arm               # without this the specify below short-circuits
    mov dx, 0x03F2             # DOR: /reset high, drive 0, no motor, no IRQ
    mov al, 0x04
    out dx, al
    call fdc_specify
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
    mov ah, 0x01               # floppy, no change-line support
    clc
    retf 2

d_params:
    push ds
    mov dx, BDA
    mov ds, dx
    mov ch, [0xB0]             # max cylinder  (captured from BPB at boot)
    mov cl, [0xB1]             # sectors/track + cyl high bits
    mov dh, [0xB2]             # max head
    mov dl, 1                  # number of drives
    mov ax, 0xF000
    mov es, ax
    mov di, offset _floppy_dpt
    pop ds
    xor ah, ah
    clc
    retf 2

## ---- d_read : read sectors via uPD765 + 8237 DMA ------------------
# in: AL=count CH=cyl CL=sector(b0-5)+cylhi(b6-7) DH=head DL=drive ES:BX=buf
# scratch in BDA: 0xA8 count,0xA9 drive,0xAA head,0xAB cyl,0xAC sector, 0xAE buf off, 0xB4 buf seg,
#                 0x95 hd/drv sel, 0x96 off(w), 0x98 seg(w),
#                 0x9A page, 0x9C physlow(w), 0x9E cnt-1(w)
d_read:
    push ds
    push bx                      # caller BX (buffer offset)
    push cx
    push dx
    push si
    push di
    push es                      # caller ES (buffer segment)
    # ---- stash incoming params into BDA scratch ----
    mov si, ax                   # save AX (count)
    mov ax, BDA
    mov ds, ax
    mov ax, si
    mov [0xA8], al               # count
    mov [0xA9], dl               # drive
    mov [0xAA], dh               # head
    mov [0xAB], ch               # cylinder (low 8)
    mov al, cl
    and al, 0x3F
    mov [0xAC], al               # sector
    mov [0xAE], bx               # buffer offset
    mov [0xB4], es               # buffer segment
    mov byte ptr [0x41], 0
    call fdc_arm                 # clears the timeout flag, and recovers the
                                 # controller if the last operation timed out
    # hd/drv select byte = (head<<2)|(drive&1)
    mov al, [0xAA]
    shl al, 1
    shl al, 1
    mov bl, [0xA9]
    and bl, 0x01
    or al, bl
    mov [0xAD], al
    # ---- FDC out of reset (DOR=0x04), then Specify (NON-DMA) ----
    mov dx, 0x03F2
    mov al, 0x04                 # /reset high, drive 0, no motor, no IRQ
    out dx, al
    call fdc_specify
    # ---- issue READ DATA command (no seek, no DMA) ----
    mov al, 0x46                 # MFM read
    call fdc_out
    mov al, [0xAD]
    call fdc_out                 # hd/drv
    mov al, [0xAB]
    call fdc_out                 # cylinder
    mov al, [0xAA]
    call fdc_out                 # head
    mov al, [0xAC]
    call fdc_out                 # sector
    mov al, 0x02
    call fdc_out                 # N = 2 (512 bytes)
    mov al, [0xAC]
    mov bl, [0xA8]
    add al, bl
    dec al
    call fdc_out                 # EOT = sector + count - 1
    mov al, 0x1B
    call fdc_out                 # GPL
    mov al, 0xFF
    call fdc_out                 # DTL
    # ---- NON-DMA execution phase: PIO read count*512 bytes ----
    cld
    mov es, [0xB4]               # ES:DI = destination buffer
    mov di, [0xAE]
    xor ax, ax
    mov al, [0xA8]               # count
    mov cl, 9
    shl ax, cl                   # *512 -> total byte count (count<=127)
    mov cx, ax                   # CX = bytes to read
.rd_pio:
    call fdc_in                  # waits for RQM&DIO, returns byte in AL
    stosb                        # store to ES:DI, DI++
    loop .rd_pio
    # ---- drain result phase ----
    call fdc_results             # watches CB, sets [0x41]=0
    mov ah, [0x41]               # status (DS still = BDA)
    cmp byte ptr [0xB6], 0       # did the link go silent along the way?
    je .rd_stat
    mov ah, 0x80                 # AH=80: drive did not respond, like a real BIOS
    mov [0x41], ah
.rd_stat:
    mov al, [0xA8]               # sectors read = requested
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ds
    test ah, ah
    jnz .dr_err
    clc
    retf 2
.dr_err:
    stc
    retf 2

## ---- d_write : write sectors via uPD765, non-DMA PIO ---------------
# in: AL=count CH=cyl CL=sector(b0-5)+cylhi(b6-7) DH=head DL=drive ES:BX=buf
# same BDA scratch layout as d_read (0x90..0x98)
d_write:
    push ds
    push bx
    push cx
    push dx
    push si
    push di
    push es
    # ---- stash incoming params into BDA scratch ----
    mov si, ax                   # save AX (count)
    mov ax, BDA
    mov ds, ax
    mov ax, si
    mov [0xA8], al               # count
    mov [0xA9], dl               # drive
    mov [0xAA], dh               # head
    mov [0xAB], ch               # cylinder (low 8)
    mov al, cl
    and al, 0x3F
    mov [0xAC], al               # sector
    mov [0xAE], bx               # buffer offset
    mov [0xB4], es               # buffer segment
    mov byte ptr [0x41], 0
    call fdc_arm                 # clears the timeout flag, and recovers the
                                 # controller if the last operation timed out
    # hd/drv select byte = (head<<2)|(drive&1)
    mov al, [0xAA]
    shl al, 1
    shl al, 1
    mov bl, [0xA9]
    and bl, 0x01
    or al, bl
    mov [0xAD], al
    # ---- FDC out of reset (DOR=0x04), then Specify (NON-DMA) ----
    mov dx, 0x03F2
    mov al, 0x04                 # /reset high, drive 0, no motor, no IRQ
    out dx, al
    call fdc_specify
    # ---- issue WRITE DATA command (no seek, no DMA) ----
    mov al, 0x45                 # MFM write
    call fdc_out
    mov al, [0xAD]
    call fdc_out                 # hd/drv
    mov al, [0xAB]
    call fdc_out                 # cylinder
    mov al, [0xAA]
    call fdc_out                 # head
    mov al, [0xAC]
    call fdc_out                 # sector
    mov al, 0x02
    call fdc_out                 # N = 2 (512 bytes)
    mov al, [0xAC]
    mov bl, [0xA8]
    add al, bl
    dec al
    call fdc_out                 # EOT = sector + count - 1
    mov al, 0x1B
    call fdc_out                 # GPL
    mov al, 0xFF
    call fdc_out                 # DTL
    # ---- NON-DMA execution phase: PIO write count*512 bytes ----
    cld
    xor ax, ax
    mov al, [0xA8]               # count
    mov cl, 9
    shl ax, cl                   # *512 -> total byte count (count<=127)
    mov cx, ax                   # CX = bytes to send
    mov si, [0xAE]               # offset
    mov ds, [0xB4]               # DS:SI = source buffer (DS leaves BDA!)
.wr_pio:
    lodsb
    call fdc_out                 # waits RQM=1,DIO=0, writes byte to FDC
    loop .wr_pio
    # ---- drain result phase (fdc_results reloads DS=BDA itself) ----
    call fdc_results             # watches CB, sets [0x41]=0
    mov ax, BDA
    mov ds, ax
    mov ah, [0x41]               # status
    cmp byte ptr [0xB6], 0       # link went silent mid-write?
    je .wr_stat
    mov ah, 0x80                 # AH=80: drive did not respond
    mov [0x41], ah
.wr_stat:
    mov al, [0xA8]               # sectors written = requested
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ds
    test ah, ah
    jnz .dw_err
    clc
    retf 2
.dw_err:
    stc
    retf 2

## ---- FDC low-level helpers -----------------------------------------
# fdc_out: send AL as a command/parameter byte (wait RQM=1,DIO=0)
##  These waits used to spin forever -- "matches working bootloader", which is
##  true and was fine while a loader was guaranteed to answer. Drive A: is a
##  serial link to a host program, though, so if that program is not serving an
##  image the data phase never produces a byte. INT 19h then hangs on its FIRST
##  boot candidate and never reaches B: or C:, which on screen looks exactly
##  like the machine doing nothing after POST.
##
##  Both waits are now bounded at roughly 2.5 s. On expiry they set a STICKY
##  flag at BDA 0xB6 and every later fdc_out/fdc_in returns immediately, so a
##  half-issued command sequence unwinds at once instead of stalling nine more
##  times, and the caller tests the flag once at the end.
fdc_out:
    push ax
    push bx
    push cx
    push dx
    push ds
    mov dx, BDA
    mov ds, dx
    cmp byte ptr [0xB6], 0
    jne .fo_out               # already given up on this operation
    mov ah, al                # stash byte to send in AH
    mov cx, 8                 # ~2.5 s at ~5 us per poll (10 MHz bus)
.fo_outer:
    xor bx, bx
.fo_wait:
    mov dx, 0x03F4            # MSR
    in al, dx
    and al, 0xC0
    cmp al, 0x80             # RQM=1, DIO=0 -> ready to accept a byte
    je .fo_send
    dec bx
    jnz .fo_wait
    loop .fo_outer
    mov byte ptr [0xB6], 1    # nothing is listening
    jmp short .fo_out
.fo_send:
    mov dx, 0x03F5
    mov al, ah
    out dx, al
.fo_out:
    pop ds
    pop dx
    pop cx
    pop bx
    pop ax
    ret

# fdc_in: read one data byte into AL (wait RQM=1,DIO=1, indefinitely)
fdc_in:
    push bx
    push cx
    push dx
    push ds
    mov dx, BDA
    mov ds, dx
    cmp byte ptr [0xB6], 0
    je .fi_go
    xor al, al                # timed out earlier: hand back a zero, fast
    jmp short .fi_out
.fi_go:
    mov cx, 8                 # ~2.5 s at ~5 us per poll (10 MHz bus)
.fi_outer:
    xor bx, bx
.fi_wait:
    mov dx, 0x03F4
    in al, dx
    and al, 0xC0
    cmp al, 0xC0
    je .fi_read
    dec bx
    jnz .fi_wait
    loop .fi_outer
    mov byte ptr [0xB6], 1
    xor al, al
    jmp short .fi_out
.fi_read:
    mov dx, 0x03F5
    in al, dx
.fi_out:
    pop ds
    pop dx
    pop cx
    pop bx
    ret

# fdc_results: drain the result phase by watching CB, like the bootloader.
#   reads whatever result bytes the FDC presents until Command-Busy clears.
##  Bounded, and this is the one that actually mattered. Command-Busy only
##  clears when the command completes, and a read whose data never arrived
##  never completes -- so this spun here for ever while the drive-A: timeout
##  in fdc_in looked like it "did not work". Worse, the sticky flag made
##  fdc_in return instantly, so the PIO loop raced down here and parked.
##
##  The budget is deliberately generous: this is also the normal path for a
##  healthy drive finishing its result phase.
fdc_results:
    push ax
    push bx
    push cx
    push dx
    push ds
    mov ax, BDA
    mov ds, ax
    mov byte ptr [0x41], 0      # assume success; boot AA55 check validates
    cmp byte ptr [0xB6], 0      # already given up? then there is nothing to
    jne .fr_done                # drain, and no reason to wait again
    mov cx, 8                 # ~2.5 s at ~5 us per poll (10 MHz bus)
.fr_outer:
    xor bx, bx
.fr_drain:
    mov dx, 0x03F4              # MSR
    in al, dx
    test al, 0x10              # CB still set? (still in command/result)
    jz .fr_done                # CB clear -> idle, done
    test al, 0x80              # RQM ready?
    jz .fr_tick
    mov dx, 0x03F5
    in al, dx                  # consume a result byte
.fr_tick:
    dec bx
    jnz .fr_drain
    loop .fr_outer
    mov byte ptr [0xB6], 1     # never went idle: the link is gone
.fr_done:
    pop ds
    pop dx
    pop cx
    pop bx
    pop ax
    ret

## fdc_arm -- prepare the controller for a new operation.
##
##  Clears the sticky timeout flag, and if the PREVIOUS operation timed out,
##  resets the controller first. That matters: a wait can expire part-way
##  through a nine-byte command sequence, leaving the FDC core still expecting
##  the rest of it, and the next command's bytes are then swallowed as stale
##  parameters of the abandoned one. Without the reset, a drive that was not
##  ready at boot stays broken for ever -- which is not how a floppy behaves.
##  You put a disk in, and it works.
##
##  The flag has to be cleared BEFORE fdc_specify, or the specify short-
##  circuits on it and the controller is never actually reprogrammed. That is
##  the bug d_reset had: AH=00, the call DOS makes to recover a drive, did
##  nothing at all once a timeout had been recorded.
fdc_arm:
    push ax
    push dx
    push ds
    mov ax, BDA
    mov ds, ax
    cmp byte ptr [0xB6], 0
    je .fa_clear
    mov byte ptr [0xB6], 0
    mov dx, 0x03F2             # DOR: /reset low ...
    xor al, al
    out dx, al
    mov al, 0x04               # ... and back high, drive 0, motor off
    out dx, al
    call fdc_specify
.fa_clear:
    mov byte ptr [0xB6], 0
    pop ds
    pop dx
    pop ax
    ret

# fdc_specify: SRT/HUT/HLT, ND=1 (non-DMA / PIO mode)
fdc_specify:
    mov al, 0x03
    call fdc_out
    mov al, 0xDF
    call fdc_out
    mov al, 0x03               # HLT<<1 | ND=1  -> non-DMA execution
    call fdc_out
    ret

# fdc_recal: recalibrate drive 0 to track 0
fdc_recal:
    mov al, 0x07
    call fdc_out
    xor al, al
    call fdc_out
    call fdc_wait_seek
    ret

# fdc_wait_seek: poll MSR until drive-busy clears, then sense int status
fdc_wait_seek:
    push cx
    push dx
    mov cx, 0x8000
.ws_l:
    mov dx, 0x03F4
    in al, dx
    test al, 0x0F            # any drive busy?
    jz .ws_sense
    loop .ws_l
.ws_sense:
    mov al, 0x08            # sense interrupt status
    call fdc_out            # all three honour the sticky timeout flag, so a
    call fdc_in             # ST0    dead link costs one timeout here, not
    call fdc_in             # PCN    three
    pop dx
    pop cx
    ret

# motor_on: select drive 0, motor on, set motor-off timeout
motor_on:
    push dx
    push ds
    mov ax, BDA
    mov ds, ax
    mov dx, 0x03F2
    mov al, 0x1C            # motor A on, drive 0, DMA en, /reset hi
    out dx, al
    mov byte ptr [0x40], 0x25   # ~2s motor-off countdown
    pop ds
    # crude spin-up delay
    mov cx, 0x2000
.mo_d:
    call io_delay
    loop .mo_d
    pop dx
    ret

io_delay:
    push ax
    in al, 0x80            # ~1us I/O delay on real HW
    pop ax
    ret

## =====================================================================
##  INT 19h - bootstrap loader  (boot floppy A:)
## =====================================================================
##  Boot order: A: (serial floppy) -> C: (USB fixed disk) -> B: (flash floppy).
##  Each is tried in turn and skipped if it will not answer or has no 0xAA55
##  signature, so an empty slot costs one failed read rather than a dead machine.
##  C: is skipped outright while BDA 40:75 says there are no fixed disks.
_int19:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    mov si, offset boot_order
.boot_next:
    push cs
    pop es
    mov al, cs:[si]
    inc si
    cmp al, 0xFF
    je .boot_fail
    mov bl, al                 # bl = drive under test, survives the calls below
    # skip drive A: if POST found nothing serving it -- otherwise every boot
    # with the loader muted pays the FDC timeout again before moving on
    test al, al
    jnz .boot_chkhd
    push ds
    xor cx, cx
    mov ds, cx
    mov cl, [0x04B7]           # BDA 40:B7, set by fd_detect
    pop ds
    test cl, cl
    jz .boot_next
    jmp short .boot_try
.boot_chkhd:
    # skip the fixed disk unless POST advertised one
    test al, 0x80
    jz .boot_try
    push ds
    xor cx, cx
    mov ds, cx
    mov cl, [0x0475]           # BDA 40:75
    pop ds
    test cl, cl
    jz .boot_next
.boot_try:
    xor ax, ax
    mov dl, bl
    int 0x13                   # reset this drive
    mov ax, 0x0201             # AH=02 read, AL=1 sector
    mov cx, 0x0001             # cyl 0, sector 1
    xor dh, dh                 # head 0
    mov dl, bl
    mov bx, 0x7C00
    xor di, di
    mov es, di
    int 0x13
    mov bl, dl                 # INT 13h may have altered DL; keep our drive
    jc .boot_next
    # check signature 0xAA55
    mov ax, [0x7DFE]
    cmp ax, 0xAA55
    jne .boot_next
    # A fixed disk's first sector is a partition table, not a BPB, so only
    # capture geometry when booting a floppy.
    test bl, 0x80
    jnz .geo_done
    # ---- capture BPB geometry for INT 13h AH=08 (DS=0, boot sec @ 7C00) ----
    #   spt   = word [7C18], heads = word [7C1A], total = word [7C13]
    #   maxcyl = total/(spt*heads) - 1
    mov ax, [0x7C18]       # sectors/track
    mov bx, [0x7C1A]       # heads
    mul bx                 # ax = spt*heads (small, dx=0)
    test ax, ax
    jz .geo_done           # bad/zero BPB -> keep POST defaults
    mov bx, ax             # divisor
    mov ax, [0x7C13]       # total sectors
    xor dx, dx
    div bx                 # ax = cylinder count
    dec ax                 # ax = max cylinder
    mov [0x04B0], al       # BDA 40:B0 = CH (max cyl low 8)
    mov dl, ah
    and dl, 0x03           # max cyl high 2 bits
    mov cl, 6
    shl dl, cl             # -> bits 7..6
    mov al, [0x7C18]       # spt (low byte)
    and al, 0x3F
    or al, dl
    mov [0x04B1], al       # BDA 40:B1 = CL (cylhi<<6 | spt)
    mov al, [0x7C1A]       # heads (low byte)
    dec al
    mov [0x04B2], al       # BDA 40:B2 = DH (max head)
.geo_done:
    # read OK -> launch the boot sector with interrupts enabled
    mov dl, bl             # boot drive we actually loaded from
    xor ax, ax
    mov ds, ax
    sti
    .byte 0xEA            # jmp 0000:7C00
    .word 0x7C00
    .word 0x0000
##  The original P2120 ROM does NOT say "Insert disk and press key when ready"
##  -- that is IBM AT wording. The dump at tools/P2120 has no "insert",
##  "strike", "any key" or "when ready" anywhere in it; what it has, at
##  0x25B1 and 0x258D, is "Boot Error." followed by "Press Ctrl-Alt-Del to
##  Reboot ... ", which is what these two strings already are. Nothing to
##  change here -- recorded so the question is not reopened.
.boot_fail:
    mov si, offset msg_bootfail
    call puts19
    mov si, offset msg_reboot
    call puts19
.bf_hang:
    jmp .bf_hang

# puts19: print ASCIZ at CS:SI (DS may be 0)
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

## =====================================================================
##  Diagnostic hex output (direct to video, bypasses INT 10h)
##  dbg_byte: AL = byte -> two hex chars at ES:DI, DI += 4
##
##  DBG_ATTR matches putrow's 0x07 so the fixed-disk line on the POST screen
##  looks like every other line, the way the original Philips BIOS presented it.
##  It was 0x0E (yellow): it stood out, but the real machine did not do that.
##  These helpers are used only by hd_detect.
## =====================================================================
.equ DBG_ATTR, 0x07
dbg_byte:
    push ax
    push bx
    mov bl, al
    shr al, 1
    shr al, 1
    shr al, 1
    shr al, 1
    call dbg_nib
    mov al, bl
    and al, 0x0F
    call dbg_nib
    pop bx
    pop ax
    ret
dbg_nib:
    and al, 0x0F
    cmp al, 10
    jb .dn0
    add al, 'A'-10
    jmp .dn1
.dn0:
    add al, '0'
.dn1:
    mov ah, DBG_ATTR
    mov es:[di], ax
    add di, 2
    ret

## =====================================================================
##  dbg_dec: AX = value -> decimal digits at ES:DI, DI advances
## =====================================================================
dbg_dec:
    push ax
    push bx
    push cx
    push dx
    xor cx, cx
    mov bx, 10
.ddc_div:
    xor dx, dx
    div bx                       # AX = AX/10, DX = remainder
    push dx
    inc cx
    test ax, ax
    jnz .ddc_div
.ddc_out:
    pop ax
    add al, '0'
    mov ah, DBG_ATTR
    mov es:[di], ax
    add di, 2
    loop .ddc_out
    pop dx
    pop cx
    pop bx
    pop ax
    ret

## =====================================================================
##  Fixed disk (SPI flash) -- low-level SPI byte transport
##
##  flash.vhd register map:
##     0x98 W = transmit byte (starts the exchange), R = byte received
##     0x99 R = status, bit 7 = BUSY
##     0x9A W = bit 0 is /CS (0 = assert, 1 = release)
## =====================================================================
.equ SPI_DATA, 0x98
.equ SPI_STAT, 0x99
.equ SPI_CTRL, 0x9A

spi_cs_lo:
    push ax
    xor al, al
    out SPI_CTRL, al
    pop ax
    ret

spi_cs_hi:
    push ax
    mov al, 1
    out SPI_CTRL, al
    pop ax
    ret

## spi_xfer: AL = byte to send -> AL = byte received simultaneously.
## An exchange is 8 SCK periods at 2.5 MHz = 3.2 us, i.e. ~16 CPU clocks, so
## the poll below spins only a handful of times.
## An exchange is 8 SCK periods at 2.5 MHz = 3.2 us, so BUSY should clear within
## a couple of I/O cycles. The count is a safety net only: a BIOS that spins on a
## peripheral forever turns any wiring or logic fault into a dead machine with no
## clue as to where, which is exactly what makes this class of bug expensive.
spi_xfer:
    push cx
    out SPI_DATA, al
    mov cx, 1000
.sx_wait:
    in  al, SPI_STAT
    test al, 0x80
    jz  .sx_ready
    loop .sx_wait
.sx_ready:
    in  al, SPI_DATA
    pop cx
    ret

## =====================================================================
##  hd_detect -- read the JEDEC ID (0x9F) and work out the flash size
##
##  The board carries an ISSI IS25LP016D, which should answer 9D 60 15:
##      0x9D = ISSI, 0x60 = IS25LP family, 0x15 = capacity code
##  The capacity code is a power of two in BYTES, so size = 1 << code, and
##  in KB that is 1 << (code-10). 0x15 -> 2^21 = 2 MB = 2048 KB.
##
##  Whatever comes back is displayed raw next to the decoded size, so a wrong
##  or absent chip is obvious rather than silently mis-decoded. All three bytes
##  reading 0x00 or 0xFF means "no answer" -- MISO stuck low or high.
##
##  Results are kept in the BDA for the INT 13h fixed-disk support to come:
##      0x40:00E0 = manufacturer   0x40:00E1 = type
##      0x40:00E2 = capacity code  0x40:00E4 = size in KB (word)
##  Entered with DS = BDA.
## =====================================================================
hd_detect:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es

    # ---- read the JEDEC ID (DS = BDA on entry) ----
    call spi_cs_hi               # start from a released chip
    call spi_cs_lo
    mov al, 0x9F                 # RDJDID
    call spi_xfer
    mov al, 0xFF
    call spi_xfer
    mov bl, al                   # BL = manufacturer
    mov al, 0xFF
    call spi_xfer
    mov bh, al                   # BH = memory type
    mov al, 0xFF
    call spi_xfer
    mov cl, al                   # CL = capacity code
    call spi_cs_hi

    mov [0xE0], bl
    mov [0xE1], bh
    mov [0xE2], cl
    mov word ptr [0xE6], 0xFFFF  # no block cached yet
    mov byte ptr [0xE8], 0       # and nothing dirty
    mov byte ptr [0x74], 0       # fixed-disk status = OK

    # ---- size in KB = 1 << (capacity-10), sane capacity codes only ----
    xor dx, dx                   # DX = size in KB, 0 = unknown
    cmp cl, 0x10                 # below 64 KB -> not a real code
    jb .hd_sz_done
    cmp cl, 0x1F                 # above 2 GB -> not a real code
    ja .hd_sz_done
    mov al, cl
    sub al, 10
    mov dx, 1
    push cx
    mov cl, al
    shl dx, cl
    pop cx
.hd_sz_done:
    mov [0xE4], dx
    # dx = decoded size, non-zero only if the JEDEC ID read answered. That is
    # what makes B: real, so record it where hd_int13's presence gate reads it.
    push ax
    xor al, al
    test dx, dx
    jz .hd_nopresent
    mov al, 1
.hd_nopresent:
    mov [0xE0], al
    pop ax

    # ---- report on POST row 9 ----
    # NB: the strings live in the ROM segment, so DS must point at CS here --
    # on entry DS is the BDA, which would print garbage.
    mov ax, VID
    mov es, ax
    mov di, 9*160
    push cs
    pop ds
    mov si, offset b_fd2         # the flash is drive B: now, not the hard disk
    call dbg_str
    test dx, dx
    jz .hd_none
    mov si, offset b_hd_ready
    call dbg_str
    call dbg_spc
    call dbg_spc
    mov ax, HD_KB                # the DRIVE's size: B: is a 1.44 MB floppy.
    call dbg_dec                 # The chip is bigger, and says so in brackets.
    mov si, offset b_hd_kb
    call dbg_str
    jmp short .hd_id
.hd_none:
    xor dx, dx                   # no chip -> no size in the brackets either
    mov si, offset b_hd_no       # "NOT READY", also the original wording
    call dbg_str
.hd_id:
    # Raw JEDEC ID last, in brackets. Not something the original printed, but it
    # is the only thing on screen that proves the chip answered and says WHICH
    # chip: a wrong part reads as a different ID, a missing one as FF FF FF.
    # dbg_byte and dbg_dec both preserve BX and CX, so the ID is still intact.
    mov si, offset b_hd_idl
    call dbg_str
    mov al, bl
    call dbg_byte
    call dbg_spc
    mov al, bh
    call dbg_byte
    call dbg_spc
    mov al, cl
    call dbg_byte
    test dx, dx                  # dbg_dec/dbg_byte/dbg_str all preserve DX
    jz .hd_idend
    call dbg_spc
    call dbg_spc
    mov ax, dx                   # the flash chip's own capacity
    call dbg_dec
    mov si, offset b_hd_kb
    call dbg_str
.hd_idend:
    mov si, offset b_hd_idr
    call dbg_str
.hd_out:
    pop es
    pop ds
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

## ---------------------------------------------------------------------
##  fd_detect -- probe drive A: and report it on POST row 8.
##
##  A: is not a drive, it is a serial link to floppy_host.py, so "Ready" has to
##  mean the host is answering AND serving an image. The only honest test is to
##  ask for a sector: reading LBA 0 to the boot-sector address costs nothing,
##  since INT 19h would load it there anyway, and the BPB in it gives the real
##  media size for the line. Silence costs the bounded ~2.5 s once.
##
##  The verdict goes in BDA 0xB7 so INT 19h can skip a drive POST already found
##  silent, rather than paying that wait a second time.
## ---------------------------------------------------------------------
fd_detect:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es

    mov ax, BDA
    mov ds, ax
    mov byte ptr [0xB7], 0

    xor ax, ax
    mov es, ax
    mov bx, 0x7C00
    mov ax, 0x0201               # AH=02 read, AL=1 sector
    mov cx, 0x0001               # cylinder 0, sector 1
    xor dx, dx                   # head 0, drive 0 = A:
    int 0x13
    mov cx, 0                    # CX = media size in KB, 0 = unknown
    jc .fdd_none
    xor ax, ax                   # the read worked: take the size from the BPB
    mov ds, ax
    mov ax, [0x7C13]             # BPB total sectors
    shr ax, 1                    # 512-byte sectors -> KB
    mov cx, ax
    mov ax, BDA
    mov ds, ax
    mov byte ptr [0xB7], 1
.fdd_none:
    mov ax, VID
    mov es, ax
    mov di, 8*160
    mov bl, [0xB7]
    push cs
    pop ds
    mov si, offset b_fd1
    call dbg_str
    test bl, bl
    jz .fdd_no
    mov si, offset b_hd_ready
    call dbg_str
    jcxz .fdd_out                # answered, but the BPB made no sense
    call dbg_spc
    call dbg_spc
    mov ax, cx
    call dbg_dec
    mov si, offset b_hd_kb
    call dbg_str
    jmp short .fdd_out
.fdd_no:
    mov si, offset b_hd_no
    call dbg_str
.fdd_out:
    pop es
    pop ds
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

## dbg_spc: one space at ES:DI (attr 0x0E), DI += 2
dbg_spc:
    push ax
    mov ax, 0x0E20
    mov es:[di], ax
    add di, 2
    pop ax
    ret

## =====================================================================
##  FIXED DISK (INT 13h, DL >= 0x80) backed by the SPI flash -- READ + WRITE
##
##  Built in stages. Reads need no buffer at all: a sector is just 512 bytes at
##  flash address LBA*512, streamed straight into the caller's buffer. Writes
##  need a 4 KB read-modify-write buffer, because the flash erases 4 KB at a
##  time; see HDBUF_SEG below.
##
##  That buffer first went into reserved conventional RAM at 0x9E000, which cost
##  8 KB and dropped the reported memory from 640 KB to 632 KB. It now lives in
##  on-chip M9K at 0xE0000 where DOS cannot see it, and the full 640 KB is
##  reported again.
##
##  Geometry: 31 cyl x 4 heads x 32 spt = 3968 sectors = 1,986,560 bytes.
##  NOT the full 4096 sectors: the top 64 KB of the flash (0x1F0000..0x1FFFFF)
##  holds the BIOS image the boot ROM falls back to when no serial host answers,
##  and 31 cylinders stops exactly at 0x1F0000 so DOS can never overwrite it.
## =====================================================================

##  1.44 MB is the largest format every DOS from 3.3 onward knows, and 80x2x18
##  = 2880 sectors = 1440 KB fits inside the 1984 KB of flash the disk region
##  has, leaving the BIOS copy at 0x1F0000 untouched. 2.88 MB would fit the CHS
##  but not the flash, and DOS 3.3 does not know it anyway.

## ---- SPI helpers on top of spi_xfer --------------------------------
## hd_send_lba: BX = LBA -> the 3 flash address bytes for LBA*512
hd_send_lba:
    push ax
    push cx
    mov ax, bx
    mov cl, 7
    shr ax, cl               # LBA >> 7
    call spi_xfer            # addr[23:16]
    mov ax, bx
    and al, 0x7F
    shl al, 1                # (LBA & 0x7F) << 1
    call spi_xfer            # addr[15:8]
    xor al, al
    call spi_xfer            # addr[7:0]  (sectors are 512-byte aligned)
    pop cx
    pop ax
    ret

## ---- hd_read_one: BX = LBA, ES:DI = destination (512 bytes) ----
hd_read_one:
    push ax
    push cx
    push di
    call spi_cs_lo
    mov al, 0x03             # READ
    call spi_xfer
    call hd_send_lba
    mov cx, 512
    cld
.hr_byte:
    mov al, 0xFF
    call spi_xfer
    stosb
    loop .hr_byte
    call spi_cs_hi
    pop di
    pop cx
    pop ax
    ret

## =====================================================================
##  Write support: one 4 KB block held in RAM, written back lazily
##
##  The flash erases 4 KB at a time, so changing a 512-byte sector means
##  erase + reprogram of the whole block. The block is buffered so that a
##  read-modify-write keeps the other 7 sectors, and so that a multi-sector
##  write inside ONE INT 13h call costs a single erase.
##
##  The buffer is flushed before any write call returns, NOT lazily across calls:
##  INT 13h AH=03 is expected to have committed when it returns, and anything
##  still dirty is lost on reboot.
##
##  The buffer lives in on-chip M9K at 0xE0000, NOT in conventional memory, so
##  it costs no DOS memory and the BIOS reports the full 640 KB. It used to sit
##  at 0x9E000, which forced the reported size down to 632 KB.
##
##  0xE0000 is load-bearing on the FPGA side: m9k_mem.vhd maps exactly
##  0xE0000..0xE0FFF, and busdecode's MEMADDR covers ADDR >= 0xE0000 so the
##  access waits on RAM_READY like any other memory cycle. Moving this segment
##  means changing m9k_mem.vhd to match -- and anywhere in 0xA0000..0xDFFFF the
##  READY handshake is bypassed, so do not put it there.
## =====================================================================
.equ HDBUF_SEG, 0xE000       # 4 KB block buffer at linear 0xE0000 (M9K, not DOS RAM)

spi_wren:                    # write enable, required before erase or program
    call spi_cs_lo
    mov al, 0x06
    call spi_xfer
    call spi_cs_hi
    ret

## spi_wait_wip: spin until the status register's WIP bit clears.
## A 4 KB erase takes ~100 ms and a page program ~1 ms; each poll here is about
## 15 us, so 0xFFFF iterations is roughly a second -- ample, while still
## guaranteeing we return if the chip never answers. An unbounded wait would turn
## a wiring fault, or a MISO that floats high, into a dead machine.
spi_wait_wip:
    push ax
    push cx
    mov cx, 0xFFFF
.ww_l:
    call spi_cs_lo
    mov al, 0x05             # RDSR
    call spi_xfer
    mov al, 0xFF
    call spi_xfer
    call spi_cs_hi
    test al, 0x01            # WIP
    jz  .ww_done
    loop .ww_l
.ww_done:
    pop cx
    pop ax
    ret

## hd_send_addr: BX = block, SI = byte offset in block -> 3 flash address bytes
## (flash address = block*4096 + offset; used for erase, program and block load)
hd_send_addr:
    push ax
    push cx
    push dx
    mov dx, bx
    mov ax, dx
    mov cl, 4
    shr ax, cl               # block >> 4
    call spi_xfer            # addr[23:16]
    mov ax, dx
    and al, 0x0F
    mov cl, 4
    shl al, cl               # (block & 0x0F) << 4
    mov dl, al
    mov ax, si
    mov cl, 8
    shr ax, cl               # offset >> 8
    or  al, dl
    call spi_xfer            # addr[15:8]
    mov ax, si
    call spi_xfer            # addr[7:0]
    pop dx
    pop cx
    pop ax
    ret

## ---- hd_flush: write the cached block back if dirty (DS = BDA) ----
hd_flush:
    push ax
    push bx
    push cx
    push si
    push ds
    cmp byte ptr [0xE8], 0
    je .hf_done
    mov bx, [0xE6]
    cmp bx, 0xFFFF
    je .hf_clean

    call spi_wren            # erase the 4 KB block
    call spi_cs_lo
    mov al, 0x20
    call spi_xfer
    xor si, si
    call hd_send_addr
    call spi_cs_hi
    call spi_wait_wip

    xor si, si               # then program it back, 16 pages of 256 bytes
.hf_page:
    call spi_wren
    call spi_cs_lo
    mov al, 0x02
    call spi_xfer
    call hd_send_addr
    push ds
    mov ax, HDBUF_SEG
    mov ds, ax
    mov cx, 256
.hf_byte:
    mov al, [si]
    call spi_xfer
    inc si
    loop .hf_byte
    pop ds
    call spi_cs_hi
    call spi_wait_wip
    cmp si, 4096
    jb .hf_page
.hf_clean:
    mov byte ptr [0xE8], 0
.hf_done:
    pop ds
    pop si
    pop cx
    pop bx
    pop ax
    ret

## ---- hd_load_block: make block AX resident (DS = BDA) ----
hd_load_block:
    push ax
    push bx
    push cx
    push si
    push di
    push es
    cmp ax, [0xE6]
    je .hl_done
    call hd_flush            # evict the previous block first
    mov [0xE6], ax
    mov bx, ax
    # 512 bytes per READ command, not one 4 KB burst.
    #
    # A long continuous read does not come back intact on this board: the boot
    # ROM streamed 64 KB in a single command and a sixth of it was wrong, while
    # the same bytes read in 512-byte commands were perfect (tools/spidump.com
    # proved both). 4 KB is eight times the length known to be safe and has
    # never been checked, and a bad block read here is worse than a bad boot --
    # it feeds read-modify-write, so it would write the corruption back.
    mov ax, HDBUF_SEG
    mov es, ax
    xor di, di
    xor si, si                   # SI = byte offset within the block
    cld
.hl_chunk:
    call spi_cs_lo
    mov al, 0x03
    call spi_xfer
    call hd_send_addr            # BX = block, SI = offset within it
    mov cx, 512
.hl_byte:
    mov al, 0xFF
    call spi_xfer
    stosb
    loop .hl_byte
    call spi_cs_hi
    add si, 512
    cmp si, 4096
    jb .hl_chunk
.hl_done:
    pop es
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

## ---- hd_chs2lba: CH/CL/DH -> AX = LBA  (DS = BDA; CX,DX preserved) ----
hd_chs2lba:
    push bx
    push cx
    push dx
    mov al, cl
    and al, 0x3F
    mov [0xEA], al           # sector, 1-based
    mov [0xEB], dh           # head
    mov al, cl               # cylinder high bits live in CL(7:6)
    and al, 0xC0
    mov ah, 0
    mov cl, 6
    shr ax, cl
    mov ah, al
    mov al, ch               # AX = cylinder
    mov bx, HD_HEADS
    mul bx                   # cyl * heads   (DX:AX, high word unused here)
    mov bl, [0xEB]
    mov bh, 0
    add ax, bx               # + head
    mov bx, HD_SPT
    mul bx                   # * sectors-per-track
    mov bl, [0xEA]
    mov bh, 0
    dec bx
    add ax, bx               # + (sector-1)
    pop dx
    pop cx
    pop bx
    ret

## =====================================================================
##  hd_int13 -- INT 13h for DL >= 0x80
## =====================================================================
hd_int13:
.if HD_DEBUG
    push ax
    mov al, ah               # show the FULL function code, not just its low
    out 0x80, al             # nibble: "A8" only told us (AH & 0x0F) == 8, which
    pop ax                   # 0x18/0x88/... also satisfy, and those fall through
.endif                       # to the unsupported path and write no marker at all
    # If POST did not advertise a fixed disk, behave exactly like a machine that
    # has none: EVERY function reports "invalid drive". This is what was breaking
    # the boot -- AH=08 answered CF=0 (success) while also reporting DL=0 drives,
    # which is self-contradictory, and DOS took the success at face value and went
    # on to act on a device that is not really there. A real machine with no hard
    # disk fails the call, and DOS then simply skips the drive.
    # B: is soldered to the board, so unlike a fixed disk it is either present
    # or the chip is dead. POST sets BDA 0xE0 from the JEDEC ID read; if that
    # failed there is no point pretending the drive exists.
    push ds
    push ax
    mov ax, BDA
    mov ds, ax
    cmp byte ptr [0xE0], 0
    pop ax                       # pop does not disturb the flags from cmp
    pop ds
    jne .hd_present
.if HD_DEBUG
    push ax
    mov al, 0xC1                 # C1 = refused (disk not advertised)
    out 0x80, al
    pop ax
.endif
    mov ah, 0x01                 # invalid drive / bad command
    stc
    retf 2
.hd_present:
.if HD_DEBUG
    push ax                  # D1 = presence gate passed
    mov al, 0xD1
    out 0x80, al
    pop ax
.endif
    cmp ah, 0x02
    je .h_read
    cmp ah, 0x03
    je .h_write
    cmp ah, 0x08
    je .h_params
    cmp ah, 0x15
    je .h_dtype
    cmp ah, 0x00             # reset -> flush, so DOS's reset is our commit point
    je .h_flushok
    cmp ah, 0x0C             # seek
    je .h_ok
    cmp ah, 0x0D             # alternate reset
    je .h_flushok
    cmp ah, 0x10             # test drive ready
    je .h_ok
    cmp ah, 0x11             # recalibrate
    je .h_ok
    cmp ah, 0x09             # initialise drive-pair characteristics
    je .h_ok
    cmp ah, 0x14             # controller internal diagnostic
    je .h_ok
    cmp ah, 0x04             # verify -- data is checked by reading it
    je .h_ok
    cmp ah, 0x01             # last status
    je .h_status
    # ---- the FORMAT group. Without these, FORMAT B: reports
    # ---- "Invalid media or Track 0 bad - disk unusable".
    cmp ah, 0x05             # format track
    je .h_fmtok
    cmp ah, 0x16             # detect disk change
    je .h_nochange
    cmp ah, 0x17             # set disk type for format
    je .h_ok
    cmp ah, 0x18             # set media type for format
    je .h_setmedia
    # unsupported
    push ds
    mov ax, BDA
    mov ds, ax
    mov byte ptr [0x74], 0x01
    pop ds
.if HD_DEBUG
    push ax                  # C9 = function not supported. Previously this path
    mov al, 0xC9             # returned silently, so a caller retrying it forever
    out 0x80, al             # looked identical to a hang inside the handler.
    pop ax
.endif
    mov ah, 0x01
    stc
    retf 2                   # replace the caller's flags (CF set)

##  AH=05 -- format track.
##  There are no physical tracks on a flash chip, so there is nothing to lay
##  down. Report success and let FORMAT get on with writing the boot sector,
##  FATs and root directory through ordinary AH=03 writes. Actually erasing the
##  whole 1.44 MB here would cost ~360 block erases and wear the part for no
##  benefit -- the FAT marks the data area free either way.
.h_fmtok:
    jmp .h_ok

##  AH=16 -- detect disk change.
##  The medium is soldered to the board, so it never changes. Answering
##  "changed", or failing outright, makes DOS re-read the BPB constantly and is
##  one of the ways FORMAT decides a disk is unusable.
.h_nochange:
    push ds
    mov ax, BDA
    mov ds, ax
    mov byte ptr [0x74], 0
    pop ds
    xor ah, ah               # 00 = no change since the last call
    clc
    retf 2

##  AH=18 -- set media type for format.
##  DOS asks "can you format this geometry?" and expects the drive parameter
##  table back in ES:DI. Refusing is reported as "Invalid media". The geometry
##  is fixed by the flash layout, so accept and hand back the 1.44 MB table
##  regardless of what was requested.
.h_setmedia:
    push cs
    pop es
    mov di, offset _floppy_dpt
    push ds
    mov ax, BDA
    mov ds, ax
    mov byte ptr [0x74], 0
    pop ds
    xor ah, ah
    clc
    retf 2

.h_ok:
    push ds
    mov ax, BDA
    mov ds, ax
    mov byte ptr [0x74], 0
    pop ds
    xor ah, ah
    clc
    retf 2

.h_flushok:
    push ds
    push ax
    mov ax, BDA
    mov ds, ax
    call hd_flush            # DOS's disk reset is our commit point
    mov byte ptr [0x74], 0
    pop ax
    pop ds
    xor ah, ah
    clc
    retf 2

.h_status:
    push ds
    mov ax, BDA
    mov ds, ax
    mov ah, [0x74]
    pop ds
    clc
    retf 2

.h_dtype:
    mov ah, 0x01                 # 01 = floppy without change-line support
    clc
    retf 2
.h_dtype_old:                    # AH=03 -> fixed disk, CX:DX = total sectors
    mov ah, 0x03
    mov cx, 0
    mov dx, HD_CYLS * HD_HEADS * HD_SPT
    clc
    retf 2

.h_params:
    # Floppy AH=08 differs from the fixed-disk form: DL is the number of FLOPPY
    # drives, BL is the drive type, and ES:DI points at the parameter table.
    push ds
    mov ax, BDA
    mov ds, ax
    mov dl, 2                    # two floppies: A: and B:
    pop ds
    mov bl, 0x04                 # type 4 = 1.44 MB, 3.5"
    mov ch, HD_CYLS-1            # 79
    mov cl, HD_SPT               # 18, high cylinder bits are 0 for 80 cyl
    mov dh, HD_HEADS-1           # 1
    push cs
    pop es
    mov di, offset _floppy_dpt
    xor ah, ah
    clc
    retf 2
.h_params_old:                   # AH=08 -> geometry
.if HD_DEBUG
    push ax                  # D8 = dispatch landed in .h_params
    mov al, 0xD8
    out 0x80, al
    pop ax
.endif
    push ds
    mov ax, BDA
    mov ds, ax
    mov dl, [0x75]           # drive count from the BDA, so a caller that probes
    pop ds                   # AH=08 agrees with what POST advertised
    mov ch, HD_CYLS - 1      # max cylinder (low 8 bits)
    mov cl, HD_SPT           # sectors/track, cylinder high bits are 0
    mov dh, HD_HEADS - 1     # max head
    xor ah, ah
    clc
.if HD_DEBUG
    push ax                  # B8 = AH=08 returned normally. If the display shows
    mov al, 0xB8             # B8 and the machine is still stuck, the fault is in
    out 0x80, al             # the CALLER, not in this handler.
    pop ax
.endif
    retf 2

.h_read:
.h_write:
    jmp short hd_transfer        # AH (02 vs 03) already says which

## ---- the shared sector loop -----------------------------------------
## AL = sector count, ES:BX = caller buffer, CH/CL/DH = CHS of the first sector
## Everything below works in LBA space: the CHS triple is converted once and
## then simply incremented, which avoids re-deriving CHS for each sector.
## BDA scratch: EC=dir ED=caller seg EF=caller off F1=LBA F3=count F5=offset
hd_transfer:
    push ds
    push es
    push si
    push di
    push cx
    push dx
    push bx
    push ax

    mov di, ax               # DI = AH:function, AL:sector count
    mov ax, BDA
    mov ds, ax
    mov [0xED], es           # caller buffer segment
    mov [0xEF], bx           # caller buffer offset
    mov byte ptr [0x74], 0
    mov ax, di               # recover AH = function, AL = count
    mov [0xF3], al           # sectors remaining
    xor al, al               # direction straight from the function code:
    cmp ah, 0x03             #   AH=03 is write, anything else here is read
    jne .ht_dirset
    mov al, 1
.ht_dirset:
    mov [0xEC], al
    call hd_chs2lba          # start LBA from CH/CL/DH
    mov [0xF1], ax

.ht_loop:
    cmp byte ptr [0xF3], 0
    je .ht_done
    mov ax, [0xF1]
    # Bounds-check against the PHYSICAL chip (4096 sectors), not the reported
    # geometry. AH=08 advertises 31 cylinders so DOS keeps out of the last one,
    # which holds the BIOS copy the boot ROM falls back to -- but a deliberate
    # tool can still address cylinder 31 to write that copy, reusing this proven
    # erase/program path instead of duplicating it.
    cmp ax, HD_PHYS_SECTORS
    jae .ht_err              # past the end of the chip

    mov bx, ax               # BX = LBA of this sector
    mov cl, 3
    mov si, ax
    shr si, cl               # SI = block = LBA >> 3
    and ax, 7
    mov cl, 9
    shl ax, cl               # AX = byte offset of the sector inside the block
    mov [0xF5], ax

    cmp byte ptr [0xEC], 0
    jne .ht_wr

    # ---- read ----------------------------------------------------------
    # If this block is cached AND dirty, the flash copy is stale, so the data
    # must come from the buffer. Otherwise read straight from flash, which
    # avoids pulling in 4 KB just to hand back 512 bytes.
    cmp byte ptr [0xE8], 0
    je .ht_rd_flash
    cmp si, [0xE6]
    jne .ht_rd_flash
    mov si, [0xF5]           # buffer -> caller
    mov es, [0xED]
    mov di, [0xEF]
    mov ax, HDBUF_SEG
    push ds
    mov ds, ax
    mov cx, 512
    cld
    rep movsb
    pop ds
    jmp short .ht_next
.ht_rd_flash:
    mov es, [0xED]
    mov di, [0xEF]
    call hd_read_one         # BX is still the LBA
    jmp short .ht_next

    # ---- write: into the buffer, block becomes dirty --------------------
.ht_wr:
    mov ax, si
    call hd_load_block       # read-modify-write: keep the other 7 sectors
    mov di, [0xF5]
    mov si, [0xEF]
    mov ax, [0xED]
    push ds
    mov ds, ax               # DS = caller segment
    mov ax, HDBUF_SEG
    mov es, ax
    mov cx, 512
    cld
    rep movsb
    pop ds                   # DS = BDA again
    mov byte ptr [0xE8], 1

.ht_next:
    add word ptr [0xEF], 512
    inc word ptr [0xF1]
    dec byte ptr [0xF3]
    jmp .ht_loop

.ht_done:
.if HD_DEBUG
    push ax
    mov al, 0xB2
    out 0x80, al
    pop ax
.endif
    # Commit before returning if this was a write.
    #
    # INT 13h AH=03 is expected to have COMMITTED by the time it returns -- real
    # hardware writes immediately, so deferring across calls is invisible to DOS
    # right up until the power goes. FDISK showed this perfectly: it wrote the
    # partition table, never issued AH=00, and the block was still dirty in RAM
    # at reboot, so the partition vanished.
    #
    # The 4 KB buffer still earns its keep: it is what makes read-modify-write
    # correct (the other 7 sectors of the block must be preserved), and a
    # multi-sector write in ONE call is still a single erase. Only batching
    # across separate calls is given up, which is the right trade -- a disk that
    # loses data on reboot is worthless however fast it is.
    cmp byte ptr [0xEC], 0
    je .ht_nocommit
    call hd_flush
.ht_nocommit:
    pop ax
    pop bx
    pop dx
    pop cx
    pop di
    pop si
    pop es
    pop ds
    xor ah, ah
    clc
    retf 2

.ht_err:
    mov byte ptr [0x74], 0x04    # sector not found
    pop ax
    pop bx
    pop dx
    pop cx
    pop di
    pop si
    pop es
    pop ds
    mov ah, 0x04
    stc
    retf 2


## dbg_str: DS:SI = ASCIZ -> written at ES:DI (attr 0x0E), DI advances
dbg_str:
    push ax
    push si
.dst_l:
    lodsb
    test al, al
    jz .dst_d
    mov ah, DBG_ATTR
    mov es:[di], ax
    add di, 2
    jmp .dst_l
.dst_d:
    pop si
    pop ax
    ret

## =====================================================================
##  Reboot
## =====================================================================
_reboot:
    cli
    .byte 0xEA            # jmp F000:FFF0 (reset entry)
    .word 0xFFF0
    .word 0xF000

## =====================================================================
##  Data tables and strings
## =====================================================================
crtc_80x25:
    .byte 0x71,0x50,0x5A,0x0A,0x1F,0x06,0x19,0x1C
    .byte 0x02,0x07,0x06,0x07,0x00,0x00,0x00,0x00

# The sixteen default EGA palette registers, for mode 0Dh.
#
# Entry 6 is 0x14 and not 0x06. That one exception is what makes colour 6 BROWN
# rather than dark yellow -- the same special case the CGA palette carries, and
# the reason wood, earth and skin look right in every game of this period.
ega_pal_def:
    .byte 0x00,0x01,0x02,0x03,0x04,0x05,0x14,0x07
    .byte 0x38,0x39,0x3A,0x3B,0x3C,0x3D,0x3E,0x3F

# Floppy disk parameter table (pointed to by INT 1E)
_floppy_dpt:
    .byte 0xDF,0x02,0x25,0x02,18,0x1B,0xFF,0x54,0xF6,0x0F,0x08

# ---- US scancode set-1 -> ASCII (lower / upper), index = scancode -----
# entries 0x00 .. 0x53
scancode_lc:
    .byte 0x00,0x1B,'1','2','3','4','5','6'        # 00-07
    .byte '7','8','9','0','-','=',0x08,0x09        # 08-0F
    .byte 'q','w','e','r','t','y','u','i'          # 10-17
    .byte 'o','p','[',']',0x0D,0x00,'a','s'        # 18-1F
    .byte 'd','f','g','h','j','k','l',';'          # 20-27
    .byte 0x27,'`',0x00,0x5C,'z','x','c','v'       # 28-2F
    .byte 'b','n','m',',','.','/',0x00,'*'         # 30-37
    .byte 0x00,' ',0x00,0x00,0x00,0x00,0x00,0x00   # 38-3F
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,'7'   # 40-47
    .byte '8','9','-','4','5','6','+','1'          # 48-4F
    .byte '2','3','0','.'                          # 50-53
scancode_uc:
    .byte 0x00,0x1B,'!','@','#','$','%','^'        # 00-07
    .byte '&','*','(',')','_','+',0x08,0x09        # 08-0F
    .byte 'Q','W','E','R','T','Y','U','I'          # 10-17
    .byte 'O','P','{','}',0x0D,0x00,'A','S'        # 18-1F
    .byte 'D','F','G','H','J','K','L',':'          # 20-27
    .byte '"','~',0x00,'|','Z','X','C','V'         # 28-2F
    .byte 'B','N','M','<','>','?',0x00,'*'         # 30-37
    .byte 0x00,' ',0x00,0x00,0x00,0x00,0x00,0x00   # 38-3F
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,'7'   # 40-47
    .byte '8','9','-','4','5','6','+','1'          # 48-4F
    .byte '2','3','0','.'                          # 50-53

# ---- boot screen strings (Philips P3105 visual style) ---------------
# ---- banner shown directly to video during POST (no CRLF) ----------
## =====================================================================
##  USB MASS STORAGE -- drive C: (INT 13h, DL = 0x80)
##
##  Sits on top of the usb_host controller at I/O 0xE8..0xEF, which does the
##  bit-level work (NRZI, stuffing, CRC, SOF, timeouts). Everything here is
##  protocol: enumeration, Bulk-Only Transport, and enough SCSI to be a disk.
##
##  LAYERS, bottom up
##    u_txn        one transaction, with NAK retry and a bounded wait
##    u_ctl_*      control transfers (SETUP / data / status)
##    u_benq       bulk IN and OUT, 64 bytes at a time, with data toggles
##    u_bot        Bulk-Only Transport: CBW -> data -> CSW
##    u_scsi_*     the handful of SCSI commands a BIOS disk needs
##    usb_int13    the INT 13h face DOS sees
##
##  DIAGNOSABILITY: BDA 0xC0 records how far enumeration got. If C: does not
##  appear, that byte says which step failed rather than leaving a silent
##  absence. USBHD.COM prints it. Every stage number is listed at u_enum.
##
##  BDA MAP (0xC0..0xDF, otherwise unused)
##    C0 b  stage reached       C1 b  present (1 = usable)
##    C2 b  device address      C3 b  bulk IN endpoint
##    C4 b  bulk OUT endpoint   C5 b  toggle IN     C6 b  toggle OUT
##    C7 b  ep0 max packet      C8 d  last LBA (32-bit)
##    CC w  cylinders           CE b  heads         CF b  sectors/track
##    D0 d  CBW tag             D4 b  bConfigurationValue
## =====================================================================

##  U_BUFSZ must be defined BEFORE u_findep compares against it. Declared down
##  with the buffers, it was a forward reference, and GNU as turns those into
##  memory operands: "cmp bx, U_BUFSZ" assembled as "cmp bx, [0x0040]", i.e. a
##  compare against the BDA's floppy motor counter. Same trap as HD_DRIVE.
.equ UF_BUFSZ, 64            # USB floppy descriptor buffer
.equ U_BUFSZ,  64            # size of u_buf, and the descriptor request length

.equ U_CMD,    0xE8
.equ U_ADDR,   0xE9
.equ U_ENDP,   0xEA          # W endpoint / R last received PID
.equ U_LEN,    0xEB
.equ U_DATA,   0xEC
.equ U_PTR,    0xED
.equ U_CTRL,   0xEE
.equ U_FRAME,  0xEF

.equ UOP_SETUP, 1
.equ UOP_IN,    2
.equ UOP_OUT,   3
.equ UGO,       0x80
.equ UD1,       0x08         # send DATA1 instead of DATA0

.equ UST_BUSY,  0x01
.equ UST_ACK,   0x02
.equ UST_NAK,   0x04
.equ UST_STALL, 0x08
.equ UST_TMO,   0x10
.equ UST_ERR,   0x20
.equ UST_RXD1,  0x40
.equ UST_RXV,   0x80

.equ UC_RESET,  0x02
.equ UC_SOFEN,  0x04
.equ UL_FS,     0x04
.equ UL_LOCK,   0x20

## ---------------------------------------------------------------------
##  u_txn -- run one transaction and wait for it to finish.
##    AL = command byte (op | UGO | toggle)
##    returns AL = status, CF set if the engine never went idle
##  Retries on NAK, which is a device saying "not yet", not an error. The
##  budget is deliberately large: a stick can NAK for milliseconds while its
##  controller thinks, and giving up early looks exactly like a dead device.
## ---------------------------------------------------------------------
##  The command is kept in BL, NOT in DL. DX is the port register for every
##  IN/OUT below, so "mov dx, U_CMD" overwrites DL a few instructions after it
##  would have been saved there. The first attempt still works, because AL is
##  loaded before the clobber -- only the RETRY path reissues garbage (0xE8,
##  which is op 0 with GO set: a NOP transaction that sends a token and waits
##  for a reply that never comes).
##
##  That made enumeration fail at the device descriptor while USBTEST.COM,
##  whose retry loop reissues the command literally, sailed through the same
##  transfer. Devices legitimately NAK the data stage of GET_DESCRIPTOR while
##  they prepare it, so the retry path is not an edge case -- it is the norm.
##  Three kinds of "no" need three different responses:
##    NAK      the device is busy -- reissue immediately, many times
##    ERR/TMO  a packet was corrupted or lost -- USB expects the HOST to retry,
##             and with no series resistors on D+/D- that is not rare here
##    STALL    a real refusal -- report it, retrying would be wrong
##  Only retrying NAK meant a single corrupted packet aborted the whole transfer
##  and left the device out of step, which is the instability seen on hardware.
u_txn:
    push bx
    push cx
    push dx
    push si
    mov bl, al                   # command, in a register DX cannot touch
    mov bh, 3                    # attempts left after a corrupted packet
    mov si, 32                   # outer NAK budget -- see .ut_attempt
.ut_attempt:
    # NAK budget: 16 rounds of 4096. These are ITERATIONS, not time, so the
    # budget scales with the bus clock -- it was doubled to 32 while c0 was
    # 10 MHz and is back to 16 now that c0 is 5. An earlier version gave up
    # after ONE
    # round (~70 ms) on the theory that the command-level retry above would
    # cover anything slower. The write soak disproved it: a flash stick
    # programming a sector NAKs the next packet for hundreds of milliseconds,
    # the phase NAK counts came out in exact multiples of 4096, and every
    # "failed" write was a merely-busy device being abandoned mid-command --
    # after which the device padded the sector from its stale internal buffer
    # and reported success. NAK is flow control, not failure: keep asking,
    # and only seconds of continuous NAK means the endpoint is truly wedged.
    mov cx, 4096
.ut_try:
    push cx
    mov al, bl
    mov dx, U_CMD
    out dx, al
    # Bound the wait for BUSY to clear. This used to be 65536 iterations at
    # ~7 us -- 0.46 s -- and 64 sectors took 30 s, which is 64 x 0.46 s almost
    # exactly. One stalled transaction per sector was costing half a second
    # each. No transaction can legitimately take more than about a millisecond,
    # so 4096 (~30 ms) is still enormously generous, and BDA 0xDB counts how
    # often it happens so the stall can be measured rather than guessed at.
    mov cx, 4096
.ut_wait:
    mov dx, U_CMD
    in al, dx
    test al, UST_BUSY
    jz .ut_done
    loop .ut_wait
    pop cx
    push ds                      # count it: BUSY never cleared
    push bx
    push ax
    mov bx, BDA
    mov ds, bx
    inc byte ptr [0xDB]
    # Latch the controller's state at the FIRST stall only. By the time POST
    # prints anything the machine has moved on, so a live read tells us nothing.
    cmp byte ptr [0xD5], 0       # D2/D3/D5 are free; D4 and DC are not
    jne .ut_nosnap
    mov byte ptr [0xD5], 1
    mov dx, 0xEF
    mov al, 0x0C                 # tx state | sequencer state
    out dx, al
    in al, dx
    mov [0xD2], al
    mov al, 0x0D                 # LOCKED, go_pend, tx_req, BUSY, sof, rst, rx
    out dx, al
    in al, dx
    mov [0xD3], al
.ut_nosnap:
    pop ax
    pop bx
    pop ds
    stc                          # engine wedged -- a different fault entirely
    jmp short .ut_out
.ut_done:
    pop cx
    test al, UST_NAK
    jz .ut_chkerr
    loop .ut_try
    dec si                       # one round of 4096 NAKs spent; the device
    jz .ut_nakout                # is busy, not broken -- re-arm and keep on
    jmp .ut_attempt
.ut_nakout:
    jmp .ut_ok                   # ~16 rounds of nothing but NAK: report it
.ut_chkerr:
    test al, UST_ERR | UST_TMO
    jz .ut_ok
    dec bh
    jz .ut_ok                    # out of attempts; report what we got
    jmp short .ut_attempt
.ut_ok:
    clc
.ut_out:
    pop si
    pop dx
    pop cx
    pop bx
    ret

## ---------------------------------------------------------------------
##  u_setptr -- buffer pointer to 0
## ---------------------------------------------------------------------
u_setptr:
    push ax
    push dx
    xor al, al
    mov dx, U_PTR
    out dx, al
    pop dx
    pop ax
    ret

## ---------------------------------------------------------------------
##  u_ctl -- a complete control transfer.
##    DS:SI = 8-byte setup packet
##    ES:DI = data buffer (may be unused)
##    CX    = data length wanted (0 = no data stage)
##    direction comes from bit 7 of the setup packet's first byte
##  Returns CF set on failure, CX = bytes actually transferred.
##
##  The status stage matters even though it moves no data: skipping it leaves
##  the device's control endpoint mid-transfer, and the NEXT request stalls.
## ---------------------------------------------------------------------
u_ctl:
    push bx
    push dx
    push si
    push di
    push bp
    # Control transfers go to endpoint 0, and the endpoint register still holds
    # whatever bulk endpoint the last transfer used. Harmless during enumeration,
    # where it was 0 throughout, but any control request issued after bulk
    # traffic -- such as the recovery below -- would go to the wrong endpoint.
    push ax
    push dx
    xor al, al
    mov dx, U_ENDP
    out dx, al
    pop dx
    pop ax
    mov bp, cx                   # bp = requested length
    # The status stage direction depends on bmRequestType, which is the first
    # byte of the packet. SI has advanced by the time we need it, so stash it
    # now. CS is PSRAM here (the BIOS lives in RAM), so it is writable scratch.
    mov al, [si]
    mov byte ptr cs:[u_reqtype], al
    # ---- how big is this device's control endpoint? ----
    # The data stage ends on a packet SHORTER THAN THE ENDPOINT'S max packet
    # size. That size is bMaxPacketSize0, published in BDA 0xC7 at stage 3, and
    # it is 8 on plenty of devices -- every Logitech Unifying receiver, for one.
    # Copied per call rather than kept here, so 0xC7 stays the single authority.
    #
    # DS is the CALLER'S segment at this point (the setup packet lives in the
    # code segment, so callers set DS=CS), which is why the BDA needs an
    # explicit segment load rather than a bare [0xC7].
    push ax
    push ds
    mov ax, BDA
    mov ds, ax
    mov al, [0xC7]
    pop ds
    # Clamp. 8 is the size every device must support and the value to assume
    # before the device has told us anything; above 64 cannot be right because
    # the packet buffer is 64 bytes, and a garbage value there would end every
    # data stage on the first packet.
    cmp al, 8
    jae .uc_szhi
    mov al, 8
.uc_szhi:
    cmp al, U_BUFSZ
    jbe .uc_szok
    mov al, U_BUFSZ
.uc_szok:
    mov byte ptr cs:[u_ep0sz], al
    pop ax
    # ---- SETUP stage, always DATA0 ----
    call u_setptr
    mov cx, 8
    mov dx, U_DATA
.uc_fill:
    lodsb
    out dx, al
    loop .uc_fill
    mov al, 8
    mov dx, U_LEN
    out dx, al
    mov al, UOP_SETUP | UGO
    call u_txn
    jc .uc_bad
    test al, UST_ACK
    jz .uc_bad
    # ---- data stage ----
    xor bx, bx                   # bx = bytes moved so far
    test bp, bp
    jz .uc_status
.uc_data:
    call u_setptr
    mov al, UOP_IN | UGO
    call u_txn
    jc .uc_bad
    test al, UST_RXV
    jz .uc_bad
    push ax
    mov dx, U_LEN
    in al, dx
    xor ah, ah
    mov cx, ax                   # cx = bytes in this packet
    pop ax
    jcxz .uc_status              # zero-length packet ends the stage
    push cx
    call u_setptr
    mov dx, U_DATA
.uc_copy:
    in al, dx
    stosb
    inc bx
    loop .uc_copy
    pop cx
    # A SHORT PACKET ENDS THE STAGE -- shorter than THIS ENDPOINT'S max packet
    # size, not shorter than 64. This used to read "cmp cx, 64", which is right
    # for every mass-storage stick (they all use a 64-byte EP0) and wrong for
    # anything smaller: with an 8-byte EP0 the FIRST FULL packet already looks
    # short, so the stage ends after 8 bytes and returns CF clear. An 18-byte
    # device descriptor then arrives as 8 valid bytes and 10 bytes of stale
    # buffer, reported as success -- and since byte 0 is bLength, the header of
    # every descriptor reads correctly and only the tail is wrong.
    mov al, byte ptr cs:[u_ep0sz]
    xor ah, ah
    cmp cx, ax
    jb .uc_status
    cmp bx, bp
    jb .uc_data
.uc_status:
    # status stage: OUT zero-length DATA1 for a control READ,
    #               IN  zero-length DATA1 for a control WRITE
    push bx
    call u_setptr
    xor al, al
    mov dx, U_LEN
    out dx, al                   # zero-length
    mov al, byte ptr cs:[u_reqtype]
    test al, 0x80
    jz .uc_st_in
    mov al, UOP_OUT | UGO | UD1
    jmp short .uc_st_go
.uc_st_in:
    mov al, UOP_IN | UGO | UD1
.uc_st_go:
    call u_txn
    pop bx
    jc .uc_bad
    mov cx, bx
    clc
    jmp short .uc_out
.uc_bad:
    xor cx, cx
    stc
.uc_out:
    pop bp
    pop di
    pop si
    pop dx
    pop bx
    ret

## ---------------------------------------------------------------------
##  u_bulk_out -- send CX bytes from DS:SI on the bulk OUT endpoint.
##  u_bulk_in  -- receive CX bytes into ES:DI on the bulk IN endpoint.
##  Both keep the endpoint's data toggle in the BDA and flip it per packet;
##  getting that wrong makes the device silently drop everything after the
##  first packet.
## ---------------------------------------------------------------------
u_bulk_out:
    push ax
    push bx
    push cx
    push dx
    push si
.ubo_pkt:
    jcxz .ubo_done
    mov bx, cx
    cmp bx, 64
    jbe .ubo_sz
    mov bx, 64
.ubo_sz:
    push cx
    call u_setptr
    mov cx, bx
    mov dx, U_DATA
.ubo_fill:
    lodsb
    out dx, al
    loop .ubo_fill
    mov al, bl
    mov dx, U_LEN
    out dx, al
    push ds
    mov ax, BDA
    mov ds, ax
    mov al, [0xC4]               # bulk OUT endpoint
    mov dx, U_ENDP
    out dx, al
    mov al, UOP_OUT | UGO
    cmp byte ptr [0xC6], 0       # toggle
    je .ubo_t0
    or al, UD1
.ubo_t0:
    pop ds
    call u_txn
    pop cx
    jc .ubo_bad
    test al, UST_ACK
    jz .ubo_bad
    # Advance the stored toggle only now, on the device's ACK. It used to be
    # flipped BEFORE the transaction, so any abandoned transfer left the host
    # one toggle ahead of the device -- and the next data phase had its first
    # packet ACKed-and-discarded as a duplicate. Sixty-four bytes silently
    # gone, every status success. (The ACK-lost case still works: the device
    # ACKs the retransmission as a duplicate, and we advance exactly once.)
    push ds
    push ax
    mov ax, BDA
    mov ds, ax
    xor byte ptr [0xC6], 1
    pop ax
    pop ds
    sub cx, bx
    jmp short .ubo_pkt
.ubo_done:
    clc
    jmp short .ubo_out
.ubo_bad:
    push ds                      # publish WHY: 10 timeout, 08 stall,
    push bx                      # 04 NAK exhausted, 20 CRC/PID error
    mov bx, BDA
    mov ds, bx
    mov [0xDF], al
    pop bx
    pop ds
    stc
.ubo_out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

u_bulk_in:
    push ax
    push bx
    push cx
    push dx
    push di
    push si
    xor si, si                   # duplicate-packet counter
.ubi_pkt:
    jcxz .ubi_done
    push cx
    call u_setptr
    push ds
    mov ax, BDA
    mov ds, ax
    mov al, [0xC3]               # bulk IN endpoint
    mov dx, U_ENDP
    out dx, al
    pop ds
    mov al, UOP_IN | UGO
    call u_txn
    pop cx
    jc .ubi_bad
    test al, UST_RXV
    jz .ubi_bad
    # ---- data toggle ----
    # A packet arriving with the toggle we are NOT expecting is a retransmission
    # of one we already took: our ACK was lost, so the device sent it again.
    # Counting it as new data shifts the whole stream by 64 bytes, and the first
    # thing that notices is the CSW signature. Discard it and read again.
    mov bh, 0
    test al, UST_RXD1
    jz .ubi_t0
    mov bh, 1
.ubi_t0:
    push ds
    push ax
    mov ax, BDA
    mov ds, ax
    mov al, [0xC5]
    cmp al, bh
    pop ax                       # POP does not disturb the flags
    pop ds
    je .ubi_togok
    inc si                       # bounded: a device that only ever repeats
    cmp si, 8                    # itself must not wedge us
    ja .ubi_bad
    jmp short .ubi_pkt
.ubi_togok:
    push ds
    push ax
    mov ax, BDA
    mov ds, ax
    xor byte ptr [0xC5], 1
    pop ax
    pop ds
    push cx
    mov dx, U_LEN
    in al, dx
    xor ah, ah
    mov bx, ax                   # bx = bytes this packet
    call u_setptr
    mov cx, bx
    jcxz .ubi_short
    mov dx, U_DATA
    cld
    # REP INSB: the whole packet in one instruction.
    #
    # This replaced "in al,dx / stosb / loop", which costs about 36 clocks per
    # byte before instruction fetch -- and the fetch is not free, because the
    # BIOS executes from PSRAM. Measured, the CPU was spending roughly 900 us
    # moving a 64-byte packet that takes 45 us on the wire, so the bus sat idle
    # about 95 % of the time and every transfer size converged on ~65 KB/s.
    #
    # INS is an 80186 instruction and the V20 implements it, which is exactly
    # the distinction docs/gotchas.md draws: .arch i8086 is a portability guard
    # that keeps ACCIDENTAL 186 encodings out, not a statement that the CPU
    # lacks them. Reaching for one deliberately is fine; the guard is switched
    # off for one instruction and straight back on, so nothing else in the file
    # loses the protection.
    #
    # It works here only because U_DATA auto-increments the controller's buffer
    # pointer on every read -- u_setptr rewinds it above -- so repeated reads of
    # one port walk the packet, which is precisely what INS expects.
    # But INS is an 80186 instruction. The V20 in the socket implements it; a
    # real Intel 8088-1, which this board is equally happy to hold, does not --
    # opcode 6C is undefined there and executing it is not survivable. So the
    # fast path is OFF at reset and something has to ask for it: 186BOOST.COM
    # tests the CPU and sets the flag. A machine with an 8088 in it never
    # reaches the instruction.
    #
    # Testing a flag costs ~20 clocks against ~640 for the copy, so guarding
    # every packet is worth the 3 % and avoids self-modifying code.
    cmp byte ptr cs:[u_fast], 0
    je .ubi_copy
    .arch i186
    rep insb                     # ES:DI <- port DX, CX times
    .arch i8086
    jmp short .ubi_short
.ubi_copy:
    in al, dx
    stosb
    loop .ubi_copy
.ubi_short:
    pop cx
    sub cx, bx
    jbe .ubi_done
    cmp bx, 64                   # short packet means the device is done
    jb .ubi_done
    jmp short .ubi_pkt
.ubi_done:
    clc
    jmp short .ubi_out
.ubi_bad:
    push ds
    push bx
    mov bx, BDA
    mov ds, bx
    mov [0xDF], al
    pop bx
    pop ds
    stc
.ubi_out:
    pop si
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

## ---------------------------------------------------------------------
##  u_chs2lba -- CHS to LBA.
##    CH = cylinder low 8, CL = sector | cylinder high 2, DH = head
##    returns DX:AX = LBA
##
##  LBA = (cyl * heads + head) * spt + sector - 1
##
##  MUL clobbers DX, and DH is the head, so the head and sector are copied to
##  BDA scratch before any multiply runs -- the same reason hd_chs2lba does it.
##  Both products need care about width: cyl <= 1023 and heads <= 16 gives at
##  most 16368, so the first MUL leaves DX = 0 and the second can safely use the
##  full 32-bit result.
## ---------------------------------------------------------------------
u_chs2lba:
    push bx
    push cx
    push ds
    push ax
    mov ax, BDA
    mov ds, ax
    pop ax

    mov al, cl
    and al, 0x3F
    mov [0xD6], al               # sector, 1-based
    mov [0xD7], dh               # head

    # cylinder = CH | ((CL & 0xC0) << 2)
    mov bl, ch
    mov bh, cl
    and bh, 0xC0
    push cx
    mov cl, 6
    shr bh, cl                   # 8086: shift by CL, never by an immediate
    pop cx
    mov ax, bx                   # ax = cylinder (0..1023)

    xor bh, bh
    mov bl, [0xCE]               # heads
    mul bx                       # dx:ax = cyl * heads  (<= 16368, so dx = 0)
    xor bh, bh
    mov bl, [0xD7]
    add ax, bx                   # + head  (<= 16383, still fits ax)

    xor bh, bh
    mov bl, [0xCF]               # sectors per track
    mul bx                       # dx:ax = (cyl*heads + head) * spt

    xor bh, bh
    mov bl, [0xD6]
    dec bx                       # sector - 1
    add ax, bx
    adc dx, 0

    pop ds
    pop cx
    pop bx
    ret

## ---------------------------------------------------------------------
##  u_rw10 -- READ(10) / WRITE(10).
##    DX:AX = LBA        BL = sector count (1..127)      ES:DI = buffer
##    direction from BDA 0xD8: 0 = read, 1 = write
##  SCSI operands are BIG-endian; the byte order below is deliberate.
## ---------------------------------------------------------------------
u_rw10:
    push ax
    push bx
    push cx
    push dx
    push si
    push bp
    push ds

    # Pick the opcode from the direction flag, read fresh out of the BDA.
    #
    # An earlier version carried the direction in AH and then popped the LBA
    # back into AX, which destroyed it -- so "test ah, ah" tested the LBA's HIGH
    # BYTE instead. For any LBA below 256 that byte is zero, so every write was
    # issued as READ(10) while the CBW correctly said "OUT, 512 bytes". The
    # device sees a read command with a write data phase, calls it a phase error
    # and rejects it: writes failed at sector 0, every time, forever.
    #
    # MOV does not touch the flags, so the JZ below still tests the direction.
    push ax
    push dx
    mov ax, BDA
    mov ds, ax
    mov al, [0xD8]
    test al, al
    mov al, 0x28                 # READ(10)
    jz .urw_op
    mov al, 0x2A                 # WRITE(10)
.urw_op:
    mov byte ptr cs:[u_cdb_rw+0], al
    pop dx
    pop ax

    mov byte ptr cs:[u_cdb_rw+1], 0
    mov byte ptr cs:[u_cdb_rw+2], dh    # LBA, big-endian
    mov byte ptr cs:[u_cdb_rw+3], dl
    mov byte ptr cs:[u_cdb_rw+4], ah
    mov byte ptr cs:[u_cdb_rw+5], al
    mov byte ptr cs:[u_cdb_rw+6], 0
    mov byte ptr cs:[u_cdb_rw+7], 0
    mov byte ptr cs:[u_cdb_rw+8], bl    # transfer length, big-endian
    mov byte ptr cs:[u_cdb_rw+9], 0

    # data length = count * 512
    xor ax, ax
    mov al, bl
    mov cl, 9
    shl ax, cl
    mov bp, ax

    # direction flag for the CBW
    mov ax, BDA
    mov ds, ax
    mov ch, 0x80                 # IN
    cmp byte ptr [0xD8], 0
    je .urw_dir
    mov ch, 0x00                 # OUT
.urw_dir:
    mov cl, 10
    push cs
    pop ds
    mov si, offset u_cdb_rw
    call u_bot

    pop ds
    pop bp
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

## ---------------------------------------------------------------------
##  u_mark -- record where a transport command failed, in BDA 0xDD, whatever
##  DS happens to be. Same idea as the enumeration stage byte: a failure that
##  says WHERE beats one that only says "no".
##    1 CBW out failed         2 data phase failed
##    3 CSW in failed          4 CSW signature wrong
##    5 CSW reported a non-zero status (the status itself goes to 0xDE)
## ---------------------------------------------------------------------
u_mark:
    push ds
    push bx
    mov bx, BDA
    mov ds, bx
    mov [0xDD], al
    pop bx
    pop ds
    ret

## ---------------------------------------------------------------------
##  u_bot -- one Bulk-Only Transport command: CBW, data, CSW.
##    DS:SI = command block (16 bytes are always copied, so every CDB table
##            below is padded to 16)
##    CL    = CB length      CH = 0x80 for data IN, 0x00 for OUT/none
##    ES:DI = data buffer    BP = data length
##  Returns CF set on failure.
##
##  All three phases must complete. If the data phase fails, the CSW is still
##  collected -- leaving it on the wire desynchronises the device and every
##  later command fails in a way that looks like a dead disk.
## ---------------------------------------------------------------------
u_bot:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push bp
    push ds
    push es

    push ax
    xor al, al
    call u_mark                  # clear any previous failure point
    pop ax

    push es                      # the caller's data buffer, needed twice below
    push di

    # ---- build the 31-byte CBW at CS:u_cbw ----
    push cs
    pop es
    mov di, offset u_cbw
    cld
    mov ax, 0x5355               # 'U','S'
    stosw
    mov ax, 0x4342               # 'B','C'
    stosw
    push ds                      # dCBWTag -- any value, echoed in the CSW
    push ax
    mov ax, BDA
    mov ds, ax
    inc word ptr [0xD0]
    mov ax, [0xD0]
    mov bx, ax
    pop ax
    pop ds
    mov ax, bx
    stosw
    xor ax, ax
    stosw
    mov ax, bp                   # dCBWDataTransferLength
    stosw
    xor ax, ax
    stosw
    mov al, ch                   # bmCBWFlags
    stosb
    xor al, al                   # bCBWLUN
    stosb
    mov al, cl                   # bCBWCBLength
    stosb
    push cx                      # the command block itself
    mov cx, 16
    rep movsb
    pop cx

    # ---- CBW out ----
    push ds
    push si
    push cx
    push cs
    pop ds
    mov si, offset u_cbw
    mov cx, 31
    call u_bulk_out
    pop cx
    pop si
    pop ds
    jnc .ub_cbw_ok
    push ax
    mov al, 1
    call u_mark
    pop ax
    jmp .ub_fail_pop
.ub_cbw_ok:

    # ---- data phase ----
    pop di                       # restore the caller's buffer
    pop es
    push es
    push di
    test bp, bp
    jz .ub_csw
    test ch, 0x80
    jz .ub_dout
    push cx
    mov cx, bp
    call u_bulk_in
    pop cx
    jnc .ub_din_ok
    push ax
    mov al, 2                    # noted, but we still collect the CSW
    call u_mark
    pop ax
.ub_din_ok:
    jmp short .ub_csw
.ub_dout:
    push cx
    push ds
    push si
    mov ax, es
    mov ds, ax
    mov si, di
    mov cx, bp
    call u_bulk_out
    pop si
    pop ds
    pop cx
    # A failed data phase still falls through to collect the CSW -- abandoning
    # a command mid-flight is what put the device out of step before -- but
    # the failure is RECORDED, and the command fails once the CSW is in hand.
    # It used to be dropped entirely: the device padded the sector from its
    # stale internal buffer, answered PASS, and a write that lost 64 bytes
    # reported success all the way up to DOS. tmo+03 with wf 0 in the soak
    # was precisely this hole.
    jnc .ub_dout_ok
    push ax
    mov al, 6
    call u_mark
    pop ax
.ub_dout_ok:

.ub_csw:
    push cs
    pop es
    mov di, offset u_csw
    push cx
    mov cx, 13
    call u_bulk_in
    pop cx
    jnc .ub_csw_in_ok
    push ax
    mov al, 3
    call u_mark
    pop ax
    jmp .ub_fail_pop
.ub_csw_in_ok:
    cmp word ptr cs:[u_csw+0], 0x5355     # 'U','S'
    jne .ub_sigbad
    cmp word ptr cs:[u_csw+2], 0x5342     # 'B','S'
    je .ub_sigok
.ub_sigbad:
    push ax
    mov al, 4
    call u_mark
    pop ax
    jmp .ub_fail_pop
.ub_sigok:
    # dCSWTag must echo the CBW's tag. Unchecked, a stale CSW left over from
    # an aborted command satisfies the NEXT command -- a retry can "succeed"
    # without moving a single byte.
    push ax
    push ds
    mov ax, BDA
    mov ds, ax
    mov ax, [0xD0]
    cmp ax, word ptr cs:[u_csw+4]
    pop ds
    pop ax
    jne .ub_tagbad
    cmp word ptr cs:[u_csw+6], 0
    je .ub_tagok
.ub_tagbad:
    push ax
    mov al, 7
    call u_mark
    pop ax
    jmp .ub_fail_pop
.ub_tagok:
    cmp byte ptr cs:[u_csw+12], 0         # bCSWStatus: 0 pass
    je .ub_statok
    push ax
    push ds
    push bx
    mov bx, BDA
    mov ds, bx
    mov al, byte ptr cs:[u_csw+12]
    mov [0xDE], al                        # publish the actual status
    pop bx
    pop ds
    mov al, 5
    call u_mark
    pop ax
    jmp .ub_fail_pop
.ub_statok:
    # The device says PASS. Believe it only if OUR side of the transfer was
    # complete: a recorded data-phase failure, or residue on an OUT, means
    # bytes never arrived -- whatever the status byte claims. The status
    # answers "did I succeed at what I received", never "did you deliver
    # everything".
    push ax
    push ds
    mov ax, BDA
    mov ds, ax
    cmp byte ptr [0xDD], 0
    pop ds
    pop ax
    jne .ub_lied
    test bp, bp
    jz .ub_honest
    test ch, 0x80
    jnz .ub_honest               # short IN data can be legal (short sense)
    cmp word ptr cs:[u_csw+8], 0          # dCSWDataResidue, low word
    jne .ub_resbad
    cmp word ptr cs:[u_csw+10], 0         # high word
    je .ub_honest
.ub_resbad:
    push ax
    mov al, 8
    call u_mark
    pop ax
.ub_lied:
    jmp .ub_fail_pop
.ub_honest:
    pop di
    pop es
    clc
    jmp .ub_out
.ub_fail_pop:
    pop di
    pop es
    stc
.ub_out:
    pop es
    pop ds
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

## ---------------------------------------------------------------------
##  u_busreset -- drive SE0 long enough to be a real bus reset, then let the
##  device recover with SOF running so it does not immediately suspend.
##  The 10 ms minimum is a minimum; 40 ms costs nothing at POST.
## ---------------------------------------------------------------------
u_busreset:
    push ax
    push cx
    push dx
    mov dx, U_CTRL
    mov al, UC_RESET
    out dx, al
    # u_delay is a SPIN LOOP, so this hold is a function of the CPU clock --
    # and the board now boots at 10 MHz instead of 5. At 30 iterations that is
    # roughly 9 ms at the new default, against a 10 ms MINIMUM in the spec:
    # doubling the clock quietly took the bus reset out of spec. It was ~18 ms
    # and legal at 5 MHz.
    #
    # This is the same trap the FDC's baud rate had, and it was fixed there by
    # moving the UART to c3 so the link stopped being a function of the speed
    # step. There is no spare clock to hang this off, so instead it is made
    # generous enough that the FASTEST step on the ladder is still comfortably
    # legal. A bus reset happens once at POST; spending 100 ms on it costs
    # nothing, and there is no upper limit on how long SE0 may be held.
    mov cx, 120                  # >= 36 ms at 10 MHz, ~72 ms at 5
.ubr_hold:
    call u_delay
    loop .ubr_hold
    mov al, UC_SOFEN
    out dx, al
    # Recovery. A flash stick is ready almost at once; a floppy drive is a
    # microcontroller with a motor and runs a self-test first, NAKing until it
    # is done -- which is the device working correctly, not failing.
    mov cx, 240
.ubr_rec:
    call u_delay
    loop .ubr_rec
    pop dx
    pop cx
    pop ax
    ret

## ---------------------------------------------------------------------
##  u_drain -- read and throw away anything the device is still trying to send.
##
##  A device NAKs a bulk OUT when it is not ready for a new command, and in
##  Bulk-Only Transport that usually means it is holding data or a CSW that
##  nobody collected. Resetting without draining leaves it in the same place, so
##  a CBW gets NAKed for ever -- 65536 retries and status 04, which is what the
##  hardware reported. Bounded at 20 packets: this runs on a device that is
##  already misbehaving, so it must not be able to spin.
## ---------------------------------------------------------------------
u_drain:
    push ax
    push bx
    push cx
    push dx
    push di
    push ds
    push es
    push cs
    pop es
    mov di, offset u_buf
    mov cx, 20
.udr_pkt:
    push cx
    call u_setptr
    mov ax, BDA
    mov ds, ax
    mov al, [0xC3]
    mov dx, U_ENDP
    out dx, al
    mov al, UOP_IN | UGO
    call u_txn
    pop cx
    jc .udr_done                 # engine wedged
    test al, UST_RXV
    jz .udr_done                 # NAK / timeout / stall: nothing left to take
    mov dx, U_LEN
    in al, dx
    xor ah, ah
    mov bx, ax
    test bx, bx
    jz .udr_done                 # zero-length packet ends it
    call u_setptr
    push cx
    mov cx, bx
    mov dx, U_DATA
.udr_rd:
    in al, dx                    # read and discard
    loop .udr_rd
    pop cx
    cmp bx, 64
    jb .udr_done                 # short packet ends it
    loop .udr_pkt
.udr_done:
    pop es
    pop ds
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

## ---------------------------------------------------------------------
##  u_botreset -- Bulk-Only Mass Storage Reset, then clear both endpoint halts.
##
##  Without this, a single failed transfer is permanent. The device is left
##  holding data it could not deliver, or a CSW nobody collected, and every
##  command after it reads those stale bytes -- which shows up as "CSW signature
##  wrong" for ever after, surviving a warm boot and clearing only on a power
##  cycle. That is exactly the intermittent-then-stuck behaviour seen on
##  hardware: the transfer works, then one hiccup poisons everything.
##
##  The sequence is the one the Bulk-Only Transport spec prescribes: class
##  request 0xFF to the interface, then CLEAR_FEATURE(ENDPOINT_HALT) on the bulk
##  IN and bulk OUT endpoints. A reset also returns both endpoints to DATA0, so
##  the toggles are cleared here to match.
## ---------------------------------------------------------------------
u_botreset:
    push ax
    push cx
    push si
    push di
    push ds
    push es
    push cs
    pop es
    mov di, offset u_buf
    push cs
    pop ds

    call u_drain                 # take back whatever it was holding first
    push cs
    pop ds

    mov si, offset u_rq_botrst   # class reset
    xor cx, cx
    call u_ctl

    push ds                      # clear halt on the bulk IN endpoint
    mov ax, BDA
    mov ds, ax
    mov al, [0xC3]
    pop ds
    mov byte ptr cs:[u_rq_clrhalt+4], al
    mov si, offset u_rq_clrhalt
    xor cx, cx
    call u_ctl

    push ds                      # and on the bulk OUT endpoint
    mov ax, BDA
    mov ds, ax
    mov al, [0xC4]
    pop ds
    mov byte ptr cs:[u_rq_clrhalt+4], al
    mov si, offset u_rq_clrhalt
    xor cx, cx
    call u_ctl

    push ds                      # a reset puts both endpoints back to DATA0
    mov ax, BDA
    mov ds, ax
    mov byte ptr [0xC5], 0
    mov byte ptr [0xC6], 0
    pop ds

    call u_delay
    pop es
    pop ds
    pop di
    pop si
    pop cx
    pop ax
    ret

## ---------------------------------------------------------------------
##  u_findep -- walk the configuration descriptor for the mass-storage
##  interface and its bulk endpoints.
##
##  Descriptors are a chain of {bLength, bDescriptorType, ...}, so the walk
##  steps by bLength rather than assuming any layout. Endpoints are only
##  accepted once a mass-storage interface (class 08) has been seen, otherwise
##  a composite device's other interface could donate the wrong pair.
##
##  Entry: DS = BDA, u_buf holds the descriptor, u_cfglen its valid length.
##  Sets BDA 0xC3 (bulk IN) and 0xC4 (bulk OUT); CF set if either is missing.
## ---------------------------------------------------------------------
u_findep:
    push ax
    push bx
    push cx
    push si
    mov byte ptr [0xC3], 0
    mov byte ptr [0xC4], 0
    mov byte ptr [0xD9], 0       # 1 once a mass-storage interface is seen
    mov bx, cs:[u_cfglen]
    cmp bx, U_BUFSZ
    jbe .fe_len
    mov bx, U_BUFSZ
.fe_len:
    xor cx, cx
.fe_walk:
    cmp cx, bx
    jae .fe_done
    mov si, cx
    add si, offset u_buf
    mov al, cs:[si]              # bLength
    cmp al, 2
    jb .fe_done                  # malformed chain, stop rather than loop
    mov ah, cs:[si+1]            # bDescriptorType
    cmp ah, 0x04
    je .fe_iface
    cmp ah, 0x05
    je .fe_endp
    jmp short .fe_next
.fe_iface:
    mov byte ptr [0xD9], 0
    cmp byte ptr cs:[si+5], 0x08 # bInterfaceClass = mass storage
    jne .fe_next
    mov byte ptr [0xD9], 1
    jmp short .fe_next
.fe_endp:
    cmp byte ptr [0xD9], 0
    je .fe_next                  # not our interface
    mov ah, cs:[si+3]            # bmAttributes
    and ah, 0x03
    cmp ah, 0x02                 # bulk?
    jne .fe_next
    mov ah, cs:[si+2]            # bEndpointAddress
    test ah, 0x80
    jz .fe_out
    cmp byte ptr [0xC3], 0
    jne .fe_next
    mov [0xC3], ah
    jmp short .fe_next
.fe_out:
    cmp byte ptr [0xC4], 0
    jne .fe_next
    mov [0xC4], ah
.fe_next:
    xor ah, ah
    add cx, ax
    jmp short .fe_walk
.fe_done:
    cmp byte ptr [0xC3], 0
    je .fe_bad
    cmp byte ptr [0xC4], 0
    je .fe_bad
    clc
    jmp short .fe_out2
.fe_bad:
    stc
.fe_out2:
    pop si
    pop cx
    pop bx
    pop ax
    ret

## ---------------------------------------------------------------------
##  u_geometry -- capacity to CHS that DOS 3.3 through 6 can address.
##
##  INT 13h carries 10 bits of cylinder, and the BIOS convention caps heads at
##  16 and sectors at 63: 1024 x 16 x 63 = 1,032,192 sectors = 504 MB. That is
##  a hard ceiling, so a larger stick is reported as 504 MB and the remainder
##  is simply unreachable. Every DOS of the era is happy inside it.
##
##  The clamp has to happen BEFORE the divide, not after: a 32 GB stick is
##  67 million sectors, and 67e6 / 1008 does not fit in 16 bits, so DIV would
##  raise a divide-overflow interrupt rather than return a wrong answer.
## ---------------------------------------------------------------------
u_geometry:
    push ax
    push cx
    push dx
    push ds
    mov ax, BDA
    mov ds, ax
    mov byte ptr [0xCE], 16
    mov byte ptr [0xCF], 63

    mov ax, [0xC8]               # last LBA, low word
    mov dx, [0xCA]               # high word
    add ax, 1                    # total sectors = last + 1
    adc dx, 0

    cmp dx, 0x000F               # clamp to 0x000FC000 = 1,032,192
    jb .ug_div
    ja .ug_clamp
    cmp ax, 0xC000
    jbe .ug_div
.ug_clamp:
    mov ax, 0xC000
    mov dx, 0x000F
.ug_div:
    mov cx, 1008                 # heads * spt
    div cx                       # dx:ax / cx -> ax = cylinders
    cmp ax, 1024
    jbe .ug_have
    mov ax, 1024
.ug_have:
    test ax, ax
    jz .ug_bad
    mov [0xCC], ax
    clc
    jmp short .ug_out
.ug_bad:
    stc
.ug_out:
    pop ds
    pop dx
    pop cx
    pop ax
    ret

## ---------------------------------------------------------------------
##  usb_int13 read/write.
##
##  ES:BX is the caller's buffer, so BX is NOT available as a direction flag --
##  an earlier draft used BH for it and quietly corrupted the buffer pointer.
##  The direction goes in BDA 0xD8 instead.
## ---------------------------------------------------------------------
.ui_read:
    push ds
    push ax
    mov ax, BDA
    mov ds, ax
    mov byte ptr [0xD8], 0
    pop ax
    pop ds
    jmp short .ui_rw
.ui_write:
    push ds
    push ax
    mov ax, BDA
    mov ds, ax
    mov byte ptr [0xD8], 1
    pop ax
    pop ds
.ui_rw:
    test al, al
    jz .ui_ok                    # zero sectors is a no-op, not an error
    cmp al, 127                  # one CBW carries at most 127 x 512 bytes
    ja .ui_err
    push ds
    push es
    push si
    push di
    push bp
    push bx
    push cx
    push dx
    mov di, bx                   # ES:DI = caller's buffer
    mov bl, al                   # BL = sector count
    push bx
    call u_chs2lba               # DX:AX = LBA, from the caller's CH/CL/DH
    pop bx
    # Retry the whole command, recovering the transport between attempts.
    #
    # 38 consecutive 512-byte writes -- some 380 packets -- succeeded before the
    # first failure, so this is not a broken code path but an occasional lost or
    # corrupted packet. One retry was not enough: the recovery itself moves
    # packets, so it can meet the same error. Four attempts makes a single
    # glitch invisible while still failing promptly on a genuinely dead device.
    #
    # Reissuing a write is safe: the same sector is written with the same data,
    # so a partially-applied attempt is simply overwritten.
    mov si, 4
.ui_try:
    push ax
    push dx
    push bx
    push si
    call u_rw10
    pop si
    pop bx
    pop dx
    pop ax
    jnc .ui_rw_ok
    dec si
    jz .ui_rw_bad
    call u_botreset
    jmp short .ui_try
.ui_rw_bad:
    stc
    jmp short .ui_rw_done
.ui_rw_ok:
    clc
.ui_rw_done:                     # POP does not disturb CF
    pop dx
    pop cx
    pop bx
    pop bp
    pop di
    pop si
    pop es
    pop ds
    jc .ui_err
    xor ah, ah
    clc
    retf 2

## TEST UNIT READY -- no data. CF set means "not ready", which during spin-up
## is normal rather than an error.
u_scsi_tur:
    push cx
    push si
    push di
    push bp
    push es
    push ds                      # MUST be saved: "push cs / pop ds" below
    push cs                      # overwrites the caller's DS, and u_enum runs
    pop es                       # with DS = BDA. Without this the stage byte
    push cs                      # and the present flag were written to
    pop ds                       # F000:00Cx instead of 0040:00Cx.
    mov si, offset u_cdb_tur
    mov cl, 6
    mov ch, 0
    xor bp, bp
    xor di, di
    call u_bot
    pop ds
    pop es
    pop bp
    pop di
    pop si
    pop cx
    ret

## REQUEST SENSE -- clears a pending check condition. Skipping this after a
## failure leaves the device refusing everything with the same sense data.
u_scsi_sense:
    push cx
    push si
    push di
    push bp
    push es
    push ds                      # MUST be saved: "push cs / pop ds" below
    push cs                      # overwrites the caller's DS, and u_enum runs
    pop es                       # with DS = BDA. Without this the stage byte
    push cs                      # and the present flag were written to
    pop ds                       # F000:00Cx instead of 0040:00Cx.
    mov si, offset u_cdb_sense
    mov cl, 6
    mov ch, 0x80
    mov bp, 18
    mov di, offset u_buf
    call u_bot
    pop ds
    pop es
    pop bp
    pop di
    pop si
    pop cx
    ret

## READ CAPACITY(10) -- returns the LAST LBA and the block size, both
## big-endian. A 512-byte block size is assumed everywhere else in the BIOS;
## anything else is rejected rather than silently mis-addressed.
u_scsi_capacity:
    push ax
    push bx
    push cx
    push si
    push di
    push bp
    push ds
    push es
    push cs
    pop es
    push cs
    pop ds
    mov si, offset u_cdb_cap
    mov cl, 10
    mov ch, 0x80
    mov bp, 8
    mov di, offset u_buf
    call u_bot
    jc .usc_bad
    # last LBA, big-endian in bytes 0..3 -> little-endian 32-bit in the BDA
    mov ax, BDA
    mov ds, ax
    mov al, byte ptr cs:[u_buf+3]
    mov ah, byte ptr cs:[u_buf+2]
    mov [0xC8], ax
    mov al, byte ptr cs:[u_buf+1]
    mov ah, byte ptr cs:[u_buf+0]
    mov [0xCA], ax
    # block size must be 512
    cmp byte ptr cs:[u_buf+6], 0x02
    jne .usc_bad
    cmp byte ptr cs:[u_buf+7], 0x00
    jne .usc_bad
    clc
    jmp short .usc_out
.usc_bad:
    stc
.usc_out:
    pop es
    pop ds
    pop bp
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret


## ---------------------------------------------------------------------
##  u_enum -- reset, address, configure, and find the bulk endpoints.
##  Records progress in BDA 0xC0 so a failure says WHERE it failed:
##    01 no 48 MHz PLL lock       02 no device on the port
##    03 device descriptor failed 04 SET_ADDRESS failed
##    05 config descriptor failed 06 no mass-storage interface
##    07 SET_CONFIGURATION failed 08 unit never became ready
##    09 READ CAPACITY failed     0A geometry unusable
##    FF success
## ---------------------------------------------------------------------
u_enum:
    push ds
    push es
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov ax, BDA
    mov ds, ax
    mov byte ptr [0xC1], 0
    mov byte ptr [0xC0], 1
    mov byte ptr [0xD0], 0
    mov byte ptr [0xD1], 0
    # 8 is what every device must support on EP0 and the only safe assumption
    # before the device has been asked. This is RAM, so without the explicit
    # store a warm boot would inherit the PREVIOUS device's size -- 64 from a
    # stick, which is exactly the wrong value to carry into enumerating a
    # dongle, and it would fail as a truncated descriptor rather than as a
    # missing one. u_ctl clamps too; both, because neither is the whole story.
    mov byte ptr [0xC7], 8

    # The PLL lock is tested BEFORE the build signature, deliberately: the
    # diagnostic registers live in the 48 MHz domain, so with the PLL dead
    # they return junk -- and junk compared against 0xA5 used to be reported
    # as "FPGA image is older", which points at entirely the wrong thing.
    # Order matters: stage 01 means no clock, stage F0 means a real mismatch
    # read with a working clock.
    mov dx, U_CTRL
    in al, dx
    test al, UL_LOCK
    jz .ue_out                   # stage 1: no PLL, nothing can work

    # Is the logic in the FPGA the logic this driver was written against? The
    # registers answer either way -- an older image still returns plausible
    # counters -- so without this the wrong bitstream reads as a USB failure,
    # and it has twice sent us chasing a fault that was not there.
    mov dx, 0xEF
    mov al, 0x0F
    out dx, al
    in al, dx
    cmp al, 0xA5
    je .ue_sig_ok
    mov byte ptr [0xC0], 0xF0    # not a USB fault at all
    jmp .ue_out
.ue_sig_ok:
    mov dx, U_CTRL               # DX still held the diag port from the check
                                 # above; the OUT below expects the controller


    mov byte ptr [0xC0], 2
    xor al, al
    out dx, al                   # port 0, no reset, no SOF
    call u_delay
    in al, dx
    test al, UL_FS
    jz .ue_out                   # stage 2: no full-speed device

    # USB 2.0 7.1.7.3: once attach is detected, leave the device alone for
    # 100 ms before resetting it. The pull-up appears as soon as the device has
    # power, well before its controller is ready to answer, so resetting the
    # moment we see full speed hits a half-awake device -- which is exactly the
    # "replug the stick and it fails at some random stage" behaviour.
    mov cx, 70
.ue_settle:
    call u_delay
    loop .ue_settle

    call u_busreset

    # ---- device descriptor at address 0 ----
    ##  Retried, with a fresh bus reset between attempts. Reflashing the FPGA
    ##  resets this controller but NOT the stick: 5 V comes straight off the
    ##  board, so the device keeps its address and configuration and ignores
    ##  requests to address 0. One reset should undo that, but a device left
    ##  mid-transaction can need more than one, and the failure looks identical
    ##  to "no device" -- which is what stage 03 was reporting after a reflash.
    mov byte ptr [0xC0], 3
    mov cx, 4
.ue_dev_try:
    push cx
    xor al, al
    mov dx, U_ADDR
    out dx, al
    mov dx, U_ENDP
    out dx, al
    push cs
    pop es
    mov di, offset u_buf
    push ds
    push cs
    pop ds
    mov si, offset u_rq_dev8
    mov cx, 8
    call u_ctl
    pop ds
    pop cx
    jnc .ue_dev_ok
    call u_busreset
    loop .ue_dev_try
    jmp .ue_out
.ue_dev_ok:
    mov al, byte ptr cs:[u_buf+7]
    mov [0xC7], al               # bMaxPacketSize0

    # ---- SET_ADDRESS(1) ----
    mov byte ptr [0xC0], 4
    push ds
    push cs
    pop ds
    mov si, offset u_rq_setaddr
    xor cx, cx
    call u_ctl
    pop ds
    jc .ue_out
    call u_delay
    call u_delay
    mov al, 1
    mov [0xC2], al
    mov dx, U_ADDR
    out dx, al

    # ---- configuration descriptor: header, then the whole thing ----
    mov byte ptr [0xC0], 5
    push ds
    push cs
    pop ds
    mov si, offset u_rq_cfg
    mov cx, 64
    call u_ctl
    pop ds
    jc .ue_out
    # Publish where the descriptor landed and how much of it arrived, so
    # USBHD.COM can dump the actual bytes. u_buf is in the BIOS segment, whose
    # offset a DOS program has no other way to know.
    mov word ptr [0xDA], offset u_buf
    mov [0xDC], cx               # bytes the device actually returned
    mov al, byte ptr cs:[u_buf+5]
    mov [0xD4], al               # bConfigurationValue
    mov ax, word ptr cs:[u_buf+2]
    mov word ptr cs:[u_cfglen], ax   # wTotalLength, clamped inside u_findep

    # ---- find the bulk endpoints of the mass-storage interface ----
    mov byte ptr [0xC0], 6
    call u_findep
    jc .ue_out

    # ---- SET_CONFIGURATION ----
    mov byte ptr [0xC0], 7
    mov al, [0xD4]
    mov byte ptr cs:[u_rq_setcfg+2], al
    push ds
    push cs
    pop ds
    mov si, offset u_rq_setcfg
    xor cx, cx
    call u_ctl
    pop ds
    jc .ue_out
    mov byte ptr [0xC5], 0       # fresh data toggles after configuring
    mov byte ptr [0xC6], 0

    # ---- TEST UNIT READY, retried: sticks report not-ready while spinning up ----
    mov byte ptr [0xC0], 8
    mov cx, 40
.ue_tur:
    push cx
    call u_scsi_tur
    pop cx
    jnc .ue_ready
    push cx
    call u_scsi_sense            # a check condition must be cleared or the
    call u_delay                 # next command fails for the same reason
    pop cx
    loop .ue_tur
    jmp short .ue_out
.ue_ready:

    # ---- READ CAPACITY, then a DOS-safe geometry ----
    mov byte ptr [0xC0], 9
    call u_scsi_capacity
    jc .ue_out
    mov byte ptr [0xC0], 0x0A
    call u_geometry
    jc .ue_out

    mov byte ptr [0xC0], 0xFF
    mov byte ptr [0xC1], 1       # C: is real
.ue_out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    pop es
    pop ds
    ret

## ---------------------------------------------------------------------

## ---------------------------------------------------------------------
##  usb_int13 -- INT 13h for DL >= 0x80 (drive C:)
## ---------------------------------------------------------------------
usb_int13:
    push ds
    push ax
    mov ax, BDA
    mov ds, ax
    cmp byte ptr [0xC1], 0
    pop ax
    pop ds
    jne .ui_present
    mov ah, 0x01                 # no such drive -- DOS then skips it
    stc
    retf 2
.ui_present:
    cmp ah, 0x02
    je .ui_read
    cmp ah, 0x03
    je .ui_write
    cmp ah, 0x08
    je .ui_params
    cmp ah, 0x15
    je .ui_dtype
    cmp ah, 0x00
    je .ui_ok
    cmp ah, 0x01
    je .ui_status
    cmp ah, 0x04
    je .ui_ok
    cmp ah, 0x09
    je .ui_ok
    cmp ah, 0x0C
    je .ui_ok
    cmp ah, 0x0D
    je .ui_ok
    cmp ah, 0x10
    je .ui_ok
    cmp ah, 0x11
    je .ui_ok
    cmp ah, 0x14
    je .ui_ok
    mov ah, 0x01
    stc
    retf 2

.ui_ok:
    push ds
    push ax
    mov ax, BDA
    mov ds, ax
    mov byte ptr [0x74], 0
    pop ax
    pop ds
    xor ah, ah
    clc
    retf 2

.ui_status:
    push ds
    mov ax, BDA
    mov ds, ax
    mov ah, [0x74]
    pop ds
    clc
    retf 2

.ui_dtype:
    mov ah, 0x03                 # 03 = fixed disk present
    push ds
    mov ax, BDA
    mov ds, ax
    mov dx, [0xC8]               # total sectors, low word
    mov cx, [0xCA]               # high word
    pop ds
    clc
    retf 2

.ui_params:
    push ds
    mov ax, BDA
    mov ds, ax
    mov ax, [0xCC]               # cylinders
    dec ax                       # max cylinder
    mov ch, al                   # low 8 bits
    mov cl, ah
    ror cl, 1
    ror cl, 1                    # high 2 bits into CL bits 7:6
    and cl, 0xC0
    or cl, [0xCF]                # sectors per track
    mov dh, [0xCE]
    dec dh                       # max head
    mov dl, 1                    # one fixed disk
    pop ds
    xor ah, ah
    clc
    retf 2


.ui_err:
    push ds
    push ax
    mov ax, BDA
    mov ds, ax
    mov byte ptr [0x74], 0x04    # sector not found / general failure
    pop ax
    pop ds
    mov ah, 0x04
    stc
    retf 2

## ---------------------------------------------------------------------
##  u_delay -- about a millisecond at 5 MHz. Every USB delay here is a
##  minimum with margin, so precision does not matter.
## ---------------------------------------------------------------------
u_delay:
    push cx
    mov cx, 300
.ud_l:
    nop
    nop
    loop .ud_l
    pop cx
    ret

## ---------------------------------------------------------------------
##  USB scratch and constant tables.
##
##  These live in the F-segment, which is PSRAM rather than ROM on this
##  machine, so the buffers below really are writable. Every CDB table is
##  padded to 16 bytes because u_bot always copies 16 into the CBW.
## ---------------------------------------------------------------------
##  Set to 1 by 186BOOST.COM once it has established that the CPU can execute
##  80186 string instructions. Zero at reset, and POST rewrites it every boot,
##  so a fast path can never be inherited across a CPU swap. Its offset is
##  published at BDA 40:BC, because a DOS tool has no other way to find it.
## =====================================================================
##  RUNTIME DATA -- OUT OF THE CHECKSUMMED REGION, DELIBERATELY.
##
##  Every byte below is written while the machine runs, and it used to sit in
##  the middle of the code at 0xEB6A. That made two instruments lie:
##
##    * the boot loader checksums 0xC000..0xEFFF and its comment claims the
##      range is "code only, none of the BIOS's own runtime scratch". It was
##      not: 112 bytes of this block were inside it, so a serial boot and a
##      flash boot could never produce the same value. That pair exists
##      precisely to prove the same image reached memory, and it could not.
##    * SPIDUMP compares the stored image against the RUNNING BIOS and read
##      41 mismatches, first at 0xEB6B -- which is u_cbw, and the byte it
##      reported was 0x55, the 'U' of the "USBC" Command Block Wrapper
##      signature. Nothing was corrupt. It was looking at a live CBW.
##
##  Chasing that cost an evening, so it does not get to happen again: this
##  block is linked ABOVE 0xEF00, past everything either instrument sums.
##  Note the templates move too -- they are not all constant. u_rq_clrhalt
##  has its byte 4 patched with the endpoint address, and a "mostly constant"
##  table in a checksummed region is the same bug with a smaller blast radius.
##
##  --section-start=.rtdata in mkbios.sh places it; mkbios FAILS THE BUILD if
##  it lands below 0xEF00 or collides with the font at 0xFA6E.
## =====================================================================

## =====================================================================
##  USB FLOPPY -- UFI over CBI on USB1, presented as drive B:
##
##  A USB floppy drive is mass storage, but NOT the transport the fixed disk
##  on USB0 uses. That one is Bulk-Only: a 31-byte CBW out on bulk, data, a
##  13-byte CSW back. A floppy is class 08 / subclass 04 / protocol 00 --
##  UFI over CBI -- which is the same command set under a different wrapper:
##
##    COMMAND  a CONTROL transfer, bmRequestType 0x21, bRequest 0x00 (ADSC),
##             wIndex = the INTERFACE, carrying a 12-byte command block
##    DATA     bulk IN or OUT, exactly as before
##    STATUS   two bytes on an INTERRUPT IN endpoint, not a CSW
##
##  For UFI those two bytes are ASC and ASCQ -- the same codes REQUEST SENSE
##  reports. Both zero means the command worked.
##
##  THE RULE THAT MATTERS MOST. A UNIT ATTENTION (sense key 6) ABORTS the
##  command in progress, is reported exactly once, is cleared by reading the
##  sense, and the command must then be REISSUED. Removable media raises it
##  after every reset and every disk change, so a driver that does not reissue
##  fails the first access after each -- which looks exactly like a broken
##  drive. It is obeyed in ONE place here, uf_do, so it cannot be applied to
##  some commands and not others.
##
##  This drive also STALLS the control status stage while still executing the
##  command. That is tolerated: the authority in CBI is the interrupt status.
##
##  Developed and debugged as tools/usbfdd.asm, which keeps the diagnostics.
## =====================================================================
.equ UF_CMD,   0xA8
.equ UF_ADDR,  0xA9
.equ UF_ENDP,  0xAA
.equ UF_LEN,   0xAB
.equ UF_DATA,  0xAC
.equ UF_PTR,   0xAD
.equ UF_CTRL,  0xAE

## uf_txn -- one transaction on port 1, NAK-retried.  AL = command byte.
##   Returns AL = status, CF set if the engine never went idle.
uf_txn:
    push bx
    push cx
    push dx
    mov bl, al
    mov bh, 3
.uft_att:
    ## NAK BUDGET, AND IT IS MEASURED IN THE WRONG UNITS ON PURPOSE.
    ## A NAK means "not ready, ask again", and READ(10) is the first command
    ## here that needs PHYSICAL DISK ACCESS -- TEST UNIT READY, INQUIRY and
    ## READ CAPACITY all answer out of the drive's own memory and reply at
    ## once. A sector has to come round under the head: at 300 RPM that is up
    ## to 200 ms of rotational latency before the first byte exists, plus the
    ## seek.
    ##
    ## 8000 retries at roughly 10 us each is about 80 ms, so the read gave up
    ## while the disk was still turning and reported a controller failure for
    ## a drive that was working exactly as intended. 0 means 65536, around
    ## 650 ms, which covers three full revolutions.
    mov cx, 0
.uft_try:
    push cx
    mov al, bl
    mov dx, UF_CMD
    out dx, al
    mov cx, 0
.uft_wait:
    mov dx, UF_CMD
    in al, dx
    test al, 0x01                # BUSY
    jz .uft_done
    loop .uft_wait
    pop cx
    jmp .uft_fail
.uft_done:
    pop cx
    test al, 0x04                # NAK -- flow control, not an error
    jz .uft_settled
    loop .uft_try
    jmp .uft_fail
.uft_settled:
    test al, 0x08                # STALL
    jnz .uft_fail
    test al, 0x30                # ERR | TIMEOUT
    jz .uft_ok
    dec bh
    jnz .uft_att
.uft_fail:
    stc
    jmp .uft_out
.uft_ok:
    clc
.uft_out:
    pop dx
    pop cx
    pop bx
    ret

uf_ptr0:
    push ax
    push dx
    xor al, al
    mov dx, UF_PTR
    out dx, al
    pop dx
    pop ax
    ret

## uf_ctlin -- control transfer with an IN data stage (descriptors only).
##   DS:SI = 8-byte setup packet, ES:DI = destination, CX = bytes wanted.
##   CF set on failure.
uf_ctlin:
    push ds
    push ax
    push bx
    push cx
    push dx
    push si
    push bp
    push cs
    pop ds                       # lodsb below reads DS:SI, and the setup
    mov bp, cx                   # packet is in the F-segment
    mov al, byte ptr [si]        # bmRequestType, for the status stage below
    mov byte ptr cs:[uf_rqt], al
    xor al, al
    mov dx, UF_ENDP
    out dx, al
    call uf_ptr0
    mov cx, 8
    mov dx, UF_DATA
.ufc_s:
    lodsb
    out dx, al
    loop .ufc_s
    mov al, 8
    mov dx, UF_LEN
    out dx, al
    mov al, 0x81                 # SETUP | GO
    call uf_txn
    jc .ufc_bad
    test al, 0x02                # ACK
    jz .ufc_bad
    xor bx, bx
    test bp, bp
    jz .ufc_st
.ufc_d:
    call uf_ptr0
    mov al, 0x82                 # IN | GO
    call uf_txn
    jc .ufc_bad
    test al, 0x80                # RXVALID
    jz .ufc_bad
    mov dx, UF_LEN
    in al, dx
    xor ah, ah
    mov cx, ax
    jcxz .ufc_st
    push cx
    call uf_ptr0
    mov dx, UF_DATA
.ufc_c:
    in al, dx
    stosb
    inc bx
    loop .ufc_c
    pop cx
    mov al, byte ptr cs:[uf_ep0]
    xor ah, ah
    cmp cx, ax                   # short packet = shorter than the ENDPOINT
    jb .ufc_st
    cmp bx, bp
    jb .ufc_d
.ufc_st:
    call uf_ptr0
    xor al, al
    mov dx, UF_LEN
    out dx, al
    ## THE STATUS STAGE RUNS THE OPPOSITE WAY TO THE DATA STAGE.
    ## A device-to-host request -- every GET_DESCRIPTOR here, bmRequestType
    ## bit 7 set -- ends with a zero-length OUT. A host-to-device one --
    ## SET_ADDRESS, SET_CONFIGURATION -- ends with an IN.
    ##
    ## This sent OUT for both. GET_DESCRIPTOR therefore worked and SET_ADDRESS
    ## was quietly malformed, so the device never completed the address change
    ## and stayed at 0 while we began addressing it as 1. Every transfer after
    ## that went to an address nothing answers on, and the first one to do so
    ## was the configuration read -- which is why the stage marker pointed one
    ## step past the actual fault.
    mov al, 0x8A                 # IN | GO | DATA1
    test byte ptr cs:[uf_rqt], 0x80
    jz .ufc_stgo
    mov al, 0x8B                 # OUT | GO | DATA1
.ufc_stgo:
    call uf_txn
    jc .ufc_bad
    clc
    jmp .ufc_out
.ufc_bad:
    stc
.ufc_out:
    pop bp
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    pop ds
    ret

## uf_adsc -- the CBI command phase: 12 bytes out through a CONTROL transfer.
##   DS:SI = 12-byte command block.
##
##   SPLIT INTO bMaxPacketSize0 CHUNKS. This drive reports an 8-byte control
##   endpoint, so the command goes out as 8 then 4 with the toggle alternating
##   DATA1, DATA0. One 12-byte packet is a packet larger than the endpoint --
##   a protocol violation -- and the device answers it with a STALL.
uf_adsc:
    push ds
    push ax
    push bx
    push cx
    push dx
    push si
    push cs
    pop ds                       # command block and setup packet are both
    mov al, byte ptr cs:[uf_iface]   # in the F-segment
    mov byte ptr cs:[uf_sp_adsc+4], al
    xor al, al
    mov dx, UF_ENDP
    out dx, al
    call uf_ptr0
    push si
    mov si, offset uf_sp_adsc
    mov cx, 8
    mov dx, UF_DATA
.ufa_s:
    lodsb
    out dx, al
    loop .ufa_s
    pop si
    mov al, 8
    mov dx, UF_LEN
    out dx, al
    mov al, 0x81
    call uf_txn
    jc .ufa_bad
    test al, 0x02
    jz .ufa_bad

    mov bx, 12                   # bytes of command block left
    mov byte ptr cs:[uf_ctog], 1 # first data packet of a control is DATA1
.ufa_dl:
    test bx, bx
    jz .ufa_stat
    mov al, byte ptr cs:[uf_ep0]
    xor ah, ah
    cmp ax, bx
    jbe .ufa_have
    mov ax, bx
.ufa_have:
    mov cx, ax
    push cx
    call uf_ptr0
    mov dx, UF_DATA
.ufa_f:
    lodsb
    out dx, al
    loop .ufa_f
    pop cx
    mov al, cl
    mov dx, UF_LEN
    out dx, al
    mov al, 0x83                 # OUT | GO
    cmp byte ptr cs:[uf_ctog], 0
    je .ufa_t0
    or al, 0x08                  # DATA1
.ufa_t0:
    call uf_txn
    jc .ufa_bad
    test al, 0x02
    jz .ufa_bad
    xor byte ptr cs:[uf_ctog], 1
    sub bx, cx
    jmp .ufa_dl

.ufa_stat:
    call uf_ptr0
    xor al, al
    mov dx, UF_LEN
    out dx, al
    mov al, 0x8A                 # IN | GO | DATA1
    call uf_txn
    ## A STALL HERE IS NOT A DEAD COMMAND. This drive stalls the control
    ## status stage while still executing what it was told -- it spins up and
    ## steps the head. Giving up here means never running the data phase or
    ## reading the interrupt status, so every command looks identically dead.
    clc
    jmp .ufa_out
.ufa_bad:
    stc
.ufa_out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    pop ds
    ret

## uf_istat -- the CBI status: two bytes on the interrupt IN endpoint.
##   For UFI they are ASC and ASCQ. CF set if absent or non-zero.
uf_istat:
    push ax
    push cx
    push dx
    mov byte ptr cs:[uf_asc], 0
    mov byte ptr cs:[uf_ascq], 0
    mov al, byte ptr cs:[uf_epint]
    and al, 0x0F
    mov dx, UF_ENDP
    out dx, al
    call uf_ptr0
    mov al, 0x82
    call uf_txn
    jc .ufi_bad
    test al, 0x80
    jz .ufi_bad
    mov dx, UF_LEN
    in al, dx
    cmp al, 2
    jb .ufi_bad
    call uf_ptr0
    mov dx, UF_DATA
    in al, dx
    mov byte ptr cs:[uf_asc], al
    in al, dx
    mov byte ptr cs:[uf_ascq], al
    mov al, byte ptr cs:[uf_asc]
    or al, byte ptr cs:[uf_ascq]
    jnz .ufi_bad
    clc
    jmp .ufi_out
.ufi_bad:
    stc
.ufi_out:
    pop dx
    pop cx
    pop ax
    ret

## uf_bulk -- CX bytes to/from ES:DI (in) or DS:SI (out), 64 at a time.
##   AH = 0 for IN, 1 for OUT. CF set on failure.
uf_bulk:
    push ax
    mov byte ptr cs:[uf_dup], 8
    push bx
    push cx
    push dx
    push bp
    mov bp, ax                   # bp high byte keeps the direction
.ufb_pkt:
    test cx, cx                  # not JCXZ: 8-bit displacement only, and
    jnz .ufb_go                  # .ufb_done is far past it
    jmp .ufb_done
.ufb_go:
    mov bx, cx
    cmp bx, 64
    jbe .ufb_sz
    mov bx, 64
.ufb_sz:
    test bp, 0x0100
    jnz .ufb_out

    ## ---- IN ----
    push cx
    mov al, byte ptr cs:[uf_epin]
    and al, 0x0F
    mov dx, UF_ENDP
    out dx, al
    call uf_ptr0
    mov al, 0x82
    call uf_txn
    pop cx
    mov byte ptr cs:[uf_lastst], al     # the status, whatever it was
    jc .ufb_bad
    test al, 0x80
    jz .ufb_bad
    ## Toggle check: a packet carrying the toggle we are NOT expecting is a
    ## retransmission of one already taken, because our ACK was lost. Counting
    ## it as new shifts the whole sector by a packet.
    push ax
    mov ah, 0
    test al, 0x40                # RXDATA1
    jz .ufb_g0
    mov ah, 1
.ufb_g0:
    mov al, byte ptr cs:[uf_tin]
    cmp al, ah
    pop ax
    je .ufb_take
    dec byte ptr cs:[uf_dup]     # bounded: a device that only ever repeats
    jnz .ufb_pkt                 # itself must not wedge the machine
    jmp .ufb_bad
.ufb_take:
    xor byte ptr cs:[uf_tin], 1
    mov dx, UF_LEN
    in al, dx
    xor ah, ah
    mov bx, ax
    test bx, bx
    jz .ufb_done
    cmp bx, cx
    jbe .ufb_fit
    mov bx, cx                   # never store more than was asked for
.ufb_fit:
    push cx
    mov cx, bx
    call uf_ptr0
    mov dx, UF_DATA
.ufb_ic:
    in al, dx
    stosb
    loop .ufb_ic
    pop cx
    sub cx, bx
    jmp .ufb_pkt

    ## ---- OUT ----
.ufb_out:
    push cx
    call uf_ptr0
    mov cx, bx
    mov dx, UF_DATA
.ufb_oc:
    mov al, byte ptr es:[si]     # ES:SI -- the caller's buffer, NOT DS:SI.
    inc si                       # lodsb here would have written whatever DS
    out dx, al                   # pointed at onto the diskette.
    loop .ufb_oc
    mov al, bl
    mov dx, UF_LEN
    out dx, al
    mov al, byte ptr cs:[uf_epout]
    and al, 0x0F
    mov dx, UF_ENDP
    out dx, al
    mov al, 0x83
    cmp byte ptr cs:[uf_tout], 0
    je .ufb_ot0
    or al, 0x08
.ufb_ot0:
    call uf_txn
    pop cx
    jc .ufb_bad
    test al, 0x02
    jz .ufb_bad
    xor byte ptr cs:[uf_tout], 1
    sub cx, bx
    jmp .ufb_pkt

.ufb_done:
    mov word ptr cs:[uf_bleft], 0
    clc
    jmp .ufb_o
.ufb_bad:
    mov word ptr cs:[uf_bleft], cx      # bytes still owed when it gave up
    stc
.ufb_o:
    pop bp
    pop dx
    pop cx
    pop bx
    pop ax
    ret

## uf_once -- one complete UFI command, no retry.
##   DS:SI = command, ES:DI = in buffer / DS:BX = out buffer, CX = bytes,
##   AH = 0 none, 1 data-in, 2 data-out.
uf_once:
    push cx
    push si
    push di
    mov byte ptr cs:[uf_dir], ah
    call uf_adsc
    jc .ufo_bad
    mov ah, byte ptr cs:[uf_dir]
    test ah, ah
    jz .ufo_stat
    cmp ah, 1
    jne .ufo_wr
    mov ah, 0
    call uf_bulk
    jc .ufo_bad
    jmp .ufo_stat
.ufo_wr:
    push si
    mov si, bx
    mov ah, 1
    call uf_bulk
    pop si
    jc .ufo_bad
.ufo_stat:
    call uf_istat
    pop di
    pop si
    pop cx
    ret
.ufo_bad:
    pop di
    pop si
    pop cx
    stc
    ret

## uf_do -- uf_once, obeying the UNIT ATTENTION reissue rule.
##
##   THE ONE PLACE THIS RULE LIVES. A unit attention aborts the command in
##   progress, announces itself once, is cleared by reading the sense, and the
##   command must then be REISSUED. Every media command goes through here, so
##   it cannot be honoured for some and forgotten for others -- which is
##   exactly how the first attempt at this driver failed.
uf_do:
    push bp
    ## KEEP THE DIRECTION. uf_once takes it in AH and returns whatever AH it
    ## last handed uf_bulk -- 0 for a read, 1 for a write -- so a retry ran
    ## with the WRONG direction: a read (1) came back 0 and was reissued with
    ## no data phase at all, leaving the device to send 512 bytes nobody
    ## collected and the bulk endpoint stuffed. Every transfer after that is a
    ## toggle out of step, which is the hang after the directory listing.
    ## A write (2) came back 1 and would have been reissued as a READ.
    mov byte ptr cs:[uf_dsave], ah
    mov bp, 4                    # bounded: each try can cost a revolution
.ufd_l:
    push bp
    mov ah, byte ptr cs:[uf_dsave]
    call uf_once
    pop bp
    jnc .ufd_ok
    call uf_reqsense
    mov al, byte ptr cs:[uf_sense+2]
    and al, 0x0F
    cmp al, 6                    # UNIT ATTENTION
    jne .ufd_bad
    ## Media may have changed. Latch it for INT 13h AH=16h before the retry
    ## consumes the only notification we will get.
    cmp byte ptr cs:[uf_sense+12], 0x28
    jne .ufd_n28
    mov byte ptr cs:[uf_chg], 1
.ufd_n28:
    dec bp
    jnz .ufd_l
.ufd_bad:
    stc
    jmp .ufd_o
.ufd_ok:
    clc
.ufd_o:
    pop bp
    ret

## uf_reqsense -- REQUEST SENSE into uf_sense. Ignores its own status: asking
##                why something failed must not itself fail.
uf_reqsense:
    push ax
    push bx
    push cx
    push di
    push si
    push es
    push cs
    pop es
    ## PRESERVE THE EVIDENCE. This routine runs BECAUSE a command failed, and
    ## its own bulk transfer would otherwise overwrite the numbers that
    ## describe that failure -- which it did: the read reported "18 bytes
    ## outstanding", 18 being the length of REQUEST SENSE, not of a 512-byte
    ## sector. A diagnostic that reports on its own cleanup is worse than none,
    ## because it looks like a measurement of the thing that went wrong.
    mov ax, word ptr cs:[uf_bleft]
    mov word ptr cs:[uf_bsave], ax
    mov al, byte ptr cs:[uf_lastst]
    mov byte ptr cs:[uf_stsave], al
    mov word ptr cs:[uf_sense+2], 0
    mov word ptr cs:[uf_sense+12], 0
    mov si, offset uf_cdb_sense
    mov di, offset uf_sense
    mov cx, 18
    mov ah, 1
    call uf_once
    mov ax, word ptr cs:[uf_bsave]
    mov word ptr cs:[uf_bleft], ax
    mov al, byte ptr cs:[uf_stsave]
    mov byte ptr cs:[uf_lastst], al
    pop es
    pop si
    pop di
    pop cx
    pop bx
    pop ax
    clc
    ret

## uf_report -- repaint the B: line for a USB floppy. Reuses hd_detect's own
##              strings so the two lines stay in the same 21 columns.
uf_report:
    push ax
    push dx
    push si
    push di
    push ds
    push es
    mov ax, VID
    mov es, ax
    mov di, 9*160
    push cs
    pop ds
    mov si, offset b_fd2
    call dbg_str
    cmp word ptr cs:[uf_blocks], 0
    je .ufp_nomedia
    mov si, offset b_hd_ready
    call dbg_str
    call dbg_spc
    call dbg_spc
    mov ax, word ptr cs:[uf_blocks]
    shr ax, 1                    # blocks of 512 -> KB
    call dbg_dec
    mov si, offset b_hd_kb
    call dbg_str
    jmp short .ufp_tag
.ufp_nomedia:
    mov si, offset b_hd_no
    call dbg_str
    call dbg_spc
    ## The sense the drive gave for refusing. 3A is no medium, 27 is write
    ## protect, 28 is a medium change it has already announced. Without this
    ## "NOT READY" is the same silent absence the stage byte existed to fix.
    mov al, byte ptr cs:[uf_sense+2]
    and al, 0x0F
    call dbg_byte
    mov al, byte ptr cs:[uf_sense+12]
    call dbg_byte
    mov al, byte ptr cs:[uf_sense+13]
    call dbg_byte
.ufp_tag:
    mov si, offset b_usbfd
    call dbg_str
.ufp_pad:
    cmp di, 9*160 + 74*2         # blank the flash line's tail, which is
    jae .ufp_padded              # longer than this one and showed through
    mov al, 0x20
    mov ah, DBG_ATTR
    stosw
    jmp short .ufp_pad
.ufp_padded:
    pop es
    pop ds
    pop di
    pop si
    pop dx
    pop ax
    ret

## uf_wait -- CX times u_delay. u_delay is a SPIN LOOP, so this is a function
##            of the CPU clock; the counts below are chosen to be legal at the
##            fastest step on the ladder, which is what the bus reset needs.
uf_wait:
    push cx
.ufw_l:
    call u_delay
    loop .ufw_l
    pop cx
    ret

## The F-segment is full: .text had grown into .rtdata, and .font_rom cannot
## move because F000:FA6E is where every piece of software expects the 8x8 font
## to be. But 386 bytes sit unused between the end of that font and the reset
## vector -- M9K that shows through once POST clears ROM_EN.
##
## uf_enum and uf_find run ONCE, at POST, long after ROM_EN is cleared, so they
## are the right things to put there. Calls across the boundary are ordinary
## near calls within the same segment; only the link address differs.
## uf_enum -- bring up USB1 and find a UFI/CBI floppy. Sets uf_pres on success.
##            Every failure is silent and simply leaves uf_pres 0: a machine
##            with no USB floppy must behave exactly like one that never had
##            the code.
uf_enum:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    push cs
    pop es
    mov byte ptr cs:[uf_pres], 0
    mov byte ptr cs:[uf_stage], 1
    mov byte ptr cs:[uf_ep0], 8

    ## CTRL persists across resets and LINE reports the engine's SWAPPED view
    ## of the pins once low speed is set, so clear it before believing LINE.
    mov dx, UF_CTRL
    xor al, al
    out dx, al
    mov cx, 60
    call uf_wait
    mov dx, UF_CTRL
    in al, dx
    mov byte ptr cs:[uf_stage], 2   # LINE read
    test al, 0x04                # full-speed device idle J
    jz .ufe_no

    mov dx, UF_CTRL
    mov al, 0x02                 # BUSRESET
    out dx, al
    mov cx, 120                  # >= 10 ms at the fastest step
    call uf_wait
    mov dx, UF_CTRL
    mov al, 0x04                 # SOFEN
    out dx, al
    ## A floppy is a microcontroller with a motor and runs a self-test before
    ## it will answer. Too short a wait here reads as a dead device.
    mov cx, 900
    call uf_wait

    xor al, al
    mov dx, UF_ADDR
    out dx, al

    mov byte ptr cs:[uf_stage], 3   # bus reset done
    mov si, offset uf_sp_dev8
    mov di, offset uf_buf
    mov cx, 8
    call uf_ctlin
    jc .ufe_no
    mov al, byte ptr cs:[uf_buf+7]
    test al, al
    jz .ufe_no
    mov byte ptr cs:[uf_ep0], al

    mov byte ptr cs:[uf_stage], 4   # device descriptor read
    mov si, offset uf_sp_setaddr
    xor cx, cx
    call uf_ctlin
    jc .ufe_no
    mov cx, 60
    call uf_wait
    mov al, 1
    mov dx, UF_ADDR
    out dx, al

    mov byte ptr cs:[uf_stage], 5   # address assigned
    mov si, offset uf_sp_cfg9
    mov di, offset uf_buf
    mov cx, 9
    call uf_ctlin
    jc .ufe_no
    mov byte ptr cs:[uf_stage], 6       # 9-byte config header read OK
    mov ax, word ptr cs:[uf_buf+2]      # wTotalLength
    cmp ax, UF_BUFSZ
    jbe .ufe_fits
    mov ax, UF_BUFSZ
.ufe_fits:
    mov word ptr cs:[uf_cfglen], ax
    mov word ptr cs:[uf_sp_cfgn+6], ax
    mov si, offset uf_sp_cfgn
    mov di, offset uf_buf
    mov cx, ax
    call uf_ctlin
    jc .ufe_no

    mov byte ptr cs:[uf_stage], 7   # configuration read
    call uf_find
    jc .ufe_no

    mov byte ptr cs:[uf_stage], 8   # UFI/CBI interface + 3 endpoints found
    mov al, byte ptr cs:[uf_buf+5]      # bConfigurationValue
    mov byte ptr cs:[uf_sp_setcfg+2], al
    mov si, offset uf_sp_setcfg
    xor cx, cx
    call uf_ctlin
    jc .ufe_no
    ## A device is allowed to take its time over SET_CONFIGURATION, and this
    ## one does. 60 delays is about 16 ms; usbfdd waits a whole BIOS tick, at
    ## least 55 ms, and works every run. At 16 ms this succeeded on one boot
    ## and left the drive deaf on the next -- enumeration reporting success
    ## while every command after it returned no sense and no CBI status at
    ## all, which is what silence from a device that is not listening yet
    ## looks like.
    mov cx, 400                  # ~108 ms
    call uf_wait
    ## SET_CONFIGURATION resets every endpoint toggle to DATA0. Ours must
    ## match or the first bulk packet of the first read is discarded.
    mov byte ptr cs:[uf_tin], 0
    mov byte ptr cs:[uf_tout], 0
    mov byte ptr cs:[uf_stage], 9   # configured
    mov byte ptr cs:[uf_pres], 1
.ufe_no:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

.section .ufaux, "ax"

## uf_find -- walk the configuration for class 08 / subclass 04 / protocol 00
##            and its three endpoints. Walking by bLength, not by assuming a
##            layout, is what makes it safe to step over blocks we do not know.
uf_find:
    push ax
    push bx
    push cx
    push si
    mov si, offset uf_buf
    mov cx, word ptr cs:[uf_cfglen]
    mov byte ptr cs:[uf_cand], 0
    mov byte ptr cs:[uf_epin], 0
    mov byte ptr cs:[uf_epout], 0
    mov byte ptr cs:[uf_epint], 0
.uff_w:
    cmp cx, 2
    jb .uff_end
    mov al, byte ptr cs:[si]
    test al, al
    jz .uff_end
    xor ah, ah
    cmp ax, cx                   # 16-bit: a config over 255 bytes is normal
    ja .uff_end
    mov bl, byte ptr cs:[si+1]

    cmp bl, 4                    # INTERFACE
    jne .uff_ne
    mov byte ptr cs:[uf_cand], 0
    mov al, byte ptr cs:[si+5]
    cmp al, 0x08
    jne .uff_nx
    mov al, byte ptr cs:[si+6]
    cmp al, 0x04                 # UFI
    jne .uff_nx
    mov al, byte ptr cs:[si+7]
    cmp al, 0x00                 # CBI with command completion interrupt
    jne .uff_nx
    mov al, byte ptr cs:[si+2]
    mov byte ptr cs:[uf_iface], al
    mov byte ptr cs:[uf_cand], 1
    jmp .uff_nx

.uff_ne:
    cmp bl, 5                    # ENDPOINT
    jne .uff_nx
    cmp byte ptr cs:[uf_cand], 0
    je .uff_nx
    mov bl, byte ptr cs:[si+3]   # bmAttributes
    and bl, 0x03
    mov bh, byte ptr cs:[si+2]   # bEndpointAddress
    cmp bl, 0x02                 # bulk
    jne .uff_ni
    test bh, 0x80
    jz .uff_eo
    mov byte ptr cs:[uf_epin], bh
    jmp .uff_nx
.uff_eo:
    mov byte ptr cs:[uf_epout], bh
    jmp .uff_nx
.uff_ni:
    cmp bl, 0x03                 # interrupt
    jne .uff_nx
    test bh, 0x80
    jz .uff_nx
    mov byte ptr cs:[uf_epint], bh

.uff_nx:
    mov al, byte ptr cs:[si]
    xor ah, ah
    add si, ax
    sub cx, ax
    jmp .uff_w

.uff_end:
    ## All three are required. A missing interrupt endpoint means this is not
    ## CBI after all, and the status phase would wait for something that never
    ## arrives.
    cmp byte ptr cs:[uf_epin], 0
    je .uff_bad
    cmp byte ptr cs:[uf_epout], 0
    je .uff_bad
    cmp byte ptr cs:[uf_epint], 0
    je .uff_bad
    clc
    jmp .uff_o
.uff_bad:
    stc
.uff_o:
    pop si
    pop cx
    pop bx
    pop ax
    ret

.section .text

## uf_ready -- spin the drive up, wait for it, and learn the geometry.
##             Returns CF set if there is no usable medium.
##
##             720K and 1.44MB are ONE code path: the drive does the low-level
##             format and reports a block count, and 2880 -> 18 sectors while
##             1440 -> 9 is the only difference. Verified against a real
##             diskette's own BPB, which agreed.
uf_ready:
    push ax
    push bx
    push cx
    push si
    push di
    push es
    push cs
    pop es

    mov byte ptr cs:[uf_rstage], 1
    mov si, offset uf_cdb_start  # START STOP UNIT -- allowed to fail
    xor ah, ah
    call uf_do

    mov byte ptr cs:[uf_rstage], 2
    mov bx, 60                   # a MECHANISM, not a memory: it has to spin
                                 # up and find a medium before it can answer
.ufr_poll:
    mov si, offset uf_cdb_tur
    xor ah, ah
    call uf_do
    jnc .ufr_up
    push bx
    mov cx, 200                  # ~54 ms a try, so ~3.2 s in total
    call uf_wait
    pop bx
    dec bx
    jnz .ufr_poll
    jmp .ufr_bad
.ufr_up:
    mov byte ptr cs:[uf_rstage], 3      # the drive answered TEST UNIT READY
    mov si, offset uf_cdb_cap
    mov di, offset uf_buf
    mov cx, 8
    mov ah, 1
    call uf_do
    jc .ufr_bad
    ## READ CAPACITY gives the LAST LBA, big-endian. Blocks = last + 1. The
    ## high half must be zero: anything else is not a floppy.
    cmp word ptr cs:[uf_buf], 0
    jne .ufr_bad
    mov al, byte ptr cs:[uf_buf+2]
    mov ah, byte ptr cs:[uf_buf+3]
    xchg al, ah
    inc ax
    mov byte ptr cs:[uf_rstage], 4      # capacity read
    mov word ptr cs:[uf_blocks], ax
    mov byte ptr cs:[uf_nsec], 18
    cmp ax, 2880
    je .ufr_ok
    mov byte ptr cs:[uf_nsec], 9
    cmp ax, 1440
    je .ufr_ok
    mov byte ptr cs:[uf_nsec], 18       # unknown: assume the common one
.ufr_ok:
    clc
    jmp .ufr_o
.ufr_bad:
    stc
.ufr_o:
    pop es
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

## =====================================================================
##  uf_int13 -- the INT 13h face DOS sees for drive B: when a USB floppy
##  is attached. Entered with the caller's registers; returns with CF and AH
##  set the way a BIOS is expected to.
## =====================================================================
uf_int13:
    sti
    cld                          # STOSB/LODSB below; DF belongs to the caller
    cmp byte ptr cs:[uf_pres], 0
    je .u13_nodrv

    cmp ah, 0x02
    je .u13_rw
    cmp ah, 0x03
    je .u13_rw
    cmp ah, 0x00
    je .u13_reset
    cmp ah, 0x04
    je .u13_ok                   # verify: the read path already checks CRC
    cmp ah, 0x01
    je .u13_status
    cmp ah, 0x08
    je .u13_parm
    cmp ah, 0x15
    je .u13_type
    cmp ah, 0x16
    je .u13_chg
    cmp ah, 0xFE
    je .u13_diag
    jmp .u13_bad

.u13_diag:
    ## Vendor-specific, and DOS never calls it. The transport works at POST
    ## and fails from here, and nothing on the screen or in a BIOS error code
    ## says WHERE -- AH=20 only says the sense held nothing, which is the
    ## absence of evidence rather than any. B13 reads this.
    ##   AL = how far uf_ready got     AH = 0
    ##   BL = sense key   BH = sense ASC
    ##   CL = last CBI status ASC      CH = its ASCQ
    ##   DL = enumeration stage
    mov al, byte ptr cs:[uf_rstage]
    mov bl, byte ptr cs:[uf_sense+2]
    and bl, 0x0F
    mov bh, byte ptr cs:[uf_sense+12]
    mov cl, byte ptr cs:[uf_asc]
    mov ch, byte ptr cs:[uf_ascq]
    mov dl, byte ptr cs:[uf_stage]
    mov si, word ptr cs:[uf_bleft]      # bytes the last bulk did NOT move
    mov di, word ptr cs:[uf_lastst]     # and the status it stopped on
    xor ah, ah
    clc
    retf 2

.u13_reset:
    call uf_ready
    jc .u13_notready
.u13_ok:
    mov byte ptr cs:[uf_err], 0
    xor ah, ah
    clc
    retf 2
.u13_status:
    mov ah, byte ptr cs:[uf_err]
    cmp ah, 0
    je .u13_ok2
    stc
    retf 2
.u13_ok2:
    clc
    retf 2

.u13_parm:
    ## Geometry for the medium that is in it now. Cylinders are always 80 and
    ## heads always 2 on both formats; only sectors/track differ.
    mov ax, 79
    mov ch, al                   # max cylinder
    mov cl, byte ptr cs:[uf_nsec]
    mov dh, 1                    # max head
    mov dl, 1                    # one drive on this handler
    mov bl, 4                    # 1.44MB drive type
    cmp byte ptr cs:[uf_nsec], 9
    jne .u13_p1
    mov bl, 3                    # 720K
.u13_p1:
    xor ah, ah
    clc
    retf 2

.u13_type:
    mov ah, 2                    # floppy WITH change-line support
    clc
    retf 2

.u13_chg:
    ## AH=16h is what stops DOS writing a stale FAT onto a disk somebody
    ## swapped. uf_do latches every 28h (medium may have changed) it sees, and
    ## this reports and clears it. Without it a swapped diskette is corrupted
    ## on the first write, which is the one failure that destroys data.
    cmp byte ptr cs:[uf_chg], 0
    je .u13_nochg
    mov byte ptr cs:[uf_chg], 0
    mov ah, 0x06
    stc
    retf 2
.u13_nochg:
    xor ah, ah
    clc
    retf 2

.u13_rw:
    push bx
    push cx
    push dx
    push si
    push di
    push bp
    push es
    mov byte ptr cs:[uf_wr], 0
    cmp ah, 0x03
    jne .u13_r1
    mov byte ptr cs:[uf_wr], 1
.u13_r1:
    mov byte ptr cs:[uf_cnt], al        # sectors requested
    mov bp, bx                          # ES:BP walks the caller's buffer

    ## CHS -> LBA:  (cyl * 2 + head) * sectors + (sector - 1)
    mov al, ch
    xor ah, ah                          # cylinder (floppies never exceed 255)
    shl ax, 1
    mov bl, dh
    xor bh, bh
    add ax, bx                          # * heads + head
    mov bl, byte ptr cs:[uf_nsec]
    xor bh, bh
    mul bx
    mov bl, cl
    and bl, 0x3F                        # sector, 1-based
    xor bh, bh
    dec bx
    add ax, bx
    mov word ptr cs:[uf_lba], ax
    xor bx, bx                          # sectors done

.u13_loop:
    mov al, byte ptr cs:[uf_cnt]
    cmp bl, al
    jae .u13_done

    ## LBA and length are BIG-endian in READ(10)/WRITE(10), backwards from
    ## everything else an 8086 touches.
    mov ax, word ptr cs:[uf_lba]
    mov si, offset uf_cdb_rd
    cmp byte ptr cs:[uf_wr], 0
    je .u13_isrd
    mov si, offset uf_cdb_wr
.u13_isrd:
    mov byte ptr cs:[si+5], al
    mov byte ptr cs:[si+4], ah

    mov cx, 512
    cmp byte ptr cs:[uf_wr], 0
    jne .u13_dowr
    mov di, bp
    mov ah, 1
    call uf_do
    jmp .u13_after
.u13_dowr:
    push bx
    mov bx, bp
    mov ah, 2
    call uf_do
    pop bx
.u13_after:
    jc .u13_err
    inc word ptr cs:[uf_lba]
    add bp, 512
    inc bl
    jmp .u13_loop

.u13_done:
    mov byte ptr cs:[uf_err], 0
    pop es
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    mov al, byte ptr cs:[uf_cnt]
    xor ah, ah
    clc
    retf 2

.u13_err:
    ## Map the sense to something DOS understands. Write protect and media
    ## change are the two it acts on differently.
    mov ah, 0x20                        # controller failure, by default
    mov al, byte ptr cs:[uf_sense+12]
    cmp al, 0x27
    jne .u13_e1
    mov ah, 0x03                        # write protected
    jmp .u13_esave
.u13_e1:
    cmp al, 0x3A
    jne .u13_e2
    mov ah, 0x31                        # no media in drive
    jmp .u13_esave
.u13_e2:
    cmp al, 0x28
    jne .u13_esave
    mov ah, 0x06                        # media changed
.u13_esave:
    mov byte ptr cs:[uf_err], ah
    pop es
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    mov al, bl
    stc
    retf 2

.u13_notready:
    mov ah, 0x31
    mov byte ptr cs:[uf_err], ah
    stc
    retf 2
.u13_nodrv:
.u13_bad:
    mov ah, 0x01
    mov byte ptr cs:[uf_err], ah
    stc
    retf 2

.section .rtdata, "aw"
##  THE CHECKSUM BOUNDARY, BY NAME. POST sums 0xC000 up to here, so everything
##  below this label is runtime data and everything above it is fixed content.
##  It used to be "offset u_cbw", which was only accidentally right: the moment
##  mhz_buf was moved into this section it landed BEFORE u_cbw and stayed inside
##  the sum, and a serial boot and a flash boot went on disagreeing by exactly
##  0xD2 -- the populated MHz string -- through three rebuilds.
_rt_start:
mhz_buf:    .space 8            # POST writes the measured MHz string here
u_fast:     .byte 0              # 1 = the REP INSB path in u_bulk_in
u_cbw:      .space 31            # Command Block Wrapper
u_csw:      .space 13            # Command Status Wrapper
u_buf:      .space U_BUFSZ       # descriptors, sense data, capacity
u_cfglen:   .word 0              # wTotalLength of the configuration
u_reqtype:  .byte 0              # bmRequestType of the control transfer in flight

u_cdb_tur:   .byte 0x00,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
u_cdb_sense: .byte 0x03,0,0,0,18,0,0,0,0,0,0,0,0,0,0,0
u_cdb_cap:   .byte 0x25,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
u_cdb_rw:    .space 16

u_rq_dev8:    .byte 0x80,0x06,0x00,0x01,0x00,0x00,0x08,0x00
u_rq_cfg:     .byte 0x80,0x06,0x00,0x02,0x00,0x00,U_BUFSZ,0x00
u_rq_setaddr: .byte 0x00,0x05,0x01,0x00,0x00,0x00,0x00,0x00
u_rq_setcfg:  .byte 0x00,0x09,0x01,0x00,0x00,0x00,0x00,0x00
##  Bulk-Only Mass Storage Reset: class request to the interface, no data.
u_rq_botrst:  .byte 0x21,0xFF,0x00,0x00,0x00,0x00,0x00,0x00
##  CLEAR_FEATURE(ENDPOINT_HALT); byte 4 is patched with the endpoint address.
u_rq_clrhalt: .byte 0x02,0x01,0x00,0x00,0x00,0x00,0x00,0x00

##  EP0 max packet for the control transfer in flight, copied from BDA 0xC7 by
##  u_ctl. It belongs next to u_reqtype and is DELIBERATELY not there: mkbios.sh
##  verifies u_cdb_sense, u_cdb_cap and u_rq_dev8 at fixed offsets into this
##  section, and those offsets are set by whatever is declared above them. One
##  byte inserted before the tables moves all three and fails the build. Adding
##  scratch AFTER them costs nothing and keeps that check meaning what it says.
u_ep0sz:    .byte 8

.text

## ---------------------------------------------------------------------
##  usb_report -- one POST line for C:, in the original BIOS's register.
## ---------------------------------------------------------------------
usb_report:
    push ax
    push bx
    push ds
    push es
    push di
    push si
    mov ax, VID
    mov es, ax
    mov di, 10*160
    mov ax, BDA
    mov ds, ax
    mov bl, [0xC1]
    mov bh, [0xC0]
    push cs
    pop ds
    mov si, offset b_usb
    call dbg_str
    test bl, bl
    jz .ur_absent
    mov si, offset b_usb_ok
    call dbg_str
    # Capacity, not the CHS triple: the geometry is an INT 13h addressing
    # detail and 504 MB says more than 1024 x 16 x 63 does. The product
    # overflows 16 bits (1024 x 1008 = 1,032,192), so it must be taken as a
    # 32-bit DX:AX result; the divide by 2048 sectors/MB is safe because the
    # quotient is only ever a few hundred.
    push ds
    push bx
    push dx
    mov ax, BDA
    mov ds, ax
    mov al, [0xCE]               # heads
    xor ah, ah
    mov bl, [0xCF]               # sectors per track
    xor bh, bh
    mul bx                       # ax = sectors per cylinder
    mov bx, [0xCC]               # cylinders
    mul bx                       # dx:ax = total sectors
    mov bx, 2048                 # 2048 sectors of 512 bytes = 1 MB
    div bx                       # ax = megabytes
    pop dx
    pop bx
    pop ds
    call dbg_dec
    mov si, offset b_usb_mb
    call dbg_str
    jmp short .ur_out
.ur_absent:
    cmp bh, 0xF0
    jne .ur_stage
    mov si, offset b_usb_old
    call dbg_str
    jmp .ur_out
.ur_stage:
    mov si, offset b_usb_no
    call dbg_str
    mov al, bh                   # the stage it stopped at
    call dbg_byte
    # Show WHY, right here. A stage number says which step failed; these say
    # whether packets were being corrupted, ignored, or refused -- which is the
    # difference between a logic bug and a signalling problem, and there is no
    # way to run a DOS tool when the failure happens at POST.
    mov si, offset b_usb_sig
    call dbg_str
    mov al, 0x0F
    mov dx, 0xEF
    out dx, al
    in al, dx
    call dbg_byte
    mov si, offset b_usb_ev
    call dbg_str
    mov al, 1                    # diag index 1 = CRC/PID errors
    mov dx, 0xEF
    out dx, al
    in al, dx
    call dbg_byte
    mov al, 2                    # 2 = timeouts
    out dx, al
    in al, dx
    call dbg_byte
    mov al, 3                    # 3 = NAKs, low byte
    out dx, al
    in al, dx
    call dbg_byte
    mov al, 4                    # 4 = STALLs
    out dx, al
    in al, dx
    call dbg_byte
    # BUSY stalls: transactions the controller accepted and never finished.
    # With crc and tmo both zero, this and STALL are the only two ways a
    # transfer can fail, so they are the two worth showing.
    push ds
    mov ax, BDA
    mov ds, ax
    mov al, [0xDB]
    pop ds
    call dbg_byte                # dbg_byte preserves AX; only AL matters here
    # txn counts commands the sequencer ACCEPTED; frm counts 1 ms frames. With
    # every event counter at zero these separate the three possibilities that
    # look identical from DOS: the 48 MHz domain is dead (frm 00), the domain
    # runs but no command ever arrives (frm counts, txn 0000), or commands are
    # accepted and complete silently (both count).
    mov si, offset b_usb_txn
    call dbg_str
    mov dx, 0xEF
    mov al, 0x0B                 # transactions, high byte
    out dx, al
    in al, dx
    call dbg_byte
    mov al, 0x0A                 # transactions, low byte
    out dx, al
    in al, dx
    call dbg_byte
    mov si, offset b_usb_frm
    call dbg_str
    xor al, al                   # index 0 = frame counter
    out dx, al
    in al, dx
    call dbg_byte
    # The state below is latched only when a stall occurs. Printing it anyway
    # showed uninitialised bytes as though they were a reading, which is worse
    # than showing nothing.
    push ds
    push ax
    mov ax, BDA
    mov ds, ax
    mov al, [0xD5]
    pop ax
    pop ds
    test al, al
    jz .ur_out
    mov si, offset b_usb_st
    call dbg_str
    push ds
    mov ax, BDA
    mov ds, ax
    mov al, [0xD2]
    pop ds
    call dbg_byte
    call dbg_spc
    push ds
    mov ax, BDA
    mov ds, ax
    mov al, [0xD3]
    pop ds
    call dbg_byte
.ur_out:
    pop si
    pop di
    pop es
    pop ds
    pop bx
    pop ax
    ret

##  Boot order: A: (serial loader), then C: (USB disk), then B: (SPI flash).
##  Each entry is tried in turn: reset, read sector 1, require the 0xAA55
##  signature. Anything missing, unreadable or unsigned simply moves to the
##  next. Running out prints what the original Philips BIOS printed -- see
##  _int19's .boot_fail.
boot_order: .byte 0x00, 0x80, 0x01, 0xFF   # A:, C:, B:, end

##  Generated by mkbios.sh on every build; see the note there. Not committed.
.include "gitver.inc"
b_rel:    .asciz "Release 1.21  "
b_ver:    .asciz "Philips ROM BIOS Version 1.21"
b_model:  .asciz "Gertieboard BIOS Retirement Edition"
b_copy:   .asciz "2026 Mathijs van den Berg (mathijsvandenberg3@gmail.com)"
b_hdr:    .asciz "                     Total  Base Extra"
b_mem:    .asciz "System Memory Found:   640   640     0 Kbytes"
b_par:    .asciz "Parity Checking Enabled"
b_cpu:    .asciz "Processor          : "
b_cpu186: .asciz "80186 / V20 found  -  fast disk path"
b_cpu86:  .asciz "8088 found  -  compatible disk path"

##  The machine being imitated announced its own clock, and had two of them.
##  Its ROM carries both wordings verbatim:
##
##      System clock set to: Turbo 10 MHz
##      System clock set to: Standard 4.77 MHz
##
##  So this is the original's phrasing rather than an invention, and 10 MHz is
##  what the P2120 called turbo -- not an overclock, but the speed it was built
##  around. Confirmed from the P2120's own 27C256 dump.
##
##  THIS IS A CONSTANT, NOT A MEASUREMENT. There is no speed register on this
##  board to read and nothing to poll: c0 is fixed by the PLL at synthesis time.
##  Edit it by hand when c0 changes, and keep it in step with clkgen-pll.md.
##  Two other places already carry the rate that way -- WAITSTAT's CLKSCALE and
##  fdc8272's CLK_FREQ generic -- and both have been wrong at some point today,
##  so treat a disagreement between this line and reality as the likely fault
##  rather than as something to explain away.
b_clk:    .asciz "System clock set to: "
b_mhz:    .asciz " MHz"
b_fd1:     .asciz "Diskette Drive A:  : "   # 21 columns, like B: and the disk
b_boot:   .asciz "Booting..."
b_sum:    .asciz "   code "
b_usb:     .asciz "Internal Hard Disk : "   # the original ROM's own wording, 0x1F39
b_usb_ok:  .asciz "Ready  "
b_usb_mb:  .asciz " MB"
b_usb_no:  .asciz "None stage "
b_usb_ev:  .asciz " c/t/n/s/b "
b_usb_sig: .asciz " fpga "
b_usb_txn: .asciz " txn "
b_usb_frm: .asciz " frm "
b_usb_st:  .asciz "  txseq/flags "
b_usb_old: .asciz "FPGA image is older than this BIOS - reprogram it"
b_fd2:     .asciz "Diskette Drive B:  : "   # same 21 columns, so the two lines align
b_usbfd:   .asciz "  USB floppy"
b_hd_ready:.asciz "Ready"
b_hd_no:   .asciz "NOT READY"
b_hd_kb:   .asciz " KB"
b_hd_idl:  .asciz "  ("
b_hd_idr:  .asciz ")"

msg_ver:      .asciz "Philips ROM BIOS Version 1.21\r\n"
msg_model:    .asciz "Gertieboard BIOS Retirement Edition\r\n"
msg_copy:     .asciz "2026 Mathijs van den Berg (mathijsvandenberg3@gmail.com)\r\n\r\n"
msg_memhdr:   .asciz "                     Total  Base Extra\r\n"
msg_memfound: .asciz "System Memory Found:   "
msg_3sp:      .asciz "   "
msg_extra0:   .asciz "     0 Kbytes\r\n"
msg_parity:   .asciz "Parity Checking Enabled\r\n\r\n"
msg_drive:    .asciz "Using 5.25\" 360K as Drive A:\r\n\r\n"
msg_boot:     .asciz "Booting...\r\n"
msg_bootfail: .asciz "\r\nBoot Error.\r\n"
msg_i10test:  .asciz "INT10-OK"
msg_reboot:   .asciz "Press Ctrl-Alt-Del to Reboot ... \r\n"

## =====================================================================
##  THE 8x8 FONT AT ITS IBM ADDRESS, F000:FA6E.
##
##  Placed by the linker via the .font_rom section, because the ADDRESS is
##  the entire point: on a real IBM PC the 8x8 graphics font for characters
##  0..127 lives at exactly F000:FA6E, and software that wants a glyph
##  bitmap of its own reads it from there DIRECTLY. INT 43h names the same
##  table, but plenty of code never looks at the vector.
##
##  King's Quest is one of them, and it cost a whole debugging round to see
##  it. Its interpreter draws inverse video -- the status bar, the menus,
##  every text window -- by copying the ROM glyph from a HARDCODED F000:FA6E
##  into a private buffer, XOR-ing it with 0xFFFF, and then handing that
##  buffer to INT 10h through the INT 43h vector. This ROM had a perfectly
##  good font at font8x8 and NOTHING at 0xFA6E, so what it copied was 1 KB of
##  zeros; inverted, every character became all-ones and painted as a SOLID
##  BLOCK. The status bar came out as a clean white strip with no letters in
##  it and the File menu as blank rows -- which reads like "the text is
##  missing" and is really "the font it asked for was not there".
##
##  Only 0..127. That is all a real machine has here, and 0xFA6E + 256*8
##  would run past the end of the segment anyway. font8x8 keeps the full 256
##  and stays the target of INT 43h, so g_render is unaffected -- this is an
##  ALIAS of the low half, not a move.
## =====================================================================
.section .font_rom, "a"
font8x8_rom:
    .incbin "font8x8.bin", 0, 1024

## =====================================================================
##  Tail of ROM:  reset vector, date, model byte, checksum
##  Placed by the linker via the .reset section at 0xFFF0.
## =====================================================================
.section .reset, "ax"
_reset:
    .byte 0xEA              # jmp F000:_post   (FFF0-FFF4)
    .word _post
    .word 0xF000
    .ascii "06/19/26"       # 8-byte date     (FFF5-FFFC)
    .byte 0x00              # pad             (FFFD)
    .byte 0xFE              # model byte = PC/XT (FFFE)
    .byte 0x00              # checksum / pad  (FFFF)

## ---- USB floppy (drive B: when present) -----------------------------
## Re-declared explicitly: appended at the END of the file, this block would
## otherwise land in whatever section was last opened -- which is .reset, all
## sixteen bytes of it at 0xFFF0, and every reference truncated against it.
## It goes at the end of .rtdata so mkbios.sh's fixed table offsets, which it
## re-derives and checks, are undisturbed.
.section .rtdata, "aw"
uf_pres:    .byte 0
uf_ep0:     .byte 8
uf_epin:    .byte 0
uf_epout:   .byte 0
uf_epint:   .byte 0
uf_tin:     .byte 0
uf_tout:    .byte 0
uf_iface:   .byte 0
uf_cand:    .byte 0
uf_ctog:    .byte 0
uf_dir:     .byte 0
uf_dup:     .byte 0
uf_wr:      .byte 0
uf_cnt:     .byte 0
uf_err:     .byte 0
uf_chg:     .byte 0
uf_nsec:    .byte 18
uf_stage:   .byte 0
uf_rqt:     .byte 0
uf_rstage:  .byte 0
uf_lastst:  .byte 0
uf_bleft:   .word 0
uf_bsave:   .word 0
uf_stsave:  .byte 0
uf_dsave:   .byte 0
uf_asc:     .byte 0
uf_ascq:    .byte 0
uf_blocks:  .word 0
uf_cfglen:  .word 0
uf_lba:     .word 0
uf_sense:   .space 20
uf_buf:     .space UF_BUFSZ

uf_sp_dev8:    .byte 0x80,6,0x00,1,0,0,8,0
uf_sp_setaddr: .byte 0x00,5,1,0,0,0,0,0
uf_sp_cfg9:    .byte 0x80,6,0x00,2,0,0,9,0
uf_sp_cfgn:    .byte 0x80,6,0x00,2,0,0,0,0
uf_sp_setcfg:  .byte 0x00,9,1,0,0,0,0,0
uf_sp_adsc:    .byte 0x21,0x00,0,0,0,0,12,0
uf_cdb_tur:    .byte 0x00,0,0,0,0,0,0,0,0,0,0,0
uf_cdb_sense:  .byte 0x03,0,0,0,18,0,0,0,0,0,0,0
uf_cdb_cap:    .byte 0x25,0,0,0,0,0,0,0,0,0,0,0
uf_cdb_start:  .byte 0x1B,0,0,0,0x01,0,0,0,0,0,0,0
uf_cdb_rd:     .byte 0x28,0,0,0,0,0,0,0,1,0,0,0
uf_cdb_wr:     .byte 0x2A,0,0,0,0,0,0,0,1,0,0,0
