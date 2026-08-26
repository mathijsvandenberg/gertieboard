; modplay.asm -- ProTracker .MOD player for the Gertieboard.
;
;   modplay file.mod
;
; Four channels mixed in software to 8-bit mono at 11025 Hz, streamed to the
; Sound Blaster DSP at 220h on DMA channel 1 with auto-init.
;
; WHY THE MIXER IS SHAPED THE WAY IT IS
;
;   4 channels x 11025 Hz is 44100 sample-operations a second, and this is a
;   10 MHz V20 with an 8-bit bus. A multiply per sample is not affordable -- so
;   volume is a LOOKUP: voltab[vol*256 + sample], 64 levels of 256 bytes, built
;   once at startup. XLAT does the whole scaling in one instruction.
;
;   Channels are mixed ONE AT A TIME across the whole buffer, additively, not
;   all four per output sample. That way ES holds one sample's segment for a
;   whole pass instead of being reloaded four times per output sample, and a
;   segment register reload is not cheap here.
;
;   The accumulator is 16-bit signed. Four channels of +/-128 cannot exceed
;   +/-512, so it cannot overflow, and the >>2 at the end is exact rather than
;   a clamp that quietly distorts loud passages.
;
; THE DMA BUFFER MUST NOT CROSS A 64 KB PHYSICAL BOUNDARY. The 8237 counts
; within a page and wraps rather than carrying, so a buffer straddling one
; plays its own beginning again halfway through. The allocation below asks for
; twice what it needs and picks a half that is clear -- the standard dodge, and
; cheaper than being clever.
;
; Mixing happens into whichever half of the buffer the DMA is NOT reading,
; decided by asking the 8237 where it has got to. No interrupt is needed for
; that, and polling means no handler to get wrong before there is any music.

CPU 8086
org 0x100

section .text

; ---- Sound Blaster ---------------------------------------------------------
SB      equ 0x220
RESETP  equ SB+6
READP   equ SB+0x0A
WRITEP  equ SB+0x0C
RSTATP  equ SB+0x0E

MIXRATE equ 11025
TCONST  equ 256 - (1000000 / MIXRATE)

; ---- buffer geometry -------------------------------------------------------
HALF    equ 1024                ; samples per half, ~93 ms
BUFLEN  equ HALF*2

; ---- Amiga PAL clock / 2, for period -> frequency --------------------------
PALHI   equ 0x0036
PALLO   equ 0x1F0F              ; 0x00361F0F = 3546895

start:
        mov  sp, stacktop
        ; DOS hands a .COM ALL free memory, so no allocation can succeed until
        ; some of it goes back. Without this every AH=48h below fails and the
        ; player reports "not enough memory" on a machine with 600 KB free.
        ; ES is still the PSP here, which is what AH=4Ah wants.
        ; stacktop is an address, not a scalar, so the paragraph count is
        ; rounded and shifted at run time rather than by the assembler. With
        ; org 0x100 it already counts from the segment base, PSP included.
        mov  bx, stacktop + 15
        mov  cl, 4
        shr  bx, cl
        mov  ah, 0x4A
        int  0x21

        mov  dx, msg_hdr
        call puts

        call getname
        jc   .usage
        call loadmod
        jc   .loadfail
        call buildvol
        call allocdma
        jc   .nodma
        call sbinit
        jc   .nosb

        call play

        call sbstop
        mov  dx, msg_bye
        call puts
        mov  ax, 0x4C00
        int  0x21

.usage:
        mov  dx, msg_usage
        call puts
        jmp  .die
.loadfail:
        mov  dx, [errmsg]
        call puts
        jmp  .die
.nodma:
        mov  dx, msg_nomem
        call puts
        jmp  .die
.nosb:
        mov  dx, msg_nosb
        call puts
.die:
        mov  ax, 0x4C01
        int  0x21

; ============================================================================
;  Command line -> fname (ASCIIZ)
; ============================================================================
getname:
        mov  si, 0x81
        mov  di, fname
        xor  cx, cx
.skip:
        lodsb
        cmp  al, ' '
        je   .skip
        cmp  al, 9
        je   .skip
        cmp  al, 13
        je   .none
.copy:
        stosb
        inc  cx
        lodsb
        cmp  al, ' '
        je   .end
        cmp  al, 13
        jne  .copy
