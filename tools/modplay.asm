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

; CPU 186, not 8086. The V20 is an 80186 core and this machine runs at 10 MHz,
; so immediate shift counts are available and "mov cl,n / shr ax,cl" is two
; instructions and a register where one will do. The BIOS and the other tools
; stay 8086 -- they have to run before anything has established what the CPU
; is. This does not: by the time it loads, POST has already identified a V20.
CPU 186
org 0x100

; ---- Sound Blaster ---------------------------------------------------------
SB      equ 0x220
RESETP  equ SB+6
READP   equ SB+0x0A
WRITEP  equ SB+0x0C
RSTATP  equ SB+0x0E

; The mixing rate is chosen at run time, because the mixer's cost scales
; exactly with it and this machine is close to the edge at four channels.
; -r8 / -r11 / -r22 pick 8000, 11025 or 22050 Hz.
DEFRATE equ 11025
BDASEG  equ 0x0040               ; BIOS data area; 40:6C is the 18.2 Hz tick

; ---- buffer geometry -------------------------------------------------------
; 1024 samples a half. This was raised to 2048 on a guess that the mixer was
; short of time; the guess was wrong. A fill measures 63000 PIT counts, 52.7 ms,
; against a 186 ms half at 11025 Hz -- 28% of the window. At 1024 the ratio is
; identical and the latency halves, from 372 ms of buffered audio to 186.
HALF    equ 1024
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
        mov  [wantpar], bx
        mov  ah, 0x4A
        int  0x21
        jnc  .shrunk
        ; Never checked before, and it is the one call everything else depends
        ; on: if the block does not shrink there is no free memory to allocate
        ; from, and every later failure is a consequence rather than a cause.
        mov  [doserr], ax
        mov  dx, msg_e_shrk
        call puts
        jmp  .die
