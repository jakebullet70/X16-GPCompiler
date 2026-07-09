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
    uword[NSARR] @shared sarr_hdr        ; BASIC array-header address per string-array slot (0 = none)
                                         ; @shared: sarr_desc reads it only from asm, and its lone prog8
                                         ; reader (sarr_dimmed) is dead-stripped in TESTBENCH=false builds
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
    sub dlen(uword d) -> ubyte {
        %asm {{
            lda  p8b_bstr.p8s_dlen.p8v_d
            sta  P8ZP_SCRATCH_W1
            lda  p8b_bstr.p8s_dlen.p8v_d+1
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)
            rts
        }}
    }
    sub dptr(uword d) -> uword {
        %asm {{
            lda  p8b_bstr.p8s_dptr.p8v_d
            sta  P8ZP_SCRATCH_W1
            lda  p8b_bstr.p8s_dptr.p8v_d+1
            sta  P8ZP_SCRATCH_W1+1
            ldy  #1
            lda  (P8ZP_SCRATCH_W1),y      ; d+1 = body ptr lo
            pha
            iny
            lda  (P8ZP_SCRATCH_W1),y      ; d+2 = body ptr hi
            tay
            pla                            ; A=lo, Y=hi
            rts
        }}
    }

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
        %asm {{
            lda  $03de                      ; tp = @(TEMPPT)
            cmp  #$df                        ; tp >= TEMPST+9 ($d6+9)?  -> temp stack full
            bcc  _pbtok
            lda  #1                          ; ?FORMULA TOO COMPLEX
            sta  p8b_bstr.p8v_err_complex
            lda  #0
            tay
            rts
_pbtok:     tax                              ; X = tp (a ZP address $d6..$dc)
            lda  p8b_bstr.p8s_push_body_temp.p8v_n
            sta  $00,x                       ; @(tp)   = n         (zp,x: base+X = tp)
            lda  p8b_bstr.p8s_push_body_temp.p8v_ptr
            sta  $01,x                       ; @(tp+1) = lsb(ptr)
            lda  p8b_bstr.p8s_push_body_temp.p8v_ptr+1
            sta  $02,x                       ; @(tp+2) = msb(ptr)
            txa                              ; @(TEMPPT) = tp + 3
            clc
            adc  #3
            sta  $03de
            txa                              ; return tp  (A=tp, Y=0)
            ldy  #0
            rts
        }}
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
        %asm {{
            lda  p8b_bstr.p8s_store_desc.p8v_sd     ; n = dlen(sd) -> park in bcopy.n (survives every call)
            ldy  p8b_bstr.p8s_store_desc.p8v_sd+1
            jsr  p8b_bstr.p8s_dlen
            sta  p8b_bstr.p8s_bcopy.p8v_n
            lda  p8b_bstr.p8s_store_desc.p8v_sd     ; if is_top_temp(sd): steal its body
            ldy  p8b_bstr.p8s_store_desc.p8v_sd+1
            jsr  p8b_bstr.p8s_is_top_temp
            beq  _sdcopy
            lda  p8b_bstr.p8s_store_desc.p8v_dd     ; W1 = dd, W2 = sd
            sta  P8ZP_SCRATCH_W1
            lda  p8b_bstr.p8s_store_desc.p8v_dd+1
            sta  P8ZP_SCRATCH_W1+1
            lda  p8b_bstr.p8s_store_desc.p8v_sd
            sta  P8ZP_SCRATCH_W2
            lda  p8b_bstr.p8s_store_desc.p8v_sd+1
            sta  P8ZP_SCRATCH_W2+1
            ldy  #0                                  ; @(dd) = n
            lda  p8b_bstr.p8s_bcopy.p8v_n
            sta  (P8ZP_SCRATCH_W1),y
            ldy  #1                                  ; @(dd+1) = @(sd+1)
            lda  (P8ZP_SCRATCH_W2),y
            sta  (P8ZP_SCRATCH_W1),y
            ldy  #2                                  ; @(dd+2) = @(sd+2)
            lda  (P8ZP_SCRATCH_W2),y
            sta  (P8ZP_SCRATCH_W1),y
            jmp  p8b_bstr.p8s_pop_temp
_sdcopy:    lda  p8b_bstr.p8s_bcopy.p8v_n           ; np = gs(n) ; may GC (sd stays rooted / off-heap)
            jsr  p8b_bstr.p8s_gs
            stx  p8b_bstr.p8s_bcopy.p8v_dst          ; np -> bcopy.dst (survives, holds the owned copy)
            sty  p8b_bstr.p8s_bcopy.p8v_dst+1
            lda  p8b_bstr.p8s_store_desc.p8v_sd      ; src = dptr(sd) -- RE-READ after the alloc
            ldy  p8b_bstr.p8s_store_desc.p8v_sd+1
            jsr  p8b_bstr.p8s_dptr
            sta  p8b_bstr.p8s_bcopy.p8v_src
            sty  p8b_bstr.p8s_bcopy.p8v_src+1
            jsr  p8b_bstr.p8s_bcopy                  ; copy body into the owned np
            lda  p8b_bstr.p8s_store_desc.p8v_dd      ; @(dd) = [n, np]
            sta  P8ZP_SCRATCH_W1
            lda  p8b_bstr.p8s_store_desc.p8v_dd+1
            sta  P8ZP_SCRATCH_W1+1
            ldy  #0
            lda  p8b_bstr.p8s_bcopy.p8v_n
            sta  (P8ZP_SCRATCH_W1),y
            ldy  #1
            lda  p8b_bstr.p8s_bcopy.p8v_dst
            sta  (P8ZP_SCRATCH_W1),y
            ldy  #2
            lda  p8b_bstr.p8s_bcopy.p8v_dst+1
            sta  (P8ZP_SCRATCH_W1),y
            rts
        }}
    }

    sub store_var(ubyte slot, uword sd) {
        %asm {{
            lda  p8b_bstr.p8s_store_var.p8v_sd      ; store_desc.sd = sd (before vdesc uses A/Y)
            sta  p8b_bstr.p8s_store_desc.p8v_sd
            lda  p8b_bstr.p8s_store_var.p8v_sd+1
            sta  p8b_bstr.p8s_store_desc.p8v_sd+1
            lda  p8b_bstr.p8s_store_var.p8v_slot    ; store_desc.dd = vdesc(slot)
            jsr  p8b_bstr.p8s_vdesc
            sta  p8b_bstr.p8s_store_desc.p8v_dd
            sty  p8b_bstr.p8s_store_desc.p8v_dd+1
            jmp  p8b_bstr.p8s_store_desc
        }}
    }

    ; store `n` bytes from an OFF-HEAP source (inbuf / DATA pool) straight into scalar slot `slot`.
    sub var_from_mem(ubyte slot, uword src, ubyte n) {
        %asm {{
            lda  p8b_bstr.p8s_var_from_mem.p8v_n    ; np = gs(n) ; may GC; src off-heap -> stable
            jsr  p8b_bstr.p8s_gs
            stx  p8b_bstr.p8s_bcopy.p8v_dst          ; np -> bcopy.dst (holds the owned body)
            sty  p8b_bstr.p8s_bcopy.p8v_dst+1
            lda  p8b_bstr.p8s_var_from_mem.p8v_src
            sta  p8b_bstr.p8s_bcopy.p8v_src
            lda  p8b_bstr.p8s_var_from_mem.p8v_src+1
            sta  p8b_bstr.p8s_bcopy.p8v_src+1
            lda  p8b_bstr.p8s_var_from_mem.p8v_n
            sta  p8b_bstr.p8s_bcopy.p8v_n
            jsr  p8b_bstr.p8s_bcopy                  ; copy src -> np
            lda  p8b_bstr.p8s_var_from_mem.p8v_slot  ; vd = vdesc(slot) -> W1
            jsr  p8b_bstr.p8s_vdesc
            sta  P8ZP_SCRATCH_W1
            sty  P8ZP_SCRATCH_W1+1
            ldy  #0                                  ; @(vd) = n
            lda  p8b_bstr.p8s_var_from_mem.p8v_n
            sta  (P8ZP_SCRATCH_W1),y
            ldy  #1                                  ; @(vd+1) = lsb(np)
            lda  p8b_bstr.p8s_bcopy.p8v_dst
            sta  (P8ZP_SCRATCH_W1),y
            ldy  #2                                  ; @(vd+2) = msb(np)
            lda  p8b_bstr.p8s_bcopy.p8v_dst+1
            sta  (P8ZP_SCRATCH_W1),y
            rts
        }}
    }

    ; --- value-producing operations (each leaves a temp descriptor, returns its address) ------
    ; result temp = a's string + b's string. a/b may be var/temp/literal/array descriptors.
    sub concat_temp(uword ad, uword bd) -> uword {
        %asm {{
            lda  p8b_bstr.p8s_concat_temp.p8v_ad    ; la = dlen(ad) -> htmp (init-only scratch, safe here)
            ldy  p8b_bstr.p8s_concat_temp.p8v_ad+1
            jsr  p8b_bstr.p8s_dlen
            sta  p8b_bstr.p8v_htmp
            lda  p8b_bstr.p8s_concat_temp.p8v_bd    ; lb = dlen(bd) -> htmp+1
            ldy  p8b_bstr.p8s_concat_temp.p8v_bd+1
            jsr  p8b_bstr.p8s_dlen
            sta  p8b_bstr.p8v_htmp+1
            clc                                      ; tot = la + lb ; > 255 -> ?STRING TOO LONG
            lda  p8b_bstr.p8v_htmp
            adc  p8b_bstr.p8v_htmp+1
            bcs  _cttoolong
            sta  p8b_bstr.p8s_push_body_temp.p8v_n   ; tot (fits a byte)
            jsr  p8b_bstr.p8s_gs                      ; rp = gs(tot) ; may GC (ad/bd rooted)
            stx  p8b_bstr.p8s_push_body_temp.p8v_ptr
            sty  p8b_bstr.p8s_push_body_temp.p8v_ptr+1
            lda  p8b_bstr.p8s_concat_temp.p8v_ad     ; bcopy(dptr(ad), rp, la) -- dptr RE-READ after gs
            ldy  p8b_bstr.p8s_concat_temp.p8v_ad+1
            jsr  p8b_bstr.p8s_dptr
            sta  p8b_bstr.p8s_bcopy.p8v_src
            sty  p8b_bstr.p8s_bcopy.p8v_src+1
            lda  p8b_bstr.p8s_push_body_temp.p8v_ptr
            sta  p8b_bstr.p8s_bcopy.p8v_dst
            lda  p8b_bstr.p8s_push_body_temp.p8v_ptr+1
            sta  p8b_bstr.p8s_bcopy.p8v_dst+1
            lda  p8b_bstr.p8v_htmp                    ; la
            sta  p8b_bstr.p8s_bcopy.p8v_n
            jsr  p8b_bstr.p8s_bcopy
            lda  p8b_bstr.p8s_concat_temp.p8v_bd     ; bcopy(dptr(bd), rp+la, lb)
            ldy  p8b_bstr.p8s_concat_temp.p8v_bd+1
            jsr  p8b_bstr.p8s_dptr
            sta  p8b_bstr.p8s_bcopy.p8v_src
            sty  p8b_bstr.p8s_bcopy.p8v_src+1
            clc                                      ; dst = rp + la
            lda  p8b_bstr.p8s_push_body_temp.p8v_ptr
            adc  p8b_bstr.p8v_htmp
            sta  p8b_bstr.p8s_bcopy.p8v_dst
            lda  p8b_bstr.p8s_push_body_temp.p8v_ptr+1
            adc  #0
            sta  p8b_bstr.p8s_bcopy.p8v_dst+1
            lda  p8b_bstr.p8v_htmp+1                  ; lb
            sta  p8b_bstr.p8s_bcopy.p8v_n
            jsr  p8b_bstr.p8s_bcopy
            lda  p8b_bstr.p8s_concat_temp.p8v_bd     ; free operands top-first (bd was pushed last)
            ldy  p8b_bstr.p8s_concat_temp.p8v_bd+1
            jsr  p8b_bstr.p8s_free_temp_if_top
            lda  p8b_bstr.p8s_concat_temp.p8v_ad
            ldy  p8b_bstr.p8s_concat_temp.p8v_ad+1
            jsr  p8b_bstr.p8s_free_temp_if_top
            jmp  p8b_bstr.p8s_push_body_temp          ; return push_body_temp(tot, rp)
_cttoolong: lda  #1
            sta  p8b_bstr.p8v_err_toolong
            lda  #0
            tay
            rts
        }}
    }

    ; result temp = `count` chars of `sd` starting at byte `start` (both clamped to the body).
    sub substr_temp(uword sd, ubyte start, ubyte count) -> uword {
        %asm {{
            lda  p8b_bstr.p8s_substr_temp.p8v_sd    ; slen = dlen(sd) -> htmp
            ldy  p8b_bstr.p8s_substr_temp.p8v_sd+1
            jsr  p8b_bstr.p8s_dlen
            sta  p8b_bstr.p8v_htmp
            lda  p8b_bstr.p8s_substr_temp.p8v_start ; if start >= slen -> count = 0
            cmp  p8b_bstr.p8v_htmp
            bcs  _stclamp0
            lda  p8b_bstr.p8v_htmp                   ; avail = slen - start
            sec
            sbc  p8b_bstr.p8s_substr_temp.p8v_start
            cmp  p8b_bstr.p8s_substr_temp.p8v_count  ; if count > avail -> count = avail
            bcs  _stok
            sta  p8b_bstr.p8s_substr_temp.p8v_count
            bra  _stok
_stclamp0:  lda  #0
            sta  p8b_bstr.p8s_substr_temp.p8v_count
_stok:      lda  p8b_bstr.p8s_substr_temp.p8v_count ; rp = gs(count) ; may GC (sd rooted)
            sta  p8b_bstr.p8s_push_body_temp.p8v_n
            jsr  p8b_bstr.p8s_gs
            stx  p8b_bstr.p8s_push_body_temp.p8v_ptr
            sty  p8b_bstr.p8s_push_body_temp.p8v_ptr+1
            stx  p8b_bstr.p8s_bcopy.p8v_dst
            sty  p8b_bstr.p8s_bcopy.p8v_dst+1
            lda  p8b_bstr.p8s_substr_temp.p8v_sd    ; src = dptr(sd) + start  (dptr RE-READ after gs)
            ldy  p8b_bstr.p8s_substr_temp.p8v_sd+1
            jsr  p8b_bstr.p8s_dptr
            clc
            adc  p8b_bstr.p8s_substr_temp.p8v_start
            sta  p8b_bstr.p8s_bcopy.p8v_src
            tya
            adc  #0
            sta  p8b_bstr.p8s_bcopy.p8v_src+1
            lda  p8b_bstr.p8s_substr_temp.p8v_count
            sta  p8b_bstr.p8s_bcopy.p8v_n
            jsr  p8b_bstr.p8s_bcopy                  ; copy (bcopy no-ops when count==0)
            lda  p8b_bstr.p8s_substr_temp.p8v_sd    ; free_temp_if_top(sd)
            ldy  p8b_bstr.p8s_substr_temp.p8v_sd+1
            jsr  p8b_bstr.p8s_free_temp_if_top
            jmp  p8b_bstr.p8s_push_body_temp          ; return push_body_temp(count, rp)
        }}
    }

    ; result temp = a single character (CHR$).
    sub chr_temp(ubyte ch) -> uword {
        %asm {{
            lda  #1
            jsr  p8b_bstr.p8s_gs                       ; rp in X=lo, Y=hi
            stx  P8ZP_SCRATCH_W1
            sty  P8ZP_SCRATCH_W1+1
            stx  p8b_bstr.p8s_push_body_temp.p8v_ptr   ; rp -> push_body_temp.ptr
            sty  p8b_bstr.p8s_push_body_temp.p8v_ptr+1
            lda  p8b_bstr.p8s_chr_temp.p8v_ch
            sta  (P8ZP_SCRATCH_W1)                     ; @(rp) = ch
            lda  #1
            sta  p8b_bstr.p8s_push_body_temp.p8v_n
            jmp  p8b_bstr.p8s_push_body_temp           ; return push_body_temp(1, rp)
        }}
    }

    ; result temp = `n` bytes copied from an OFF-HEAP source (ROM FOUT buffer for STR$, etc).
    sub mem_to_temp(uword src, ubyte n) -> uword {
        %asm {{
            lda  p8b_bstr.p8s_mem_to_temp.p8v_n
            jsr  p8b_bstr.p8s_gs                       ; rp in X=lo, Y=hi (may GC; src off-heap, stable)
            stx  p8b_bstr.p8s_push_body_temp.p8v_ptr   ; rp -> push_body_temp.ptr and bcopy.dst
            sty  p8b_bstr.p8s_push_body_temp.p8v_ptr+1
            stx  p8b_bstr.p8s_bcopy.p8v_dst
            sty  p8b_bstr.p8s_bcopy.p8v_dst+1
            lda  p8b_bstr.p8s_mem_to_temp.p8v_src
            sta  p8b_bstr.p8s_bcopy.p8v_src
            lda  p8b_bstr.p8s_mem_to_temp.p8v_src+1
            sta  p8b_bstr.p8s_bcopy.p8v_src+1
            lda  p8b_bstr.p8s_mem_to_temp.p8v_n
            sta  p8b_bstr.p8s_bcopy.p8v_n
            sta  p8b_bstr.p8s_push_body_temp.p8v_n
            jsr  p8b_bstr.p8s_bcopy                    ; copy src -> rp
            jmp  p8b_bstr.p8s_push_body_temp           ; return push_body_temp(n, rp)
        }}
    }

    ; --- comparison / conversion --------------------------------------------------------------
    ; length-counted lexical compare: -1 if a<b, 0 if equal, 1 if a>b (BASIC's string ordering).
    sub bcompare(uword ad, uword bd) -> byte {
        %asm {{
            lda  p8b_bstr.p8s_bcompare.p8v_ad     ; la = dlen(ad) -> REG
            ldy  p8b_bstr.p8s_bcompare.p8v_ad+1
            jsr  p8b_bstr.p8s_dlen
            sta  P8ZP_SCRATCH_REG
            lda  p8b_bstr.p8s_bcompare.p8v_bd     ; lb = dlen(bd) -> B1
            ldy  p8b_bstr.p8s_bcompare.p8v_bd+1
            jsr  p8b_bstr.p8s_dlen
            sta  P8ZP_SCRATCH_B1
            lda  p8b_bstr.p8s_bcompare.p8v_bd     ; pb = dptr(bd) -> park in p8v_bd (dptr clobbers W1)
            ldy  p8b_bstr.p8s_bcompare.p8v_bd+1
            jsr  p8b_bstr.p8s_dptr
            sta  p8b_bstr.p8s_bcompare.p8v_bd
            sty  p8b_bstr.p8s_bcompare.p8v_bd+1
            lda  p8b_bstr.p8s_bcompare.p8v_ad     ; pa = dptr(ad) -> W1 (last dptr; W1 survives the loop)
            ldy  p8b_bstr.p8s_bcompare.p8v_ad+1
            jsr  p8b_bstr.p8s_dptr
            sta  P8ZP_SCRATCH_W1
            sty  P8ZP_SCRATCH_W1+1
            lda  p8b_bstr.p8s_bcompare.p8v_bd     ; W2 = pb
            sta  P8ZP_SCRATCH_W2
            lda  p8b_bstr.p8s_bcompare.p8v_bd+1
            sta  P8ZP_SCRATCH_W2+1
            lda  P8ZP_SCRATCH_REG                 ; m = min(la,lb) -> p8v_ad(lo)
            cmp  P8ZP_SCRATCH_B1
            bcc  _mla
            lda  P8ZP_SCRATCH_B1
            bra  _mset
_mla:       lda  P8ZP_SCRATCH_REG
_mset:      sta  p8b_bstr.p8s_bcompare.p8v_ad
            ldy  #0                                ; i in Y
_lp:        cpy  p8b_bstr.p8s_bcompare.p8v_ad     ; i < m ?
            bcs  _eqlen
            lda  (P8ZP_SCRATCH_W1),y              ; ca
            cmp  (P8ZP_SCRATCH_W2),y              ; cb
            bcc  _lt                               ; ca < cb -> -1
            bne  _gt                               ; ca > cb ->  1
            iny
            bra  _lp
_eqlen:     lda  P8ZP_SCRATCH_REG                 ; equal prefix: order by length
            cmp  P8ZP_SCRATCH_B1
            bcc  _lt                               ; la < lb -> -1
            beq  _eq                               ; la = lb ->  0
_gt:        lda  #$01
            rts
_lt:        lda  #$ff
            rts
_eq:        lda  #$00
            rts
        }}
    }

    ; copy the body of `d` into cbuf, null-terminate it, and return &cbuf (for VAL / floats.parse).
    sub to_cbuf(uword d) -> uword {
        %asm {{
            lda  p8b_bstr.p8s_to_cbuf.p8v_d
            ldy  p8b_bstr.p8s_to_cbuf.p8v_d+1
            jsr  p8b_bstr.p8s_dlen                 ; n
            sta  p8b_bstr.p8s_bcopy.p8v_n
            pha                                    ; keep n for cbuf[n]=0
            lda  p8b_bstr.p8s_to_cbuf.p8v_d
            ldy  p8b_bstr.p8s_to_cbuf.p8v_d+1
            jsr  p8b_bstr.p8s_dptr                 ; dptr(d) -> A=lo, Y=hi
            sta  p8b_bstr.p8s_bcopy.p8v_src
            sty  p8b_bstr.p8s_bcopy.p8v_src+1
            lda  #<p8b_bstr.p8v_cbuf
            sta  p8b_bstr.p8s_bcopy.p8v_dst
            lda  #>p8b_bstr.p8v_cbuf
            sta  p8b_bstr.p8s_bcopy.p8v_dst+1
            jsr  p8b_bstr.p8s_bcopy                ; cbuf <- body
            pla                                    ; n
            tay
            lda  #0
            sta  p8b_bstr.p8v_cbuf,y               ; cbuf[n] = 0 (null-terminate)
            lda  #<p8b_bstr.p8v_cbuf               ; return &cbuf
            ldy  #>p8b_bstr.p8v_cbuf
            rts
        }}
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
        %asm {{
            ldy  p8b_bstr.p8s_sarr_desc.p8v_slot
            lda  p8b_bstr.p8v_sarr_hdr_lsb,y          ; h = sarr_hdr[slot]
            sta  P8ZP_SCRATCH_W1
            lda  p8b_bstr.p8v_sarr_hdr_msb,y
            sta  P8ZP_SCRATCH_W1+1
            ldy  #4
            lda  (P8ZP_SCRATCH_W1),y                  ; nd = @(h+4)
            asl  a                                     ; nd*2  (nd <= MAXDIMS, no overflow)
            clc
            adc  #5                                     ; nd*2 + 5
            clc
            adc  P8ZP_SCRATCH_W1                        ; data = h + 5 + nd*2 -> W1
            sta  P8ZP_SCRATCH_W1
            bcc  +
            inc  P8ZP_SCRATCH_W1+1
+           lda  p8b_bstr.p8s_sarr_desc.p8v_elemidx    ; W2 = elemidx*3 = elemidx*2 + elemidx
            sta  P8ZP_SCRATCH_W2
            lda  p8b_bstr.p8s_sarr_desc.p8v_elemidx+1
            sta  P8ZP_SCRATCH_W2+1
            asl  P8ZP_SCRATCH_W2
            rol  P8ZP_SCRATCH_W2+1
            clc
            lda  P8ZP_SCRATCH_W2
            adc  p8b_bstr.p8s_sarr_desc.p8v_elemidx
            sta  P8ZP_SCRATCH_W2
            lda  P8ZP_SCRATCH_W2+1
            adc  p8b_bstr.p8s_sarr_desc.p8v_elemidx+1
            sta  P8ZP_SCRATCH_W2+1
            clc                                         ; return data + elemidx*3
            lda  P8ZP_SCRATCH_W1
            adc  P8ZP_SCRATCH_W2
            tax
            lda  P8ZP_SCRATCH_W1+1
            adc  P8ZP_SCRATCH_W2+1
            tay
            txa                                         ; A=lo, Y=hi
            rts
        }}
    }

    sub sarr_dimmed(ubyte slot) -> bool {
        return sarr_hdr[slot] != 0
    }
}