.end:
        xor  al, al
        stosb
        test cx, cx
        jz   .none
        clc
        ret
.none:
        stc
        ret

; ============================================================================
;  loadmod -- read the file, parse the header, load patterns and samples
;
;  Sample data goes into its OWN allocated block per sample, so a sample is
;  addressed as one segment plus a 16-bit offset and the mixer never has to
;  think about crossing a segment. ProTracker samples are at most 64 KB, so
;  this always fits.
; ============================================================================
loadmod:
        mov  dx, fname
        mov  ax, 0x3D00
        int  0x21
        jnc  .opened
        mov  word [errmsg], msg_e_open
        stc
        ret
.opened:
        mov  [fh], ax

        ; ---- 1084-byte header ----
        mov  bx, [fh]
        mov  cx, 1084
        mov  dx, hdr
        mov  ah, 0x3F
        int  0x21
        jc   .short
        cmp  ax, 1084
        je   .hdrok
.short:
        mov  word [errmsg], msg_e_short
        stc
        ret
.hdrok:

        ; signature must be M.K. (or 4CHN/FLT4 -- all 4-channel)
        mov  ax, [hdr+1080]
        cmp  ax, 'M.'
        je   .sigok
        cmp  ax, '4C'
        je   .sigok
        cmp  ax, 'FL'
        je   .sigok
        mov  word [errmsg], msg_e_sig
        stc
        ret
.sigok:

        ; ---- 31 sample headers, 30 bytes each from offset 20 ----
        ; Lengths, repeat offsets and repeat lengths are all in WORDS and
        ; big-endian. Doubling them to bytes is why every one goes through
        ; bswap-and-shift rather than a plain load.
        mov  si, hdr+20
        xor  bx, bx                     ; sample index
.sloop:
        mov  ax, [si+22]                ; length, words, big-endian
        xchg al, ah
        shl  ax, 1
        mov  [s_len+bx], ax

        mov  al, [si+24]
        and  al, 0x0F
        mov  [s_fine+bx], al            ; (parsed; finetune unused for now)

        mov  al, [si+25]
        cmp  al, 64
        jbe  .volok
        mov  al, 64
.volok:
        mov  [s_vol+bx], al

        mov  ax, [si+26]                ; repeat offset, words
        xchg al, ah
        shl  ax, 1
        mov  [s_rep+bx], ax

        mov  ax, [si+28]                ; repeat length, words
        xchg al, ah
        shl  ax, 1
        mov  [s_replen+bx], ax

        add  si, 30
        add  bx, 2
        cmp  bx, 62
        jb   .sloop

        ; ---- song length, order table ----
        mov  al, [hdr+950]
        mov  [songlen], al

        ; highest pattern number in the order table decides how many to read
        xor  ah, ah
        mov  si, hdr+952
        mov  cx, 128
        xor  bl, bl
.hpat:
        lodsb
        cmp  al, bl
        jbe  .nothigh
        mov  bl, al
.nothigh:
        loop .hpat
        inc  bl
        mov  [npat], bl

        ; ---- patterns: npat * 1024 bytes, into their own block ----
        mov  al, [npat]
        xor  ah, ah
        mov  cl, 6                      ; 1024 bytes = 64 paragraphs each
        shl  ax, cl                     ; paragraphs needed
        mov  bx, ax
        mov  ah, 0x48
        int  0x21
        jc   .bad
        mov  [patseg], ax

        ; One pattern at a time into its own 64-paragraph slot. Reading the
        ; lot in one call would need a byte count, and npat*1024 reaches 128 KB
        ; on a long module -- which does not fit in CX at all.
        xor  bp, bp
.pread:
        mov  al, [npat]
        xor  ah, ah
        cmp  bp, ax
        jae  .pdone
        mov  ax, bp
        mov  cl, 6
        shl  ax, cl                     ; pattern * 64 paragraphs
        add  ax, [patseg]
        push ds
        mov  ds, ax
        xor  dx, dx
        mov  cx, 1024
        mov  bx, [cs:fh]
        mov  ah, 0x3F
        int  0x21
        pop  ds
        jc   .bad
        inc  bp
        jmp  .pread
