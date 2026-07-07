; bstr.p8 -- BASIC-format string storage for GPC, collected by the ROM garbage collector.
;
; Strings are stored exactly as X16 BASIC stores them:
;   * a VALUE is a 3-byte descriptor [len][ptr_lo][ptr_hi]; the body is `len` raw bytes
;     (NOT null-terminated) on the BASIC string heap between STREND and MEMSIZ.
;   * scalar variables are 7-byte BASIC simple-var entries in a GPC-owned table (svartab);
;     the descriptor is at offset +2.
;   * expression temporaries are 3-byte descriptors on BASIC's temp stack at TEMPST (3 slots).
;   * literals/DATA descriptors point at bodies OFF the heap (program image), which the
;     collector ignores -- so they need no rooting and never move.
; Allocation is ROM `getspa` (which invokes ROM `garbag` on collision); GPC never runs its
; own collector. Because getspa/garba2 walk BASIC's var/array/temp tables, every live string
; is found and relocated. Verified in spikes/strvar.p8 and spikes/bstr_spike.p8.

bstr {
    const uword MEMTOPK = $ff99          ; KERNAL MEMTOP
    const uword GETSPA  = $dc35          ; ROM string allocator (GCs on collision)
    const ubyte NVARS   = 64             ; scalar string variable slots
    ; BASIC string-management pointers (R49):
    const uword VARTAB = $03e1
    const uword ARYTAB = $03e3
    const uword STREND = $03e5
    const uword FRETOP = $03e7
    const uword MEMSIZ = $03e9
    const uword TEMPPT = $03de           ; 1 byte: low byte of the temp-stack top (tempst is in ZP)
    const ubyte TEMPST = $d6             ; base of the 3-slot temp descriptor stack (ZP)

    uword svartab                        ; base of the NVARS*7 scalar string-var table
    ubyte gsbank                         ; scratch: saved ROM bank across a getspa call
    bool  err_toolong                    ; set on a >255 concat (?STRING TOO LONG)
    bool  err_complex                    ; set on a >3-deep string temp (?FORMULA TOO COMPLEX)

    ; --- set up an empty BASIC string environment with the var table at `image_top` ---
    ; [image_top .. MEMTOP] must be free RAM: var table grows up from image_top, string heap
    ; grows down from MEMTOP; getspa's STREND-vs-FRETOP check yields ?OUT OF MEMORY when they meet.
    sub init(uword image_top) {
        err_toolong = false
        err_complex = false
        svartab = image_top
        uword e = svartab
        ubyte i
        for i in 0 to NVARS-1 {
            @(e)   = $41 + (i & 15)              ; name byte 0 (bit7 clear)
            @(e+1) = ($41 + (i >> 4)) | $80      ; name byte 1, string-type bit set
            @(e+2) = 0                           ; len 0 (empty)
            @(e+3) = 0
            @(e+4) = 0
            @(e+5) = 0
            @(e+6) = 0
            e += 7
        }
        uword tabend = svartab + (NVARS as uword) * 7
        pokew(VARTAB, svartab)
        pokew(ARYTAB, tabend)                    ; (string arrays will extend from here later)
        pokew(STREND, tabend)                    ; heap floor
        @(TEMPPT) = TEMPST                        ; empty temp stack
        %asm {{
            lda  $01
            pha
            stz  $01                             ; KERNAL bank for MEMTOP
            sec
            jsr  $ff99                           ; MEMTOP -> X=lo, Y=hi
            pla
            sta  $01
            stx  $03e9                           ; memsiz
            sty  $03ea
            stx  $03e7                           ; fretop = memsiz (empty heap)
            sty  $03e8
        }}
    }

    ; allocate `n` bytes on the BASIC string heap (GCs on collision); returns the body pointer.
    asmsub gs(ubyte n @A) -> uword @XY {
        %asm {{
            ldy  $01
            sty  p8v_gsbank
            ldy  #4                              ; BASIC ROM bank
            sty  $01
            jsr  $dc35                           ; getspa: in A=n; out A=n, X=lo, Y=hi
            lda  p8v_gsbank
            sta  $01
            rts
        }}
    }

    sub vdesc(ubyte slot) -> uword { return svartab + (slot as uword) * 7 + 2 }
    sub dlen(uword d) -> ubyte { return @(d) }
    sub dptr(uword d) -> uword { return peekw(d + 1) }

    ; is descriptor `d` the/a live temp? (temps live in ZP [TEMPST .. temppt))
    sub is_temp(uword d) -> bool {
        return d >= TEMPST and lsb(d) < @(TEMPPT) and msb(d) == 0
    }

    ; push a fresh temp string of `n` bytes; returns its descriptor address (body uninitialised).
    sub push_temp(ubyte n) -> uword {
        ubyte tp = @(TEMPPT)
        if tp >= TEMPST + 9 {                    ; 3 slots * 3 bytes
            err_complex = true
            return 0
        }
        uword ptr = gs(n)                        ; may GC; existing temps stay rooted
        @(tp as uword)     = n
        @((tp as uword)+1) = lsb(ptr)
        @((tp as uword)+2) = msb(ptr)
        @(TEMPPT) = tp + 3
        return tp as uword
    }

    sub pop_temp() {
        @(TEMPPT) = @(TEMPPT) - 3
    }

    sub bcopy(uword src, uword dst, ubyte n) {
        if n != 0
            sys.memcopy(src, dst, n as uword)
    }

    ; assign the string described by `srcd` into scalar slot `slot`.
    sub store_var(ubyte slot, uword srcd) {
        uword vd = vdesc(slot)
        ubyte n = dlen(srcd)
        if is_temp(srcd) {
            @(vd)   = n                          ; take ownership of the temp's body
            @(vd+1) = @(srcd+1)
            @(vd+2) = @(srcd+2)
            pop_temp()                           ; assumes srcd is the top temp
        } else {
            uword np = gs(n)                     ; own copy; may GC (srcd rooted or off-heap)
            bcopy(dptr(srcd), np, n)             ; re-read srcd ptr AFTER the alloc
            @(vd)   = n
            @(vd+1) = lsb(np)
            @(vd+2) = msb(np)
        }
    }

    ; result-in-var: dslot's string = a's string + b's string (a/b may be var/temp/literal descs).
    sub concat_to_var(ubyte dslot, uword ad, uword bd) {
        ubyte la = dlen(ad)
        ubyte lb = dlen(bd)
        uword tot = (la as uword) + lb
        if tot > 255 {
            err_toolong = true
            return
        }
        uword rp = gs(lsb(tot))                  ; may GC; ad/bd rooted or off-heap -> re-read after
        bcopy(dptr(ad), rp, la)
        bcopy(dptr(bd), rp + la, lb)
        uword vd = vdesc(dslot)
        @(vd)   = lsb(tot)
        @(vd+1) = lsb(rp)
        @(vd+2) = msb(rp)
    }
}
