; bstr.p8 -- BASIC-format string storage for GPC, collected by the ROM garbage collector.
;
; Strings are stored exactly as X16 BASIC stores them:
;   * a VALUE is a 3-byte descriptor [len][ptr_lo][ptr_hi]; the body is `len` raw bytes
;     (NOT null-terminated) on the BASIC string heap between STREND and MEMSIZ.
;   * scalar variables are 7-byte BASIC simple-var entries in a GPC-owned table (svartab);
;     the descriptor is at offset +2.
;   * string-array elements are 3-byte descriptors inside a BASIC array entry (in the arytab
;     region ARYTAB..STREND); the collector walks them by stride.
;   * expression temporaries are 3-byte descriptors on BASIC's temp stack at TEMPST (3 slots).
;   * literals/DATA descriptors point at bodies OFF the heap (program image), which the
;     collector ignores -- so they need no rooting and never move.
; Allocation is ROM `getspa` (which invokes ROM `garbag` on collision); GPC never runs its
; own collector. Because getspa/garba2 walk BASIC's var/array/temp tables, every live string
; is found and relocated. Verified in spikes/strvar.p8 and spikes/bstr_spike.p8.
;
; Temp discipline (mirrors BASIC): a value-producing op allocates its result body while the
; operands are still rooted (so a GC during getspa preserves them), copies the bodies, then
; frees the operand temps top-first, then pushes the result descriptor (no further alloc). Max
; live string temps is 3 (BASIC's ?FORMULA TOO COMPLEX boundary) -- GPC compiles the same
; expressions, so it hits the limit in exactly the places BASIC would.

bstr {
    const uword MEMTOPK = $ff99          ; KERNAL MEMTOP
    const uword GETSPA  = $dc35          ; ROM string allocator (GCs on collision)
    const ubyte NVARS   = 64             ; scalar string variable slots
    const ubyte NSARR   = 32             ; string array slots
    ; BASIC string-management pointers (R49):
    const uword VARTAB = $03e1
    const uword ARYTAB = $03e3
    const uword STREND = $03e5
    const uword FRETOP = $03e7
    const uword MEMSIZ = $03e9
    const uword TEMPPT = $03de           ; 1 byte: low byte of the temp-stack top (tempst is in ZP)
    const ubyte TEMPST = $d6             ; base of the 3-slot temp descriptor stack (ZP)

    uword svartab                        ; base of the NVARS*7 scalar string-var table
    uword htmp                           ; scratch: KERNAL MEMTOP read during init()
    uword htmp2                          ; scratch: computed heap ceiling during init()
    uword[NSARR] sarr_hdr                ; BASIC array-header address per string-array slot (0 = none)
    ubyte gsbank                         ; scratch: saved ROM bank across a getspa call
    bool  err_toolong                    ; set on a >255 concat (?STRING TOO LONG)
    bool  err_complex                    ; set on a >3-deep string temp (?FORMULA TOO COMPLEX)
    ubyte[256] cbuf                      ; scratch null-terminated copy of a body (for VAL/parse)

    ; --- set up an empty BASIC string environment with the var table at `image_top` ---
    ; [image_top .. heap ceiling] must be free RAM: var table grows up from image_top, then string
    ; arrays, then the string heap grows down from the ceiling; getspa's STREND-vs-FRETOP check yields
    ; ?OUT OF MEMORY when they meet. The ceiling is KERNAL MEMTOP, but `cap` lowers it below any LIVE
    ; RAM that sits above image_top -- in-process, the runtime's own high slabs (varsf/arrheap/...) live
    ; up there, so the heap must stop below them (else it silently corrupts numeric vars). Pass the
    ; lowest such slab (varsf) as `cap`; standalone, varsf is BELOW image_top so `cap` is ignored.
    sub init(uword image_top, uword cap) {
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
        for i in 0 to NSARR-1 {
            sarr_hdr[i] = 0                       ; no string arrays dimensioned yet
        }
        uword tabend = svartab + (NVARS as uword) * 7
        pokew(VARTAB, svartab)
        pokew(ARYTAB, tabend)                    ; string arrays extend from here
        pokew(STREND, tabend)                    ; heap floor (moves up as arrays are DIMmed)
        @(TEMPPT) = TEMPST                        ; empty temp stack
        htmp = 0
        %asm {{
            lda  $01
            pha
            stz  $01                             ; KERNAL bank for MEMTOP
            sec
            jsr  $ff99                           ; C=1: read MEMTOP -> X=lo, Y=hi
            pla
            sta  $01
            stx  p8v_htmp                        ; htmp = MEMTOP
            sty  p8v_htmp+1
        }}
        htmp2 = htmp                              ; ceiling = KERNAL MEMTOP, unless a live slab is below it
        if cap > image_top and cap < htmp2 {
            htmp2 = cap
            ; lower KERNAL MEMTOP to the cap so the ROM collector (garba2), which re-reads MEMTOP
            ; itself, also honours it -- otherwise a GC would relocate strings above the cap.
            %asm {{
                lda  $01
                pha
                stz  $01
                clc                             ; C=0: SET MEMTOP from X=lo, Y=hi
                ldx  p8v_htmp2
                ldy  p8v_htmp2+1
                jsr  $ff99
                pla
                sta  $01
            }}
        }
        pokew(MEMSIZ, htmp2)
        pokew(FRETOP, htmp2)                       ; fretop = memsiz (empty heap)
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

    ; --- descriptor accessors -----------------------------------------------------------------
    sub vdesc(ubyte slot) -> uword { return svartab + (slot as uword) * 7 + 2 }
    sub dlen(uword d) -> ubyte { return @(d) }
    sub dptr(uword d) -> uword { return peekw(d + 1) }

    ; --- temp-stack management ----------------------------------------------------------------
    ; is descriptor `d` a live temp? (temps live in ZP [TEMPST .. temppt))
    sub is_temp(uword d) -> bool {
        return d >= TEMPST and lsb(d) < @(TEMPPT) and msb(d) == 0
    }

    ; is `d` the most-recently pushed temp? (only the top temp may be popped, to keep LIFO order)
    sub is_top_temp(uword d) -> bool {
        ubyte tp = @(TEMPPT)
        if tp <= TEMPST
            return false
        return msb(d) == 0 and lsb(d) == tp - 3
    }

    sub pop_temp() {
        @(TEMPPT) = @(TEMPPT) - 3
    }

    ; free `d` iff it is the top temp (no-op for vars, literals, array elements, deeper temps)
    sub free_temp_if_top(uword d) {
        if is_top_temp(d)
            pop_temp()
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

    ; push a temp descriptor over an ALREADY-allocated body `ptr` (no getspa -> cannot GC).
    sub push_body_temp(ubyte n, uword ptr) -> uword {
        ubyte tp = @(TEMPPT)
        if tp >= TEMPST + 9 {
            err_complex = true
            return 0
        }
        @(tp as uword)     = n
        @((tp as uword)+1) = lsb(ptr)
        @((tp as uword)+2) = msb(ptr)
        @(TEMPPT) = tp + 3
        return tp as uword
    }

    sub bcopy(uword src, uword dst, ubyte n) {
        if n != 0
            sys.memcopy(src, dst, n as uword)
    }

    ; --- assignment ---------------------------------------------------------------------------
    ; assign the string described by `sd` into the descriptor at `dd` (scalar var or array elem),
    ; with BASIC's heap-copy semantics: if `sd` is the top temp, steal its body (and pop it);
    ; otherwise allocate an owned copy. The previous body at `dd` is orphaned for the collector.
    sub store_desc(uword dd, uword sd) {
        ubyte n = dlen(sd)
        if is_top_temp(sd) {
            @(dd)   = n                          ; take ownership of the temp's body
            @(dd+1) = @(sd+1)
            @(dd+2) = @(sd+2)
            pop_temp()
        } else {
            uword np = gs(n)                     ; own copy; may GC (sd rooted or off-heap)
            bcopy(dptr(sd), np, n)               ; re-read sd ptr AFTER the alloc
            @(dd)   = n
            @(dd+1) = lsb(np)
            @(dd+2) = msb(np)
        }
    }

    sub store_var(ubyte slot, uword sd) {
        store_desc(vdesc(slot), sd)
    }

    ; store `n` bytes from an OFF-HEAP source (inbuf / DATA pool) straight into scalar slot `slot`.
    sub var_from_mem(ubyte slot, uword src, ubyte n) {
        uword np = gs(n)                         ; may GC; src is off-heap -> stable across it
        bcopy(src, np, n)
        uword vd = vdesc(slot)
        @(vd)   = n
        @(vd+1) = lsb(np)
        @(vd+2) = msb(np)
    }

    ; --- value-producing operations (each leaves a temp descriptor, returns its address) ------
    ; result temp = a's string + b's string. a/b may be var/temp/literal/array descriptors.
    sub concat_temp(uword ad, uword bd) -> uword {
        ubyte la = dlen(ad)
        ubyte lb = dlen(bd)
        uword tot = (la as uword) + lb
        if tot > 255 {
            err_toolong = true
            return 0
        }
        uword rp = gs(lsb(tot))                  ; alloc result; may GC; ad/bd rooted -> re-read after
        bcopy(dptr(ad), rp, la)
        bcopy(dptr(bd), rp + la, lb)
        free_temp_if_top(bd)                     ; free operands top-first (bd pushed last)
        free_temp_if_top(ad)
        return push_body_temp(lsb(tot), rp)
    }

    ; result temp = `count` chars of `sd` starting at byte `start` (both clamped to the body).
    sub substr_temp(uword sd, ubyte start, ubyte count) -> uword {
        ubyte slen = dlen(sd)
        if start >= slen {
            count = 0
        } else {
            ubyte avail = slen - start
            if count > avail
                count = avail
        }
        uword rp = gs(count)                     ; may GC; sd rooted -> re-read after
        if count != 0
            sys.memcopy(dptr(sd) + start, rp, count as uword)
        free_temp_if_top(sd)
        return push_body_temp(count, rp)
    }

    ; result temp = a single character (CHR$).
    sub chr_temp(ubyte ch) -> uword {
        uword rp = gs(1)
        @(rp) = ch
        return push_body_temp(1, rp)
    }

    ; result temp = `n` bytes copied from an OFF-HEAP source (ROM FOUT buffer for STR$, etc).
    sub mem_to_temp(uword src, ubyte n) -> uword {
        uword rp = gs(n)                         ; may GC; src off-heap -> stable
        bcopy(src, rp, n)
        return push_body_temp(n, rp)
    }

    ; --- comparison / conversion --------------------------------------------------------------
    ; length-counted lexical compare: -1 if a<b, 0 if equal, 1 if a>b (BASIC's string ordering).
    sub bcompare(uword ad, uword bd) -> byte {
        ubyte la = dlen(ad)
        ubyte lb = dlen(bd)
        uword pa = dptr(ad)
        uword pb = dptr(bd)
        ubyte m = la
        if lb < la
            m = lb
        ubyte i = 0
        while i < m {
            ubyte ca = @(pa + i)
            ubyte cb = @(pb + i)
            if ca < cb
                return -1
            if ca > cb
                return 1
            i++
        }
        if la < lb
            return -1
        if la > lb
            return 1
        return 0
    }

    ; copy the body of `d` into cbuf, null-terminate it, and return &cbuf (for VAL / floats.parse).
    sub to_cbuf(uword d) -> uword {
        ubyte n = dlen(d)
        bcopy(dptr(d), &cbuf, n)
        cbuf[n] = 0
        return &cbuf
    }

    ; --- string arrays (real BASIC arrays in the ARYTAB..STREND region) ------------------------
    ; Build an empty string array of `nelem` 3-byte descriptors with `ndims` dimensions for slot
    ; `slot`, appended above the current STREND. Returns false (leaving the slot undimensioned)
    ; if the header would collide with the string heap. The collector walks these element
    ; descriptors natively, so array-held strings are rooted and relocated with everything else.
    sub sarr_alloc(ubyte slot, uword nelem, ubyte ndims) -> bool {
        uword h = peekw(STREND)
        uword total = 5 + (ndims as uword) * 2 + nelem * 3
        if h + total >= peekw(FRETOP)            ; would run into the string heap
            return false
        @(h)   = $41 + (slot & 15)               ; array name byte 0 (bit7 clear)
        @(h+1) = ($41 + (slot >> 4)) | $80       ; name byte 1, string-type bit set
        @(h+2) = lsb(total)                       ; offset to next array (the collector steps by this)
        @(h+3) = msb(total)
        @(h+4) = ndims
        uword p = h + 5
        ubyte j = 0
        while j < ndims {                         ; dim sizes: unused by the collector, kept zero
            @(p) = 0
            @(p+1) = 0
            p += 2
            j++
        }
        uword k = 0
        while k < nelem {                         ; every element starts empty (len 0)
            @(p)   = 0
            @(p+1) = 0
            @(p+2) = 0
            p += 3
            k++
        }
        sarr_hdr[slot] = h
        pokew(STREND, h + total)
        return true
    }

    ; descriptor address of element `elemidx` (row-major, precomputed by the caller) of slot `slot`.
    sub sarr_desc(ubyte slot, uword elemidx) -> uword {
        uword h = sarr_hdr[slot]
        ubyte nd = @(h + 4)
        uword data = h + 5 + (nd as uword) * 2
        return data + elemidx * 3
    }

    sub sarr_dimmed(ubyte slot) -> bool {
        return sarr_hdr[slot] != 0
    }
}