.pdone:

        ; ---- sample data, one block each ----
        xor  bx, bx
.dloop:
        mov  ax, [s_len+bx]
        mov  [s_seg+bx], 0
        cmp  ax, 2                      ; length 0 or 1 word = no sample
        jbe  .dnext

        add  ax, 15
        mov  cl, 4
        shr  ax, cl                     ; bytes -> paragraphs
        push bx
        mov  bx, ax
        mov  ah, 0x48
        int  0x21
        pop  bx
        jc   .bad
        mov  [s_seg+bx], ax

        push ds
        mov  cx, [s_len+bx]
        mov  ds, ax
        xor  dx, dx
        mov  bx, [cs:fh]
        mov  ah, 0x3F
        int  0x21
        pop  ds
.dnext:
        add  bx, 2
        cmp  bx, 62
        jb   .dloop

        mov  bx, [fh]
        mov  ah, 0x3E
        int  0x21

        ; ---- report ----
        mov  dx, msg_title
        call puts
        mov  si, hdr
        mov  cx, 20
.tname:
        lodsb
        test al, al
        jz   .tdone
        cmp  al, ' '
        jb   .tskip
        mov  dl, al
        mov  ah, 2
        int  0x21
.tskip:
        loop .tname
.tdone:
        mov  dx, msg_crlf
        call puts

        mov  dx, msg_pats
        call puts
        mov  al, [npat]
        xor  ah, ah
        call putdec
        mov  dx, msg_pos
        call puts
        mov  al, [songlen]
        xor  ah, ah
        call putdec
        mov  dx, msg_crlf
        call puts
        clc
        ret
.bad:
        mov  word [errmsg], msg_e_mem
        stc
        ret

; ============================================================================
;  buildvol -- voltab[v*256 + s] = s * v / 64, signed
;
;  16 KB, built once. Everything the mixer does to a sample is this table.
; ============================================================================
buildvol:
        push ds
        pop  es
        mov  di, voltab
        xor  bx, bx                     ; volume level 0..63
        mov  cl, 6                      ; shift count, constant for the whole
                                        ; build -- CX cannot also be the loop
                                        ; counter, which is what DX is for
.vloop:
        xor  dx, dx                     ; sample value 0..255
.sloop2:
        mov  al, dl
        imul bl                         ; AL is read as SIGNED, which is what a
                                        ; MOD sample is. AX = sample * vol.
        sar  ax, cl                     ; / 64
        stosb
        inc  dx
        cmp  dx, 256
        jb   .sloop2
        inc  bx
        cmp  bx, 64
        jb   .vloop
        ret

; ============================================================================
;  allocdma -- a BUFLEN buffer guaranteed not to cross a 64 KB boundary
; ============================================================================
allocdma:
        mov  bx, (BUFLEN*2)/16 + 1
        mov  ah, 0x48
        int  0x21
        jc   .bad
        mov  [dmaseg], ax

        ; physical address of the block
        mov  dx, ax
        mov  cl, 12
        mov  bx, dx
        shr  bx, cl                     ; page
        mov  cl, 4
        shl  dx, cl                     ; offset in page
        ; if the buffer would run past the end of this page, start at the
        ; next page instead -- there is room, we asked for double.
        mov  ax, dx
        add  ax, BUFLEN
        jnc  .fits
        ; carry means it crossed: move to the next page boundary
        inc  bl
        xor  dx, dx
.fits:
        mov  [dmaphys], dx
        mov  [dmapage], bl
        ; the offset within our allocated segment that corresponds to dmaphys
        mov  ax, [dmaseg]
        mov  cl, 4
        shl  ax, cl
        mov  bx, dx
        sub  bx, ax
        mov  [dmaoff], bx
        clc
        ret
.bad:
        mov  word [errmsg], msg_e_mem
        stc
        ret

; ============================================================================
;  sbinit -- reset the DSP, check it, set the rate, start auto-init DMA
; ============================================================================
sbinit:
        mov  dx, RESETP
        mov  al, 1
        out  dx, al
        mov  cx, 100
.w1:    in   al, 0x80
        loop .w1
        xor  al, al
        out  dx, al
        mov  cx, 1000
.w2:    mov  dx, RSTATP
        in   al, dx
        test al, 0x80
        jnz  .got
        loop .w2
        stc
        ret