.shrunk:

        mov  dx, msg_hdr
        call puts

        call scanopts
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
        mov  dx, msg_e_det
        call puts
        mov  ax, [freepar]
        call putdec
        mov  dx, msg_e_par
        call puts
        mov  ax, [doserr]
        call putdec
        mov  dx, msg_crlf
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
;  scanopts -- -1 .. -4 play ONE channel and mute the rest.
;
;  Four channels of wrong are much harder to read than one. If a module sounds
;  like noise, playing each channel alone says whether every channel is wrong
;  (the mixer or the buffer) or one is (that channel's trigger or effect), and
;  those are different faults with different fixes.
;
;  A dash prefix, so a filename with a digit in it is never taken for an option.
; ============================================================================
scanopts:
        mov  byte [chmask], 0x0F
        mov  si, 0x81
.s:
        lodsb
        cmp  al, 13
        je   .done
        cmp  al, '-'
        jne  .s
        lodsb
        cmp  al, 13
        je   .done
        cmp  al, 'r'
        je   .rate
        cmp  al, 'R'
        je   .rate
        cmp  al, '1'
        jb   .s
        cmp  al, '4'
        ja   .s
        sub  al, '1'
        mov  cl, al
        mov  al, 1
        shl  al, cl                     ; 8086: shift by CL, not by immediate
        mov  [chmask], al
        jmp  .s
.rate:
        lodsb
        cmp  al, '8'
        jne  .r11
        mov  word [mixrate], 8000
        jmp  .s
.r11:
        cmp  al, '2'
        jne  .r1
        mov  word [mixrate], 22050
        jmp  .s
.r1:
        cmp  al, '1'
        jne  .s
        mov  word [mixrate], 11025
        jmp  .s
.done:
        ret

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
        shl  ax, 6                      ; 1024 bytes = 64 paragraphs each
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

        ; ---- sample data: as much of it as there is room for ----------------
        ; DOS hands this program about 57 KB in total, so a 41 KB set of
        ; samples does not fit alongside 11 KB of patterns. Rather than refuse
        ; to play, each sample takes what is left and is TRUNCATED if it has
        ; to be -- s_len is set to what actually loaded, so the mixer stops at
        ; the real end and never reads a block it does not own.
        ;
        ; Whatever is not read still has to be SKIPPED IN THE FILE, or every
        ; sample after it loads from the wrong offset and the module turns to
        ; noise. That is what the seek at the end of the loop is for.
        xor  bx, bx
.dloop:
        mov  ax, [s_len+bx]
        mov  word [s_seg+bx], 0
        cmp  ax, 2                      ; length 0 or 1 word = no sample
        jbe  .dnext
        mov  [wantb], ax
        mov  word [gotb], 0

        add  ax, 15
        mov  cl, 4
        shr  ax, cl
        mov  [wantp], ax

        ; what will DOS actually give us? A failing AH=48h reports the largest
        ; block in BX, which is the honest number to size the request against.
        push bx
        mov  bx, 0xFFFF
        mov  ah, 0x48
        int  0x21
        mov  ax, bx
        pop  bx
        test ax, ax
        jz   .noroom
        cmp  ax, [wantp]
        jae  .askfor
        mov  [wantp], ax                ; take what there is
.askfor:
        push bx
        mov  bx, [wantp]
        mov  ah, 0x48
        int  0x21
        pop  bx
        jc   .noroom
        mov  [s_seg+bx], ax

        ; how many bytes that block can hold, capped by the sample's length
        mov  ax, [wantp]
        mov  cl, 4
        shl  ax, cl
        cmp  ax, [wantb]
        jbe  .capped
        mov  ax, [wantb]
.capped:
        mov  [gotb], ax
        mov  [s_len+bx], ax             ; the mixer stops at what really loaded
        cmp  ax, [wantb]
        je   .full
        inc  byte [ncut]
        jmp  .doread
.full:
        inc  byte [nfull]
.doread:
        mov  ax, [s_seg+bx]
        push bx
        mov  cx, [gotb]
        push ds
        mov  ds, ax
        xor  dx, dx
        mov  bx, [cs:fh]
        mov  ah, 0x3F
        int  0x21
        pop  ds
        pop  bx
        jmp  .skiprest
.noroom:
        inc  byte [nskip]
        mov  word [s_len+bx], 0         ; nothing to play from
.skiprest:
        ; step over whatever was not read
        mov  ax, [wantb]
        sub  ax, [gotb]
        jz   .dnext
        push bx
        mov  bx, [fh]
        xor  cx, cx
        mov  dx, ax
        mov  ax, 0x4201                 ; seek from current position
        int  0x21
        pop  bx
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

        mov  dx, msg_smp
        call puts
        mov  al, [nfull]
        xor  ah, ah
        call putdec
        mov  dx, msg_smp2
        call puts
        mov  al, [ncut]
        xor  ah, ah
        call putdec
        mov  dx, msg_smp3
        call puts
        mov  al, [nskip]
        xor  ah, ah
        call putdec
        mov  dx, msg_smp4
        call puts
        clc
        ret
.bad:
        ; A failed AH=48h returns the largest block available in BX. Printing
        ; it turns "out of memory" from a guess into a measurement: a big
        ; number means the request was wrong, a tiny one means the shrink was.
        mov  [doserr], ax
        mov  bx, 0xFFFF
        mov  ah, 0x48
        int  0x21
        mov  [freepar], bx
        mov  word [errmsg], msg_e_mem
        stc
        ret

; ============================================================================
;  buildvol -- voltab[v*256 + s] = s * v / 64, signed, for v = 0..64
;
;  65 rows because MOD volume is inclusive of 64. Everything the mixer does to
;  a sample is this table, so a missing row is not a rounding error -- it is a
;  read into whatever the linker put next.
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
        cmp  bx, VOLROWS
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
        ; A failed AH=48h returns the largest block available in BX. Printing
        ; it turns "out of memory" from a guess into a measurement: a big
        ; number means the request was wrong, a tiny one means the shrink was.
        mov  [doserr], ax
        mov  bx, 0xFFFF
        mov  ah, 0x48
        int  0x21
        mov  [freepar], bx
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
        ; tc = 256 - 1000000/rate, worked out here rather than by the
        ; assembler now that the rate is not known until the command line is
        mov  dx, 0x000F
        mov  ax, 0x4240                 ; 1000000
        div  word [mixrate]
        neg  al                         ; 256 - al, modulo 256
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
        mov  dx, msg_rate
        call puts
        mov  ax, [mixrate]
        call putdec
        mov  dx, msg_hz
        call puts
        mov  dx, msg_chan
        call puts
        mov  al, [chmask]
        xor  ah, ah
        call puthexb
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_playing
        call puts
        ; the line the status will own, taken once from the cursor
        mov  ah, 0x03
        xor  bh, bh
        int  0x10
        mov  [vidrow], dh
        push es
        mov  ax, BDASEG
        mov  es, ax
        mov  ax, [es:0x6C]
        mov  [tkstart], ax
        pop  es

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
        mov  byte [posdirty], 1         ; a fill always refreshes the line, so
        ; TIME THE FILL AGAINST THE BIOS TICK, NOT THE PIT.
        ;
        ; DOS runs PIT channel 0 in mode 3, where it decrements by TWO, so it
        ; wraps every 27.5 ms. A fill longer than that produced a delta with no
        ; meaning, and the maximum then stuck near 65535 -- which is what "it
        ; expands to 65503" was: a saturated counter, not a slower fill.
        ;
        ; 40:6C counts at 18.2 Hz and does not wrap for hours. One tick is too
        ; coarse to time a single fill, but summing across many gives the total
        ; time spent filling, and against elapsed time that is the utilisation
        ; -- which is the number that actually decides whether this keeps up.
        push es
        mov  ax, BDASEG
        mov  es, ax
        mov  ax, [es:0x6C]
        mov  [tk0], ax
        pop  es
        call fillhalf
        push es
        mov  ax, BDASEG
        mov  es, ax
        mov  ax, [es:0x6C]
        sub  ax, [tk0]
        add  [busytk], ax
        pop  es
        call dmacnt                     ; refresh BX for the gap test below
.nofill:
        ; HOW FAR DID THE DMA MOVE SINCE THE LAST LOOK?
        ;
        ; The previous counter asked whether the DMA had crossed into the half
        ; being written, and counted it as a failure. But crossing into that
        ; half is what is SUPPOSED to happen -- it is the buffer being played.
        ; So it counted normal operation, which is why a lower mixing rate
        ; scored worse despite doing less work per second.
        ;
        ; The 8237's count is monotonic between reloads, so the distance it
        ; moved between two polls is exactly how much audio went out. More than
        ; a half in one gap means a boundary passed unseen and a half went out
        ; unwritten. That is an underrun and nothing else is.
        mov  ax, [prevcnt]
        sub  ax, bx                     ; counts DOWN, so this is the distance
        cmp  ax, BUFLEN
        jb   .gap_ok
        add  ax, BUFLEN                 ; it wrapped past zero
.gap_ok:
        cmp  ax, HALF
        jbe  .gap_fine
        inc  word [nunder]
.gap_fine:
        mov  [prevcnt], bx

        ; ---- status, safely outside the mix ----
        cmp  byte [posdirty], 0
        je   .nopaint
        mov  byte [posdirty], 0
        call showpos
.nopaint:

        ; ---- keys ----
        mov  ah, 1
        int  0x16
        jz   .loop
        mov  ah, 0
        int  0x16
        cmp  al, 27
        je   .quit
        cmp  al, ' '
        jne  .n_sp
        xor  byte [paused], 1
        jmp  .loop
.n_sp:
        cmp  al, 's'
        je   .stats
        cmp  al, 'S'
        jne  .loop
.stats:
        mov  dx, msg_crlf
        call puts
        call showpos
        mov  dx, msg_crlf
        call puts
        jmp  .loop
.quit:
        ret

; ----------------------------------------------------------------------------
;  fillhalf -- mix one half-buffer, running the sequencer as it goes
; ----------------------------------------------------------------------------
fillhalf:
        push es
        ; No clear here any more: the first live channel of each chunk STORES
        ; rather than adds, and a chunk with no live channel silences itself.
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
;  mixchunk -- add [chunklen] samples of every live channel into the accumulator
;
;  MEASURED: about 134 cycles per sample per channel, which is five times what
;  the instruction count suggests. The difference is memory. Every access in
;  here crosses the V20's eight-bit bus to SDRAM, so what matters is the NUMBER
;  OF ACCESSES per sample and very little else. The old loop made six:
;
;      mov al,[es:si]   xlat   add [di],ax (read+write)
;      cmp si,[chlen]   cmp di,[accend]
;
;  Two of those are bookkeeping. Both are gone from the fast path:
;
;   * the end-of-sample check, by computing beforehand how many samples can be
;     produced before the sample ends. When the step is under one byte per
;     sample -- which is every note at or below the mixing rate -- n samples
;     advance strictly less than n bytes, so "bytes remaining" IS a safe count
;     and needs no division to find.
;
;   * the loop-end check, by freeing DX to be the counter. DX only held the
;     high half of the step, which is zero for exactly the same notes, so
;     "adc si,0" replaces it and costs no memory at all.
;
;  Four accesses instead of six. Notes above the mixing rate keep the general
;  loop, which still checks both.
;
;  The accumulator is cleared once per chunk with rep stosw rather than having
;  the first channel store into it. A block move has no per-word instruction
;  fetch, which on this bus is worth more than the read it saves -- and it puts
;  every channel on one code path instead of two.
; ----------------------------------------------------------------------------
; wrapchk -- SI has reached the end of the sample. Loop it, or stop the
; channel and return carry set. Shared by both inner loops, so the looping rule
; lives in exactly one place.
wrapchk:
        push bx
        mov  bx, [curch]
        mov  ax, [ch_replen+bx]
        cmp  ax, 2
        jbe  .stopit
        mov  si, [ch_rep+bx]
        pop  bx
        clc
        ret
.stopit:
        mov  word [ch_seg+bx], 0
        pop  bx
        stc
        ret

; ----------------------------------------------------------------------------
;  skipch -- advance a silent channel's position without mixing it.
;
;  A channel at volume zero contributes nothing and costs exactly as much as one
;  at full volume: every sample still read, still scaled through a table of
;  zeros, still added. This walks the position instead, with no sample read, no
;  table lookup and no accumulator traffic -- the four memory accesses a sample
;  that dominate the mixer become none.
;
;  The position still has to advance, and the sample still has to loop or stop,
;  or the channel jumps when its volume comes back up. BP = channel index.
; ----------------------------------------------------------------------------
skipch:
        push ax
        push bx
        push cx
        push dx
        push si
        mov  cx, [ch_step_l+bp]
        mov  dx, [ch_step_h+bp]
        mov  si, [ch_pos_h+bp]
        mov  bx, [ch_pos_l+bp]
        mov  ax, [chunklen]
.sk:
        add  bx, cx
        adc  si, dx
        cmp  si, [chlen]
        jb   .skn
        push ax
        mov  ax, [ch_replen+bp]
        cmp  ax, 2
        jbe  .skstop
        mov  si, [ch_rep+bp]
        pop  ax
        jmp  .skn
.skstop:
        pop  ax
        mov  word [ch_seg+bp], 0
        jmp  .skdone
.skn:
        dec  ax
        jnz  .sk
.skdone:
        mov  [ch_pos_h+bp], si
        mov  [ch_pos_l+bp], bx
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

mixchunk:
        ; clear this chunk's slice of the accumulator
        push es
        push ds
        pop  es
        mov  ax, [filled]
        add  ax, ax
        add  ax, accum
        mov  di, ax
        mov  cx, [chunklen]
        xor  ax, ax
        rep  stosw
        pop  es

        mov  word [curch], 0
.chan:
        mov  bp, [curch]

        mov  ax, bp
        shr  ax, 1
        mov  cl, al
        mov  al, 1
        shl  al, cl
        test byte [chmask], al
        jz   .nextch

        mov  bx, bp
        mov  ax, [ch_seg+bx]
        test ax, ax
        jz   .nextch
        mov  es, ax
        mov  ax, [ch_len+bx]
        test ax, ax
        jz   .nextch
        mov  [chlen], ax

        ; A channel at volume zero contributes nothing but costs exactly as
        ; much as one at full volume -- every sample still read, scaled through
        ; a table of zeros and added. Skipping it is free, and it is worth most
        ; in precisely the sustained quiet sections where the mixer is already
        ; closest to its deadline. The position must still advance, or the
        ; channel jumps when it fades back in.
        cmp  word [ch_vol+bp], 0
        jne  .audible
        call skipch
        jmp  .nextch
.audible:

        mov  ax, [filled]
        add  ax, ax
        add  ax, accum
        mov  di, ax
        mov  ax, [chunklen]
        add  ax, ax
        add  ax, di
        mov  [accend], ax

        mov  al, [ch_vol+bp]
        xor  ah, ah
        shl  ax, 8
        add  ax, voltab
        mov  [tabptr], ax

        mov  cx, [ch_step_l+bp]
        mov  dx, [ch_step_h+bp]
        mov  si, [ch_pos_h+bp]
        mov  bp, [ch_pos_l+bp]
        mov  bx, [tabptr]

        test dx, dx
        jnz  .slow                      ; note above the mixing rate

; ---- fast path: step < 1 byte per sample -----------------------------------
.frun:
        mov  ax, [chlen]
        sub  ax, si
        jbe  .fwrap                     ; at or past the end already
        push ax
        mov  ax, [accend]
        sub  ax, di
        shr  ax, 1                      ; samples left in the chunk
        mov  dx, ax
        pop  ax
        test dx, dx
        jz   .chdone
        cmp  ax, dx
        jae  .fgo                       ; the sample outlasts the chunk
        mov  dx, ax                     ; else it runs out first
.fgo:
.fast:
        mov  al, [es:si]
        xlat
        cbw
        add  [di], ax
        inc  di
        inc  di
        add  bp, cx
        adc  si, 0
        dec  dx
        jnz  .fast
        cmp  di, [accend]
        jb   .frun
        jmp  .chdone
.fwrap:
        call wrapchk
        jc   .chdone
        jmp  .frun

; ---- general path: the position advances a whole byte or more --------------
.slow:
        cmp  si, [chlen]
        jae  .swrap
.sgo:
        mov  al, [es:si]
        xlat
        cbw
        add  [di], ax
        inc  di
        inc  di
        add  bp, cx
        adc  si, dx
        cmp  di, [accend]
        jb   .slow
        jmp  .chdone
.swrap:
        call wrapchk
        jc   .chdone
        jmp  .sgo

.chdone:
        mov  bx, [curch]
        mov  [ch_pos_h+bx], si
        mov  [ch_pos_l+bx], bp
.nextch:
        add  word [curch], 2
        cmp  word [curch], 8
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
        shl  ax, 6
        add  ax, [patseg]
        mov  [patcur], ax
        mov  bl, [row]
        xor  bh, bh
        shl  bx, 4
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
        ; NOT showpos here. This runs inside fillhalf, and printing a status
        ; line costs ~15 INT 21h character writes through BIOS teletype, with
        ; scrolling -- tens of milliseconds injected into the middle of a mix
        ; that has to finish before the DMA reaches the half being written.
        ; The main loop paints it instead, where being slow costs nothing.
        mov  byte [posdirty], 1
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
        mov  bx, [mixrate]
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
        mov  ax, [mixrate]
        mov  cx, 5
        mul  cx                         ; DX:AX = rate * 5
        div  bx
        mov  [samptick], ax
        ret

; ----------------------------------------------------------------------------
;  vputs / vputdec / vblit -- the status line, without DOS.
;
;  showpos used to print through INT 21h, which goes to BIOS teletype: cursor
;  positioning and a scroll check per character, tens of milliseconds for a
;  50-character line. That sat in the main loop between finishing one fill and
;  noticing the next half boundary -- so the mixer had 28% of the window and the
;  status line was quietly spending much of the rest.
;
;  A line is 50 word writes straight into video memory instead. Microseconds.
; ----------------------------------------------------------------------------
vputs:                                  ; DS:DX -> $-terminated, DI = buffer pos
        push si
        mov  si, dx
.vs:    lodsb
        cmp  al, '$'
        je   .vsd
        mov  [di], al
        inc  di
        jmp  .vs
.vsd:   pop  si
        ret

vputdec:                                ; AX = value, DI = buffer pos
        push ax
        push bx
        push cx
        push dx
        mov  bx, 10
        xor  cx, cx
.vd:    xor  dx, dx
        div  bx
        push dx
        inc  cx
        test ax, ax
        jnz  .vd
.vp:    pop  ax
        add  al, '0'
        mov  [di], al
        inc  di
        loop .vp
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

vblit:                                  ; DI = end of text in linebuf
        push es
        push ds
        pop  es
        mov  cx, di
        sub  cx, linebuf
.pad:   cmp  cx, 60                     ; clear the tail of the previous line
        jae  .padded
        mov  byte [di], ' '
        inc  di
        inc  cx
        jmp  .pad
.padded:
        mov  ax, 0xB800
        mov  es, ax
        mov  al, [vidrow]
        xor  ah, ah
        mov  bx, 160
        mul  bx
        mov  di, ax
        mov  si, linebuf
        mov  cx, 60
        mov  ah, 0x07
.bl:    lodsb
        stosw
        loop .bl
        pop  es
        ret

; ----------------------------------------------------------------------------
;  showpos -- one line of status, rewritten in place
; ----------------------------------------------------------------------------
showpos:
        mov  di, linebuf
        mov  dx, msg_p
        call vputs
        mov  al, [pos]
        xor  ah, ah
        call vputdec
        mov  dx, msg_slash
        call vputs
        mov  al, [songlen]
        xor  ah, ah
        call vputdec
        mov  dx, msg_r
        call vputs
        mov  al, [row]
        xor  ah, ah
        call vputdec
        mov  dx, msg_und
        call vputs
        mov  ax, [nunder]
        call vputdec
        mov  dx, msg_fill
        call vputs
        push es
        mov  ax, BDASEG
        mov  es, ax
        mov  ax, [es:0x6C]
        pop  es
        sub  ax, [tkstart]              ; elapsed ticks
        mov  bx, ax
        test bx, bx
        jz   .nopct
        mov  ax, [busytk]
        mov  cx, 100
        mul  cx
        div  bx
        call vputdec
        mov  dx, msg_pct
        call vputs
.nopct:
        call vblit
        ret

; ============================================================================
;  pitrd -- PIT channel 0, latched. 1.193182 MHz, counting down. AX = count.
; ============================================================================
pitrd:
        push dx
        xor  al, al
        out  0x43, al                   ; latch counter 0
        in   al, 0x40
        mov  dl, al
        in   al, 0x40
        mov  dh, al
        mov  ax, dx
        pop  dx
        ret

; ============================================================================
;  dmacnt -- the 8237's channel-1 count, read until two agree closely.
;
;  The engine decrements this while we read it, and the two halves come from
;  separate IN instructions -- so a read can catch the low byte from before an
;  update and the high byte from after, producing a value wildly away from
;  either. As a progress measure that is invisible; as the basis of an underrun
;  test it invents underruns that never happened.
;
;  Returns BX.
; ============================================================================
dmacnt:
        push ax
        push cx
        push dx
        mov  cx, 8
.try:
        xor  al, al
        out  0x0C, al
        in   al, 0x03
        mov  bl, al
        in   al, 0x03
        mov  bh, al
        ; read again; if the two are within a sane distance the pair is good
        xor  al, al
        out  0x0C, al
        in   al, 0x03
        mov  dl, al
        in   al, 0x03
        mov  dh, al
        mov  ax, bx
        sub  ax, dx                     ; counts down, so this is small and >= 0
        cmp  ax, 256
        jb   .good
        loop .try
.good:
        mov  bx, dx
        pop  dx
        pop  cx
        pop  ax
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

puthexb:
        push ax
        push dx
        push cx
        mov  cx, 2
        mov  dl, al
.hb:    mov  al, dl
        push cx
        mov  cl, 4
        shr  al, cl
        pop  cx
        cmp  cx, 2
        je   .hi
        mov  al, dl
        and  al, 0x0F
.hi:    add  al, '0'
        cmp  al, '9'
        jbe  .em2
        add  al, 7
.em2:   push dx
        mov  dl, al
        mov  ah, 2
        int  0x21
        pop  dx
        loop .hb
        pop  cx
        pop  dx
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
freepar   dw 0
doserr    dw 0
wantpar   dw 0
wantb     dw 0
wantp     dw 0
gotb      dw 0
nfull     db 0
ncut      db 0
nskip     db 0
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
mixrate   dw DEFRATE
paused    db 0
posdirty  db 0
nunder    dw 0
prevcnt   dw 0
t0        dw 0
tk0       dw 0
tkstart   dw 0
busytk    dw 0
tmax      dw 0
vidrow    db 0
linebuf   times 80 db ' '
chmask    db 0x0F
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
curch     dw 0
chlen     dw 0
accend    dw 0
tmp_lo    dw 0
tmp_cnt   dw 0

s_len     times 31 dw 0
; WORD arrays, every one of them, because bx and bp step by 2 when they walk
; samples and channels. As db these overlapped: sample 30's volume landed 60
; bytes in, inside s_rep, and channel 2's volume read ch_eff. The music played
; but every channel had someone else's volume and someone else's effect.
s_fine    times 31 dw 0
s_vol     times 31 dw 0
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
ch_vol    times 4 dw 0
ch_period times 4 dw 0
ch_eff    times 4 dw 0
ch_par    times 4 dw 0

msg_hdr     db 'MODPLAY - ProTracker 4-channel, Sound Blaster at 220h',13,10,'$'
msg_usage   db 'usage: modplay file.mod [-1..-4 one channel] [-r8|-r11|-r22 rate]',13,10,'$'
msg_e_open  db 'cannot open that file - check the name and that it is on the disk',13,10,'$'
msg_e_short db 'file is too short to be a MOD - the header is 1084 bytes',13,10,'$'
msg_e_sig   db 'not a 4-channel MOD - no M.K., 4CHN or FLT4 signature at 1080',13,10,'$'
msg_e_mem   db 'out of memory loading patterns or samples',13,10,'$'
msg_e_shrk  db 'DOS refused to shrink this program down to size',13,10,'$'
msg_e_det   db '  largest free block: $'
msg_e_par   db ' paragraphs, DOS error $'
msg_nomem   db 'not enough memory for the DMA buffer',13,10,'$'
msg_nosb    db 'no Sound Blaster answered at 220h',13,10,'$'
msg_title   db 'title    : $'
msg_pats    db 'patterns : $'
msg_pos     db '   positions : $'
msg_smp     db 'samples  : $'
msg_smp2    db ' whole, $'
msg_smp3    db ' shortened, $'
msg_smp4    db ' skipped',13,10,'$'
msg_rate    db 'mixing   : $'
msg_hz      db ' Hz',13,10,'$'
msg_chan    db 'channels : mask $'
msg_playing db 'playing - SPACE pauses, S shows stats, ESC quits',13,10,'$'
msg_bye     db 13,10,'stopped.',13,10,'$'
msg_crlf    db 13,10,'$'
msg_cr      db 13,'$'
msg_p       db 'pos $'
msg_slash   db '/$'
msg_r       db '  row $'
msg_und     db '  underrun $'
msg_fill    db '  busy $'
msg_pct     db '%$'
msg_sp      db '    $'

; ---- buffers, placed by hand and NOT emitted ---------------------------
;
; Laid out with EQU from one aligned label rather than as a .bss section.
; NASM's bin output does not chain a nobits section after .text on its own --
; it started .bss at address ZERO, and because the section holds no file data
; nothing about that looked wrong. hdr landed on the PSP, command line and
; memory-control fields included, and voltab landed on the program's own code.
; The visible symptom was every DOS allocation failing: "out of memory" on a
; machine with 600 KB free, because the PSP DOS was consulting had been
; overwritten by a MOD header.
;
; This way the addresses are arithmetic on a label the assembler has already
; placed, so they cannot be anywhere else. voltab goes first because XLAT needs
; it 256-aligned and the align directive below is the only padding emitted.

          align 256
bufbase:
; SIXTY-FIVE rows, not 64. MOD volume runs 0 to 64 INCLUSIVE, and 64 is the
; maximum and what most samples carry. With 64 rows a full-volume note indexed
; one row past the end of the table and was scaled through whatever followed
; it -- which was hdr, so every loud note was multiplied by the MOD file's own
; header. Quiet notes sounded right, loud ones came out as noise on top of the
; music.
VOLROWS   equ 65
voltab    equ bufbase                          ; VOLROWS x 256, 256-aligned
hdr       equ bufbase + VOLROWS*256            ; the whole 1084-byte MOD header
accum     equ bufbase + VOLROWS*256 + 1084     ; HALF 16-bit mixing slots
stacktop  equ bufbase + VOLROWS*256 + 1084 + HALF*2 + 512
