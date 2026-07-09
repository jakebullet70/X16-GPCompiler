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

%import strings
%import floats
%import pcode_format
%import bstr

vm {
    const uword EMU_CHROUT = $9fbb        ; x16emu: writing here echoes a char to the host console

    float[32] stack
    ubyte     sp
    ; Integer-first arithmetic (Phase 5): istack is a parallel 16-bit-word stack that SHARES `sp` with
    ; the float `stack`. A given slot holds EITHER a float (stack[sp]) or an int (istack[sp]); which one
    ; is live is fixed by the compiler's typed opcode stream, so no runtime tag is kept. Coercion opcodes
    ; (OP_ITOF/ITOF2/FTOI) move a value between the two representations at the same slot.
    word[32]  @shared istack     ; @shared: referenced only from hand-asm handlers (prog8 can't see those)
    ; The five VM slabs (varsf, ivarsf, arrheap, arr_dims, sarr_dims -- SLAB_BYTES total) are no longer
    ; prog8-allocated in low BSS. They're host-assigned POINTERS placed at run() time: a standalone
    ; program parks them in free RAM just ABOVE the loaded P-code (so nothing sits between the runtime
    ; code and the P-code, and the .PRG carries no multi-KB filler); the resident compiler pre-sets them
    ; to its own buffer before vm.run. See run() for the layout.
    const uword SLAB_BYTES = 640 + 256 + 2048 + 256 + 256 + 1024 + 256   ; = 4736
                             ; varsf ivarsf arrheap arr_dims sarr_dims iarrheap iarr_dims
    ; variable slots: 128 floats * 5 bytes = 640, addressed as varsf + slot*5 via peekf/pokef
    uword @shared varsf
    ; integer (`%`) variable slots: 128 words addressed as ivarsf + slot*2
    uword @shared ivarsf
    word      last_printed        ; most recent PRINTI, truncated to an integer (for headless tests)
    ; When true, emit_char also mirrors each printed byte to the x16emu debug register $9FBB so the
    ; HEADLESS test harness can capture program output on the host console. A shipped program (visual /
    ; standalone / interactive) must NOT touch $9FBB -- native X16 BASIC never does -- so this defaults
    ; OFF and each main enables it only in its TESTBENCH build (vm.host_echo = TESTBENCH before vm.run).
    bool      host_echo = false

    uword[16] @shared callstack  ; GOSUB return addresses (referenced only from asm op_gosub/op_ret)
    ubyte     csp

    ubyte[8]  @shared for_var    ; FOR loop frames (innermost on top); @shared: all FOR handlers are now asm
    float[8]  @shared for_limit
    float[8]  @shared for_step
    word[8]   @shared for_ilimit ; integer FOR (FOR I%=..): 16-bit limit + step, and for_var holds an
    word[8]   @shared for_istep  ; ivarsf slot. A frame uses EITHER the float or the int pair -- which is
                                 ; @shared: now referenced only from hand-asm op_iforpush/op_ifornext
                                 ; fixed by the opcode (OP_FORNEXT vs OP_IFORNEXT), so no per-frame tag.
    uword[8]  @shared for_top    ; pcode offset of the loop body's first instruction
    ubyte     forsp

    ; --- strings (BASIC-format, collected by the ROM garbage collector via the bstr module) ---
    ; sstack holds descriptor ADDRESSES (into bstr's var table / temp stack / string-array data, or
    ; a scratch cell in sdesc for off-heap literals & DATA). A string VALUE is a 3-byte descriptor
    ; [len][ptr_lo][ptr_hi]; bstr owns allocation (ROM getspa) and rooting (BASIC's own tables), so
    ; the VM keeps no private string heap and runs no collector of its own.
    ; --- interpreter dispatch state (module-level so the hand-asm jump-table loop in run() and the
    ;     per-opcode handler subs share them) ---
    uword      pcbase            ; base address of the P-code blob
    uword      pc                ; program counter: offset into the blob
    bool       halt              ; a handler sets this to end run() (OP_END / a fatal string error)

    uword[16]  sstack            ; string-value stack (holds descriptor addresses)
    ubyte      ssp
    ubyte[48]  sdesc             ; per-slot scratch descriptors for off-heap literals/DATA (16 * 3)
    uword @shared shtmp          ; hand-asm string handlers park a descriptor here across bstr calls
    uword @shared shtmp2         ; second scratch word (string-array handlers need slot/nd + tot/off)
                                 ; (BSS, so they cost no .prg bytes; live only within one handler)
    str        str_long_msg  = "?STRING TOO LONG"     ; a concat would exceed BASIC's 255-char limit
    str        formula_msg   = "?FORMULA TOO COMPLEX" ; > 3 live string temporaries (BASIC's limit)
    str        empty_c       = ""                     ; off-heap "" for out-of-data READ results
    uword      litbase           ; base address of the string-literal pool (set by the host
                                 ; before run(): &litpool in-process, from the header standalone)
    uword      sys_target        ; OP_SYS call target (indirection cell for the JSR trick)

    ; --- READ / DATA: the data pool is null-terminated item texts in line order; a cursor walks
    ;     it, RESTORE rewinds it. database/datatop are set by the host before run() (like litbase). ---
    uword      database          ; start of the DATA pool
    uword      datatop           ; one past the end of the DATA pool (out-of-data boundary)
    uword      dataptr           ; the READ cursor
    ; string-heap FLOOR: where BASIC's string var table + heap are placed. In-process (compiler resident)
    ; the host sets this to sys.progend() -- ABOVE all the compiler's + runtime's slabs, so the heap uses
    ; the free RAM up to MEMTOP without a slab-ordering dependency. Standalone leaves it 0 -> the heap
    ; floors at datatop (above the loaded P-code). Kept separate from datatop, which READ still needs.
    uword      heapfloor

    ; --- numeric arrays (DIM): a bump-allocated heap of floats + per-array descriptors. Arrays are
    ;     N-dimensional (up to pcode.MAXDIMS subscripts); the per-dimension SIZES drive the row-major
    ;     element offset (see index_of) and per-subscript bounds checks. ---
    const uword ARRHEAP_SIZE = 2048          ; ~409 float elements shared across all arrays
    uword @shared arrheap                    ; host-assigned (see SLAB_BYTES / run())
    uword[32]  arr_base           ; byte offset of each array within arrheap
    uword[32]  arr_len            ; total element count of each array (0 = undimensioned/unusable)
    ubyte[32]  arr_ndims          ; number of dimensions of each array
    ; per-array dimension sizes, MAXDIMS words per array: arr_dims[slot*MAXDIMS + j] = size of dim j
    uword @shared arr_dims                   ; host-assigned (see SLAB_BYTES / run())
    uword      arr_top            ; bump pointer into arrheap (bytes)

    ; --- integer arrays (DIM A%(...)): the int twins of the numeric arrays above. Elements are 16-bit
    ;     words (2 bytes) in their own bump heap; the same generic dim_setup/index_of drive layout. Their
    ;     own slot namespace (the compiler's iarrnames table), so the metadata is a separate set of 32. ---
    const uword IARRHEAP_SIZE = 1024         ; 512 int elements shared across all `%` arrays
    uword @shared iarrheap                   ; host-assigned (see SLAB_BYTES / run())
    uword[32]  iarr_base          ; byte offset of each int array within iarrheap
    uword[32]  iarr_len           ; total element count (0 = undimensioned/unusable)
    ubyte[32]  iarr_ndims         ; number of dimensions
    uword @shared iarr_dims                  ; per-array dim sizes (MAXDIMS words/array); host-assigned
    uword      iarr_top           ; bump pointer into iarrheap (bytes)

    ; --- string arrays (DIM A$(...)): real BASIC arrays built by bstr in the ARYTAB..STREND region;
    ;     each element is a 3-byte descriptor the ROM collector walks. The VM keeps only the per-array
    ;     dimension metadata (for row-major index math); bstr owns the element storage + rooting. ---
    const uword SARR_MAXELEM = 8192          ; cap on a string array's element count (dim_setup guard)
    uword[32]  sarr_len          ; total element count (0 = undimensioned/unusable)
    ubyte[32]  sarr_ndims
    uword @shared sarr_dims                  ; host-assigned (see SLAB_BYTES / run())

    ubyte[16]  inbuf              ; one line of INPUT text (null-terminated)
    ; OP_PASSTHRU scratch: a low-RAM copy of one tokenized statement handed to ROM BASIC. Low RAM (not
    ; the banked P-code) so TXTPTR/CHRGET reach it regardless of the current RAM bank. Layout the ROM
    ; expects: [':' the first CHRGET steps over][statement tokens...][$00 end-of-line]. 256 = dummy +
    ; up to 254 tokenized bytes (the compiler caps the operand there) + the terminator.
    ubyte[256] passbuf
    ; OP_CALLX scratch: xbuf holds a synthesized tokenized X16-function call handed to frmevl; xargs
    ; holds the argument values popped off the stack (in source order) before they're formatted into
    ; xbuf; xdest is the address of the stack cell the packed FAC1 result is written back into.
    ; 256 bytes: op_callxs also reuses xbuf to copy a string RESULT off-heap, and RPT$(byte,count) can
    ; return up to 255 bytes (the synthesized-call input is far shorter and fully consumed by then).
    ubyte[256] xbuf
    float[pcode.MAX_XARGS] xargs
    uword xdest
    ubyte xslen                  ; OP_CALLXS: length of the string result frmevl returned
    uword xsptr                  ; OP_CALLXS: heap address of that result's body

    sub run(uword base) {
        pcbase = base
        pc = 0
        halt = false
        sp = 0
        csp = 0
        forsp = 0
        ssp = 0
        ; Place the five VM slabs + BASIC's string var table/heap in free RAM. Two regimes, keyed off
        ; heapfloor (the host's "free RAM begins here" hint):
        ;   * in-process (compiler resident): host sets heapfloor = progend AND pre-sets the five slab
        ;     pointers to its own low buffer (the compiler is huge, so little RAM sits above it -- the
        ;     slabs must stay in the compiler's BSS, not eat the small heap). The string heap then owns
        ;     all free RAM from progend up to MEMTOP.
        ;   * standalone / selftest: heapfloor is 0. Free RAM begins at datatop (just above the loaded
        ;     P-code), so the slabs are parked there and the string var table/heap stack ABOVE them --
        ;     nothing lands between the runtime code and the P-code, so the .PRG needs no filler.
        uword image_top = heapfloor
        if image_top == 0 {
            uword sbase = datatop
            if sbase == 0
                sbase = sys.progend()        ; selftest: hand-built P-code, no datatop
            varsf     = sbase                ; layout must match SLAB_BYTES (and gpc.p8's in-process copy)
            ivarsf    = sbase + 640
            arrheap   = sbase + 896
            arr_dims  = sbase + 2944
            sarr_dims = sbase + 3200
            iarrheap  = sbase + 3456
            iarr_dims = sbase + 4480
            image_top = sbase + SLAB_BYTES   ; string var table + heap stack above the slabs
        }
        bstr.init(image_top, varsf)
        sys.memset(varsf, 640, 0)        ; all-zero bytes == float 0.0 (BASIC vars start at 0)
        sys.memset(ivarsf, 256, 0)       ; integer (`%`) vars start at 0 too
        arr_top = 0
        iarr_top = 0
        sys.memset(&arr_len, 64, 0)      ; 32 words -> 64 bytes: all numeric arrays undimensioned
        sys.memset(&iarr_len, 64, 0)     ; all integer arrays undimensioned too
        sys.memset(&sarr_len, 64, 0)     ; all string arrays undimensioned too
        dataptr = database               ; READ starts at the first DATA item
        %asm {{
_next:
            lda  p8b_vm.p8v_pcbase
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)         ; A = opcode at pcbase+pc
            inc  p8b_vm.p8v_pc             ; pc++ (16-bit)
            bne  +
            inc  p8b_vm.p8v_pc+1
+
            cmp  #92                       ; opcodes 0..91 valid; >=92 unknown -> ignore (when no-match)
            bcs  _next
            asl  a                         ; *2 for the word table (0..91 -> 0..182)
            tax
            ; RTS-dispatch: push _after-1 so each handler's own final rts returns to _after.
            ; This lets _optab point STRAIGHT at the handlers -- no per-opcode "jsr h / jmp
            ; _after" trampoline (was ~89*6 bytes). The 3 inline ops (_t0/_t1/_t2) jmp instead
            ; of rts, so they pull the pushed address off first.
            lda  #>(_after-1)
            pha
            lda  #<(_after-1)
            pha
            jmp  (_optab,x)
_after:
            lda  p8b_vm.p8v_halt
            beq  _next
            jmp  _end
_optab:
            ; opcodes 0/1/2 stay inline (jmp, not rts); 3..91 point straight at their handler subs
            .word _t0, _t1, _t2
            .word p8b_vm.p8s_op_pushi, p8b_vm.p8s_op_loadv, p8b_vm.p8s_op_storv, p8b_vm.p8s_op_add, p8b_vm.p8s_op_sub, p8b_vm.p8s_op_mul, p8b_vm.p8s_op_div, p8b_vm.p8s_op_neg
            .word p8b_vm.p8s_op_cmpeq, p8b_vm.p8s_op_cmpne, p8b_vm.p8s_op_cmplt, p8b_vm.p8s_op_cmpgt, p8b_vm.p8s_op_cmple, p8b_vm.p8s_op_cmpge, p8b_vm.p8s_op_and, p8b_vm.p8s_op_or, p8b_vm.p8s_op_not
            .word p8b_vm.p8s_op_printi, p8b_vm.p8s_op_prints, p8b_vm.p8s_op_newline, p8b_vm.p8s_op_gosub, p8b_vm.p8s_op_ret, p8b_vm.p8s_op_forpush, p8b_vm.p8s_op_fornext
            .word p8b_vm.p8s_op_pushs, p8b_vm.p8s_op_loads, p8b_vm.p8s_op_stors, p8b_vm.p8s_op_concat, p8b_vm.p8s_op_poke, p8b_vm.p8s_op_peek, p8b_vm.p8s_op_sys
            .word p8b_vm.p8s_op_dim, p8b_vm.p8s_op_aload, p8b_vm.p8s_op_astore, p8b_vm.p8s_op_inputv, p8b_vm.p8s_op_inputs, p8b_vm.p8s_op_pushf, p8b_vm.p8s_op_callfn
            .word p8b_vm.p8s_op_strnum, p8b_vm.p8s_op_numstr, p8b_vm.p8s_op_lefts, p8b_vm.p8s_op_rights, p8b_vm.p8s_op_mids, p8b_vm.p8s_op_read, p8b_vm.p8s_op_reads, p8b_vm.p8s_op_restore
            .word p8b_vm.p8s_op_sdim, p8b_vm.p8s_op_saload, p8b_vm.p8s_op_sastore, p8b_vm.p8s_op_rdnum, p8b_vm.p8s_op_rdstr, p8b_vm.p8s_op_scmp
            .word p8b_vm.p8s_op_open, p8b_vm.p8s_op_close, p8b_vm.p8s_op_getch, p8b_vm.p8s_op_status, p8b_vm.p8s_op_chkout, p8b_vm.p8s_op_chkin, p8b_vm.p8s_op_clrch, p8b_vm.p8s_op_pow, p8b_vm.p8s_op_wait
            .word p8b_vm.p8s_op_passthru, p8b_vm.p8s_op_callx, p8b_vm.p8s_op_callxs
            .word p8b_vm.p8s_op_ipushi, p8b_vm.p8s_op_iloadv, p8b_vm.p8s_op_istorv, p8b_vm.p8s_op_iadd, p8b_vm.p8s_op_isub, p8b_vm.p8s_op_imul, p8b_vm.p8s_op_ineg
            .word p8b_vm.p8s_op_itof, p8b_vm.p8s_op_itof2, p8b_vm.p8s_op_ftoi
            .word p8b_vm.p8s_op_icmpeq, p8b_vm.p8s_op_icmpne, p8b_vm.p8s_op_icmplt, p8b_vm.p8s_op_icmpgt, p8b_vm.p8s_op_icmple, p8b_vm.p8s_op_icmpge, p8b_vm.p8s_op_ijz, p8b_vm.p8s_op_iand, p8b_vm.p8s_op_ior, p8b_vm.p8s_op_inot
            .word p8b_vm.p8s_op_iforpush, p8b_vm.p8s_op_ifornext, p8b_vm.p8s_op_idim, p8b_vm.p8s_op_iaload, p8b_vm.p8s_op_iastore
_t0:                                    ; OP_END -> leave the interpreter loop
            pla                          ; drop the RTS-dispatch return addr (we jmp, not rts)
            pla
            jmp  _end
_t1:                                    ; OP_JMP -> pc = target word at pcbase+pc
            pla
            pla
            jmp  _setpc
_t2:                                    ; OP_JZ -> sp--; if stack[sp]==0.0 take the branch
            pla                          ; drop the RTS-dispatch return addr (both JZ paths jmp)
            pla
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp
            asl  a
            asl  a
            clc
            adc  p8b_vm.p8v_sp          ; A = sp*5 (float-cell byte offset)
            tax
            lda  p8b_vm.p8v_stack,x     ; MFLPT exponent byte: $00 iff the value is 0.0
            beq  _setpc                 ; zero -> branch taken
            lda  p8b_vm.p8v_pc          ; nonzero -> skip the 2-byte target operand
            clc
            adc  #2
            sta  p8b_vm.p8v_pc
            bcc  _jzdone
            inc  p8b_vm.p8v_pc+1
_jzdone:
            jmp  _next
_setpc:                                 ; pc = word at pcbase+pc  (shared by JMP and JZ-taken)
            lda  p8b_vm.p8v_pcbase
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            ldy  #1
            lda  (P8ZP_SCRATCH_W1),y    ; target hi
            pha
            dey
            lda  (P8ZP_SCRATCH_W1),y    ; target lo
            sta  p8b_vm.p8v_pc
            pla
            sta  p8b_vm.p8v_pc+1
            jmp  _next
_end:
        }}
    }

    ; OP_END / OP_JMP / OP_JZ (opcodes 0/1/2) are handled inline in run()'s asm dispatch
    ; (_t0/_t1/_t2): END exits the loop, JMP/JZ set pc directly, JZ tests the MFLPT exponent
    ; byte instead of a ROM float-compare. No Prog8 handler subs are needed for them.
    asmsub op_pushi() {                      ; stack[sp] = (unsigned imm word) as float
        %asm {{
            lda  p8b_vm.p8v_pcbase
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)           ; imm lo
            pha
            ldy  #1
            lda  (P8ZP_SCRATCH_W1),y         ; imm hi
            tay
            pla                              ; A = lo, Y = hi
            jsr  floats.GIVUAYFAY            ; FAC = unsigned(A/Y) as float
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_faddr
            jsr  $fe66                       ; MOVMF  stack[sp] = FAC
            lda  p8b_vm.p8v_pc
            clc
            adc  #2
            sta  p8b_vm.p8v_pc
            bcc  +
            inc  p8b_vm.p8v_pc+1
+           inc  p8b_vm.p8v_sp
            rts
        }}
    }
    asmsub op_loadv() {                      ; stack[sp] = var[slot]  (var = varsf + slot*5)
        %asm {{
            lda  p8b_vm.p8v_pcbase
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)           ; slot
            ldy  #0
            jsr  prog8_math.mul_word_5       ; A=lo, Y=hi of slot*5
            clc
            adc  p8b_vm.p8v_varsf
            sta  P8ZP_SCRATCH_W2
            tya
            adc  p8b_vm.p8v_varsf+1
            sta  P8ZP_SCRATCH_W2+1           ; W2 = &var
            lda  P8ZP_SCRATCH_W2
            ldy  P8ZP_SCRATCH_W2+1
            jsr  $fe63                       ; MOVFM  FAC = var
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_faddr
            jsr  $fe66                       ; MOVMF  stack[sp] = FAC
            lda  p8b_vm.p8v_pc
            clc
            adc  #2
            sta  p8b_vm.p8v_pc
            bcc  +
            inc  p8b_vm.p8v_pc+1
+           inc  p8b_vm.p8v_sp
            rts
        }}
    }
    asmsub op_storv() {                      ; var[slot] = stack[sp]; sp--
        %asm {{
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_pcbase
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)           ; slot
            ldy  #0
            jsr  prog8_math.mul_word_5
            clc
            adc  p8b_vm.p8v_varsf
            sta  P8ZP_SCRATCH_W2
            tya
            adc  p8b_vm.p8v_varsf+1
            sta  P8ZP_SCRATCH_W2+1           ; W2 = &var
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe63                       ; MOVFM  FAC = stack[sp]
            ldx  P8ZP_SCRATCH_W2
            ldy  P8ZP_SCRATCH_W2+1
            jsr  $fe66                       ; MOVMF  var = FAC
            lda  p8b_vm.p8v_pc
            clc
            adc  #2
            sta  p8b_vm.p8v_pc
            bcc  +
            inc  p8b_vm.p8v_pc+1
+           rts
        }}
    }
    ; --- Phase 2: float arithmetic + compare, hand-asm. The numeric cell is a 5-byte ROM MFLPT float at
    ;     stack + i*5. These call the X16 stable float API ($FE00-$FE90) directly: FAC1<-mem via MOVFM
    ;     ($FE63, ptr A/Y); the op reads its second operand from mem (FADD $FE18 / FSUB $FE12 / FMULT
    ;     $FE1E / FDIV $FE24, ptr A/Y); MOVMF ($FE66, ptr X/Y) writes FAC1 back. No tempv/copy_float round
    ;     trips (the old Prog8 per-op cost). FSUB/FDIV/FPWR are FAC = mem OP FAC, so for a<op>b load
    ;     FAC=b (stack[sp]) then op with mem=a (stack[sp-1]). ---

    ; &stack[i] for i in A -> X=lo, Y=hi (i<32 => i*5<256 fits a byte). Clobbers A, SCRATCH_REG.
    asmsub faddr(ubyte i @A) -> ubyte @X, ubyte @Y {
        %asm {{
            sta  P8ZP_SCRATCH_REG
            asl  a
            asl  a
            clc
            adc  P8ZP_SCRATCH_REG            ; A = i*5
            clc
            adc  #<p8b_vm.p8v_stack
            tax
            lda  #>p8b_vm.p8v_stack
            adc  #0
            tay
            rts
        }}
    }
    ; (stack[i] as uword) -> P8ZP_SCRATCH_W1 (lo), W1+1 (hi).  Same conversion routine prog8's
    ; `as uword` cast uses, so semantics are identical.  Used by the machine ops (POKE/PEEK/SYS/
    ; CLOSE/CHKIN/CHKOUT) to turn a numeric-stack cell into an address / device / logical-file number.
    asmsub stack_word(ubyte i @A) {
        %asm {{
            jsr  p8b_vm.p8s_faddr                    ; X=lo, Y=hi of &stack[i]
            txa                                      ; A=lo, Y=hi -> MOVFM ptr
            jsr  floats.MOVFM                        ; FAC = stack[i]
            jsr  floats.cast_FAC1_as_uw_into_ya      ; Y=lo, A=hi of (FAC as uword)
            sty  P8ZP_SCRATCH_W1
            sta  P8ZP_SCRATCH_W1+1
            rts
        }}
    }
    ; P8ZP_SCRATCH_W1 = &operand = pcbase + pc.  The string handlers read their imm operand bytes
    ; via `lda (P8ZP_SCRATCH_W1)` / `ldy #n : lda (P8ZP_SCRATCH_W1),y` right after calling this --
    ; before any bstr/helper call, which may reuse W1.  Leaves X and Y untouched.
    asmsub opw() {
        %asm {{
            lda  p8b_vm.p8v_pcbase
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            rts
        }}
    }
    ; pc += A -- advance the program counter past the consumed operand bytes. Clobbers A.
    asmsub pcadd(ubyte n @A) {
        %asm {{
            clc
            adc  p8b_vm.p8v_pc
            sta  p8b_vm.p8v_pc
            bcc  +
            inc  p8b_vm.p8v_pc+1
+           rts
        }}
    }
    float @shared c_negone = -1.0           ; MFLPT constant for the CBM 'true' compare result (-1.0)
    float @shared c_one = 1.0               ; MFLPT 1.0 -- positive RND arg (op_callfn: fresh random 0..1)

    asmsub st_cmpfalse() {                  ; stack[sp-1] = 0.0
        %asm {{
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_faddr
            stx  P8ZP_SCRATCH_W1
            sty  P8ZP_SCRATCH_W1+1
            lda  #0
            ldy  #4
-           sta  (P8ZP_SCRATCH_W1),y
            dey
            bpl  -
            rts
        }}
    }
    asmsub st_cmptrue() {                   ; stack[sp-1] = -1.0
        %asm {{
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_faddr
            stx  P8ZP_SCRATCH_W1
            sty  P8ZP_SCRATCH_W1+1
            ldy  #4
-           lda  p8b_vm.p8v_c_negone,y
            sta  (P8ZP_SCRATCH_W1),y
            dey
            bpl  -
            rts
        }}
    }
    asmsub fcmp() -> ubyte @A {             ; A = FCOMP(a=stack[sp-1], b=stack[sp]): 0 eq / 1 a>b / $ff a<b
        %asm {{
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe63                       ; MOVFM  FAC = a
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe54                       ; FCOMP  A = sign(a - b)
            rts
        }}
    }

    asmsub op_add() {                        ; stack[sp-1] += stack[sp]  (commutative)
        %asm {{
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe63                       ; MOVFM  FAC = stack[sp]
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe18                       ; FADD   FAC += stack[sp-1]
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_faddr
            jsr  $fe66                       ; MOVMF  stack[sp-1] = FAC
            rts
        }}
    }
    asmsub op_sub() {                        ; stack[sp-1] -= stack[sp]  (a-b: FAC=b, FSUB mem=a)
        %asm {{
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe63                       ; MOVFM  FAC = b
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe12                       ; FSUB   FAC = a - b
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_faddr
            jsr  $fe66                       ; MOVMF
            rts
        }}
    }
    asmsub op_mul() {                        ; stack[sp-1] *= stack[sp]  (commutative)
        %asm {{
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe63                       ; MOVFM  FAC = stack[sp]
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe1e                       ; FMULT  FAC *= stack[sp-1]
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_faddr
            jsr  $fe66                       ; MOVMF
            rts
        }}
    }
    asmsub op_div() {                        ; stack[sp-1] /= stack[sp]  (a/b: FAC=b, FDIV mem=a)
        %asm {{
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe63                       ; MOVFM  FAC = b
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe24                       ; FDIV   FAC = a / b
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_faddr
            jsr  $fe66                       ; MOVMF
            rts
        }}
    }
    asmsub op_neg() {                        ; stack[sp-1] = -stack[sp-1]
        %asm {{
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe63                       ; MOVFM  FAC = x
            jsr  $fe33                       ; NEGOP  FAC = -FAC
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_faddr
            jsr  $fe66                       ; MOVMF
            rts
        }}
    }
    asmsub op_cmpeq() {                      ; a==b  <=>  FCOMP == 0
        %asm {{
            dec  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_fcmp
            cmp  #0
            bne  +
            jmp  p8b_vm.p8s_st_cmptrue
+           jmp  p8b_vm.p8s_st_cmpfalse
        }}
    }
    asmsub op_cmpne() {                      ; a!=b  <=>  FCOMP != 0
        %asm {{
            dec  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_fcmp
            cmp  #0
            beq  +
            jmp  p8b_vm.p8s_st_cmptrue
+           jmp  p8b_vm.p8s_st_cmpfalse
        }}
    }
    asmsub op_cmplt() {                      ; a<b  <=>  FCOMP == $ff
        %asm {{
            dec  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_fcmp
            cmp  #$ff
            bne  +
            jmp  p8b_vm.p8s_st_cmptrue
+           jmp  p8b_vm.p8s_st_cmpfalse
        }}
    }
    asmsub op_cmpgt() {                      ; a>b  <=>  FCOMP == 1
        %asm {{
            dec  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_fcmp
            cmp  #1
            bne  +
            jmp  p8b_vm.p8s_st_cmptrue
+           jmp  p8b_vm.p8s_st_cmpfalse
        }}
    }
    asmsub op_cmple() {                      ; a<=b  <=>  FCOMP != 1
        %asm {{
            dec  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_fcmp
            cmp  #1
            beq  +
            jmp  p8b_vm.p8s_st_cmptrue
+           jmp  p8b_vm.p8s_st_cmpfalse
        }}
    }
    asmsub op_cmpge() {                      ; a>=b  <=>  FCOMP != $ff
        %asm {{
            dec  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_fcmp
            cmp  #$ff
            beq  +
            jmp  p8b_vm.p8s_st_cmptrue
+           jmp  p8b_vm.p8s_st_cmpfalse
        }}
    }
    sub op_and() {                        ; bitwise AND of the two 16-bit values
                    sp--
                    stack[sp-1] = ((as_bits(stack[sp-1]) & as_bits(stack[sp])) as word) as float
                }
    sub op_or() {                         ; bitwise OR
                    sp--
                    stack[sp-1] = ((as_bits(stack[sp-1]) | as_bits(stack[sp])) as word) as float
                }
    sub op_not() {                        ; bitwise complement (NOT x == -(x+1))
                    stack[sp-1] = ((~ as_bits(stack[sp-1])) as word) as float
                }

    ; --- integer-first arithmetic (Phase 5): the compiler emits these for integer-typed subexpressions,
    ;     keeping values in istack[] (16-bit signed, shares sp with stack[]) to skip the ROM float path.
    ;     Arithmetic wraps at 16 bits (the `%` opt-in). Coercion ops bridge to/from float. ---
    asmsub op_ipushi() {
        %asm {{
            lda  p8b_vm.p8v_pcbase                ; W1 = pcbase + pc
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            ldx  p8b_vm.p8v_sp
            lda  (P8ZP_SCRATCH_W1)                ; imm lo
            sta  p8b_vm.p8v_istack_lsb,x
            ldy  #1
            lda  (P8ZP_SCRATCH_W1),y              ; imm hi
            sta  p8b_vm.p8v_istack_msb,x
            lda  p8b_vm.p8v_pc                    ; pc += 2
            clc
            adc  #2
            sta  p8b_vm.p8v_pc
            bcc  +
            inc  p8b_vm.p8v_pc+1
+           inc  p8b_vm.p8v_sp                    ; sp++
            rts
        }}
    }
    asmsub op_iloadv() {
        %asm {{
            lda  p8b_vm.p8v_pcbase                ; W1 = pcbase + pc
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)                ; slot byte
            ldy  #0                               ; W2 = ivarsf + slot*2
            asl  a
            bcc  +
            iny
+           clc
            adc  p8b_vm.p8v_ivarsf
            sta  P8ZP_SCRATCH_W2
            tya
            adc  p8b_vm.p8v_ivarsf+1
            sta  P8ZP_SCRATCH_W2+1
            ldx  p8b_vm.p8v_sp
            lda  (P8ZP_SCRATCH_W2)                ; var lo
            sta  p8b_vm.p8v_istack_lsb,x
            ldy  #1
            lda  (P8ZP_SCRATCH_W2),y              ; var hi
            sta  p8b_vm.p8v_istack_msb,x
            lda  p8b_vm.p8v_pc                    ; pc += 2
            clc
            adc  #2
            sta  p8b_vm.p8v_pc
            bcc  +
            inc  p8b_vm.p8v_pc+1
+           inc  p8b_vm.p8v_sp                    ; sp++
            rts
        }}
    }
    asmsub op_istorv() {
        %asm {{
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_pcbase                ; W1 = pcbase + pc
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)                ; slot byte
            ldy  #0                               ; W2 = ivarsf + slot*2
            asl  a
            bcc  +
            iny
+           clc
            adc  p8b_vm.p8v_ivarsf
            sta  P8ZP_SCRATCH_W2
            tya
            adc  p8b_vm.p8v_ivarsf+1
            sta  P8ZP_SCRATCH_W2+1
            ldx  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_istack_lsb,x          ; store istack[sp] -> var
            sta  (P8ZP_SCRATCH_W2)
            lda  p8b_vm.p8v_istack_msb,x
            ldy  #1
            sta  (P8ZP_SCRATCH_W2),y
            lda  p8b_vm.p8v_pc                    ; pc += 2
            clc
            adc  #2
            sta  p8b_vm.p8v_pc
            bcc  +
            inc  p8b_vm.p8v_pc+1
+           rts
        }}
    }
    asmsub op_iadd() {
        %asm {{
            dec  p8b_vm.p8v_sp                    ; sp--
            ldy  p8b_vm.p8v_sp                    ; y = sp -> istack[sp]; istack[sp-1] via base-1,y
            clc
            lda  p8b_vm.p8v_istack_lsb-1,y
            adc  p8b_vm.p8v_istack_lsb,y
            sta  p8b_vm.p8v_istack_lsb-1,y
            lda  p8b_vm.p8v_istack_msb-1,y
            adc  p8b_vm.p8v_istack_msb,y
            sta  p8b_vm.p8v_istack_msb-1,y
            rts
        }}
    }
    asmsub op_isub() {
        %asm {{
            dec  p8b_vm.p8v_sp
            ldy  p8b_vm.p8v_sp
            sec
            lda  p8b_vm.p8v_istack_lsb-1,y
            sbc  p8b_vm.p8v_istack_lsb,y
            sta  p8b_vm.p8v_istack_lsb-1,y
            lda  p8b_vm.p8v_istack_msb-1,y
            sbc  p8b_vm.p8v_istack_msb,y
            sta  p8b_vm.p8v_istack_msb-1,y
            rts
        }}
    }
    asmsub op_imul() {
        %asm {{
            dec  p8b_vm.p8v_sp
            ldx  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_istack_lsb,x          ; multiplier = istack[sp]
            sta  prog8_math.multiply_words.multiplier
            lda  p8b_vm.p8v_istack_msb,x
            sta  prog8_math.multiply_words.multiplier+1
            lda  p8b_vm.p8v_istack_lsb-1,x        ; A/Y = istack[sp-1]
            ldy  p8b_vm.p8v_istack_msb-1,x
            jsr  prog8_math.multiply_words        ; result A=lo, Y=hi (wraps at 16 bits)
            ldx  p8b_vm.p8v_sp                    ; reload (multiply may clobber X)
            sta  p8b_vm.p8v_istack_lsb-1,x
            tya
            sta  p8b_vm.p8v_istack_msb-1,x
            rts
        }}
    }
    asmsub op_ineg() {
        %asm {{
            ldy  p8b_vm.p8v_sp
            dey                                   ; y = sp-1 (top)
            sec
            lda  #0
            sbc  p8b_vm.p8v_istack_lsb,y
            sta  p8b_vm.p8v_istack_lsb,y
            lda  #0
            sbc  p8b_vm.p8v_istack_msb,y
            sta  p8b_vm.p8v_istack_msb,y
            rts
        }}
    }
    asmsub op_itof() {                    ; coerce the TOP cell int -> float (signed)
        %asm {{
            lda  p8b_vm.p8v_sp
            dec  a
            tay
            lda  p8b_vm.p8v_istack_lsb,y
            ldx  p8b_vm.p8v_istack_msb,y
            stx  P8ZP_SCRATCH_REG
            ldy  P8ZP_SCRATCH_REG            ; A = lo, Y = hi (signed)
            jsr  floats.GIVAYFAY             ; FAC = signed(A/Y) as float
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_faddr
            jsr  $fe66                       ; MOVMF  stack[sp-1] = FAC
            rts
        }}
    }
    asmsub op_itof2() {                   ; coerce the SECOND-from-top cell int -> float (mixed a<op>b)
        %asm {{
            lda  p8b_vm.p8v_sp
            sec
            sbc  #2
            tay
            lda  p8b_vm.p8v_istack_lsb,y
            ldx  p8b_vm.p8v_istack_msb,y
            stx  P8ZP_SCRATCH_REG
            ldy  P8ZP_SCRATCH_REG
            jsr  floats.GIVAYFAY
            lda  p8b_vm.p8v_sp
            sec
            sbc  #2
            jsr  p8b_vm.p8s_faddr
            jsr  $fe66                       ; MOVMF  stack[sp-2] = FAC
            rts
        }}
    }
    sub op_ftoi() {                       ; coerce the TOP cell float -> int, truncating toward zero
                    ; `as word` rounds; CBM `%` assignment truncates toward zero (A%=7.9 -> 7, -7.9 -> -7)
                    float x = stack[sp-1]
                    if x < 0.0
                        istack[sp-1] = - (floats.floor(-x) as word)
                    else
                        istack[sp-1] = floats.floor(x) as word
                }
    ; --- integer comparison / logic / branch (Phase 5 increment 2): all operate on istack[] (16-bit
    ;     signed), pushing the CBM truth value -1/0; they skip the ROM float compare entirely. ---
    asmsub op_icmpeq() {
        %asm {{
            dec  p8b_vm.p8v_sp
            ldx  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_istack_lsb-1,x
            cmp  p8b_vm.p8v_istack_lsb,x
            bne  _eqf
            lda  p8b_vm.p8v_istack_msb-1,x
            cmp  p8b_vm.p8v_istack_msb,x
            bne  _eqf
            lda  #$ff
            bne  _eqs                             ; $ff != 0 -> always: store true
_eqf:       lda  #0
_eqs:       sta  p8b_vm.p8v_istack_lsb-1,x
            sta  p8b_vm.p8v_istack_msb-1,x
            rts
        }}
    }
    asmsub op_icmpne() {
        %asm {{
            dec  p8b_vm.p8v_sp
            ldx  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_istack_lsb-1,x
            cmp  p8b_vm.p8v_istack_lsb,x
            bne  _net
            lda  p8b_vm.p8v_istack_msb-1,x
            cmp  p8b_vm.p8v_istack_msb,x
            bne  _net
            lda  #0                               ; equal -> false
            beq  _nes
_net:       lda  #$ff
_nes:       sta  p8b_vm.p8v_istack_lsb-1,x
            sta  p8b_vm.p8v_istack_msb-1,x
            rts
        }}
    }
    asmsub op_icmplt() {
        %asm {{
            dec  p8b_vm.p8v_sp
            ldx  p8b_vm.p8v_sp                    ; x = sp
            sec                                   ; signed 16-bit istack[sp-1] < istack[sp] via N eor V
            lda  p8b_vm.p8v_istack_lsb-1,x
            sbc  p8b_vm.p8v_istack_lsb,x
            lda  p8b_vm.p8v_istack_msb-1,x
            sbc  p8b_vm.p8v_istack_msb,x
            bvc  +
            eor  #$80
+           bmi  _true                            ; N set (corrected) -> A < B
            lda  #0                               ; false -> 0
            sta  p8b_vm.p8v_istack_lsb-1,x
            sta  p8b_vm.p8v_istack_msb-1,x
            rts
_true:      lda  #$ff                             ; true -> -1 (CBM truth)
            sta  p8b_vm.p8v_istack_lsb-1,x
            sta  p8b_vm.p8v_istack_msb-1,x
            rts
        }}
    }
    asmsub op_icmpgt() {                          ; A>B  <=>  B<A (signed)
        %asm {{
            dec  p8b_vm.p8v_sp
            ldx  p8b_vm.p8v_sp
            sec
            lda  p8b_vm.p8v_istack_lsb,x          ; B_lo
            sbc  p8b_vm.p8v_istack_lsb-1,x        ; - A_lo
            lda  p8b_vm.p8v_istack_msb,x          ; B_hi
            sbc  p8b_vm.p8v_istack_msb-1,x        ; - A_hi
            bvc  +
            eor  #$80
+           bmi  _gtt                             ; B<A -> A>B true
            lda  #0
            beq  _gts
_gtt:       lda  #$ff
_gts:       sta  p8b_vm.p8v_istack_lsb-1,x
            sta  p8b_vm.p8v_istack_msb-1,x
            rts
        }}
    }
    asmsub op_icmple() {                          ; A<=B  <=>  not(B<A)
        %asm {{
            dec  p8b_vm.p8v_sp
            ldx  p8b_vm.p8v_sp
            sec
            lda  p8b_vm.p8v_istack_lsb,x          ; B_lo
            sbc  p8b_vm.p8v_istack_lsb-1,x        ; - A_lo
            lda  p8b_vm.p8v_istack_msb,x
            sbc  p8b_vm.p8v_istack_msb-1,x
            bvc  +
            eor  #$80
+           bmi  _lef                             ; B<A -> A<=B false
            lda  #$ff
            bne  _les
_lef:       lda  #0
_les:       sta  p8b_vm.p8v_istack_lsb-1,x
            sta  p8b_vm.p8v_istack_msb-1,x
            rts
        }}
    }
    asmsub op_icmpge() {                          ; A>=B  <=>  not(A<B)
        %asm {{
            dec  p8b_vm.p8v_sp
            ldx  p8b_vm.p8v_sp
            sec
            lda  p8b_vm.p8v_istack_lsb-1,x        ; A_lo
            sbc  p8b_vm.p8v_istack_lsb,x          ; - B_lo
            lda  p8b_vm.p8v_istack_msb-1,x
            sbc  p8b_vm.p8v_istack_msb,x
            bvc  +
            eor  #$80
+           bmi  _gef                             ; A<B -> A>=B false
            lda  #$ff
            bne  _ges
_gef:       lda  #0
_ges:       sta  p8b_vm.p8v_istack_lsb-1,x
            sta  p8b_vm.p8v_istack_msb-1,x
            rts
        }}
    }
    asmsub op_ijz() {                             ; pop int; branch to the operand target if it is zero
        %asm {{
            dec  p8b_vm.p8v_sp
            ldx  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_istack_lsb,x
            ora  p8b_vm.p8v_istack_msb,x
            bne  _ijznt                           ; nonzero -> fall through, skip the 2-byte target
            lda  p8b_vm.p8v_pcbase                ; zero -> pc = target word (LE at pcbase+pc)
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            ldy  #1
            lda  (P8ZP_SCRATCH_W1),y              ; target hi
            pha
            lda  (P8ZP_SCRATCH_W1)                ; target lo
            sta  p8b_vm.p8v_pc
            pla
            sta  p8b_vm.p8v_pc+1
            rts
_ijznt:     lda  p8b_vm.p8v_pc                    ; pc += 2
            clc
            adc  #2
            sta  p8b_vm.p8v_pc
            bcc  +
            inc  p8b_vm.p8v_pc+1
+           rts
        }}
    }
    asmsub op_iand() {                            ; bitwise AND of the two 16-bit ints (truth -1/0)
        %asm {{
            dec  p8b_vm.p8v_sp
            ldy  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_istack_lsb-1,y
            and  p8b_vm.p8v_istack_lsb,y
            sta  p8b_vm.p8v_istack_lsb-1,y
            lda  p8b_vm.p8v_istack_msb-1,y
            and  p8b_vm.p8v_istack_msb,y
            sta  p8b_vm.p8v_istack_msb-1,y
            rts
        }}
    }
    asmsub op_ior() {                             ; bitwise OR
        %asm {{
            dec  p8b_vm.p8v_sp
            ldy  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_istack_lsb-1,y
            ora  p8b_vm.p8v_istack_lsb,y
            sta  p8b_vm.p8v_istack_lsb-1,y
            lda  p8b_vm.p8v_istack_msb-1,y
            ora  p8b_vm.p8v_istack_msb,y
            sta  p8b_vm.p8v_istack_msb-1,y
            rts
        }}
    }
    asmsub op_inot() {                            ; bitwise complement (NOT x == -(x+1))
        %asm {{
            ldy  p8b_vm.p8v_sp
            dey                                   ; y = sp-1 (top, unary)
            lda  p8b_vm.p8v_istack_lsb,y
            eor  #$ff
            sta  p8b_vm.p8v_istack_lsb,y
            lda  p8b_vm.p8v_istack_msb,y
            eor  #$ff
            sta  p8b_vm.p8v_istack_msb,y
            rts
        }}
    }
    sub op_printi() {
                    sp--
                    float pv = stack[sp]
                    ; last_printed feeds the headless test mailbox ONLY. Prog8's float->word cast is
                    ; range-checked by the ROM and throws ILLEGAL QUANTITY outside -32768..32767, so it
                    ; must be guarded: a real PRINT of a large number (directory block counts, addresses,
                    ; big sums) has to PRINT, not crash. FOUT (below) handles the full float range fine;
                    ; only this mailbox convenience needed the cast. Values in signed-word range keep an
                    ; exact mailbox (any fractional part rounds within range since pv <= 32767.0 can't
                    ; reach the 32768 throw threshold); out-of-range values leave the mailbox 0 (no test
                    ; inspects it for those -- they assert the printed text instead).
                    if pv >= -32768.0 and pv <= 32767.0
                        last_printed = pv as word
                    else
                        last_printed = 0
                    print_float(pv)                      ; BASIC-formatted, no newline
                }
    asmsub op_prints() {
        ; psd stays at sstack[ssp] (ssp fixed after the dec), so it's re-read for the trailing free.
        %asm {{
            dec  p8b_vm.p8v_ssp
            ldx  p8b_vm.p8v_ssp
            lda  p8b_vm.p8v_sstack_lsb,x
            ldy  p8b_vm.p8v_sstack_msb,x
            jsr  p8b_vm.p8s_print_desc          ; length-counted (bodies aren't null-terminated)
            ldx  p8b_vm.p8v_ssp
            lda  p8b_vm.p8v_sstack_lsb,x
            ldy  p8b_vm.p8v_sstack_msb,x
            jmp  p8b_bstr.p8s_free_temp_if_top  ; a printed temp is done -> reclaim its slot
        }}
    }
    sub op_newline() {
                    emit_char(13)                         ; CR to screen, LF to host console
                }
    asmsub op_gosub() {                      ; push return addr, jump to the little-endian word operand
        %asm {{
            lda  p8b_vm.p8v_pcbase           ; W1 = pcbase + pc  (points at the 2-byte target operand)
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            ldy  #0                           ; target (lo,hi) -> W2
            lda  (P8ZP_SCRATCH_W1),y
            sta  P8ZP_SCRATCH_W2
            iny
            lda  (P8ZP_SCRATCH_W1),y
            sta  P8ZP_SCRATCH_W2+1
            lda  p8b_vm.p8v_pc               ; pc += 2  (return address = byte after the operand)
            clc
            adc  #2
            sta  p8b_vm.p8v_pc
            bcc  _gsnoc
            inc  p8b_vm.p8v_pc+1
_gsnoc:     ldy  p8b_vm.p8v_csp              ; callstack[csp] = pc ; csp++
            lda  p8b_vm.p8v_pc
            sta  p8b_vm.p8v_callstack_lsb,y
            lda  p8b_vm.p8v_pc+1
            sta  p8b_vm.p8v_callstack_msb,y
            inc  p8b_vm.p8v_csp
            lda  P8ZP_SCRATCH_W2             ; pc = target
            sta  p8b_vm.p8v_pc
            lda  P8ZP_SCRATCH_W2+1
            sta  p8b_vm.p8v_pc+1
            rts
        }}
    }
    asmsub op_ret() {                        ; pop return addr off the GOSUB callstack
        %asm {{
            dec  p8b_vm.p8v_csp
            ldy  p8b_vm.p8v_csp
            lda  p8b_vm.p8v_callstack_lsb,y
            sta  p8b_vm.p8v_pc
            lda  p8b_vm.p8v_callstack_msb,y
            sta  p8b_vm.p8v_pc+1
            rts
        }}
    }
    asmsub op_forpush() {                    ; FOR var=start TO limit STEP step -- open a float loop frame
        %asm {{
            lda  p8b_vm.p8v_pcbase
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)           ; slot
            pha
            lda  p8b_vm.p8v_pc               ; pc += 2 (body start)
            clc
            adc  #2
            sta  p8b_vm.p8v_pc
            bcc  +
            inc  p8b_vm.p8v_pc+1
+           dec  p8b_vm.p8v_sp               ; sp -= 2 : limit at [sp], step at [sp+1]
            dec  p8b_vm.p8v_sp
            ldy  p8b_vm.p8v_forsp
            pla                              ; slot -> for_var[forsp]
            sta  p8b_vm.p8v_for_var,y
            lda  p8b_vm.p8v_sp               ; for_limit[forsp] = stack[sp]
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe63                       ; MOVFM  FAC = limit
            lda  p8b_vm.p8v_forsp
            sta  P8ZP_SCRATCH_REG
            asl  a
            asl  a
            clc
            adc  P8ZP_SCRATCH_REG            ; forsp*5
            clc
            adc  #<p8b_vm.p8v_for_limit
            tax
            lda  #>p8b_vm.p8v_for_limit
            adc  #0
            tay
            jsr  $fe66                       ; MOVMF  for_limit[forsp] = FAC
            lda  p8b_vm.p8v_sp               ; for_step[forsp] = stack[sp+1]
            clc
            adc  #1
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe63                       ; MOVFM  FAC = step
            lda  p8b_vm.p8v_forsp
            sta  P8ZP_SCRATCH_REG
            asl  a
            asl  a
            clc
            adc  P8ZP_SCRATCH_REG            ; forsp*5
            clc
            adc  #<p8b_vm.p8v_for_step
            tax
            lda  #>p8b_vm.p8v_for_step
            adc  #0
            tay
            jsr  $fe66                       ; MOVMF  for_step[forsp] = FAC
            ldy  p8b_vm.p8v_forsp            ; for_top[forsp] = pc
            lda  p8b_vm.p8v_pc
            sta  p8b_vm.p8v_for_top_lsb,y
            lda  p8b_vm.p8v_pc+1
            sta  p8b_vm.p8v_for_top_msb,y
            inc  p8b_vm.p8v_forsp
            rts
        }}
    }
    asmsub op_fornext() {                    ; step the innermost float FOR (the old ~1.5KB copy_float hog)
        %asm {{
            ldx  p8b_vm.p8v_forsp
            dex                              ; x = top
            stx  P8ZP_SCRATCH_B1
            lda  p8b_vm.p8v_for_var,x        ; vaddr = varsf + for_var[top]*5 -> W2
            ldy  #0
            jsr  prog8_math.mul_word_5
            clc
            adc  p8b_vm.p8v_varsf
            sta  P8ZP_SCRATCH_W2
            tya
            adc  p8b_vm.p8v_varsf+1
            sta  P8ZP_SCRATCH_W2+1
            lda  P8ZP_SCRATCH_W2             ; FAC = peekf(vaddr) = loop var
            ldy  P8ZP_SCRATCH_W2+1
            jsr  $fe63                       ; MOVFM
            lda  P8ZP_SCRATCH_B1             ; FAC += for_step[top]  (addr = for_step + top*5)
            sta  P8ZP_SCRATCH_REG
            asl  a
            asl  a
            clc
            adc  P8ZP_SCRATCH_REG
            clc
            adc  #<p8b_vm.p8v_for_step
            tax
            lda  #>p8b_vm.p8v_for_step
            adc  #0
            tay
            txa
            jsr  $fe18                       ; FADD  FAC = nv
            ldx  P8ZP_SCRATCH_W2             ; pokef(vaddr, nv)
            ldy  P8ZP_SCRATCH_W2+1
            jsr  $fe66                       ; MOVMF  store nv to loop var
            lda  P8ZP_SCRATCH_B1             ; step sign -> ascending/descending
            sta  P8ZP_SCRATCH_REG
            asl  a
            asl  a
            clc
            adc  P8ZP_SCRATCH_REG            ; top*5 -> X (index into for_step bytes)
            tax
            lda  p8b_vm.p8v_for_step,x       ; MFLPT exponent byte
            beq  _fnasc                      ; 0.0 -> step >= 0 -> ascending
            lda  p8b_vm.p8v_for_step+1,x     ; sign byte
            bpl  _fnasc                      ; positive -> ascending
            jsr  _fncmp                      ; descending: cont = nv >= limit <=> FCOMP != $ff
            cmp  #$ff
            beq  _fnstop
            bne  _fncont
_fnasc:     jsr  _fncmp                      ; ascending: cont = nv <= limit <=> FCOMP != 1
            cmp  #1
            beq  _fnstop
_fncont:    ldy  P8ZP_SCRATCH_B1             ; continue: pc = for_top[top]
            lda  p8b_vm.p8v_for_top_lsb,y
            sta  p8b_vm.p8v_pc
            lda  p8b_vm.p8v_for_top_msb,y
            sta  p8b_vm.p8v_pc+1
            rts
_fnstop:    dec  p8b_vm.p8v_forsp            ; loop finished; pop the frame
            rts
_fncmp:     lda  P8ZP_SCRATCH_B1             ; A = FCOMP(FAC=nv, for_limit[top])
            sta  P8ZP_SCRATCH_REG
            asl  a
            asl  a
            clc
            adc  P8ZP_SCRATCH_REG            ; top*5
            clc
            adc  #<p8b_vm.p8v_for_limit
            tax
            lda  #>p8b_vm.p8v_for_limit
            adc  #0
            tay
            txa
            jmp  $fe54                       ; FCOMP (tail): returns A, rts to caller
        }}
    }
    asmsub op_iforpush() {                        ; FOR I%=start TO limit STEP step -- open an integer frame
        %asm {{
            lda  p8b_vm.p8v_pcbase                ; slot = @(pcbase+pc)
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)
            pha                                   ; save slot
            lda  p8b_vm.p8v_pc                    ; pc += 2 (body starts here)
            clc
            adc  #2
            sta  p8b_vm.p8v_pc
            bcc  +
            inc  p8b_vm.p8v_pc+1
+           dec  p8b_vm.p8v_sp                    ; sp-- (step index) ; sp-- (limit index)
            dec  p8b_vm.p8v_sp
            ldy  p8b_vm.p8v_forsp
            pla                                   ; slot -> for_var[forsp]
            sta  p8b_vm.p8v_for_var,y
            ldx  p8b_vm.p8v_sp                    ; istack[sp] = limit
            lda  p8b_vm.p8v_istack_lsb,x
            sta  p8b_vm.p8v_for_ilimit_lsb,y
            lda  p8b_vm.p8v_istack_msb,x
            sta  p8b_vm.p8v_for_ilimit_msb,y
            inx                                   ; istack[sp+1] = step
            lda  p8b_vm.p8v_istack_lsb,x
            sta  p8b_vm.p8v_for_istep_lsb,y
            lda  p8b_vm.p8v_istack_msb,x
            sta  p8b_vm.p8v_for_istep_msb,y
            lda  p8b_vm.p8v_pc                    ; for_top[forsp] = pc
            sta  p8b_vm.p8v_for_top_lsb,y
            lda  p8b_vm.p8v_pc+1
            sta  p8b_vm.p8v_for_top_msb,y
            inc  p8b_vm.p8v_forsp
            rts
        }}
    }
    asmsub op_ifornext() {                        ; step the innermost integer FOR (16-bit, wraps)
        %asm {{
            lda  p8b_vm.p8v_forsp                 ; top = forsp-1 -> B1
            sec
            sbc  #1
            sta  P8ZP_SCRATCH_B1
            tay
            lda  p8b_vm.p8v_for_var,y             ; vaddr = ivarsf + for_var[top]*2 -> W2
            ldx  #0
            asl  a
            bcc  +
            ldx  #1
+           clc
            adc  p8b_vm.p8v_ivarsf
            sta  P8ZP_SCRATCH_W2
            txa
            adc  p8b_vm.p8v_ivarsf+1
            sta  P8ZP_SCRATCH_W2+1
            ldy  #0                               ; nv = peekw(vaddr) + for_istep[top]
            lda  (P8ZP_SCRATCH_W2),y
            ldy  P8ZP_SCRATCH_B1
            clc
            adc  p8b_vm.p8v_for_istep_lsb,y
            sta  P8ZP_SCRATCH_W1
            ldy  #1
            lda  (P8ZP_SCRATCH_W2),y
            ldy  P8ZP_SCRATCH_B1
            adc  p8b_vm.p8v_for_istep_msb,y
            sta  P8ZP_SCRATCH_W1+1
            lda  P8ZP_SCRATCH_W1                  ; store nv back to the loop var
            ldy  #0
            sta  (P8ZP_SCRATCH_W2),y
            lda  P8ZP_SCRATCH_W1+1
            ldy  #1
            sta  (P8ZP_SCRATCH_W2),y
            ldy  P8ZP_SCRATCH_B1
            lda  p8b_vm.p8v_for_istep_msb,y       ; step sign -> ascending/descending
            bmi  _ifndn
            sec                                   ; ascending: stop if limit < nv (signed)
            lda  p8b_vm.p8v_for_ilimit_lsb,y
            sbc  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_for_ilimit_msb,y
            sbc  P8ZP_SCRATCH_W1+1
            bvc  +
            eor  #$80
+           bmi  _ifnstop                         ; limit<nv -> nv>limit -> stop
            bpl  _ifncont
_ifndn:     sec                                   ; descending: stop if nv < limit (signed)
            lda  P8ZP_SCRATCH_W1
            sbc  p8b_vm.p8v_for_ilimit_lsb,y
            lda  P8ZP_SCRATCH_W1+1
            sbc  p8b_vm.p8v_for_ilimit_msb,y
            bvc  +
            eor  #$80
+           bmi  _ifnstop                         ; nv<limit -> stop
_ifncont:   ldy  P8ZP_SCRATCH_B1                  ; continue: pc = for_top[top]
            lda  p8b_vm.p8v_for_top_lsb,y
            sta  p8b_vm.p8v_pc
            lda  p8b_vm.p8v_for_top_msb,y
            sta  p8b_vm.p8v_pc+1
            rts
_ifnstop:   dec  p8b_vm.p8v_forsp                 ; loop finished; pop the frame
            rts
        }}
    }
    asmsub op_pushs() {
        ; operand is a little-endian offset into the literal pool; litbase makes it absolute. Literal
        ; bodies are off-heap (program text) -> a scratch descriptor over them, which the collector
        ; ignores (never rooted, never moved), so the same P-code works in-process and standalone.
        %asm {{
            jsr  p8b_vm.p8s_opw                 ; W1 = pcbase+pc
            lda  (P8ZP_SCRATCH_W1)              ; lo = operand[0]
            clc
            adc  p8b_vm.p8v_litbase
            pha
            ldy  #1
            lda  (P8ZP_SCRATCH_W1),y            ; hi = operand[1] (carry from lo-add preserved)
            adc  p8b_vm.p8v_litbase+1
            tay                                 ; Y = hi
            pla                                 ; A = lo
            jsr  p8b_vm.p8s_push_cstr           ; push_cstr(litbase + le16)
            lda  #2
            jmp  p8b_vm.p8s_pcadd               ; pc += 2
        }}
    }
    asmsub op_loads() {                     ; push the variable's descriptor address
        %asm {{
            jsr  p8b_vm.p8s_opw                 ; W1 = pcbase+pc
            lda  (P8ZP_SCRATCH_W1)              ; slot
            jsr  p8b_bstr.p8s_vdesc             ; A=lo, Y=hi of the var's descriptor
            ldx  p8b_vm.p8v_ssp
            sta  p8b_vm.p8v_sstack_lsb,x
            tya
            sta  p8b_vm.p8v_sstack_msb,x
            inc  p8b_vm.p8v_ssp
            lda  #2
            jmp  p8b_vm.p8s_pcadd
        }}
    }
    asmsub op_stors() {                     ; heap-copy / steal-temp assignment into a string var
        %asm {{
            dec  p8b_vm.p8v_ssp
            jsr  p8b_vm.p8s_opw                 ; W1 = pcbase+pc
            lda  (P8ZP_SCRATCH_W1)              ; slot
            sta  p8b_bstr.p8s_store_var.p8v_slot
            ldx  p8b_vm.p8v_ssp
            lda  p8b_vm.p8v_sstack_lsb,x
            sta  p8b_bstr.p8s_store_var.p8v_sd
            lda  p8b_vm.p8v_sstack_msb,x
            sta  p8b_bstr.p8s_store_var.p8v_sd+1
            jsr  p8b_bstr.p8s_store_var
            lda  #2
            jmp  p8b_vm.p8s_pcadd
        }}
    }
    asmsub op_concat() {
        ; result = a + b, produced as a BASIC temp. concat_temp allocates the result body while a/b are
        ; still rooted (a GC during getspa relocates them), copies, frees any operand temps top-first,
        ; then returns the result temp. A total > 255 sets err_toolong -> ?STRING TOO LONG. We write the
        ; result cell then tail-call str_error: on error it sets halt (run() stops, so the just-written
        ; cell is inert); on success it returns false, leaving the pushed result exactly as before.
        %asm {{
            ldx  p8b_vm.p8v_ssp
            dex                                 ; ssp-1 -> b (pushed last)
            lda  p8b_vm.p8v_sstack_lsb,x
            sta  p8b_bstr.p8s_concat_temp.p8v_bd
            lda  p8b_vm.p8v_sstack_msb,x
            sta  p8b_bstr.p8s_concat_temp.p8v_bd+1
            dex                                 ; ssp-2 -> a
            lda  p8b_vm.p8v_sstack_lsb,x
            sta  p8b_bstr.p8s_concat_temp.p8v_ad
            lda  p8b_vm.p8v_sstack_msb,x
            sta  p8b_bstr.p8s_concat_temp.p8v_ad+1
            jsr  p8b_bstr.p8s_concat_temp       ; A=lo, Y=hi = result temp
            ldx  p8b_vm.p8v_ssp
            dex
            dex                                 ; X = ssp-2 (result lands where a was)
            sta  p8b_vm.p8v_sstack_lsb,x
            tya
            sta  p8b_vm.p8v_sstack_msb,x
            inx                                 ; net ssp = ssp-1 (two popped, one pushed)
            stx  p8b_vm.p8v_ssp
            jmp  p8b_vm.p8s_str_error           ; sets halt on overflow; bool result ignored by dispatch
        }}
    }
    asmsub op_poke() {                    ; POKE addr, v : write the low byte of v to addr
        %asm {{
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_stack_word         ; W1 = value word
            lda  P8ZP_SCRATCH_W1               ; A = value low byte
            pha
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_stack_word         ; W1 = target address
            pla
            sta  (P8ZP_SCRATCH_W1)             ; @(addr) = v
            rts
        }}
    }
    asmsub op_peek() {                    ; PEEK(addr) : stack[sp-1] = byte at addr (0..255) as float
        %asm {{
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_stack_word         ; W1 = addr (from stack[sp-1])
            lda  (P8ZP_SCRATCH_W1)             ; byte at addr
            tay
            jsr  floats.FREADUY                ; FAC = unsigned(Y) as float
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_faddr              ; X=lo, Y=hi of &stack[sp-1]
            jsr  $fe66                         ; MOVMF  stack[sp-1] = FAC
            rts
        }}
    }
    asmsub op_sys() {                     ; SYS addr : subroutine-call the target, return here
        %asm {{
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_stack_word         ; W1 = target
            lda  P8ZP_SCRATCH_W1
            sta  p8b_vm.p8v_sys_target
            lda  P8ZP_SCRATCH_W1+1
            sta  p8b_vm.p8v_sys_target+1
            jmp  (p8b_vm.p8v_sys_target)       ; JSR-trick: target's rts returns to op_sys's caller
        }}
    }
    sub op_dim() {                        ; DIM A(d0[,d1..]): allocate a numeric array
                    ubyte adslot = @(pcbase + pc)          ; imm16 slot (low byte; slot < 256)
                    ubyte adnd = @(pcbase + pc + 2)        ; ndims byte follows the 2-byte slot
                    pc += 3
                    uword adtot = dim_setup(arr_dims, adslot, adnd, ARRHEAP_SIZE / 5)
                    if adtot != 0 and arr_top + adtot * 5 <= ARRHEAP_SIZE {
                        arr_base[adslot] = arr_top
                        arr_len[adslot] = adtot
                        arr_ndims[adslot] = adnd
                        ; BASIC guarantees DIM'd numeric elements start at 0.0. arrheap is an
                        ; uninitialized memory() slab (in-process: stale compiler bytes), so a
                        ; never-stored element would otherwise read a garbage 5-byte value -- and a
                        ; non-normalized MFLPT float hangs the ROM FOUT formatter when PRINTed.
                        sys.memset(arrheap + arr_top, adtot * 5, 0)
                        arr_top += adtot * 5
                    } else {
                        arr_len[adslot] = 0                  ; too big / out of heap -> unusable
                    }
                }
    asmsub op_aload() {                   ; A(i[,j..]): push element; 0.0 if any subscript out of range
        %asm {{
            ; --- operands: slot @ pcbase+pc (low byte), nd @ pcbase+pc+2 ; then pc += 3 ---
            lda  p8b_vm.p8v_pcbase
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)               ; slot
            sta  p8b_vm.p8s_index_of.p8v_slot
            ldy  #2
            lda  (P8ZP_SCRATCH_W1),y             ; nd
            sta  p8b_vm.p8s_index_of.p8v_nd
            lda  p8b_vm.p8v_pc
            clc
            adc  #3
            sta  p8b_vm.p8v_pc
            bcc  +
            inc  p8b_vm.p8v_pc+1
+           ; --- aloff = index_of(arr_dims, slot, nd, sp-nd, arr_len[slot]) ---
            lda  p8b_vm.p8v_arr_dims            ; index_of reads (never writes) slot/nd, so the
            sta  p8b_vm.p8s_index_of.p8v_dims_ptr   ; param slots double as our slot/nd storage after the call
            lda  p8b_vm.p8v_arr_dims+1
            sta  p8b_vm.p8s_index_of.p8v_dims_ptr+1
            lda  p8b_vm.p8v_sp
            sec
            sbc  p8b_vm.p8s_index_of.p8v_nd
            sta  p8b_vm.p8s_index_of.p8v_first
            ldy  p8b_vm.p8s_index_of.p8v_slot
            lda  p8b_vm.p8v_arr_len_lsb,y
            sta  p8b_vm.p8s_index_of.p8v_total
            lda  p8b_vm.p8v_arr_len_msb,y
            sta  p8b_vm.p8s_index_of.p8v_total+1
            jsr  p8b_vm.p8s_index_of            ; A=lo, Y=hi of aloff ($ffff => out of range)
            pha
            phy
            lda  p8b_vm.p8v_sp                  ; sp -= nd
            sec
            sbc  p8b_vm.p8s_index_of.p8v_nd
            sta  p8b_vm.p8v_sp
            ply
            pla
            cmp  #$ff                           ; aloff == $ffff ?
            bne  _alok
            cpy  #$ff
            beq  _alzero
_alok:      jsr  prog8_math.mul_word_5         ; A/Y = aloff*5   (clobbers W1,W2)
            clc                                 ; src = arrheap + arr_base[slot] + aloff*5 -> W1
            adc  p8b_vm.p8v_arrheap
            sta  P8ZP_SCRATCH_W1
            tya
            adc  p8b_vm.p8v_arrheap+1
            sta  P8ZP_SCRATCH_W1+1
            ldy  p8b_vm.p8s_index_of.p8v_slot
            lda  P8ZP_SCRATCH_W1
            clc
            adc  p8b_vm.p8v_arr_base_lsb,y
            sta  P8ZP_SCRATCH_W1
            lda  P8ZP_SCRATCH_W1+1
            adc  p8b_vm.p8v_arr_base_msb,y
            sta  P8ZP_SCRATCH_W1+1
            lda  p8b_vm.p8v_sp                  ; dest = &stack[sp] -> W2
            jsr  p8b_vm.p8s_faddr
            stx  P8ZP_SCRATCH_W2
            sty  P8ZP_SCRATCH_W2+1
            ldy  #4                             ; copy the 5-byte element straight in (no FAC round-trip)
-           lda  (P8ZP_SCRATCH_W1),y
            sta  (P8ZP_SCRATCH_W2),y
            dey
            bpl  -
            jmp  _aldone
_alzero:    lda  p8b_vm.p8v_sp                  ; out of range: stack[sp] = 0.0
            jsr  p8b_vm.p8s_faddr
            stx  P8ZP_SCRATCH_W2
            sty  P8ZP_SCRATCH_W2+1
            lda  #0
            ldy  #4
-           sta  (P8ZP_SCRATCH_W2),y
            dey
            bpl  -
_aldone:    inc  p8b_vm.p8v_sp
            rts
        }}
    }
    asmsub op_astore() {                  ; A(i[,j..]) = v: store element; dropped if any subscript out of range
        %asm {{
            ; --- operands: slot, nd ; pc += 3 ---
            lda  p8b_vm.p8v_pcbase
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)
            sta  p8b_vm.p8s_index_of.p8v_slot
            ldy  #2
            lda  (P8ZP_SCRATCH_W1),y
            sta  p8b_vm.p8s_index_of.p8v_nd
            lda  p8b_vm.p8v_pc
            clc
            adc  #3
            sta  p8b_vm.p8v_pc
            bcc  +
            inc  p8b_vm.p8v_pc+1
+           dec  p8b_vm.p8v_sp                  ; sp-- : value now at stack[sp], subscripts below it
            ; --- asoff = index_of(arr_dims, slot, nd, sp-nd, arr_len[slot]) ---
            lda  p8b_vm.p8v_arr_dims
            sta  p8b_vm.p8s_index_of.p8v_dims_ptr
            lda  p8b_vm.p8v_arr_dims+1
            sta  p8b_vm.p8s_index_of.p8v_dims_ptr+1
            lda  p8b_vm.p8v_sp
            sec
            sbc  p8b_vm.p8s_index_of.p8v_nd
            sta  p8b_vm.p8s_index_of.p8v_first
            ldy  p8b_vm.p8s_index_of.p8v_slot
            lda  p8b_vm.p8v_arr_len_lsb,y
            sta  p8b_vm.p8s_index_of.p8v_total
            lda  p8b_vm.p8v_arr_len_msb,y
            sta  p8b_vm.p8s_index_of.p8v_total+1
            jsr  p8b_vm.p8s_index_of            ; A=lo, Y=hi of asoff
            pha
            phy
            lda  p8b_vm.p8v_sp                  ; B1 = value slot (= sp before sp-=nd)
            sta  P8ZP_SCRATCH_B1
            sec                                 ; sp -= nd
            sbc  p8b_vm.p8s_index_of.p8v_nd
            sta  p8b_vm.p8v_sp
            ply
            pla
            cmp  #$ff                           ; asoff == $ffff -> drop the store
            bne  _asok
            cpy  #$ff
            beq  _asdone
_asok:      jsr  prog8_math.mul_word_5         ; A/Y = asoff*5  (clobbers W1,W2)
            clc                                 ; dest = arrheap + arr_base[slot] + asoff*5 -> W1
            adc  p8b_vm.p8v_arrheap
            sta  P8ZP_SCRATCH_W1
            tya
            adc  p8b_vm.p8v_arrheap+1
            sta  P8ZP_SCRATCH_W1+1
            ldy  p8b_vm.p8s_index_of.p8v_slot
            lda  P8ZP_SCRATCH_W1
            clc
            adc  p8b_vm.p8v_arr_base_lsb,y
            sta  P8ZP_SCRATCH_W1
            lda  P8ZP_SCRATCH_W1+1
            adc  p8b_vm.p8v_arr_base_msb,y
            sta  P8ZP_SCRATCH_W1+1
            lda  P8ZP_SCRATCH_B1               ; src = &stack[value slot] -> W2
            jsr  p8b_vm.p8s_faddr
            stx  P8ZP_SCRATCH_W2
            sty  P8ZP_SCRATCH_W2+1
            ldy  #4                             ; copy 5-byte value straight into the element
-           lda  (P8ZP_SCRATCH_W2),y
            sta  (P8ZP_SCRATCH_W1),y
            dey
            bpl  -
_asdone:    rts
        }}
    }
    sub op_idim() {                       ; DIM A%(d0[,d1..]): allocate an integer array (2 bytes/element)
                    ubyte idslot = @(pcbase + pc)
                    ubyte idnd = @(pcbase + pc + 2)
                    pc += 3
                    uword idtot = dim_setup(iarr_dims, idslot, idnd, IARRHEAP_SIZE / 2)
                    if idtot != 0 and iarr_top + idtot * 2 <= IARRHEAP_SIZE {
                        iarr_base[idslot] = iarr_top
                        iarr_len[idslot] = idtot
                        iarr_ndims[idslot] = idnd
                        sys.memset(iarrheap + iarr_top, idtot * 2, 0)   ; A%() elements start at 0
                        iarr_top += idtot * 2
                    } else {
                        iarr_len[idslot] = 0                  ; too big / out of heap -> unusable
                    }
                }
    asmsub op_iaload() {                  ; A%(i[,j..]): push int element; 0 if any subscript out of range
        %asm {{
            lda  p8b_vm.p8v_pcbase              ; --- operands slot@pc, nd@pc+2 ; pc += 3 ---
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)
            sta  p8b_vm.p8s_index_of.p8v_slot
            ldy  #2
            lda  (P8ZP_SCRATCH_W1),y
            sta  p8b_vm.p8s_index_of.p8v_nd
            lda  p8b_vm.p8v_pc
            clc
            adc  #3
            sta  p8b_vm.p8v_pc
            bcc  +
            inc  p8b_vm.p8v_pc+1
+           lda  p8b_vm.p8v_iarr_dims           ; iloff = index_of(iarr_dims, slot, nd, sp-nd, iarr_len[slot])
            sta  p8b_vm.p8s_index_of.p8v_dims_ptr
            lda  p8b_vm.p8v_iarr_dims+1
            sta  p8b_vm.p8s_index_of.p8v_dims_ptr+1
            lda  p8b_vm.p8v_sp
            sec
            sbc  p8b_vm.p8s_index_of.p8v_nd
            sta  p8b_vm.p8s_index_of.p8v_first
            ldy  p8b_vm.p8s_index_of.p8v_slot
            lda  p8b_vm.p8v_iarr_len_lsb,y
            sta  p8b_vm.p8s_index_of.p8v_total
            lda  p8b_vm.p8v_iarr_len_msb,y
            sta  p8b_vm.p8s_index_of.p8v_total+1
            jsr  p8b_vm.p8s_index_of            ; A=lo, Y=hi of iloff ($ffff => out of range)
            pha
            phy
            lda  p8b_vm.p8v_sp                  ; sp -= nd
            sec
            sbc  p8b_vm.p8s_index_of.p8v_nd
            sta  p8b_vm.p8v_sp
            ply
            pla
            cmp  #$ff
            bne  _ilok
            cpy  #$ff
            beq  _ilzero
_ilok:      asl  a                              ; iloff*2 (2-byte elements) -> A=lo, Y=hi
            sta  P8ZP_SCRATCH_W1
            tya
            rol  a
            tay
            lda  P8ZP_SCRATCH_W1               ; W1 = iarrheap + iloff*2
            clc
            adc  p8b_vm.p8v_iarrheap
            sta  P8ZP_SCRATCH_W1
            tya
            adc  p8b_vm.p8v_iarrheap+1
            sta  P8ZP_SCRATCH_W1+1
            ldy  p8b_vm.p8s_index_of.p8v_slot ; + iarr_base[slot]
            lda  P8ZP_SCRATCH_W1
            clc
            adc  p8b_vm.p8v_iarr_base_lsb,y
            sta  P8ZP_SCRATCH_W1
            lda  P8ZP_SCRATCH_W1+1
            adc  p8b_vm.p8v_iarr_base_msb,y
            sta  P8ZP_SCRATCH_W1+1
            ldx  p8b_vm.p8v_sp                 ; istack[sp] = word at (W1)
            lda  (P8ZP_SCRATCH_W1)
            sta  p8b_vm.p8v_istack_lsb,x
            ldy  #1
            lda  (P8ZP_SCRATCH_W1),y
            sta  p8b_vm.p8v_istack_msb,x
            jmp  _ildone
_ilzero:    ldx  p8b_vm.p8v_sp                 ; out of range: istack[sp] = 0
            lda  #0
            sta  p8b_vm.p8v_istack_lsb,x
            sta  p8b_vm.p8v_istack_msb,x
_ildone:    inc  p8b_vm.p8v_sp
            rts
        }}
    }
    asmsub op_iastore() {                 ; A%(i[,j..]) = v: store int element; dropped if out of range
        %asm {{
            lda  p8b_vm.p8v_pcbase              ; --- operands slot@pc, nd@pc+2 ; pc += 3 ---
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)
            sta  p8b_vm.p8s_index_of.p8v_slot
            ldy  #2
            lda  (P8ZP_SCRATCH_W1),y
            sta  p8b_vm.p8s_index_of.p8v_nd
            lda  p8b_vm.p8v_pc
            clc
            adc  #3
            sta  p8b_vm.p8v_pc
            bcc  +
            inc  p8b_vm.p8v_pc+1
+           dec  p8b_vm.p8v_sp                  ; sp-- : value at istack[sp], subscripts below it
            lda  p8b_vm.p8v_iarr_dims           ; isoff = index_of(iarr_dims, slot, nd, sp-nd, iarr_len[slot])
            sta  p8b_vm.p8s_index_of.p8v_dims_ptr
            lda  p8b_vm.p8v_iarr_dims+1
            sta  p8b_vm.p8s_index_of.p8v_dims_ptr+1
            lda  p8b_vm.p8v_sp
            sec
            sbc  p8b_vm.p8s_index_of.p8v_nd
            sta  p8b_vm.p8s_index_of.p8v_first
            ldy  p8b_vm.p8s_index_of.p8v_slot
            lda  p8b_vm.p8v_iarr_len_lsb,y
            sta  p8b_vm.p8s_index_of.p8v_total
            lda  p8b_vm.p8v_iarr_len_msb,y
            sta  p8b_vm.p8s_index_of.p8v_total+1
            jsr  p8b_vm.p8s_index_of            ; A=lo, Y=hi of isoff
            pha
            phy
            lda  p8b_vm.p8v_sp                  ; B1 = value slot (= sp before sp-=nd)
            sta  P8ZP_SCRATCH_B1
            sec                                 ; sp -= nd
            sbc  p8b_vm.p8s_index_of.p8v_nd
            sta  p8b_vm.p8v_sp
            ply
            pla
            cmp  #$ff                           ; isoff == $ffff -> drop the store
            bne  _isok
            cpy  #$ff
            beq  _isdone
_isok:      asl  a                              ; isoff*2 -> A=lo, Y=hi
            sta  P8ZP_SCRATCH_W1
            tya
            rol  a
            tay
            lda  P8ZP_SCRATCH_W1               ; W1 = iarrheap + isoff*2
            clc
            adc  p8b_vm.p8v_iarrheap
            sta  P8ZP_SCRATCH_W1
            tya
            adc  p8b_vm.p8v_iarrheap+1
            sta  P8ZP_SCRATCH_W1+1
            ldy  p8b_vm.p8s_index_of.p8v_slot ; + iarr_base[slot]
            lda  P8ZP_SCRATCH_W1
            clc
            adc  p8b_vm.p8v_iarr_base_lsb,y
            sta  P8ZP_SCRATCH_W1
            lda  P8ZP_SCRATCH_W1+1
            adc  p8b_vm.p8v_iarr_base_msb,y
            sta  P8ZP_SCRATCH_W1+1
            ldx  P8ZP_SCRATCH_B1              ; istack[value slot] -> (W1)
            lda  p8b_vm.p8v_istack_lsb,x
            sta  (P8ZP_SCRATCH_W1)
            lda  p8b_vm.p8v_istack_msb,x
            ldy  #1
            sta  (P8ZP_SCRATCH_W1),y
_isdone:    rts
        }}
    }
    sub op_inputv() {
                    ubyte ivslot = @(pcbase + pc)
                    pc += 2
                    read_line()
                    pokef(varsf + (ivslot as uword) * 5, floats.parse(&inbuf))
                }
    asmsub op_inputs() {
        ; slot parked in shtmp across read_line (which must not see var_from_mem's params set yet).
        %asm {{
            jsr  p8b_vm.p8s_opw                 ; W1 = pcbase+pc
            lda  (P8ZP_SCRATCH_W1)              ; slot
            sta  p8b_vm.p8v_shtmp
            lda  #2
            jsr  p8b_vm.p8s_pcadd               ; pc += 2
            jsr  p8b_vm.p8s_read_line           ; read one line into inbuf
            lda  p8b_vm.p8v_shtmp
            sta  p8b_bstr.p8s_var_from_mem.p8v_slot
            lda  #<p8b_vm.p8v_inbuf
            sta  p8b_bstr.p8s_var_from_mem.p8v_src
            lda  #>p8b_vm.p8v_inbuf
            sta  p8b_bstr.p8s_var_from_mem.p8v_src+1
            lda  #<p8b_vm.p8v_inbuf
            ldy  #>p8b_vm.p8v_inbuf
            jsr  strings.length                 ; Y = length(inbuf)
            sty  p8b_bstr.p8s_var_from_mem.p8v_n
            jmp  p8b_bstr.p8s_var_from_mem      ; heap-copy into the var
        }}
    }
    asmsub op_pushf() {                      ; stack[sp] = 5-byte float immediate at pcbase+pc
        %asm {{
            lda  p8b_vm.p8v_pcbase
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            lda  P8ZP_SCRATCH_W1
            ldy  P8ZP_SCRATCH_W1+1
            jsr  $fe63                       ; MOVFM  FAC = immediate float
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_faddr
            jsr  $fe66                       ; MOVMF  stack[sp] = FAC
            lda  p8b_vm.p8v_pc
            clc
            adc  #5
            sta  p8b_vm.p8v_pc
            bcc  +
            inc  p8b_vm.p8v_pc+1
+           inc  p8b_vm.p8v_sp
            rts
        }}
    }
    asmsub op_callfn() {                     ; stack[sp-1] = FN(stack[sp-1]) -- dispatch fnid to a ROM float fn
        %asm {{
            lda  p8b_vm.p8v_pcbase           ; fnid = @(pcbase+pc)
            clc
            adc  p8b_vm.p8v_pc
            sta  P8ZP_SCRATCH_W1
            lda  p8b_vm.p8v_pcbase+1
            adc  p8b_vm.p8v_pc+1
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)
            pha                              ; stash fnid
            inc  p8b_vm.p8v_pc               ; pc++
            bne  _cfnopc
            inc  p8b_vm.p8v_pc+1
_cfnopc:    lda  p8b_vm.p8v_sp               ; FAC = stack[sp-1]  (the argument)
            dec  a
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe63                       ; MOVFM
            pla
            tax                              ; X = fnid
            cpx  #4                          ; FN_RND: ignore arg, use FAC = 1.0 (positive -> fresh random)
            bne  _cfgo
            lda  #<p8b_vm.p8v_c_one
            ldy  #>p8b_vm.p8v_c_one
            jsr  $fe63                       ; MOVFM  FAC = 1.0
            ldx  #4                          ; MOVFM may clobber X; restore the RND index
_cfgo:      lda  _cffnlo,x                   ; vector = ROM entry for this fnid
            sta  P8ZP_SCRATCH_W2
            lda  _cffnhi,x
            sta  P8ZP_SCRATCH_W2+1
            jsr  _cfvec                      ; FAC = fn(FAC)   (ROM rts returns here)
            lda  p8b_vm.p8v_sp               ; stack[sp-1] = FAC
            dec  a
            jsr  p8b_vm.p8s_faddr
            jsr  $fe66                       ; MOVMF
            rts
_cfvec:     jmp  (P8ZP_SCRATCH_W2)
            ; ROM float-function entry points, indexed by FN_* id (0..10):
            ;  SGN  INT  ABS  SQR  RND  SIN  COS  TAN  ATN  LOG  EXP
_cffnlo:    .byte <$fe84, <$fe2d, <$fe4e, <$fe30, <$fe57, <$fe42, <$fe3f, <$fe45, <$fe48, <$fe2a, <$fe3c
_cffnhi:    .byte >$fe84, >$fe2d, >$fe4e, >$fe30, >$fe57, >$fe42, >$fe3f, >$fe45, >$fe48, >$fe2a, >$fe3c
            ; !notreached!  (the two .byte rows above are the jump-vector data, not code)
        }}
    }
    asmsub op_strnum() {                  ; LEN/ASC/VAL: pop string, push number
        ; snd stays valid at sstack[ssp] (ssp is fixed after the single dec), so it's re-read for the
        ; trailing free_temp; we park it in shtmp only to survive the dlen/dptr/to_cbuf/parse calls.
        %asm {{
            jsr  p8b_vm.p8s_opw                 ; W1 = pcbase+pc
            lda  (P8ZP_SCRATCH_W1)              ; snid
            pha
            lda  #1
            jsr  p8b_vm.p8s_pcadd               ; pc++
            dec  p8b_vm.p8v_ssp
            ldx  p8b_vm.p8v_ssp                 ; snd = sstack[ssp]
            lda  p8b_vm.p8v_sstack_lsb,x
            sta  p8b_vm.p8v_shtmp
            lda  p8b_vm.p8v_sstack_msb,x
            sta  p8b_vm.p8v_shtmp+1
            pla                                 ; A = snid
            cmp  #1                             ; SN_ASC
            beq  _snasc
            cmp  #2                             ; SN_VAL
            beq  _snval
            ; --- SN_LEN: FAC = dlen(snd) ---
            lda  p8b_vm.p8v_shtmp
            ldy  p8b_vm.p8v_shtmp+1
            jsr  p8b_bstr.p8s_dlen              ; A = length
            tay
            jsr  floats.FREADUY                 ; FAC = unsigned(Y)
            bra  _snstore
_snasc:     lda  p8b_vm.p8v_shtmp               ; ASC: PETSCII of first char, 0 for ""
            ldy  p8b_vm.p8v_shtmp+1
            jsr  p8b_bstr.p8s_dlen
            tay
            beq  _snasc_fac                     ; empty -> Y=0 -> FREADUY gives 0.0
            lda  p8b_vm.p8v_shtmp
            ldy  p8b_vm.p8v_shtmp+1
            jsr  p8b_bstr.p8s_dptr              ; A=lo, Y=hi = body ptr
            sta  P8ZP_SCRATCH_W1
            sty  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)              ; first char
            tay
_snasc_fac: jsr  floats.FREADUY
            bra  _snstore
_snval:     lda  p8b_vm.p8v_shtmp               ; VAL: parse leading number
            ldy  p8b_vm.p8v_shtmp+1
            jsr  p8b_bstr.p8s_to_cbuf           ; A=lo, Y=hi -> null-terminated copy
            jsr  floats.parse                   ; FAC = parsed number
_snstore:   lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_faddr               ; X=lo, Y=hi of &stack[sp]
            jsr  $fe66                          ; MOVMF  stack[sp] = FAC
            inc  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_shtmp               ; free_temp_if_top(snd)
            ldy  p8b_vm.p8v_shtmp+1
            jmp  p8b_bstr.p8s_free_temp_if_top
        }}
    }
    asmsub op_numstr() {                  ; CHR$/STR$: pop number, push a string temp
        %asm {{
            jsr  p8b_vm.p8s_opw                 ; W1 = pcbase+pc
            lda  (P8ZP_SCRATCH_W1)              ; nsid
            pha
            lda  #1
            jsr  p8b_vm.p8s_pcadd               ; pc++
            dec  p8b_vm.p8v_sp
            pla                                 ; A = nsid
            beq  _nschr                         ; NS_CHR (0)
            ; --- NS_STR: the number's printed form (FOUT), leading space dropped like PRINT ---
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe63                          ; MOVFM  FAC = stack[sp]
            jsr  floats.tostr                   ; A=lo, Y=hi -> ROM string buffer (null-terminated)
            sta  P8ZP_SCRATCH_W1
            sty  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)
            cmp  #32                            ; leading ' ' ?
            bne  _nslen
            inc  P8ZP_SCRATCH_W1                ; skip it
            bne  _nslen
            inc  P8ZP_SCRATCH_W1+1
_nslen:     lda  P8ZP_SCRATCH_W1               ; src -> mem_to_temp
            sta  p8b_bstr.p8s_mem_to_temp.p8v_src
            lda  P8ZP_SCRATCH_W1+1
            sta  p8b_bstr.p8s_mem_to_temp.p8v_src+1
            ldy  #0                             ; n = strlen(src)  (number strings are short)
_nsslen:    lda  (P8ZP_SCRATCH_W1),y
            beq  _nsgo
            iny
            bne  _nsslen
_nsgo:      tya
            sta  p8b_bstr.p8s_mem_to_temp.p8v_n
            jsr  p8b_bstr.p8s_mem_to_temp       ; A=lo, Y=hi = result temp
            bra  _nspush
_nschr:     lda  p8b_vm.p8v_sp                 ; NS_CHR: one PETSCII char = CHR$(n)
            jsr  p8b_vm.p8s_stack_word          ; W1 = stack[sp] as uword
            lda  P8ZP_SCRATCH_W1                ; low byte
            jsr  p8b_bstr.p8s_chr_temp          ; A=lo, Y=hi = result temp
_nspush:    ldx  p8b_vm.p8v_ssp                ; sstack[ssp] = result ; ssp++
            sta  p8b_vm.p8v_sstack_lsb,x
            tya
            sta  p8b_vm.p8v_sstack_msb,x
            inc  p8b_vm.p8v_ssp
            jmp  p8b_vm.p8s_str_error
        }}
    }
    asmsub op_lefts() {                   ; LEFT$(s,n): first n chars
        ; substr_temp frees the src temp and pushes the result body; we just replace the top sstack
        ; slot (pop src / push result = same depth). Write-then-tail-str_error: inert if it halts.
        %asm {{
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_faddr               ; X=lo, Y=hi of &stack[sp]
            stx  P8ZP_SCRATCH_W1
            sty  P8ZP_SCRATCH_W1+1
            lda  #<p8b_vm.p8s_clamp_count.p8v_f
            ldy  #>p8b_vm.p8s_clamp_count.p8v_f
            jsr  floats.copy_float              ; clamp_count.f = stack[sp]
            jsr  p8b_vm.p8s_clamp_count         ; A = n (0..255)
            sta  p8b_bstr.p8s_substr_temp.p8v_count
            stz  p8b_bstr.p8s_substr_temp.p8v_start   ; LEFT$ starts at 0
            dec  p8b_vm.p8v_ssp
            ldx  p8b_vm.p8v_ssp                 ; src = sstack[ssp]
            lda  p8b_vm.p8v_sstack_lsb,x
            sta  p8b_bstr.p8s_substr_temp.p8v_sd
            lda  p8b_vm.p8v_sstack_msb,x
            sta  p8b_bstr.p8s_substr_temp.p8v_sd+1
            jsr  p8b_bstr.p8s_substr_temp       ; A=lo, Y=hi = result temp
            ldx  p8b_vm.p8v_ssp
            sta  p8b_vm.p8v_sstack_lsb,x
            tya
            sta  p8b_vm.p8v_sstack_msb,x
            inc  p8b_vm.p8v_ssp
            jmp  p8b_vm.p8s_str_error
        }}
    }
    asmsub op_rights() {                  ; RIGHT$(s,n): last n chars
        %asm {{
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_faddr
            stx  P8ZP_SCRATCH_W1
            sty  P8ZP_SCRATCH_W1+1
            lda  #<p8b_vm.p8s_clamp_count.p8v_f
            ldy  #>p8b_vm.p8s_clamp_count.p8v_f
            jsr  floats.copy_float
            jsr  p8b_vm.p8s_clamp_count         ; A = n
            sta  p8b_bstr.p8s_substr_temp.p8v_count
            dec  p8b_vm.p8v_ssp
            ldx  p8b_vm.p8v_ssp                 ; src = sstack[ssp]
            lda  p8b_vm.p8v_sstack_lsb,x
            sta  p8b_bstr.p8s_substr_temp.p8v_sd
            lda  p8b_vm.p8v_sstack_msb,x
            sta  p8b_bstr.p8s_substr_temp.p8v_sd+1
            lda  p8b_bstr.p8s_substr_temp.p8v_sd     ; start = (n < len) ? len-n : 0
            ldy  p8b_bstr.p8s_substr_temp.p8v_sd+1
            jsr  p8b_bstr.p8s_dlen              ; A = len
            sec
            sbc  p8b_bstr.p8s_substr_temp.p8v_count   ; A = len - n ; C set iff len >= n
            bcs  +
            lda  #0                             ; n > len -> start 0 (whole string)
+           sta  p8b_bstr.p8s_substr_temp.p8v_start
            jsr  p8b_bstr.p8s_substr_temp
            ldx  p8b_vm.p8v_ssp
            sta  p8b_vm.p8v_sstack_lsb,x
            tya
            sta  p8b_vm.p8v_sstack_msb,x
            inc  p8b_vm.p8v_ssp
            jmp  p8b_vm.p8s_str_error
        }}
    }
    asmsub op_mids() {                    ; MID$(s,start,len): substring, start 1-based
        ; start arg is a SIGNED word: <=0 -> 0, 1..256 -> start-1, >256 -> 255 (past end -> empty).
        %asm {{
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_faddr
            stx  P8ZP_SCRATCH_W1
            sty  P8ZP_SCRATCH_W1+1
            lda  #<p8b_vm.p8s_clamp_count.p8v_f
            ldy  #>p8b_vm.p8s_clamp_count.p8v_f
            jsr  floats.copy_float
            jsr  p8b_vm.p8s_clamp_count         ; A = len
            sta  p8b_bstr.p8s_substr_temp.p8v_count
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe63                          ; MOVFM  FAC = stack[sp] (start)
            jsr  floats.cast_FAC1_as_w_into_ay  ; A=lo, Y=hi = start (signed word)
            cpy  #0
            bmi  _md0                           ; start < 0 -> 0
            bne  _mdcap                          ; start >= 256 -> 255
            cmp  #0                             ; hi==0: start in 0..255
            beq  _mdset                          ; start == 0 -> 0
            dec  a                              ; start-1
            bra  _mdset
_md0:       lda  #0
            bra  _mdset
_mdcap:     lda  #255
_mdset:     sta  p8b_bstr.p8s_substr_temp.p8v_start
            dec  p8b_vm.p8v_ssp
            ldx  p8b_vm.p8v_ssp                 ; src = sstack[ssp]
            lda  p8b_vm.p8v_sstack_lsb,x
            sta  p8b_bstr.p8s_substr_temp.p8v_sd
            lda  p8b_vm.p8v_sstack_msb,x
            sta  p8b_bstr.p8s_substr_temp.p8v_sd+1
            jsr  p8b_bstr.p8s_substr_temp
            ldx  p8b_vm.p8v_ssp
            sta  p8b_vm.p8v_sstack_lsb,x
            tya
            sta  p8b_vm.p8v_sstack_msb,x
            inc  p8b_vm.p8v_ssp
            jmp  p8b_vm.p8s_str_error
        }}
    }
    sub op_read() {                       ; READ into a numeric var: parse the item
                    ubyte rdslot = @(pcbase + pc)
                    pc += 2
                    pokef(varsf + (rdslot as uword) * 5, floats.parse(data_next()))
                }
    asmsub op_reads() {                   ; READ into a string var: heap-copy the item
        %asm {{
            jsr  p8b_vm.p8s_opw                 ; W1 = pcbase+pc
            lda  (P8ZP_SCRATCH_W1)              ; slot
            pha
            lda  #2
            jsr  p8b_vm.p8s_pcadd               ; pc += 2
            jsr  p8b_vm.p8s_data_next           ; A=lo, Y=hi -> DATA-pool text (stable)
            sta  p8b_bstr.p8s_var_from_mem.p8v_src
            sty  p8b_bstr.p8s_var_from_mem.p8v_src+1
            jsr  strings.length                 ; A/Y still the src ptr -> Y = length
            sty  p8b_bstr.p8s_var_from_mem.p8v_n
            pla
            sta  p8b_bstr.p8s_var_from_mem.p8v_slot
            jmp  p8b_bstr.p8s_var_from_mem
        }}
    }
    sub op_restore() {                    ; rewind the DATA cursor to the first item
                    dataptr = database
                }
    asmsub op_sdim() {                    ; DIM A$(...): allocate a BASIC string array
        ; shtmp = slot(lo)/ndims(hi) parked across dim_setup + sarr_alloc; shtmp2 = element total.
        %asm {{
            jsr  p8b_vm.p8s_opw                 ; W1 = pcbase+pc
            lda  (P8ZP_SCRATCH_W1)              ; slot
            sta  p8b_vm.p8v_shtmp
            ldy  #2
            lda  (P8ZP_SCRATCH_W1),y            ; ndims
            sta  p8b_vm.p8v_shtmp+1
            lda  #3
            jsr  p8b_vm.p8s_pcadd               ; pc += 3
            lda  p8b_vm.p8v_sarr_dims           ; dim_setup(sarr_dims, slot, nd, SARR_MAXELEM)
            sta  p8b_vm.p8s_dim_setup.p8v_dims_ptr
            lda  p8b_vm.p8v_sarr_dims+1
            sta  p8b_vm.p8s_dim_setup.p8v_dims_ptr+1
            lda  p8b_vm.p8v_shtmp
            sta  p8b_vm.p8s_dim_setup.p8v_slot
            lda  p8b_vm.p8v_shtmp+1
            sta  p8b_vm.p8s_dim_setup.p8v_nd
            lda  #<8192
            sta  p8b_vm.p8s_dim_setup.p8v_cap
            lda  #>8192
            sta  p8b_vm.p8s_dim_setup.p8v_cap+1
            jsr  p8b_vm.p8s_dim_setup           ; A=lo, Y=hi = total
            sta  p8b_vm.p8v_shtmp2
            sty  p8b_vm.p8v_shtmp2+1
            ora  p8b_vm.p8v_shtmp2+1            ; total == 0 -> unusable
            beq  _sdfail
            lda  p8b_vm.p8v_shtmp               ; sarr_alloc(slot, total, ndims)
            sta  p8b_bstr.p8s_sarr_alloc.p8v_slot
            lda  p8b_vm.p8v_shtmp2
            sta  p8b_bstr.p8s_sarr_alloc.p8v_nelem
            lda  p8b_vm.p8v_shtmp2+1
            sta  p8b_bstr.p8s_sarr_alloc.p8v_nelem+1
            lda  p8b_vm.p8v_shtmp+1
            sta  p8b_bstr.p8s_sarr_alloc.p8v_ndims
            jsr  p8b_bstr.p8s_sarr_alloc        ; A = bool (0 = out of memory)
            beq  _sdfail
            ldy  p8b_vm.p8v_shtmp               ; sarr_len[slot] = total ; sarr_ndims[slot] = ndims
            lda  p8b_vm.p8v_shtmp2
            sta  p8b_vm.p8v_sarr_len_lsb,y
            lda  p8b_vm.p8v_shtmp2+1
            sta  p8b_vm.p8v_sarr_len_msb,y
            lda  p8b_vm.p8v_shtmp+1
            sta  p8b_vm.p8v_sarr_ndims,y
            rts
_sdfail:    ldy  p8b_vm.p8v_shtmp               ; sarr_len[slot] = 0 -> unusable
            lda  #0
            sta  p8b_vm.p8v_sarr_len_lsb,y
            sta  p8b_vm.p8v_sarr_len_msb,y
            rts
        }}
    }
    asmsub op_saload() {                  ; A$(i[,j..]): push the element's descriptor ("" if out of range)
        ; shtmp = slot(lo)/nd(hi); shtmp2 = element offset ($ffff if any subscript out of range).
        %asm {{
            jsr  p8b_vm.p8s_opw                 ; W1 = pcbase+pc
            lda  (P8ZP_SCRATCH_W1)              ; slot
            sta  p8b_vm.p8v_shtmp
            ldy  #2
            lda  (P8ZP_SCRATCH_W1),y            ; nd
            sta  p8b_vm.p8v_shtmp+1
            lda  #3
            jsr  p8b_vm.p8s_pcadd               ; pc += 3
            lda  p8b_vm.p8v_sarr_dims           ; index_of(sarr_dims, slot, nd, sp-nd, sarr_len[slot])
            sta  p8b_vm.p8s_index_of.p8v_dims_ptr
            lda  p8b_vm.p8v_sarr_dims+1
            sta  p8b_vm.p8s_index_of.p8v_dims_ptr+1
            lda  p8b_vm.p8v_shtmp
            sta  p8b_vm.p8s_index_of.p8v_slot
            lda  p8b_vm.p8v_shtmp+1
            sta  p8b_vm.p8s_index_of.p8v_nd
            lda  p8b_vm.p8v_sp
            sec
            sbc  p8b_vm.p8v_shtmp+1
            sta  p8b_vm.p8s_index_of.p8v_first
            ldy  p8b_vm.p8v_shtmp
            lda  p8b_vm.p8v_sarr_len_lsb,y
            sta  p8b_vm.p8s_index_of.p8v_total
            lda  p8b_vm.p8v_sarr_len_msb,y
            sta  p8b_vm.p8s_index_of.p8v_total+1
            jsr  p8b_vm.p8s_index_of            ; A=lo, Y=hi = off
            sta  p8b_vm.p8v_shtmp2
            sty  p8b_vm.p8v_shtmp2+1
            lda  p8b_vm.p8v_sp                  ; sp -= nd
            sec
            sbc  p8b_vm.p8v_shtmp+1
            sta  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_shtmp2              ; off == $ffff -> out of range
            and  p8b_vm.p8v_shtmp2+1
            cmp  #$ff
            beq  _slempty
            lda  p8b_vm.p8v_shtmp               ; sstack[ssp] = sarr_desc(slot, off) ; ssp++
            sta  p8b_bstr.p8s_sarr_desc.p8v_slot
            lda  p8b_vm.p8v_shtmp2
            sta  p8b_bstr.p8s_sarr_desc.p8v_elemidx
            lda  p8b_vm.p8v_shtmp2+1
            sta  p8b_bstr.p8s_sarr_desc.p8v_elemidx+1
            jsr  p8b_bstr.p8s_sarr_desc         ; A=lo, Y=hi = live descriptor address (GC root)
            ldx  p8b_vm.p8v_ssp
            sta  p8b_vm.p8v_sstack_lsb,x
            tya
            sta  p8b_vm.p8v_sstack_msb,x
            inc  p8b_vm.p8v_ssp
            rts
_slempty:   jmp  p8b_vm.p8s_push_empty          ; out of range reads as ""
        }}
    }
    asmsub op_sastore() {                 ; A$(i[,j..])=v$: store the element (dropped if out of range)
        ; ssval stays at sstack[ssp] (ssp fixed after the dec) so it's re-read for store/free.
        %asm {{
            jsr  p8b_vm.p8s_opw                 ; W1 = pcbase+pc
            lda  (P8ZP_SCRATCH_W1)              ; slot
            sta  p8b_vm.p8v_shtmp
            ldy  #2
            lda  (P8ZP_SCRATCH_W1),y            ; nd
            sta  p8b_vm.p8v_shtmp+1
            lda  #3
            jsr  p8b_vm.p8s_pcadd               ; pc += 3
            dec  p8b_vm.p8v_ssp                 ; ssval = sstack[ssp] (pushed after the subscripts)
            lda  p8b_vm.p8v_sarr_dims           ; index_of(sarr_dims, slot, nd, sp-nd, sarr_len[slot])
            sta  p8b_vm.p8s_index_of.p8v_dims_ptr
            lda  p8b_vm.p8v_sarr_dims+1
            sta  p8b_vm.p8s_index_of.p8v_dims_ptr+1
            lda  p8b_vm.p8v_shtmp
            sta  p8b_vm.p8s_index_of.p8v_slot
            lda  p8b_vm.p8v_shtmp+1
            sta  p8b_vm.p8s_index_of.p8v_nd
            lda  p8b_vm.p8v_sp
            sec
            sbc  p8b_vm.p8v_shtmp+1
            sta  p8b_vm.p8s_index_of.p8v_first
            ldy  p8b_vm.p8v_shtmp
            lda  p8b_vm.p8v_sarr_len_lsb,y
            sta  p8b_vm.p8s_index_of.p8v_total
            lda  p8b_vm.p8v_sarr_len_msb,y
            sta  p8b_vm.p8s_index_of.p8v_total+1
            jsr  p8b_vm.p8s_index_of            ; A=lo, Y=hi = off
            sta  p8b_vm.p8v_shtmp2
            sty  p8b_vm.p8v_shtmp2+1
            lda  p8b_vm.p8v_sp                  ; sp -= nd
            sec
            sbc  p8b_vm.p8v_shtmp+1
            sta  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_shtmp2              ; off == $ffff -> drop store, still free the value
            and  p8b_vm.p8v_shtmp2+1
            cmp  #$ff
            beq  _ssdrop
            lda  p8b_vm.p8v_shtmp               ; store_desc(sarr_desc(slot, off), ssval)
            sta  p8b_bstr.p8s_sarr_desc.p8v_slot
            lda  p8b_vm.p8v_shtmp2
            sta  p8b_bstr.p8s_sarr_desc.p8v_elemidx
            lda  p8b_vm.p8v_shtmp2+1
            sta  p8b_bstr.p8s_sarr_desc.p8v_elemidx+1
            jsr  p8b_bstr.p8s_sarr_desc         ; A=lo, Y=hi = element descriptor address (GC root)
            sta  p8b_bstr.p8s_store_desc.p8v_dd
            sty  p8b_bstr.p8s_store_desc.p8v_dd+1
            ldx  p8b_vm.p8v_ssp                 ; ssval = sstack[ssp]
            lda  p8b_vm.p8v_sstack_lsb,x
            sta  p8b_bstr.p8s_store_desc.p8v_sd
            lda  p8b_vm.p8v_sstack_msb,x
            sta  p8b_bstr.p8s_store_desc.p8v_sd+1
            jmp  p8b_bstr.p8s_store_desc        ; heap-copy / steal-temp
_ssdrop:    ldx  p8b_vm.p8v_ssp                 ; free_temp_if_top(ssval)
            lda  p8b_vm.p8v_sstack_lsb,x
            ldy  p8b_vm.p8v_sstack_msb,x
            jmp  p8b_bstr.p8s_free_temp_if_top
        }}
    }
    sub op_rdnum() {                      ; READ into an array element: push the item as a number
                    stack[sp] = floats.parse(data_next())
                    sp++
                }
    asmsub op_rdstr() {                   ; READ into a string-array element: push the item text
        %asm {{
            jsr  p8b_vm.p8s_data_next           ; A=lo, Y=hi -> off-heap DATA text (stable)
            jmp  p8b_vm.p8s_push_cstr           ; scratch descriptor over it
        }}
    }
    asmsub op_scmp() {                    ; compare two strings -> numeric truth (-1/0)
        ; sca=sstack[ssp], scb=sstack[ssp+1] after ssp-=2; ssp is then fixed, so both are re-read for the
        ; top-first frees. bcompare overwrites its own ad/bd params, hence the re-read rather than reuse.
        %asm {{
            jsr  p8b_vm.p8s_opw                 ; W1 = pcbase+pc
            lda  (P8ZP_SCRATCH_W1)              ; scid
            pha
            lda  #1
            jsr  p8b_vm.p8s_pcadd               ; pc++
            dec  p8b_vm.p8v_ssp
            dec  p8b_vm.p8v_ssp                 ; ssp -= 2
            ldx  p8b_vm.p8v_ssp
            lda  p8b_vm.p8v_sstack_lsb,x        ; sca (left) -> bcompare.ad
            sta  p8b_bstr.p8s_bcompare.p8v_ad
            lda  p8b_vm.p8v_sstack_msb,x
            sta  p8b_bstr.p8s_bcompare.p8v_ad+1
            lda  p8b_vm.p8v_sstack_lsb+1,x      ; scb (right) -> bcompare.bd
            sta  p8b_bstr.p8s_bcompare.p8v_bd
            lda  p8b_vm.p8v_sstack_msb+1,x
            sta  p8b_bstr.p8s_bcompare.p8v_bd+1
            jsr  p8b_bstr.p8s_bcompare          ; A = rel: $ff (a<b) / 0 (=) / 1 (a>b)
            tay                                 ; rel -> Y
            pla                                 ; A = scid (0..5)
            beq  _sceq                          ; SC_EQ
            cmp  #1
            beq  _scne
            cmp  #2
            beq  _sclt
            cmp  #3
            beq  _scgt
            cmp  #4
            beq  _scle
            ; SC_GE: rel >= 0
            tya
            bmi  _scfalse
            bra  _sctrue
_sceq:      tya
            beq  _sctrue
            bra  _scfalse
_scne:      tya
            bne  _sctrue
            bra  _scfalse
_sclt:      tya
            bmi  _sctrue
            bra  _scfalse
_scgt:      tya                                 ; rel > 0
            beq  _scfalse
            bmi  _scfalse
            bra  _sctrue
_scle:      tya                                 ; rel <= 0
            beq  _sctrue
            bmi  _sctrue
_scfalse:   lda  #0
            bra  _scfin
_sctrue:    lda  #1
_scfin:     jsr  p8b_vm.p8s_bool_to_float       ; FAC = -1.0 (true) / 0.0 (false)
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_faddr
            jsr  $fe66                          ; MOVMF  stack[sp] = FAC
            inc  p8b_vm.p8v_sp
            ldx  p8b_vm.p8v_ssp                 ; free scb (top) then sca
            lda  p8b_vm.p8v_sstack_lsb+1,x
            ldy  p8b_vm.p8v_sstack_msb+1,x
            jsr  p8b_bstr.p8s_free_temp_if_top
            ldx  p8b_vm.p8v_ssp
            lda  p8b_vm.p8v_sstack_lsb,x
            ldy  p8b_vm.p8v_sstack_msb,x
            jmp  p8b_bstr.p8s_free_temp_if_top
        }}
    }
    asmsub op_open() {                     ; OPEN lfn,dev,sa,"name"
        ; sa/dev parked in shtmp, lfn in shtmp2, consumed by SETLFS; then shtmp reused for the name.
        %asm {{
            dec  p8b_vm.p8v_sp                  ; pop sa
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_stack_word
            lda  P8ZP_SCRATCH_W1
            sta  p8b_vm.p8v_shtmp
            dec  p8b_vm.p8v_sp                  ; pop dev
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_stack_word
            lda  P8ZP_SCRATCH_W1
            sta  p8b_vm.p8v_shtmp+1
            dec  p8b_vm.p8v_sp                  ; pop lfn
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_stack_word
            lda  P8ZP_SCRATCH_W1
            sta  p8b_vm.p8v_shtmp2
            lda  p8b_vm.p8v_shtmp2              ; SETLFS(lfn, dev, sa)
            ldx  p8b_vm.p8v_shtmp+1
            ldy  p8b_vm.p8v_shtmp
            jsr  cbm.SETLFS
            dec  p8b_vm.p8v_ssp                 ; pop name descriptor
            ldx  p8b_vm.p8v_ssp
            lda  p8b_vm.p8v_sstack_lsb,x
            sta  p8b_vm.p8v_shtmp
            lda  p8b_vm.p8v_sstack_msb,x
            sta  p8b_vm.p8v_shtmp+1
            lda  p8b_vm.p8v_shtmp               ; SETNAM(dlen(name), dptr(name))
            ldy  p8b_vm.p8v_shtmp+1
            jsr  p8b_bstr.p8s_dptr              ; A=lo, Y=hi = body ptr
            tax
            phx
            phy
            lda  p8b_vm.p8v_shtmp
            ldy  p8b_vm.p8v_shtmp+1
            jsr  p8b_bstr.p8s_dlen              ; A = length
            ply
            plx
            jsr  cbm.SETNAM                     ; A=len, X=lo, Y=hi
            jsr  cbm.OPEN
            lda  p8b_vm.p8v_shtmp               ; free_temp_if_top(name)
            ldy  p8b_vm.p8v_shtmp+1
            jmp  p8b_bstr.p8s_free_temp_if_top
        }}
    }
    asmsub op_close() {                    ; CLOSE lfn
        %asm {{
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_stack_word         ; W1 = lfn word
            lda  P8ZP_SCRATCH_W1               ; A = lfn (low byte)
            jmp  cbm.CLOSE
        }}
    }
    asmsub op_getch() {                    ; GET#lfn,v$ : one byte -> a 0/1-char string
        %asm {{
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_stack_word          ; W1 = stack[sp] as uword
            ldx  P8ZP_SCRATCH_W1                ; X = lfn (low byte)
            jsr  cbm.CHKIN
            jsr  cbm.CHRIN                      ; A = byte (0 if none available)
            pha
            jsr  cbm.CLRCHN
            pla
            bne  _gcchar
            jmp  p8b_vm.p8s_push_empty          ; no byte -> ""
_gcchar:    jsr  p8b_bstr.p8s_chr_temp          ; chr_temp(A=byte) -> A=lo, Y=hi (1-char temp)
            ldx  p8b_vm.p8v_ssp
            sta  p8b_vm.p8v_sstack_lsb,x
            tya
            sta  p8b_vm.p8v_sstack_msb,x
            inc  p8b_vm.p8v_ssp
            jmp  p8b_vm.p8s_str_error
        }}
    }
    sub op_status() {                      ; ST : the KERNAL I/O status word
                    stack[sp] = cbm.READST() as float
                    sp++
                }
    asmsub op_chkout() {                   ; PRINT#lfn : redirect the following PRINTs
        %asm {{
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_stack_word         ; W1 = lfn word
            ldx  P8ZP_SCRATCH_W1               ; CHKOUT takes the logical file number in X
            jmp  cbm.CHKOUT
        }}
    }
    asmsub op_chkin() {                    ; INPUT#lfn : redirect the following INPUT
        %asm {{
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp
            jsr  p8b_vm.p8s_stack_word         ; W1 = lfn word
            ldx  P8ZP_SCRATCH_W1               ; CHKIN takes the logical file number in X
            jmp  cbm.CHKIN
        }}
    }
    sub op_clrch() {                       ; end a PRINT#/INPUT#, restore default I/O
                    cbm.CLRCHN()
                }
    asmsub op_pow() {                 ; a ^ b  (a=stack[sp-1], b=stack[sp]); FPWRT: FAC = ARG ^ FAC
        %asm {{
            dec  p8b_vm.p8v_sp
            lda  p8b_vm.p8v_sp            ; ARG = a (base)  via CONUPK
            dec  a
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe5a                    ; CONUPK  ARG = stack[sp-1] = a
            lda  p8b_vm.p8v_sp            ; FAC = b (exponent)  via MOVFM
            jsr  p8b_vm.p8s_faddr
            txa
            jsr  $fe63                    ; MOVFM   FAC = stack[sp] = b
            jsr  $fe39                    ; FPWRT   FAC = ARG ^ FAC = a ^ b
            lda  p8b_vm.p8v_sp
            dec  a
            jsr  p8b_vm.p8s_faddr
            jsr  $fe66                    ; MOVMF
            rts
        }}
    }
    sub op_wait() {                   ; WAIT addr,mask,xor: spin until (peek(addr) ^ xor) & mask
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

    ; OP_PASSTHRU: hand one tokenized BASIC statement to the ROM interpreter (leaf/extension
    ; statements -- VERA/sound/graphics/disk -- that run and RTS back). The operand is a length byte
    ; then that many (marker-encoded) tokenized bytes; we expand them into low-RAM passbuf framed as
    ; [':'][bytes][$00], point TXTPTR at it, page in BASIC ROM, prime CHRGET, and JSR gone3. Banks are
    ; saved/restored so a statement that touches banking (or the in-process banked P-code) is safe.
    ;
    ; A $01<slot> marker is a scalar GPC numeric variable the compiler couldn't leave as a name (the ROM
    ; would look it up in BASIC's variable table, where GPC's vars don't live -- see parse_passthru). We
    ; splice in the variable's current value as ASCII decimal, so a statement like `VPOKE 0,A,V` reaches
    ; the ROM as `VPOKE 0,4660,66`. Markers are only honoured OUTSIDE quoted strings.
    sub op_passthru() {
        ubyte plen = @(pcbase + pc)
        passbuf[0] = $3a                          ; ':' -- CHRGET pre-increments past it to the first token
        ubyte w = 1                               ; passbuf write index (byte-sized; bounded < 254 below)
        ubyte i = 0
        bool inq = false
        while i < plen and w < 254 {
            ubyte ch = @(pcbase + pc + 1 + i)
            i++
            if inq {
                passbuf[w] = ch
                w++
                if ch == '"'
                    inq = false
            } else if ch == '"' {
                passbuf[w] = ch
                w++
                inq = true
            } else if ch == $01 {
                ubyte slot = @(pcbase + pc + 1 + i)   ; variable marker -> splice its value as ASCII decimal
                i++
                uword ds = floats.tostr(peekf(varsf + (slot as uword) * 5))
                if @(ds) == ' '
                    ds++                          ; drop STR$'s leading sign-space (CHRGET would skip it anyway)
                while @(ds) != 0 and w < 254 {
                    passbuf[w] = @(ds)
                    w++
                    ds++
                }
            } else {
                passbuf[w] = ch
                w++
            }
        }
        passbuf[w] = 0                            ; end-of-line: gone3 runs exactly this one statement
        pc += (plen as uword) + 1                 ; step past the length byte + the (marker-encoded) bytes
        %asm {{
            lda  #<p8b_vm.p8v_passbuf
            sta  $ee                              ; TXTPTR lo
            lda  #>p8b_vm.p8v_passbuf
            sta  $ef                              ; TXTPTR hi
            stz  $03eb                            ; curlin = 0 (program mode, not $FFxx direct)
            stz  $03ec
            lda  $00
            pha                                   ; save RAM bank (the P-code bank, in-process)
            lda  $01
            pha                                   ; save ROM bank
            lda  #4
            sta  $01                              ; page in BASIC ROM
            jsr  $00e7                            ; CHRGET: step past ':', read the first token
            jsr  $cc63                            ; gone3: dispatch + run the statement, RTS back
            pla
            sta  $01                              ; restore ROM bank
            pla
            sta  $00                              ; restore RAM bank
        }}
    }

    ; OP_CALLX: evaluate an X16 ROM expression-function (VPEEK/JOY/MX/...) whose numeric arguments GPC
    ; has already pushed. GPC's own variables aren't in BASIC's table, so a whole VPEEK(0,X) can't just
    ; be handed to frmevl; instead the compiler emitted code to evaluate each argument, and here we pop
    ; the computed values, format them as ASCII decimal into a synthesized tokenized call in low-RAM
    ; xbuf ([$CE][subtok] then '(' arg,arg,... ')'), point TXTPTR at it, page in BASIC ROM, and JSR
    ; frmevl. The ROM handler runs and leaves a numeric result in FAC1; MOVMF packs it into the stack
    ; cell the arguments occupied. Banks + curlin are saved/restored exactly as OP_PASSTHRU does. (Zero-
    ; arg functions -- MX/MY/MB/MWHEEL -- emit no parens: xbuf is just [$CE][subtok].)
    ; Build the synthesized tokenized X16-function call in xbuf from the OP_CALLX/OP_CALLXS operand:
    ; read subtok + nargs, pop nargs numeric args off the stack (in SOURCE order -- the stack top is the
    ; last arg), and format them as ASCII decimal into  $CE subtok [ '(' arg0 ',' arg1 ... ')' ] $00.
    ; Shared by op_callx (numeric result) and op_callxs (string result).
    sub xbuild() {
        ubyte xsub = @(pcbase + pc)
        ubyte xn   = @(pcbase + pc + 1)
        pc += 2
        ubyte k = xn
        while k != 0 {
            k--
            sp--
            xargs[k] = stack[sp]
        }
        xbuf[0] = $ce
        xbuf[1] = xsub
        ubyte w = 2                                   ; xbuf index (byte-sized; the compiler caps nargs)
        if xn != 0 {
            xbuf[w] = '('
            w++
            ubyte a = 0
            while a < xn {
                if a != 0 {
                    xbuf[w] = ','
                    w++
                }
                uword ds = floats.tostr(xargs[a])         ; null-terminated PETSCII; a leading space (for
                ubyte j = 0                               ; non-negatives) is harmless -- CHRGET skips it
                while @(ds + j) != 0 {
                    xbuf[w] = @(ds + j)
                    w++
                    j++
                }
                a++
            }
            xbuf[w] = ')'
            w++
        }
        xbuf[w] = 0
    }

    sub op_callx() {
        xbuild()
        xdest = &stack[sp]                                ; the result goes back where the args were
        %asm {{
            lda  #<p8b_vm.p8v_xbuf
            sta  $ee                                      ; TXTPTR lo -> xbuf (frmevl parses from here)
            lda  #>p8b_vm.p8v_xbuf
            sta  $ef                                      ; TXTPTR hi
            stz  $03eb                                    ; curlin = 0 (program mode, not $FFxx direct)
            stz  $03ec
            lda  $00
            pha                                           ; save RAM bank (the P-code bank, in-process)
            lda  $01
            pha                                           ; save ROM bank
            lda  #4
            sta  $01                                      ; page in BASIC ROM
            jsr  $d350                                    ; frmevl: evaluate the call -> result in FAC1
            ldx  p8b_vm.p8v_xdest
            ldy  p8b_vm.p8v_xdest+1
            jsr  $fe66                                    ; MOVMF: pack FAC1 -> [xdest] as a 5-byte MFLPT
            pla
            sta  $01                                      ; restore ROM bank
            pla
            sta  $00                                      ; restore RAM bank
        }}
        sp++                                              ; the result now occupies the cell at xdest
    }

    ; OP_CALLXS: a string-returning X16 function (HEX$/BIN$/RPT$). Same synthesized call as op_callx
    ; (xbuild formats the 1-or-2 numeric args), but frmevl leaves a STRING result. We call the ROM's
    ; `frestr` ($DE0E) -- it verifies the value is a string, frees the BASIC temp descriptor, and returns
    ; len in A + the heap body pointer in X/Y. The body is still intact (freeing only pops the descriptor
    ; and moves fretop), so we copy it off-heap into xbuf (its synthesized-call input already consumed;
    ; xbuf is sized 256 so RPT$'s up-to-255-byte result fits), then adopt it into a GPC string temp via
    ; bstr.mem_to_temp -- exactly how STR$/CHR$ (op_numstr) turn a ROM-produced string into a GPC temp.
    sub op_callxs() {
        xbuild()
        %asm {{
            lda  #<p8b_vm.p8v_xbuf
            sta  $ee                                      ; TXTPTR lo -> xbuf
            lda  #>p8b_vm.p8v_xbuf
            sta  $ef                                      ; TXTPTR hi
            stz  $03eb                                    ; curlin = 0
            stz  $03ec
            lda  $00
            pha                                           ; save RAM bank
            lda  $01
            pha                                           ; save ROM bank
            lda  #4
            sta  $01                                      ; page in BASIC ROM
            jsr  $d350                                    ; frmevl: evaluate the call -> string result
            jsr  $de0e                                    ; frestr: A=len, X/Y=body ptr; frees the temp
            sta  p8b_vm.p8v_xslen
            stx  p8b_vm.p8v_xsptr
            sty  p8b_vm.p8v_xsptr+1
            pla
            sta  $01                                      ; restore ROM bank
            pla
            sta  $00                                      ; restore RAM bank
        }}
        ubyte k = 0                                       ; copy the result body off-heap (into xbuf) before
        while k < xslen {                                 ; mem_to_temp's getspa can reuse the freed space
            xbuf[k] = @(xsptr + k)
            k++
        }
        sstack[ssp] = bstr.mem_to_temp(&xbuf, xslen)      ; own copy on the GPC string heap
        if str_error()
            return
        ssp++
    }

    ; --- string helpers (BASIC-format descriptors; no VM-side collector) -----------------------
    ; There is no private heap or compactor anymore: bstr allocates via ROM getspa and the ROM
    ; garbage collector (reached inside getspa) walks BASIC's var/array/temp tables to reclaim and
    ; relocate. sstack entries are descriptor addresses into those rooted structures (or a scratch
    ; sdesc cell for off-heap literals/DATA), so nothing here needs to root or move strings.

    ; push a scratch descriptor over an OFF-HEAP null-terminated string (literal pool / DATA pool).
    ; The body never moves and the collector ignores it, so the scratch cell needs no rooting.
    sub push_cstr(uword cstr) {
        uword d = &sdesc + (ssp as uword) * 3
        @(d)   = strings.length(cstr)
        @(d+1) = lsb(cstr)
        @(d+2) = msb(cstr)
        sstack[ssp] = d
        ssp++
    }

    ; push an empty string ("" = a len-0 descriptor); for out-of-range / no-data results.
    sub push_empty() {
        uword d = &sdesc + (ssp as uword) * 3
        @(d) = 0
        sstack[ssp] = d
        ssp++
    }

    ; print the body of descriptor `d`, length-counted (BASIC bodies are NOT null-terminated).
    sub print_desc(uword d) {
        ubyte n = bstr.dlen(d)
        uword p = bstr.dptr(d)
        ubyte i = 0
        while i < n {
            emit_char(@(p + i))
            i++
        }
    }

    ; surface a pending string error (set by bstr) and clear it; returns true if run() must halt.
    sub str_error() -> bool {
        if bstr.err_toolong {
            bstr.err_toolong = false
            print_cstr(&str_long_msg)
            emit_char(13)
            halt = true
            return true
        }
        if bstr.err_complex {
            bstr.err_complex = false
            print_cstr(&formula_msg)
            emit_char(13)
            halt = true
            return true
        }
        return false
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

    ; (op_callfn dispatches FN_* straight to the ROM float jump table in hand-asm; the old Prog8
    ;  apply_fn -- and with it floats.sin/cos/tan/atan/ln/rnd + sgn/sqrt -- is no longer needed.)

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

    ; return the current DATA item's text and advance the cursor past it. Out of data reads as ""
    ; (which parses as 0 for a numeric READ) rather than raising a runtime error.
    sub data_next() -> uword {
        if dataptr >= datatop
            return &empty_c
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
        cbm.CHROUT(ch)                          ; to the X16 screen -- exactly what native BASIC does
        if host_echo
            @(EMU_CHROUT) = to_host(ch)         ; test-only mirror to the host console (see host_echo)
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