.got:
        mov  dx, READP
        in   al, dx
        cmp  al, 0xAA
        je   .ok
        stc
        ret
.ok:
        ; silence the buffer before anything can play it
        push es
        mov  es, [dmaseg]
        mov  di, [dmaoff]
        mov  cx, BUFLEN
        mov  al, 0x80
        rep  stosb
        pop  es

        ; ---- 8237 channel 1, auto-init, read from memory ----
        mov  al, 0x05
        out  0x0A, al                   ; mask ch1
        xor  al, al
        out  0x0C, al                   ; clear byte pointer
        mov  al, 0x59                   ; auto-init, read from memory, ch1
        out  0x0B, al
        mov  ax, [dmaphys]
        out  0x02, al
        mov  al, ah
        out  0x02, al
        mov  al, [dmapage]
        out  0x83, al
        mov  ax, BUFLEN-1
        out  0x03, al
        mov  al, ah
        out  0x03, al
        mov  al, 0x01
        out  0x0A, al                   ; unmask

        mov  al, 0xD1                   ; speaker on
        call dspwr
        mov  al, 0x40                   ; time constant
        call dspwr
        mov  al, TCONST
        call dspwr
        mov  al, 0x48                   ; auto-init block length
        call dspwr
        mov  ax, BUFLEN-1
        call dspwr
        mov  al, ah
        call dspwr
        mov  al, 0x1C                   ; auto-init 8-bit DMA output
        call dspwr
        clc
        ret

sbstop:
        mov  al, 0xD0                   ; halt DMA
        call dspwr
        mov  al, 0xD3                   ; speaker off
        call dspwr
        mov  al, 0x05
        out  0x0A, al                   ; mask ch1
        mov  dx, RESETP                 ; and reset, so the next program finds
        mov  al, 1                      ; the card idle rather than streaming
        out  dx, al
        mov  cx, 100
.w:     in   al, 0x80
        loop .w
        xor  al, al
        out  dx, al
        ret

; ============================================================================
;  play -- the main loop
; ============================================================================
play:
        mov  byte [pos], 0
        mov  byte [row], 0
        mov  byte [speed], 6
        mov  byte [tickno], 0
        mov  word [tickcnt], 0
        mov  byte [lasthalf], 0xFF
        mov  dx, msg_playing
        call puts

.loop:
        ; ---- which half is the DMA reading? ----
        xor  al, al
        out  0x0C, al
        in   al, 0x03
        mov  bl, al
        in   al, 0x03
        mov  bh, al
        ; count counts DOWN from BUFLEN-1, so >= HALF means it is in the FIRST
        ; half and the second is free to write.
        xor  al, al
        cmp  bx, HALF
        jb   .insecond
        mov  al, 1                      ; DMA in first half -> fill second
.insecond:
        cmp  al, [lasthalf]
        je   .nofill
        mov  [lasthalf], al
        call fillhalf
.nofill:

        ; ---- keys ----
        mov  ah, 1
        int  0x16
        jz   .loop
        mov  ah, 0
        int  0x16
        cmp  al, 27
        je   .quit
        cmp  al, ' '
        jne  .loop
        xor  byte [paused], 1
        jmp  .loop
.quit:
        ret

; ----------------------------------------------------------------------------
;  fillhalf -- mix one half-buffer, running the sequencer as it goes
; ----------------------------------------------------------------------------
fillhalf:
        push es
        ; clear the 16-bit accumulator
        push ds
        pop  es
        mov  di, accum
        mov  cx, HALF
        xor  ax, ax
        rep  stosw

        mov  word [filled], 0
.chunk:
        ; how many samples until the next tick?
        mov  ax, [tickcnt]
        test ax, ax
        jnz  .havetick
        call dotick
        mov  ax, [tickcnt]
.havetick:
        mov  bx, HALF
        sub  bx, [filled]
        jz   .mixdone
        cmp  ax, bx
        jbe  .usea
        mov  ax, bx
.usea:
        mov  [chunklen], ax
        sub  [tickcnt], ax
        call mixchunk
        mov  ax, [chunklen]
        add  [filled], ax
        cmp  word [filled], HALF
        jb   .chunk
