; vm.p8 -- Blitz-X16 P-code runtime VM (reusable module).
;
; Stack-based interpreter over a P-code blob. Numeric cells are 5-byte ROM floats
; (Commodore MFLPT), so BASIC's default number type is supported; arithmetic runs
; through Prog8's float operators, which call the X16 ROM Math library. Integer
; contexts (memory addresses, array indices, line numbers) truncate on demand.
; Call vm.run(address_of_blob).
;
; This is a *module* (block `vm`), used both by the standalone runtime and, for
; now, embedded in the compiler so it can compile-and-run on the X16.

%import textio
%import strings
%import floats
%import pcode_format

vm {
    const uword EMU_CHROUT = $9fbb        ; x16emu: writing here echoes a char to the host console

    float[32] stack
    ubyte     sp
    ; variable slots live in a slab (128 floats * 5 bytes = 640 > the 256-byte array cap),
    ; addressed as varsf + slot*5 via peekf/pokef
    uword     varsf = memory("vm_vars", 640, 0)
    word      last_printed        ; most recent PRINTI, truncated to an integer (for headless tests)

    uword[16] callstack          ; GOSUB return addresses
    ubyte     csp

    ubyte[8]  for_var            ; FOR loop frames (innermost on top)
    float[8]  for_limit
    float[8]  for_step
    uword[8]  for_top            ; pcode offset of the loop body's first instruction
    ubyte     forsp

    uword[16]  sstack            ; string-value stack (holds pointers)
    ubyte      ssp
    uword[64]  svars             ; string variable pointers (max 64 string variables)
    ; string heap (concat/slice/CHR$/INPUT/READ results), bump-allocated. A slab (not a 256-byte
    ; array) so string arrays -- which can hold many strings at once -- have real room to work in.
    const uword HEAP_SIZE = 1024
    uword      heap = memory("vm_heap", HEAP_SIZE, 0)
    uword      heap_top
    str        empty_str = ""    ; shared value for unset string variables
    str        heap_full_msg = "?OUT OF MEMORY"   ; string heap still full after a compaction
    str        str_long_msg  = "?STRING TOO LONG" ; a concat would exceed BASIC's 255-char limit
    uword      litbase           ; base address of the string-literal pool (set by the host
                                 ; before run(): &litpool in-process, from the header standalone)
    uword      sys_target        ; OP_SYS call target (indirection cell for the JSR trick)

    ; --- READ / DATA: the data pool is null-terminated item texts in line order; a cursor walks
    ;     it, RESTORE rewinds it. database/datatop are set by the host before run() (like litbase). ---
    uword      database          ; start of the DATA pool
    uword      datatop           ; one past the end of the DATA pool (out-of-data boundary)
    uword      dataptr           ; the READ cursor

    ; --- numeric arrays (DIM): a bump-allocated heap of floats + per-array descriptors. Arrays are
    ;     N-dimensional (up to pcode.MAXDIMS subscripts); the per-dimension SIZES drive the row-major
    ;     element offset (see index_of) and per-subscript bounds checks. ---
    const uword ARRHEAP_SIZE = 2048          ; ~409 float elements shared across all arrays
    uword      arrheap = memory("vm_arrheap", ARRHEAP_SIZE, 0)
    uword[32]  arr_base           ; byte offset of each array within arrheap
    uword[32]  arr_len            ; total element count of each array (0 = undimensioned/unusable)
    ubyte[32]  arr_ndims          ; number of dimensions of each array
    ; per-array dimension sizes, MAXDIMS words per array: arr_dims[slot*MAXDIMS + j] = size of dim j
    uword      arr_dims = memory("vm_arrdims", 32 * pcode.MAXDIMS * 2, 0)
    uword      arr_top            ; bump pointer into arrheap (bytes)

    ; --- string arrays (DIM A$(...)): same shape as numeric arrays, but each element is a 2-byte
    ;     string pointer (into the string heap, or &empty_str when unset) held in its own heap ---
    const uword SARRHEAP_SIZE = 512          ; 256 element pointers shared across all string arrays
    uword      sarrheap = memory("vm_sarrheap", SARRHEAP_SIZE, 0)
    uword[32]  sarr_base          ; byte offset of each string array within sarrheap
    uword[32]  sarr_len           ; total element count (0 = undimensioned/unusable)
    ubyte[32]  sarr_ndims
    uword      sarr_dims = memory("vm_sarrdims", 32 * pcode.MAXDIMS * 2, 0)
    uword      sarr_top           ; bump pointer into sarrheap (bytes)

    ubyte[16]  inbuf              ; one line of INPUT text (null-terminated)

    sub run(uword base) {
        uword pc = 0
        sp = 0
        csp = 0
        forsp = 0
        ssp = 0
        heap_top = 0
        sys.memset(varsf, 640, 0)        ; all-zero bytes == float 0.0 (BASIC vars start at 0)
        arr_top = 0
        sys.memset(&arr_len, 64, 0)      ; 32 words -> 64 bytes: all numeric arrays undimensioned
        sarr_top = 0
        sys.memset(&sarr_len, 64, 0)     ; all string arrays undimensioned too
        dataptr = database               ; READ starts at the first DATA item
        ubyte si
        for si in 0 to 63 {
            svars[si] = &empty_str       ; unset string variables read as ""
        }
        repeat {
            ubyte op = @(base + pc)
            pc++
            when op {
                pcode.OP_PUSHI -> {
                    stack[sp] = mkword(@(base + pc + 1), @(base + pc)) as float
                    pc += 2
                    sp++
                }
                pcode.OP_PUSHF -> {
                    stack[sp] = peekf(base + pc)         ; 5-byte float immediate
                    pc += 5
                    sp++
                }
                pcode.OP_LOADV -> {
                    stack[sp] = peekf(varsf + (@(base + pc) as uword) * 5)
                    pc += 2
                    sp++
                }
                pcode.OP_STORV -> {
                    sp--
                    pokef(varsf + (@(base + pc) as uword) * 5, stack[sp])
                    pc += 2
                }
                pcode.OP_ADD -> {
                    sp--
                    stack[sp-1] += stack[sp]
                }
                pcode.OP_SUB -> {
                    sp--
                    stack[sp-1] -= stack[sp]
                }
                pcode.OP_MUL -> {
                    sp--
                    stack[sp-1] *= stack[sp]
                }
                pcode.OP_DIV -> {
                    sp--
                    stack[sp-1] /= stack[sp]
                }
                pcode.OP_POW -> {                    ; a ^ b  (float power via ROM's FPWR)
                    sp--
                    stack[sp-1] = floats.pow(stack[sp-1], stack[sp])
                }
                pcode.OP_NEG -> {
                    stack[sp-1] = -stack[sp-1]
                }
                pcode.OP_CMPEQ -> {
                    sp--
                    stack[sp-1] = bool_to_float(stack[sp-1] == stack[sp])
                }
                pcode.OP_CMPNE -> {
                    sp--
                    stack[sp-1] = bool_to_float(stack[sp-1] != stack[sp])
                }
                pcode.OP_CMPLT -> {
                    sp--
                    stack[sp-1] = bool_to_float(stack[sp-1] < stack[sp])
                }
                pcode.OP_CMPGT -> {
                    sp--
                    stack[sp-1] = bool_to_float(stack[sp-1] > stack[sp])
                }
                pcode.OP_CMPLE -> {
                    sp--
                    stack[sp-1] = bool_to_float(stack[sp-1] <= stack[sp])
                }
                pcode.OP_CMPGE -> {
                    sp--
                    stack[sp-1] = bool_to_float(stack[sp-1] >= stack[sp])
                }
                pcode.OP_AND -> {                        ; bitwise AND of the two 16-bit values
                    sp--
                    stack[sp-1] = ((as_bits(stack[sp-1]) & as_bits(stack[sp])) as word) as float
                }
                pcode.OP_OR -> {                         ; bitwise OR
                    sp--
                    stack[sp-1] = ((as_bits(stack[sp-1]) | as_bits(stack[sp])) as word) as float
                }
                pcode.OP_NOT -> {                        ; bitwise complement (NOT x == -(x+1))
                    stack[sp-1] = ((~ as_bits(stack[sp-1])) as word) as float
                }
                pcode.OP_JMP -> {
                    pc = mkword(@(base + pc + 1), @(base + pc))
                }
                pcode.OP_JZ -> {
                    sp--
                    if stack[sp] == 0.0
                        pc = mkword(@(base + pc + 1), @(base + pc))
                    else
                        pc += 2
                }
                pcode.OP_GOSUB -> {
                    uword target = mkword(@(base + pc + 1), @(base + pc))
                    pc += 2
                    callstack[csp] = pc          ; return here
                    csp++
                    pc = target
                }
                pcode.OP_RET -> {
                    csp--
                    pc = callstack[csp]
                }
                pcode.OP_FORPUSH -> {
                    ubyte slot = @(base + pc)    ; slot < 128, fits in a byte
                    pc += 2
                    sp--
                    float stepv = stack[sp]      ; step was pushed last
                    sp--
                    for_var[forsp] = slot
                    for_limit[forsp] = stack[sp] ; then limit
                    for_step[forsp] = stepv
                    for_top[forsp] = pc          ; body starts right after this opcode
                    forsp++
                }
                pcode.OP_FORNEXT -> {
                    ubyte top = forsp - 1
                    uword vaddr = varsf + (for_var[top] as uword) * 5
                    float nv = peekf(vaddr) + for_step[top]
                    pokef(vaddr, nv)
                    bool cont
                    if for_step[top] >= 0.0
                        cont = nv <= for_limit[top]
                    else
                        cont = nv >= for_limit[top]
                    if cont
                        pc = for_top[top]
                    else
                        forsp--                  ; loop finished; pop the frame
                }
                pcode.OP_PRINTI -> {
                    sp--
                    last_printed = stack[sp] as word     ; truncated integer, for the mailbox
                    print_float(stack[sp])               ; BASIC-formatted, no newline
                }
                pcode.OP_PRINTS -> {
                    ssp--
                    print_cstr(sstack[ssp])
                }
                pcode.OP_NEWLINE -> {
                    emit_char(13)                         ; CR to screen, LF to host console
                }
                pcode.OP_PUSHS -> {
                    ; operand is an offset into the literal pool; litbase makes it absolute,
                    ; so the same P-code works both in-process and in a standalone .PRG
                    sstack[ssp] = litbase + mkword(@(base + pc + 1), @(base + pc))
                    ssp++
                    pc += 2
                }
                pcode.OP_LOADS -> {
                    sstack[ssp] = svars[@(base + pc)]
                    ssp++
                    pc += 2
                }
                pcode.OP_STORS -> {
                    ssp--
                    svars[@(base + pc)] = sstack[ssp]
                    pc += 2
                }
                pcode.OP_CONCAT -> {
                    ; BASIC caps strings at 255 chars because the length is one byte -- and our
                    ; strings.length/copy are ubyte too, so a longer string would wrap and corrupt the
                    ; heap. Enforce it here (as the ROM does with ?STRING TOO LONG), computing the total
                    ; in uword so the check itself can't wrap. Both operands are <=255 by induction.
                    uword ctot = (strings.length(sstack[ssp-1]) as uword) + strings.length(sstack[ssp-2])
                    if ctot > 255 {
                        print_cstr(&str_long_msg)
                        emit_char(13)
                        return
                    }
                    ; reserve while both operands are still on sstack (so a GC keeps + relocates them),
                    ; then re-read a/b -- gc_ensure may have compacted the heap and moved them.
                    uword cneed = ctot + 1
                    if not gc_ensure(cneed)
                        return
                    ssp--
                    uword b = sstack[ssp]
                    ssp--
                    uword a = sstack[ssp]
                    uword dst = heap + heap_top
                    ubyte la = strings.copy(a, dst)
                    ubyte lb = strings.copy(b, dst + la)
                    heap_top += la
                    heap_top += lb
                    heap_top++                            ; the terminating null
                    sstack[ssp] = dst
                    ssp++
                }
                pcode.OP_DIM -> {                        ; DIM A(d0[,d1..]): allocate a numeric array
                    ubyte adslot = @(base + pc)          ; imm16 slot (low byte; slot < 256)
                    ubyte adnd = @(base + pc + 2)        ; ndims byte follows the 2-byte slot
                    pc += 3
                    uword adtot = dim_setup(arr_dims, adslot, adnd, ARRHEAP_SIZE / 5)
                    if adtot != 0 and arr_top + adtot * 5 <= ARRHEAP_SIZE {
                        arr_base[adslot] = arr_top
                        arr_len[adslot] = adtot
                        arr_ndims[adslot] = adnd
                        arr_top += adtot * 5
                    } else {
                        arr_len[adslot] = 0                  ; too big / out of heap -> unusable
                    }
                }
                pcode.OP_ALOAD -> {                      ; A(i[,j..]): push the element (0 if out of range)
                    ubyte alslot = @(base + pc)
                    ubyte alnd = @(base + pc + 2)
                    pc += 3
                    uword aloff = index_of(arr_dims, alslot, alnd, sp - alnd, arr_len[alslot])
                    sp -= alnd
                    if aloff != $ffff
                        stack[sp] = peekf(arrheap + arr_base[alslot] + aloff * 5)
                    else
                        stack[sp] = 0.0
                    sp++
                }
                pcode.OP_ASTORE -> {                     ; A(i[,j..])=v: store into the element (dropped if out of range)
                    ubyte asslot = @(base + pc)
                    ubyte asnd = @(base + pc + 2)
                    pc += 3
                    sp--
                    float asval = stack[sp]                  ; value was pushed after the subscripts
                    uword asoff = index_of(arr_dims, asslot, asnd, sp - asnd, arr_len[asslot])
                    sp -= asnd
                    if asoff != $ffff
                        pokef(arrheap + arr_base[asslot] + asoff * 5, asval)
                }
                pcode.OP_SDIM -> {                       ; DIM A$(...): allocate a string array (elements start "")
                    ubyte sdslot = @(base + pc)
                    ubyte sdnd = @(base + pc + 2)
                    pc += 3
                    uword sdtot = dim_setup(sarr_dims, sdslot, sdnd, SARRHEAP_SIZE / 2)
                    if sdtot != 0 and sarr_top + sdtot * 2 <= SARRHEAP_SIZE {
                        sarr_base[sdslot] = sarr_top
                        sarr_len[sdslot] = sdtot
                        sarr_ndims[sdslot] = sdnd
                        uword sdp = sarrheap + sarr_top
                        uword sdi = 0
                        while sdi < sdtot {
                            pokew(sdp, &empty_str)           ; unset elements read as ""
                            sdp += 2
                            sdi++
                        }
                        sarr_top += sdtot * 2
                    } else {
                        sarr_len[sdslot] = 0
                    }
                }
                pcode.OP_SALOAD -> {                     ; A$(i[,j..]): push the element string ("" if out of range)
                    ubyte slslot = @(base + pc)
                    ubyte slnd = @(base + pc + 2)
                    pc += 3
                    uword sloff = index_of(sarr_dims, slslot, slnd, sp - slnd, sarr_len[slslot])
                    sp -= slnd
                    if sloff != $ffff
                        sstack[ssp] = peekw(sarrheap + sarr_base[slslot] + sloff * 2)
                    else
                        sstack[ssp] = &empty_str
                    ssp++
                }
                pcode.OP_SASTORE -> {                    ; A$(i[,j..])=v$: store the element (dropped if out of range)
                    ubyte ssslot = @(base + pc)
                    ubyte ssnd = @(base + pc + 2)
                    pc += 3
                    ssp--
                    uword ssval = sstack[ssp]                ; the string value, pushed after the subscripts
                    uword ssoff = index_of(sarr_dims, ssslot, ssnd, sp - ssnd, sarr_len[ssslot])
                    sp -= ssnd
                    if ssoff != $ffff
                        pokew(sarrheap + sarr_base[ssslot] + ssoff * 2, ssval)
                }
                pcode.OP_INPUTV -> {
                    ubyte ivslot = @(base + pc)
                    pc += 2
                    read_line()
                    pokef(varsf + (ivslot as uword) * 5, floats.parse(&inbuf))
                }
                pcode.OP_INPUTS -> {
                    ubyte isslot = @(base + pc)
                    pc += 2
                    read_line()
                    if not gc_ensure(strings.length(&inbuf) as uword + 1)
                        return
                    uword idst = heap + heap_top          ; keep the entered text on the string heap
                    ubyte iln = strings.copy(&inbuf, idst)
                    heap_top += iln
                    heap_top++
                    svars[isslot] = idst
                }
                pcode.OP_POKE -> {
                    sp--
                    ubyte v = lsb(stack[sp] as uword)    ; value (low byte)
                    sp--
                    @(stack[sp] as uword) = v            ; ...into the target address
                }
                pcode.OP_PEEK -> {
                    stack[sp-1] = @(stack[sp-1] as uword) as float   ; addr -> byte 0..255
                }
                pcode.OP_WAIT -> {                   ; WAIT addr,mask,xor: spin until (peek(addr) ^ xor) & mask
                    sp--
                    ubyte wxor = lsb(stack[sp] as uword)
                    sp--
                    ubyte wmask = lsb(stack[sp] as uword)
                    sp--
                    uword waddr = stack[sp] as uword
                    while ((@(waddr) ^ wxor) & wmask) == 0 {
                        ; spin until the masked bits (after the XOR flip) go nonzero
                    }
                }
                pcode.OP_CALLFN -> {
                    ubyte fnid = @(base + pc)
                    pc++
                    stack[sp-1] = apply_fn(fnid, stack[sp-1])
                }
                pcode.OP_STRNUM -> {                     ; LEN/ASC/VAL: pop string, push number
                    ubyte snid = @(base + pc)
                    pc++
                    ssp--
                    uword snstr = sstack[ssp]
                    when snid {
                        pcode.SN_LEN -> stack[sp] = strings.length(snstr) as float
                        pcode.SN_ASC -> stack[sp] = @(snstr) as float   ; first byte (0 if empty)
                        pcode.SN_VAL -> stack[sp] = floats.parse(snstr)
                    }
                    sp++
                }
                pcode.OP_NUMSTR -> {                     ; CHR$/STR$: pop number, push heap string
                    ubyte nsid = @(base + pc)
                    pc++
                    sp--
                    uword nsdst = 0                                     ; assigned in each branch after its GC
                    when nsid {
                        pcode.NS_CHR -> {
                            if not gc_ensure(2)
                                return
                            nsdst = heap + heap_top                     ; derive AFTER a possible GC
                            @(nsdst) = lsb(stack[sp] as uword)          ; one PETSCII char
                            @(nsdst + 1) = 0
                            heap_top += 2
                        }
                        pcode.NS_STR -> {
                            uword nssrc = floats.tostr(stack[sp])       ; ROM buffer, stable across a GC
                            if @(nssrc) == ' '
                                nssrc++                                 ; match PRINT: drop FOUT's lead space
                            if not gc_ensure(strings.length(nssrc) as uword + 1)
                                return
                            nsdst = heap + heap_top
                            ubyte nsn = strings.copy(nssrc, nsdst)
                            heap_top += nsn
                            heap_top++
                        }
                    }
                    sstack[ssp] = nsdst
                    ssp++
                }
                pcode.OP_LEFTS -> {                      ; LEFT$(s,n): first n chars
                    sp--
                    ubyte lfn = clamp_count(stack[sp])
                    if not gc_ensure(lfn as uword + 1)   ; src still on sstack -> protected across a GC
                        return
                    ssp--
                    uword lfsrc = sstack[ssp]            ; re-read: gc_ensure may have compacted the heap
                    sstack[ssp] = substr(lfsrc, 0, lfn)
                    ssp++
                }
                pcode.OP_RIGHTS -> {                     ; RIGHT$(s,n): last n chars
                    sp--
                    ubyte rtn = clamp_count(stack[sp])
                    if not gc_ensure(rtn as uword + 1)
                        return
                    ssp--
                    uword rtsrc = sstack[ssp]            ; re-read: gc_ensure may have compacted the heap
                    ubyte rtlen = strings.length(rtsrc)
                    ubyte rtstart = 0
                    if rtn < rtlen
                        rtstart = rtlen - rtn
                    sstack[ssp] = substr(rtsrc, rtstart, rtn)
                    ssp++
                }
                pcode.OP_MIDS -> {                       ; MID$(s,start,len): substring, start 1-based
                    sp--
                    ubyte mdlen = clamp_count(stack[sp])
                    sp--
                    word mdstart = stack[sp] as word
                    if not gc_ensure(mdlen as uword + 1)
                        return
                    ssp--
                    uword mdsrc = sstack[ssp]            ; re-read: gc_ensure may have compacted the heap
                    ubyte mds0 = 0
                    if mdstart > 256
                        mds0 = 255                                      ; past end -> empty
                    else if mdstart >= 1
                        mds0 = (mdstart - 1) as ubyte
                    sstack[ssp] = substr(mdsrc, mds0, mdlen)
                    ssp++
                }
                pcode.OP_READ -> {                       ; READ into a numeric var: parse the item
                    ubyte rdslot = @(base + pc)
                    pc += 2
                    pokef(varsf + (rdslot as uword) * 5, floats.parse(data_next()))
                }
                pcode.OP_READS -> {                      ; READ into a string var: heap-copy the item
                    ubyte rsslot = @(base + pc)
                    pc += 2
                    uword rssrc = data_next()            ; DATA-pool text (stable across a GC)
                    if not gc_ensure(strings.length(rssrc) as uword + 1)
                        return
                    uword rsdst = heap + heap_top
                    ubyte rsn = strings.copy(rssrc, rsdst)
                    heap_top += rsn
                    heap_top++
                    svars[rsslot] = rsdst
                }
                pcode.OP_RESTORE -> {                    ; rewind the DATA cursor to the first item
                    dataptr = database
                }
                pcode.OP_RDNUM -> {                      ; READ into an array element: push the item as a number
                    stack[sp] = floats.parse(data_next())
                    sp++
                }
                pcode.OP_RDSTR -> {                      ; READ into a string-array element: push the item text
                    sstack[ssp] = data_next()            ; the pool text persists all run -> no heap copy needed
                    ssp++
                }
                pcode.OP_SCMP -> {                       ; compare two strings -> numeric truth (-1/0)
                    ubyte scid = @(base + pc)
                    pc++
                    ssp--
                    uword scb = sstack[ssp]              ; right operand (pushed last)
                    ssp--
                    uword sca = sstack[ssp]              ; left operand
                    byte rel = strings.compare(sca, scb) ; -1 if a<b, 0 if equal, 1 if a>b
                    bool scres = false
                    when scid {
                        pcode.SC_EQ -> scres = rel == 0
                        pcode.SC_NE -> scres = rel != 0
                        pcode.SC_LT -> scres = rel < 0
                        pcode.SC_GT -> scres = rel > 0
                        pcode.SC_LE -> scres = rel <= 0
                        pcode.SC_GE -> scres = rel >= 0
                    }
                    stack[sp] = bool_to_float(scres)
                    sp++
                }
                pcode.OP_SYS -> {
                    sp--
                    sys_target = stack[sp] as uword
                    sys_call()                            ; JSR to sys_target, returns here
                }
                pcode.OP_OPEN -> {                        ; OPEN lfn,dev,sa,"name"
                    sp--
                    ubyte o_sa  = lsb(stack[sp] as uword)
                    sp--
                    ubyte o_dev = lsb(stack[sp] as uword)
                    sp--
                    ubyte o_lfn = lsb(stack[sp] as uword)
                    ssp--
                    uword o_name = sstack[ssp]
                    cbm.SETNAM(strings.length(o_name), o_name)
                    cbm.SETLFS(o_lfn, o_dev, o_sa)
                    void cbm.OPEN()
                }
                pcode.OP_CLOSE -> {                       ; CLOSE lfn
                    sp--
                    cbm.CLOSE(lsb(stack[sp] as uword))
                }
                pcode.OP_GETCH -> {                       ; GET#lfn,v$ : one byte -> a 0/1-char heap string
                    sp--
                    void cbm.CHKIN(lsb(stack[sp] as uword))
                    ubyte g_ch = cbm.CHRIN()
                    cbm.CLRCHN()
                    if not gc_ensure(2)                   ; g_ch is a local -> stable across a GC
                        return
                    uword g_dst = heap + heap_top
                    @(g_dst) = g_ch                       ; g_ch==0 -> "" (empty), else a 1-char string
                    @(g_dst + 1) = 0
                    heap_top += 2
                    sstack[ssp] = g_dst
                    ssp++
                }
                pcode.OP_STATUS -> {                      ; ST : the KERNAL I/O status word
                    stack[sp] = cbm.READST() as float
                    sp++
                }
                pcode.OP_CHKOUT -> {                      ; PRINT#lfn : redirect the following PRINTs
                    sp--
                    cbm.CHKOUT(lsb(stack[sp] as uword))
                }
                pcode.OP_CHKIN -> {                       ; INPUT#lfn : redirect the following INPUT
                    sp--
                    void cbm.CHKIN(lsb(stack[sp] as uword))
                }
                pcode.OP_CLRCH -> {                       ; end a PRINT#/INPUT#, restore default I/O
                    cbm.CLRCHN()
                }
                pcode.OP_END -> {
                    return
                }
            }
        }
    }

    ; --- string-heap garbage collection --------------------------------------------------------
    ; The heap is a bump arena of null-terminated strings; concat/slice/CHR$/INPUT/READ abandon the
    ; old copies, so it fills with garbage. We mirror the 1986 Blitz exactly: it bump-allocated
    ; strings downward and only JSR'd the C64 ROM's GARBAG collector *on collision*, then re-checked
    ; and raised OUT OF MEMORY if that still didn't free enough (BLITZ.prg $1f7a). We can't borrow a
    ; ROM collector on the X16 (its string internals are undocumented, like SYSPASS), so we compact
    ; over our own roots instead. gc_ensure() is called at every allocation site with the exact byte
    ; count needed; it collects only when the fast bump would overflow.

    ; Ensure `need` free bytes on the heap. Fast path: already fits. Else compact and re-check; if it
    ; still won't fit, print ?OUT OF MEMORY and return false so the caller halts run().
    sub gc_ensure(uword need) -> bool {
        if heap_top + need <= HEAP_SIZE
            return true
        gc_collect()
        if heap_top + need <= HEAP_SIZE
            return true
        print_cstr(&heap_full_msg)
        emit_char(13)
        return false
    }

    ; Mark-compact: slide every string still reachable from a root down to the bottom of the heap
    ; (dropping the unreferenced ones) and repoint the roots. Roots = svars, the live sstack, and
    ; string-array elements (sarrheap). Pointers outside [heap, heap+heap_top) -- literals, DATA,
    ; &empty_str -- aren't ours and are left alone. Liveness needs no mark bit: it's "some root
    ; points at this start", tested against the small fixed root set (see gc_referenced).
    sub gc_collect() {
        uword rd = heap                       ; read cursor over the existing strings
        uword wr = heap                       ; write cursor: compacted output, packed from the bottom
        uword hend = heap + heap_top
        while rd < hend {
            uword nextrd = rd                 ; find the terminator, then step one past it
            while @(nextrd) != 0
                nextrd++
            nextrd++
            uword s = rd                      ; tentatively slide down to wr (wr <= rd -> safe forward copy)
            uword d = wr
            while s != nextrd {
                @(d) = @(s)
                s++
                d++
            }
            if gc_rewrite(rd, wr)             ; live? repoint roots rd->wr and keep the copy
                wr += nextrd - rd
            rd = nextrd                       ; dead: leave wr, so the next string overwrites the copy
        }
        heap_top = wr - heap
    }

    ; Repoint every root holding `oldp` to `newp`; return true if any did -- which doubles as the
    ; liveness test the compactor needs, so there's no separate scan. Roots = svars, the live sstack,
    ; and string-array elements (sarrheap).
    sub gc_rewrite(uword oldp, uword newp) -> bool {
        bool found = false
        ubyte i
        for i in 0 to 63 {
            if svars[i] == oldp {
                svars[i] = newp
                found = true
            }
        }
        i = 0
        while i < ssp {                       ; while-form avoids the ubyte 0-1 wrap when ssp==0
            if sstack[i] == oldp {
                sstack[i] = newp
                found = true
            }
            i++
        }
        uword e = 0
        while e < sarr_top {
            if peekw(sarrheap + e) == oldp {
                pokew(sarrheap + e, newp)
                found = true
            }
            e += 2
        }
        return found
    }

    ; Indirect JSR for OP_SYS: the 65C02 has no "JSR (indirect)", so we JSR into here and
    ; JMP-indirect to the target. The target's RTS returns to run()'s dispatch loop (our
    ; caller), so the net effect is a subroutine call to sys_target -- exactly BASIC's SYS.
    sub sys_call() {
        %asm {{
            jmp  (p8b_vm.p8v_sys_target)
        }}
    }

    ; BASIC truth values: true = -1, false = 0 (as floats)
    sub bool_to_float(bool b) -> float {
        if b
            return -1.0
        return 0.0
    }

    ; reinterpret a numeric cell as its 16-bit integer bit pattern (float -> signed word -> bits),
    ; for the bitwise AND/OR/NOT. -1.0 -> $FFFF, 0.0 -> $0000, 5.0 -> $0005.
    sub as_bits(float f) -> uword {
        return (f as word) as uword
    }

    ; apply a built-in function to x. Most delegate to the ROM Math library (via Prog8's
    ; floats module / float builtins); INT is floor, SGN returns -1/0/1.
    sub apply_fn(ubyte fnid, float x) -> float {
        when fnid {
            pcode.FN_SGN -> return sgn(x) as float
            pcode.FN_INT -> return floats.floor(x)
            pcode.FN_ABS -> return abs(x)
            pcode.FN_SQR -> return sqrt(x)
            pcode.FN_RND -> return floats.rnd()      ; a fresh random 0..1 (arg ignored)
            pcode.FN_SIN -> return floats.sin(x)
            pcode.FN_COS -> return floats.cos(x)
            pcode.FN_TAN -> return floats.tan(x)
            pcode.FN_ATN -> return floats.atan(x)
            pcode.FN_LOG -> return floats.ln(x)
        }
        return x
    }

    ; Set up an N-D array descriptor from `nd` max-index subscripts sitting on top of the numeric
    ; stack (which it pops). Writes the per-dimension sizes s_j = idx_j+1 into dims_ptr for `slot`,
    ; zeroes the unused dimension slots, and returns the total element count -- or 0 if the product
    ; overflows `cap` (the caller then marks the array unusable rather than allocating past its heap).
    sub dim_setup(uword dims_ptr, ubyte slot, ubyte nd, uword cap) -> uword {
        uword total = 1
        ubyte j = 0
        while j < nd {
            uword sz = (stack[sp - nd + j] as uword) + 1     ; DIM A(n) -> n+1 elements in that dim
            pokew(dims_ptr + (((slot as uword) * pcode.MAXDIMS) + j) * 2, sz)
            if total != 0 {
                if sz == 0 or total > cap / sz
                    total = 0                                ; too large (or negative dim wrapped) -> unusable
                else
                    total = total * sz
            }
            j++
        }
        while j < pcode.MAXDIMS {
            pokew(dims_ptr + (((slot as uword) * pcode.MAXDIMS) + j) * 2, 0)   ; clear unused dims
            j++
        }
        sp -= nd
        return total
    }

    ; Row-major element offset for the `nd` subscripts at stack[first .. first+nd-1], using the
    ; per-dimension sizes at dims_ptr for `slot`. `total` is the array's element count (0 for an
    ; undimensioned array). Returns $ffff if any subscript is outside its dimension -- so the caller
    ; reads 0/"" or drops the store, and never a heap access outside the array.
    sub index_of(uword dims_ptr, ubyte slot, ubyte nd, ubyte first, uword total) -> uword {
        if total == 0
            return $ffff
        uword off = 0
        ubyte j = 0
        while j < nd {
            uword sz = peekw(dims_ptr + (((slot as uword) * pcode.MAXDIMS) + j) * 2)
            uword ix = stack[first + j] as uword
            if ix >= sz
                return $ffff
            off = off * sz + ix
            j++
        }
        return off
    }

    ; copy `count` chars starting at byte `start` of `src` onto the string heap, null-terminate,
    ; and return the new string. Clamps to the source's actual length, so an over-long request or
    ; a start past the end simply yields a shorter (possibly empty) string -- never a read past it.
    sub substr(uword src, ubyte start, ubyte count) -> uword {
        ubyte slen = strings.length(src)
        if start >= slen {
            count = 0
        } else {
            ubyte avail = slen - start
            if count > avail
                count = avail
        }
        uword dst = heap + heap_top
        ubyte k = 0
        while k < count {
            @(dst + k) = @(src + start + k)
            k++
        }
        @(dst + count) = 0
        heap_top += count
        heap_top++
        return dst
    }

    ; return the current DATA item's text and advance the cursor past it. Out of data reads as ""
    ; (which parses as 0 for a numeric READ) rather than raising a runtime error.
    sub data_next() -> uword {
        if dataptr >= datatop
            return &empty_str
        uword item = dataptr
        while @(dataptr) != 0            ; walk to the item's terminating null
            dataptr++
        dataptr++                        ; and past it, to the next item
        return item
    }

    ; a character count for LEFT$/RIGHT$/MID$: truncate the float to 0..255 (BASIC takes INT of it)
    sub clamp_count(float f) -> ubyte {
        if f <= 0.0
            return 0
        if f >= 255.0
            return 255
        return lsb(f as uword)
    }

    ; print a float in BASIC's format, echoing to screen + host console. FOUT prefixes a
    ; leading space for non-negative numbers; drop it so numeric output stays compact.
    sub print_float(float f) {
        uword s = floats.tostr(f)
        if @(s) == ' '
            s++
        print_cstr(s)
    }

    ; one character to the X16 screen, and echoed to the host console for headless
    ; tests. The host byte is translated PETSCII->ASCII (CR->LF) so captured output
    ; is readable text.
    sub emit_char(ubyte ch) {
        cbm.CHROUT(ch)
        @(EMU_CHROUT) = to_host(ch)
    }

    sub to_host(ubyte ch) -> ubyte {
        if ch == 13
            return 10                    ; newline for the host console
        if ch >= $c1 and ch <= $da
            return ch - $80              ; defensive: any shifted-PETSCII uppercase -> ASCII
        return ch                        ; ASCII letters/digits/punctuation pass through
    }

    sub print_cstr(uword ptr) {
        ubyte ch = @(ptr)
        while ch != 0 {
            emit_char(ch)
            ptr++
            ch = @(ptr)
        }
    }

    ; read one line from the keyboard into inbuf (null-terminated). Characters echo to the
    ; screen only (not the host console), so headless output stays clean. Waits for a key via
    ; GETIN, ending on CR; long input is capped at the buffer size.
    sub read_line() {
        ubyte n = 0
        repeat {
            ubyte ch = cbm.GETIN2()
            if ch == 0
                continue                 ; queue empty: keep waiting for a key
            if ch == 13
                break                    ; RETURN ends the line
            if n < 15 {
                inbuf[n] = ch
                cbm.CHROUT(ch)           ; echo to the screen only
                n++
            }
        }
        inbuf[n] = 0
        cbm.CHROUT(13)                   ; move the cursor to the next line
    }
}