.mixdone:

        ; ---- accumulator -> 8-bit unsigned, into the free half ----
        mov  es, [dmaseg]
        mov  di, [dmaoff]
        cmp  byte [lasthalf], 1
        jne  .firsthalf                 ; lasthalf=1: DMA is reading the FIRST
        add  di, HALF                   ; half, so write the second
.firsthalf:
        mov  si, accum
        mov  cx, HALF
.conv:
        lodsw
        sar  ax, 1
        sar  ax, 1                      ; /4: four channels of +/-128
        add  ax, 128
        stosb
        loop .conv
        pop  es
        ret

; ----------------------------------------------------------------------------
;  mixchunk -- add [chunklen] samples of all four channels into the accumulator
; ----------------------------------------------------------------------------
mixchunk:
        xor  bp, bp                     ; channel index * 2
.chan:
        mov  bx, bp
        mov  ax, [ch_seg+bx]
        test ax, ax
        jz   .nextch                    ; nothing playing here
        mov  cx, [ch_len+bx]
        test cx, cx
        jz   .nextch

        push bp
        mov  es, ax

        ; voltab row for this channel's volume
        mov  al, [ch_vol+bp]
        xor  ah, ah
        mov  cl, 8
        shl  ax, cl
        add  ax, voltab
        mov  [tabptr], ax

        mov  si, [ch_pos_h+bp]
        mov  ax, [ch_pos_l+bp]
        mov  [tmp_lo], ax
        mov  di, accum
        mov  ax, [chunklen]
        mov  [tmp_cnt], ax
.smp:
        cmp  si, [ch_len+bp]
        jb   .inrange
        ; past the end: loop if the sample has a repeat, else stop it
        mov  ax, [ch_replen+bp]
        cmp  ax, 2
        jbe  .stop
        mov  ax, [ch_rep+bp]
        mov  si, ax
        jmp  .inrange
.stop:
        mov  word [ch_seg+bp], 0
        jmp  .chdone
.inrange:
        mov  al, [es:si]
        mov  bx, [tabptr]
        xlat                            ; DS:BX + AL
        cbw
        add  [di], ax
        inc  di
        inc  di

        mov  ax, [tmp_lo]
        add  ax, [ch_step_l+bp]
        mov  [tmp_lo], ax
        mov  ax, [ch_step_h+bp]
        adc  si, ax

        dec  word [tmp_cnt]
        jnz  .smp
.chdone:
        mov  [ch_pos_h+bp], si
        mov  ax, [tmp_lo]
        mov  [ch_pos_l+bp], ax
        pop  bp
.nextch:
        add  bp, 2
        cmp  bp, 8
        jb   .chan
        ret

; ----------------------------------------------------------------------------
;  dotick -- one tick of the sequencer. New row every [speed] ticks.
; ----------------------------------------------------------------------------
dotick:
        mov  ax, [samptick]
        mov  [tickcnt], ax

        cmp  byte [paused], 0
        jne  .ret

        mov  al, [tickno]
        test al, al
        jnz  .fx
        call dorow
        inc  byte [tickno]
        ret
.fx:
        call doeffects
        inc  byte [tickno]
        mov  al, [tickno]
        cmp  al, [speed]
        jb   .ret
        mov  byte [tickno], 0
.ret:
        ret

; ----------------------------------------------------------------------------
;  dorow -- read the four notes of the current row and act on them
; ----------------------------------------------------------------------------
dorow:
        ; pattern = order[pos]; row data at patseg:(pat*1024 + row*16)
        ; pattern -> its own segment, row -> a 16-bit offset inside it. Doing
        ; it this way rather than pat*1024 as a flat offset is what lets a
        ; module have more than 63 patterns.
        mov  bl, [pos]
        xor  bh, bh
        mov  al, [hdr+952+bx]
        xor  ah, ah
        mov  cl, 6
        shl  ax, cl
        add  ax, [patseg]
        mov  [patcur], ax
        mov  bl, [row]
        xor  bh, bh
        mov  cl, 4
        shl  bx, cl
        mov  [rowoff], bx

        mov  byte [brk], 0
        mov  byte [brkflag], 0          ; a break TO ROW 0 is legal and common,
        mov  byte [jmpto], 0xFF         ; so the row cannot also be the flag

        push es
        mov  es, [patcur]
        mov  si, [rowoff]
        xor  bp, bp
.ch:
        ; four bytes: sample-hi/period-hi, period-lo, sample-lo/effect, param
        mov  al, [es:si]
        mov  ah, [es:si+1]
        mov  bl, al
        and  bl, 0x0F
        mov  bh, ah
        xchg bl, bh
        mov  [period], bx               ; 12-bit period

        mov  al, [es:si]
        and  al, 0xF0
        mov  cl, [es:si+2]
        mov  ch, cl
        and  ch, 0xF0
        mov  cl, 4
        shr  ch, cl
        or   al, ch                     ; sample number 0..31
        mov  [smpno], al

        mov  al, [es:si+2]
        and  al, 0x0F
        mov  [ch_eff+bp], al
        mov  al, [es:si+3]
        mov  [ch_par+bp], al

        call trigger

        add  si, 4
        add  bp, 2
        cmp  bp, 8
        jb   .ch
        pop  es

        call rowfx

        ; ---- advance ----
        cmp  byte [jmpto], 0xFF
        je   .nojump
        mov  al, [jmpto]
        mov  [pos], al
        mov  byte [row], 0
        jmp  .checkend
.nojump:
        cmp  byte [brkflag], 0
        je   .nextrow
        mov  al, [brk]
        mov  [row], al
        inc  byte [pos]
        jmp  .checkend
.nextrow:
        inc  byte [row]
        cmp  byte [row], 64
        jb   .done
        mov  byte [row], 0
        inc  byte [pos]
.checkend:
        mov  al, [pos]
        cmp  al, [songlen]
        jb   .done
        mov  byte [pos], 0              ; loop the song
.done:
        call showpos
        ret

; ----------------------------------------------------------------------------
;  trigger -- a new sample and/or period on channel BP
; ----------------------------------------------------------------------------
trigger:
        push bp
        mov  al, [smpno]
        test al, al
        jz   .noinst
        dec  al
        xor  ah, ah
        shl  ax, 1
        mov  bx, ax                     ; sample index * 2
        mov  ax, [s_seg+bx]
        mov  [ch_smpseg+bp], ax
        mov  ax, [s_len+bx]
        mov  [ch_len+bp], ax
        mov  ax, [s_rep+bx]
        mov  [ch_rep+bp], ax
        mov  ax, [s_replen+bx]
        mov  [ch_replen+bp], ax
        mov  al, [s_vol+bx]
        mov  [ch_vol+bp], al
.noinst:
        mov  ax, [period]
        test ax, ax
        jz   .noper
        mov  [ch_period+bp], ax
        ; a note restarts the sample from the top
        mov  ax, [ch_smpseg+bp]
        mov  [ch_seg+bp], ax
        mov  word [ch_pos_h+bp], 0
        mov  word [ch_pos_l+bp], 0
        call setstep
.noper:
        pop  bp
        ret

; ----------------------------------------------------------------------------
;  setstep -- period -> 16.16 step for channel BP
;
;    freq = 3546895 / period          (PAL Amiga clock / 2)
;    step = freq / MIXRATE, in 16.16
;
;  Done as an integer divide followed by a second divide of the remainder
;  shifted up 16, because freq/MIXRATE can exceed 1.0 -- at the top of the
;  range it is nearly 3 -- and a single 32/16 divide would overflow.
; ----------------------------------------------------------------------------
setstep:
        mov  bx, [ch_period+bp]
        cmp  bx, 108
        jae  .perok
        mov  bx, 108                    ; clamp: below this the divide overflows
.perok:
        mov  dx, PALHI
        mov  ax, PALLO
        div  bx                         ; AX = frequency
        xor  dx, dx
        mov  bx, MIXRATE
        div  bx                         ; AX = integer part, DX = remainder
        mov  [ch_step_h+bp], ax
        mov  ax, 0
        ; DX already holds the remainder: DX:AX is remainder << 16
        div  bx
        mov  [ch_step_l+bp], ax
        ret

; ----------------------------------------------------------------------------
;  rowfx -- tick-0 effects (the ones that act once, when the row is read)
; ----------------------------------------------------------------------------
rowfx:
        xor  bp, bp
.ch:
        mov  al, [ch_eff+bp]
        mov  ah, [ch_par+bp]

        cmp  al, 0x0C                   ; Cxx set volume
        jne  .n_c
        cmp  ah, 64
        jbe  .cok
        mov  ah, 64
.cok:
        mov  [ch_vol+bp], ah
.n_c:
        cmp  al, 0x0F                   ; Fxx speed / tempo
        jne  .n_f
        test ah, ah
        jz   .n_f
        cmp  ah, 32
        jae  .bpm
        mov  [speed], ah
        jmp  .n_f
.bpm:
        mov  [bpm], ah
        call setbpm
.n_f:
        cmp  al, 0x0B                   ; Bxx position jump
        jne  .n_b
        mov  [jmpto], ah
.n_b:
        cmp  al, 0x0D                   ; Dxx pattern break (parameter is BCD)
        jne  .n_d
        mov  al, ah
        mov  cl, 4
        shr  al, cl
        mov  ch, al
        add  ch, ch                     ; *2
        mov  al, ch
        add  al, al
        add  al, al                     ; *8  -> tens*8
        add  al, ch                     ; + tens*2  = tens*10
        mov  ch, ah
        and  ch, 0x0F
        add  al, ch
        cmp  al, 64
        jb   .dok
        xor  al, al
.dok:
        mov  [brk], al
        mov  byte [brkflag], 1
.n_d:
        add  bp, 2
        cmp  bp, 8
        jb   .ch
        ret

; ----------------------------------------------------------------------------
;  doeffects -- per-tick effects (ticks 1..speed-1)
; ----------------------------------------------------------------------------
doeffects:
        xor  bp, bp
.ch:
        mov  al, [ch_eff+bp]
        mov  ah, [ch_par+bp]

        cmp  al, 0x01                   ; 1xx portamento up
        jne  .n_1
        mov  bl, ah
        xor  bh, bh
        mov  ax, [ch_period+bp]
        sub  ax, bx
        cmp  ax, 113
        jae  .p1ok
        mov  ax, 113
.p1ok:
        mov  [ch_period+bp], ax
        call setstep
        jmp  .next
.n_1:
        cmp  al, 0x02                   ; 2xx portamento down
        jne  .n_2
        mov  bl, ah
        xor  bh, bh
        mov  ax, [ch_period+bp]
        add  ax, bx
        cmp  ax, 856
        jbe  .p2ok
        mov  ax, 856
.p2ok:
        mov  [ch_period+bp], ax
        call setstep
        jmp  .next
.n_2:
        cmp  al, 0x0A                   ; Axy volume slide
        jne  .next
        mov  al, ah
        mov  cl, 4
        shr  al, cl                     ; x = up
        mov  bl, ah
        and  bl, 0x0F                   ; y = down
        mov  ch, [ch_vol+bp]
        test al, al
        jz   .slidedn
        add  ch, al
        cmp  ch, 64
        jbe  .vset
        mov  ch, 64
        jmp  .vset
.slidedn:
        sub  ch, bl
        jnc  .vset
        xor  ch, ch
.vset:
        mov  [ch_vol+bp], ch
.next:
        add  bp, 2
        cmp  bp, 8
        jb   .ch
        ret

; ----------------------------------------------------------------------------
;  setbpm -- samples per tick = MIXRATE * 2.5 / bpm = MIXRATE*5 / (bpm*2)
; ----------------------------------------------------------------------------
setbpm:
        mov  al, [bpm]
        xor  ah, ah
        add  ax, ax
        mov  bx, ax                     ; bpm * 2
        mov  dx, (MIXRATE*5) >> 16
        mov  ax, (MIXRATE*5) & 0xFFFF
        div  bx
        mov  [samptick], ax
        ret

; ----------------------------------------------------------------------------
;  showpos -- one line of status, rewritten in place
; ----------------------------------------------------------------------------
showpos:
        mov  dx, msg_cr
        call puts
        mov  dx, msg_p
        call puts
        mov  al, [pos]
        xor  ah, ah
        call putdec
        mov  dx, msg_slash
        call puts
        mov  al, [songlen]
        xor  ah, ah
        call putdec
        mov  dx, msg_r
        call puts
        mov  al, [row]
        xor  ah, ah
        call putdec
        mov  dx, msg_sp
        call puts
        ret

; ============================================================================
;  DSP write -- poll bit 7 of the write port, then send
; ============================================================================
dspwr:
        push ax
        push cx
        push dx
        mov  cx, 4000
        mov  dx, WRITEP
.w:     in   al, dx
        test al, 0x80
        jz   .ready
        loop .w
.ready:
        pop  dx
        pop  cx
        pop  ax
        push dx
        mov  dx, WRITEP
        out  dx, al
        pop  dx
        ret

; ============================================================================
;  text helpers
; ============================================================================
puts:
        push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

putdec:
        push ax
        push bx
        push cx
        push dx
        mov  bx, 10
        xor  cx, cx
.dv:    xor  dx, dx
        div  bx
        push dx
        inc  cx
        test ax, ax
        jnz  .dv
.pr:    pop  dx
        add  dl, '0'
        mov  ah, 2
        int  0x21
        loop .pr
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ============================================================================
;  data
; ============================================================================
fname     times 80 db 0
fh        dw 0
errmsg    dw 0
patseg    dw 0
dmaseg    dw 0
dmaphys   dw 0
dmapage   db 0
dmaoff    dw 0

songlen   db 0
npat      db 0
pos       db 0
row       db 0
speed     db 6
bpm       db 125
tickno    db 0
tickcnt   dw 0
samptick  dw 220
paused    db 0
lasthalf  db 0xFF
filled    dw 0
chunklen  dw 0
rowoff    dw 0
patcur    dw 0
period    dw 0
smpno     db 0
brk       db 0
brkflag   db 0
jmpto     db 0xFF
tabptr    dw 0
tmp_lo    dw 0
tmp_cnt   dw 0

s_len     times 31 dw 0
s_fine    times 31 db 0
s_vol     times 31 db 0
s_rep     times 31 dw 0
s_replen  times 31 dw 0
s_seg     times 31 dw 0

ch_seg    times 4 dw 0
ch_smpseg times 4 dw 0
ch_pos_h  times 4 dw 0
ch_pos_l  times 4 dw 0
ch_step_h times 4 dw 0
ch_step_l times 4 dw 0
ch_len    times 4 dw 0
ch_rep    times 4 dw 0
ch_replen times 4 dw 0
ch_vol    times 4 db 0
ch_period times 4 dw 0
ch_eff    times 4 db 0
ch_par    times 4 db 0

msg_hdr     db 'MODPLAY - ProTracker 4-channel, Sound Blaster at 220h',13,10,'$'
msg_usage   db 'usage: modplay file.mod',13,10,'$'
msg_e_open  db 'cannot open that file - check the name and that it is on the disk',13,10,'$'
msg_e_short db 'file is too short to be a MOD - the header is 1084 bytes',13,10,'$'
msg_e_sig   db 'not a 4-channel MOD - no M.K., 4CHN or FLT4 signature at 1080',13,10,'$'
msg_e_mem   db 'out of memory loading patterns or samples',13,10,'$'
msg_nomem   db 'not enough memory for the DMA buffer',13,10,'$'
msg_nosb    db 'no Sound Blaster answered at 220h',13,10,'$'
msg_title   db 'title    : $'
msg_pats    db 'patterns : $'
msg_pos     db '   positions : $'
msg_playing db 'playing - SPACE pauses, ESC quits',13,10,'$'
msg_bye     db 13,10,'stopped.',13,10,'$'
msg_crlf    db 13,10,'$'
msg_cr      db 13,'$'
msg_p       db 'pos $'
msg_slash   db '/$'
msg_r       db '  row $'
msg_sp      db '    $'

section .bss
; ---- uninitialised, and deliberately NOT in the file --------------------
; buildvol fills voltab, the file read fills hdr, and accum is cleared every
; pass -- so emitting 20 KB of zeros only makes the .COM 20 KB longer to load
; and to store. NASM's flat binary output drops trailing reserved space, which
; takes this from 23 KB to under 5.
hdr       resb 1084             ; the whole MOD header: the order table at +952
                                ; is read on every row, so it stays resident
accum     resw HALF             ; 16-bit mixing accumulator
          alignb 256            ; XLAT needs the table 256-aligned per row
voltab    resb 64*256
          resb 512
stacktop:
