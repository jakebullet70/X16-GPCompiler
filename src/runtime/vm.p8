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
%import bstr

vm {
    const uword EMU_CHROUT = $9fbb        ; x16emu: writing here echoes a char to the host console

    float[32] stack
    ubyte     sp
    ; Integer-first arithmetic (Phase 5): istack is a parallel 16-bit-word stack that SHARES `sp` with
    ; the float `stack`. A given slot holds EITHER a float (stack[sp]) or an int (istack[sp]); which one
    ; is live is fixed by the compiler's typed opcode stream, so no runtime tag is kept. Coercion opcodes
    ; (OP_ITOF/ITOF2/FTOI) move a value between the two representations at the same slot.
    word[32]  istack
    ; variable slots live in a slab (128 floats * 5 bytes = 640 > the 256-byte array cap),
    ; addressed as varsf + slot*5 via peekf/pokef
    uword     varsf = memory("vm_vars", 640, 0)
    ; integer (`%`) variable slots: their own namespace + storage, 128 words addressed as ivarsf + slot*2
    uword     ivarsf = memory("vm_ivars", 256, 0)
    word      last_printed        ; most recent PRINTI, truncated to an integer (for headless tests)
    ; When true, emit_char also mirrors each printed byte to the x16emu debug register $9FBB so the
    ; HEADLESS test harness can capture program output on the host console. A shipped program (visual /
    ; standalone / interactive) must NOT touch $9FBB -- native X16 BASIC never does -- so this defaults
    ; OFF and each main enables it only in its TESTBENCH build (vm.host_echo = TESTBENCH before vm.run).
    bool      host_echo = false

    uword[16] callstack          ; GOSUB return addresses
    ubyte     csp

    ubyte[8]  for_var            ; FOR loop frames (innermost on top)
    float[8]  for_limit
    float[8]  for_step
    word[8]   for_ilimit         ; integer FOR (FOR I%=..): 16-bit limit + step, and for_var holds an
    word[8]   for_istep          ; ivarsf slot. A frame uses EITHER the float or the int pair -- which is
                                 ; fixed by the opcode (OP_FORNEXT vs OP_IFORNEXT), so no per-frame tag.
    uword[8]  for_top            ; pcode offset of the loop body's first instruction
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
    uword      arrheap = memory("vm_arrheap", ARRHEAP_SIZE, 0)
    uword[32]  arr_base           ; byte offset of each array within arrheap
    uword[32]  arr_len            ; total element count of each array (0 = undimensioned/unusable)
    ubyte[32]  arr_ndims          ; number of dimensions of each array
    ; per-array dimension sizes, MAXDIMS words per array: arr_dims[slot*MAXDIMS + j] = size of dim j
    uword      arr_dims = memory("vm_arrdims", 32 * pcode.MAXDIMS * 2, 0)
    uword      arr_top            ; bump pointer into arrheap (bytes)

    ; --- string arrays (DIM A$(...)): real BASIC arrays built by bstr in the ARYTAB..STREND region;
    ;     each element is a 3-byte descriptor the ROM collector walks. The VM keeps only the per-array
    ;     dimension metadata (for row-major index math); bstr owns the element storage + rooting. ---
    const uword SARR_MAXELEM = 8192          ; cap on a string array's element count (dim_setup guard)
    uword[32]  sarr_len          ; total element count (0 = undimensioned/unusable)
    ubyte[32]  sarr_ndims
    uword      sarr_dims = memory("vm_sarrdims", 32 * pcode.MAXDIMS * 2, 0)

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
        ; place BASIC's string var table + heap in free RAM: bstr grows the var table UP from image_top
        ; and the string heap DOWN from a ceiling (KERNAL MEMTOP, or `cap` if that sits lower). Floor
        ; selection (heapfloor -> datatop -> progend):
        ;   * in-process (compiler resident): the host sets heapfloor = sys.progend(), i.e. ABOVE ALL of
        ;     the compiler's + runtime's slabs, so the heap owns the free RAM up to MEMTOP. (The Phase-5
        ;     banked-RAM move sent the compiler's name tables to banked RAM, so the old trick of reusing
        ;     the dead low-RAM name-table gap between datatop and varsf is gone -- progend is the room.)
        ;   * standalone: heapfloor is 0, so the heap floors at datatop (above the loaded P-code) and runs
        ;     to MEMTOP (varsf sits far below, so the `cap` is ignored).
        ;   * VM selftest (hand-built P-code): heapfloor and datatop both 0 -> fall back to progend.
        uword image_top = heapfloor
        if image_top == 0
            image_top = datatop
        if image_top == 0
            image_top = sys.progend()
        bstr.init(image_top, varsf)
        sys.memset(varsf, 640, 0)        ; all-zero bytes == float 0.0 (BASIC vars start at 0)
        sys.memset(ivarsf, 256, 0)       ; integer (`%`) vars start at 0 too
        arr_top = 0
        sys.memset(&arr_len, 64, 0)      ; 32 words -> 64 bytes: all numeric arrays undimensioned
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
            cmp  #89                       ; unknown opcode -> ignore (parity with when no-match)
            bcs  _next
            asl  a                         ; *2 for the word table (0..88 -> 0..176)
            tax
            jmp  (_optab,x)
_after:
            lda  p8b_vm.p8v_halt
            beq  _next
            jmp  _end
_optab:
            .word _t0, _t1, _t2, _t3, _t4, _t5, _t6, _t7, _t8, _t9, _t10, _t11, _t12, _t13, _t14, _t15, _t16, _t17, _t18, _t19, _t20, _t21, _t22, _t23, _t24, _t25, _t26, _t27, _t28, _t29, _t30, _t31, _t32, _t33, _t34, _t35, _t36, _t37, _t38, _t39, _t40, _t41, _t42, _t43, _t44, _t45, _t46, _t47, _t48, _t49, _t50, _t51, _t52, _t53, _t54, _t55, _t56, _t57, _t58, _t59, _t60, _t61, _t62, _t63, _t64, _t65, _t66, _t67, _t68, _t69, _t70, _t71, _t72, _t73, _t74, _t75, _t76, _t77, _t78, _t79, _t80, _t81, _t82, _t83, _t84, _t85, _t86, _t87, _t88
_t0:                                    ; OP_END -> leave the interpreter loop
            jmp  _end
_t1:                                    ; OP_JMP -> pc = target word at pcbase+pc
            jmp  _setpc
_t2:                                    ; OP_JZ -> sp--; if stack[sp]==0.0 take the branch
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
_t3:
            jsr  p8b_vm.p8s_op_pushi
            jmp  _after
_t4:
            jsr  p8b_vm.p8s_op_loadv
            jmp  _after
_t5:
            jsr  p8b_vm.p8s_op_storv
            jmp  _after
_t6:
            jsr  p8b_vm.p8s_op_add
            jmp  _after
_t7:
            jsr  p8b_vm.p8s_op_sub
            jmp  _after
_t8:
            jsr  p8b_vm.p8s_op_mul
            jmp  _after
_t9:
            jsr  p8b_vm.p8s_op_div
            jmp  _after
_t10:
            jsr  p8b_vm.p8s_op_neg
            jmp  _after
_t11:
            jsr  p8b_vm.p8s_op_cmpeq
            jmp  _after
_t12:
            jsr  p8b_vm.p8s_op_cmpne
            jmp  _after
_t13:
            jsr  p8b_vm.p8s_op_cmplt
            jmp  _after
_t14:
            jsr  p8b_vm.p8s_op_cmpgt
            jmp  _after
_t15:
            jsr  p8b_vm.p8s_op_cmple
            jmp  _after
_t16:
            jsr  p8b_vm.p8s_op_cmpge
            jmp  _after
_t17:
            jsr  p8b_vm.p8s_op_and
            jmp  _after
_t18:
            jsr  p8b_vm.p8s_op_or
            jmp  _after
_t19:
            jsr  p8b_vm.p8s_op_not
            jmp  _after
_t20:
            jsr  p8b_vm.p8s_op_printi
            jmp  _after
_t21:
            jsr  p8b_vm.p8s_op_prints
            jmp  _after
_t22:
            jsr  p8b_vm.p8s_op_newline
            jmp  _after
_t23:
            jsr  p8b_vm.p8s_op_gosub
            jmp  _after
_t24:
            jsr  p8b_vm.p8s_op_ret
            jmp  _after
_t25:
            jsr  p8b_vm.p8s_op_forpush
            jmp  _after
_t26:
            jsr  p8b_vm.p8s_op_fornext
            jmp  _after
_t27:
            jsr  p8b_vm.p8s_op_pushs
            jmp  _after
_t28:
            jsr  p8b_vm.p8s_op_loads
            jmp  _after
_t29:
            jsr  p8b_vm.p8s_op_stors
            jmp  _after
_t30:
            jsr  p8b_vm.p8s_op_concat
            jmp  _after
_t31:
            jsr  p8b_vm.p8s_op_poke
            jmp  _after
_t32:
            jsr  p8b_vm.p8s_op_peek
            jmp  _after
_t33:
            jsr  p8b_vm.p8s_op_sys
            jmp  _after
_t34:
            jsr  p8b_vm.p8s_op_dim
            jmp  _after
_t35:
            jsr  p8b_vm.p8s_op_aload
            jmp  _after
_t36:
            jsr  p8b_vm.p8s_op_astore
            jmp  _after
_t37:
            jsr  p8b_vm.p8s_op_inputv
            jmp  _after
_t38:
            jsr  p8b_vm.p8s_op_inputs
            jmp  _after
_t39:
            jsr  p8b_vm.p8s_op_pushf
            jmp  _after
_t40:
            jsr  p8b_vm.p8s_op_callfn
            jmp  _after
_t41:
            jsr  p8b_vm.p8s_op_strnum
            jmp  _after
_t42:
            jsr  p8b_vm.p8s_op_numstr
            jmp  _after
_t43:
            jsr  p8b_vm.p8s_op_lefts
            jmp  _after
_t44:
            jsr  p8b_vm.p8s_op_rights
            jmp  _after
_t45:
            jsr  p8b_vm.p8s_op_mids
            jmp  _after
_t46:
            jsr  p8b_vm.p8s_op_read
            jmp  _after
_t47:
            jsr  p8b_vm.p8s_op_reads
            jmp  _after
_t48:
            jsr  p8b_vm.p8s_op_restore
            jmp  _after
_t49:
            jsr  p8b_vm.p8s_op_sdim
            jmp  _after
_t50:
            jsr  p8b_vm.p8s_op_saload
            jmp  _after
_t51:
            jsr  p8b_vm.p8s_op_sastore
            jmp  _after
_t52:
            jsr  p8b_vm.p8s_op_rdnum
            jmp  _after
_t53:
            jsr  p8b_vm.p8s_op_rdstr
            jmp  _after
_t54:
            jsr  p8b_vm.p8s_op_scmp
            jmp  _after
_t55:
            jsr  p8b_vm.p8s_op_open
            jmp  _after
_t56:
            jsr  p8b_vm.p8s_op_close
            jmp  _after
_t57:
            jsr  p8b_vm.p8s_op_getch
            jmp  _after
_t58:
            jsr  p8b_vm.p8s_op_status
            jmp  _after
_t59:
            jsr  p8b_vm.p8s_op_chkout
            jmp  _after
_t60:
            jsr  p8b_vm.p8s_op_chkin
            jmp  _after
_t61:
            jsr  p8b_vm.p8s_op_clrch
            jmp  _after
_t62:
            jsr  p8b_vm.p8s_op_pow
            jmp  _after
_t63:
            jsr  p8b_vm.p8s_op_wait
            jmp  _after
_t64:
            jsr  p8b_vm.p8s_op_passthru
            jmp  _after
_t65:
            jsr  p8b_vm.p8s_op_callx
            jmp  _after
_t66:
            jsr  p8b_vm.p8s_op_callxs
            jmp  _after
_t67:
            jsr  p8b_vm.p8s_op_ipushi
            jmp  _after
_t68:
            jsr  p8b_vm.p8s_op_iloadv
            jmp  _after
_t69:
            jsr  p8b_vm.p8s_op_istorv
            jmp  _after
_t70:
            jsr  p8b_vm.p8s_op_iadd
            jmp  _after
_t71:
            jsr  p8b_vm.p8s_op_isub
            jmp  _after
_t72:
            jsr  p8b_vm.p8s_op_imul
            jmp  _after
_t73:
            jsr  p8b_vm.p8s_op_ineg
            jmp  _after
_t74:
            jsr  p8b_vm.p8s_op_itof
            jmp  _after
_t75:
            jsr  p8b_vm.p8s_op_itof2
            jmp  _after
_t76:
            jsr  p8b_vm.p8s_op_ftoi
            jmp  _after
_t77:
            jsr  p8b_vm.p8s_op_icmpeq
            jmp  _after
_t78:
            jsr  p8b_vm.p8s_op_icmpne
            jmp  _after
_t79:
            jsr  p8b_vm.p8s_op_icmplt
            jmp  _after
_t80:
            jsr  p8b_vm.p8s_op_icmpgt
            jmp  _after
_t81:
            jsr  p8b_vm.p8s_op_icmple
            jmp  _after
_t82:
            jsr  p8b_vm.p8s_op_icmpge
            jmp  _after
_t83:
            jsr  p8b_vm.p8s_op_ijz
            jmp  _after
_t84:
            jsr  p8b_vm.p8s_op_iand
            jmp  _after
_t85:
            jsr  p8b_vm.p8s_op_ior
            jmp  _after
_t86:
            jsr  p8b_vm.p8s_op_inot
            jmp  _after
_t87:
            jsr  p8b_vm.p8s_op_iforpush
            jmp  _after
_t88:
            jsr  p8b_vm.p8s_op_ifornext
            jmp  _after
_end:
        }}
    }

    ; OP_END / OP_JMP / OP_JZ (opcodes 0/1/2) are handled inline in run()'s asm dispatch
    ; (_t0/_t1/_t2): END exits the loop, JMP/JZ set pc directly, JZ tests the MFLPT exponent
    ; byte instead of a ROM float-compare. No Prog8 handler subs are needed for them.
    sub op_pushi() {
                    stack[sp] = mkword(@(pcbase + pc + 1), @(pcbase + pc)) as float
                    pc += 2
                    sp++
                }
    sub op_loadv() {
                    stack[sp] = peekf(varsf + (@(pcbase + pc) as uword) * 5)
                    pc += 2
                    sp++
                }
    sub op_storv() {
                    sp--
                    pokef(varsf + (@(pcbase + pc) as uword) * 5, stack[sp])
                    pc += 2
                }
    sub op_add() {
                    sp--
                    stack[sp-1] += stack[sp]
                }
    sub op_sub() {
                    sp--
                    stack[sp-1] -= stack[sp]
                }
    sub op_mul() {
                    sp--
                    stack[sp-1] *= stack[sp]
                }
    sub op_div() {
                    sp--
                    stack[sp-1] /= stack[sp]
                }
    sub op_neg() {
                    stack[sp-1] = -stack[sp-1]
                }
    sub op_cmpeq() {
                    sp--
                    stack[sp-1] = bool_to_float(stack[sp-1] == stack[sp])
                }
    sub op_cmpne() {
                    sp--
                    stack[sp-1] = bool_to_float(stack[sp-1] != stack[sp])
                }
    sub op_cmplt() {
                    sp--
                    stack[sp-1] = bool_to_float(stack[sp-1] < stack[sp])
                }
    sub op_cmpgt() {
                    sp--
                    stack[sp-1] = bool_to_float(stack[sp-1] > stack[sp])
                }
    sub op_cmple() {
                    sp--
                    stack[sp-1] = bool_to_float(stack[sp-1] <= stack[sp])
                }
    sub op_cmpge() {
                    sp--
                    stack[sp-1] = bool_to_float(stack[sp-1] >= stack[sp])
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
    sub op_ipushi() {
                    istack[sp] = mkword(@(pcbase + pc + 1), @(pcbase + pc)) as word
                    pc += 2
                    sp++
                }
    sub op_iloadv() {
                    istack[sp] = peekw(ivarsf + (@(pcbase + pc) as uword) * 2) as word
                    pc += 2
                    sp++
                }
    sub op_istorv() {
                    sp--
                    pokew(ivarsf + (@(pcbase + pc) as uword) * 2, istack[sp] as uword)
                    pc += 2
                }
    sub op_iadd() {
                    sp--
                    istack[sp-1] += istack[sp]
                }
    sub op_isub() {
                    sp--
                    istack[sp-1] -= istack[sp]
                }
    sub op_imul() {
                    sp--
                    istack[sp-1] *= istack[sp]
                }
    sub op_ineg() {
                    istack[sp-1] = -istack[sp-1]
                }
    sub op_itof() {                       ; coerce the TOP cell int -> float
                    stack[sp-1] = istack[sp-1] as float
                }
    sub op_itof2() {                      ; coerce the SECOND-from-top cell int -> float (mixed a<op>b)
                    stack[sp-2] = istack[sp-2] as float
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
    sub op_icmpeq() {
                    sp--
                    if istack[sp-1] == istack[sp]  istack[sp-1] = -1  else  istack[sp-1] = 0
                }
    sub op_icmpne() {
                    sp--
                    if istack[sp-1] != istack[sp]  istack[sp-1] = -1  else  istack[sp-1] = 0
                }
    sub op_icmplt() {
                    sp--
                    if istack[sp-1] < istack[sp]  istack[sp-1] = -1  else  istack[sp-1] = 0
                }
    sub op_icmpgt() {
                    sp--
                    if istack[sp-1] > istack[sp]  istack[sp-1] = -1  else  istack[sp-1] = 0
                }
    sub op_icmple() {
                    sp--
                    if istack[sp-1] <= istack[sp]  istack[sp-1] = -1  else  istack[sp-1] = 0
                }
    sub op_icmpge() {
                    sp--
                    if istack[sp-1] >= istack[sp]  istack[sp-1] = -1  else  istack[sp-1] = 0
                }
    sub op_ijz() {                        ; pop int; branch to the operand offset if it is zero
                    sp--
                    if istack[sp] == 0
                        pc = mkword(@(pcbase + pc + 1), @(pcbase + pc))   ; take the branch (absolute offset)
                    else
                        pc += 2                                          ; fall through, skip the 2-byte target
                }
    sub op_iand() {                       ; bitwise AND of the two 16-bit ints (== logical, truth is -1/0)
                    sp--
                    istack[sp-1] = (istack[sp-1] as uword & istack[sp] as uword) as word
                }
    sub op_ior() {                        ; bitwise OR
                    sp--
                    istack[sp-1] = (istack[sp-1] as uword | istack[sp] as uword) as word
                }
    sub op_inot() {                       ; bitwise complement (NOT x == -(x+1))
                    istack[sp-1] = (~ (istack[sp-1] as uword)) as word
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
    sub op_prints() {
                    ssp--
                    uword psd = sstack[ssp]
                    print_desc(psd)                       ; length-counted (bodies aren't null-terminated)
                    bstr.free_temp_if_top(psd)            ; a printed temp is done -> reclaim its slot
                }
    sub op_newline() {
                    emit_char(13)                         ; CR to screen, LF to host console
                }
    sub op_gosub() {
                    uword target = mkword(@(pcbase + pc + 1), @(pcbase + pc))
                    pc += 2
                    callstack[csp] = pc          ; return here
                    csp++
                    pc = target
                }
    sub op_ret() {
                    csp--
                    pc = callstack[csp]
                }
    sub op_forpush() {
                    ubyte slot = @(pcbase + pc)    ; slot < 128, fits in a byte
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
    sub op_fornext() {
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
    sub op_iforpush() {                   ; FOR I%=start TO limit STEP step -- open an integer loop frame
                    ubyte slot = @(pcbase + pc)    ; ivarsf slot (< 128, fits a byte)
                    pc += 2
                    sp--
                    word istepv = istack[sp]     ; step was pushed last
                    sp--
                    for_var[forsp] = slot
                    for_ilimit[forsp] = istack[sp]  ; then limit
                    for_istep[forsp] = istepv
                    for_top[forsp] = pc          ; body starts right after this opcode
                    forsp++
                }
    sub op_ifornext() {                   ; step the innermost integer FOR (16-bit, wraps like other % ops)
                    ubyte top = forsp - 1
                    uword vaddr = ivarsf + (for_var[top] as uword) * 2
                    word nv = (peekw(vaddr) as word) + for_istep[top]
                    pokew(vaddr, nv as uword)
                    bool cont
                    if for_istep[top] >= 0
                        cont = nv <= for_ilimit[top]
                    else
                        cont = nv >= for_ilimit[top]
                    if cont
                        pc = for_top[top]
                    else
                        forsp--                  ; loop finished; pop the frame
                }
    sub op_pushs() {
                    ; operand is an offset into the literal pool; litbase makes it absolute. Literal
                    ; bodies are off-heap (program text) -> a scratch descriptor over them, which the
                    ; collector ignores (never rooted, never moved), so the same P-code works both
                    ; in-process and in a standalone .PRG.
                    push_cstr(litbase + mkword(@(pcbase + pc + 1), @(pcbase + pc)))
                    pc += 2
                }
    sub op_loads() {
                    sstack[ssp] = bstr.vdesc(@(pcbase + pc))    ; push the variable's descriptor address
                    ssp++
                    pc += 2
                }
    sub op_stors() {
                    ssp--
                    bstr.store_var(@(pcbase + pc), sstack[ssp]) ; heap-copy / steal-temp assignment
                    pc += 2
                }
    sub op_concat() {
                    ; result = a + b, produced as a BASIC temp. concat_temp allocates the result body
                    ; while a/b are still rooted (a GC during getspa relocates them), copies, frees any
                    ; operand temps top-first, then pushes the result temp. A total > 255 sets
                    ; err_toolong -> ?STRING TOO LONG (checked by str_error).
                    uword b = sstack[ssp-1]
                    uword a = sstack[ssp-2]
                    uword cres = bstr.concat_temp(a, b)
                    if str_error()
                        return
                    ssp -= 2
                    sstack[ssp] = cres
                    ssp++
                }
    sub op_poke() {
                    sp--
                    ubyte v = lsb(stack[sp] as uword)    ; value (low byte)
                    sp--
                    @(stack[sp] as uword) = v            ; ...into the target address
                }
    sub op_peek() {
                    stack[sp-1] = @(stack[sp-1] as uword) as float   ; addr -> byte 0..255
                }
    sub op_sys() {
                    sp--
                    sys_target = stack[sp] as uword
                    sys_call()                            ; JSR to sys_target, returns here
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
    sub op_aload() {                      ; A(i[,j..]): push the element (0 if out of range)
                    ubyte alslot = @(pcbase + pc)
                    ubyte alnd = @(pcbase + pc + 2)
                    pc += 3
                    uword aloff = index_of(arr_dims, alslot, alnd, sp - alnd, arr_len[alslot])
                    sp -= alnd
                    if aloff != $ffff
                        stack[sp] = peekf(arrheap + arr_base[alslot] + aloff * 5)
                    else
                        stack[sp] = 0.0
                    sp++
                }
    sub op_astore() {                     ; A(i[,j..])=v: store into the element (dropped if out of range)
                    ubyte asslot = @(pcbase + pc)
                    ubyte asnd = @(pcbase + pc + 2)
                    pc += 3
                    sp--
                    float asval = stack[sp]                  ; value was pushed after the subscripts
                    uword asoff = index_of(arr_dims, asslot, asnd, sp - asnd, arr_len[asslot])
                    sp -= asnd
                    if asoff != $ffff
                        pokef(arrheap + arr_base[asslot] + asoff * 5, asval)
                }
    sub op_inputv() {
                    ubyte ivslot = @(pcbase + pc)
                    pc += 2
                    read_line()
                    pokef(varsf + (ivslot as uword) * 5, floats.parse(&inbuf))
                }
    sub op_inputs() {
                    ubyte isslot = @(pcbase + pc)
                    pc += 2
                    read_line()
                    bstr.var_from_mem(isslot, &inbuf, strings.length(&inbuf))   ; heap-copy into the var
                }
    sub op_pushf() {
                    stack[sp] = peekf(pcbase + pc)         ; 5-byte float immediate
                    pc += 5
                    sp++
                }
    sub op_callfn() {
                    ubyte fnid = @(pcbase + pc)
                    pc++
                    stack[sp-1] = apply_fn(fnid, stack[sp-1])
                }
    sub op_strnum() {                     ; LEN/ASC/VAL: pop string, push number
                    ubyte snid = @(pcbase + pc)
                    pc++
                    ssp--
                    uword snd = sstack[ssp]
                    when snid {
                        pcode.SN_LEN -> stack[sp] = bstr.dlen(snd) as float
                        pcode.SN_ASC -> {
                            if bstr.dlen(snd) == 0
                                stack[sp] = 0.0                          ; ASC("") -> 0 (as the ported VM did)
                            else
                                stack[sp] = @(bstr.dptr(snd)) as float    ; PETSCII of the first char
                        }
                        pcode.SN_VAL -> stack[sp] = floats.parse(bstr.to_cbuf(snd))   ; parse needs a null
                    }
                    sp++
                    bstr.free_temp_if_top(snd)               ; the consumed string temp is done
                }
    sub op_numstr() {                     ; CHR$/STR$: pop number, push a string temp
                    ubyte nsid = @(pcbase + pc)
                    pc++
                    sp--
                    uword nsres = 0
                    when nsid {
                        pcode.NS_CHR -> nsres = bstr.chr_temp(lsb(stack[sp] as uword))   ; one PETSCII char
                        pcode.NS_STR -> {
                            uword nssrc = floats.tostr(stack[sp])       ; ROM buffer, off-heap/stable
                            if @(nssrc) == ' '
                                nssrc++                                 ; match PRINT: drop FOUT's lead space
                            nsres = bstr.mem_to_temp(nssrc, strings.length(nssrc))
                        }
                    }
                    if str_error()
                        return
                    sstack[ssp] = nsres
                    ssp++
                }
    sub op_lefts() {                      ; LEFT$(s,n): first n chars
                    sp--
                    ubyte lfn = clamp_count(stack[sp])
                    ssp--
                    uword lfsrc = sstack[ssp]
                    uword lfres = bstr.substr_temp(lfsrc, 0, lfn)   ; frees src temp, pushes result temp
                    if str_error()
                        return
                    sstack[ssp] = lfres
                    ssp++
                }
    sub op_rights() {                     ; RIGHT$(s,n): last n chars
                    sp--
                    ubyte rtn = clamp_count(stack[sp])
                    ssp--
                    uword rtsrc = sstack[ssp]
                    ubyte rtlen = bstr.dlen(rtsrc)
                    ubyte rtstart = 0
                    if rtn < rtlen
                        rtstart = rtlen - rtn
                    uword rtres = bstr.substr_temp(rtsrc, rtstart, rtn)
                    if str_error()
                        return
                    sstack[ssp] = rtres
                    ssp++
                }
    sub op_mids() {                       ; MID$(s,start,len): substring, start 1-based
                    sp--
                    ubyte mdlen = clamp_count(stack[sp])
                    sp--
                    word mdstart = stack[sp] as word
                    ssp--
                    uword mdsrc = sstack[ssp]
                    ubyte mds0 = 0
                    if mdstart > 256
                        mds0 = 255                                      ; past end -> empty
                    else if mdstart >= 1
                        mds0 = (mdstart - 1) as ubyte
                    uword mdres = bstr.substr_temp(mdsrc, mds0, mdlen)
                    if str_error()
                        return
                    sstack[ssp] = mdres
                    ssp++
                }
    sub op_read() {                       ; READ into a numeric var: parse the item
                    ubyte rdslot = @(pcbase + pc)
                    pc += 2
                    pokef(varsf + (rdslot as uword) * 5, floats.parse(data_next()))
                }
    sub op_reads() {                      ; READ into a string var: heap-copy the item
                    ubyte rsslot = @(pcbase + pc)
                    pc += 2
                    uword rssrc = data_next()            ; DATA-pool text (off-heap, stable)
                    bstr.var_from_mem(rsslot, rssrc, strings.length(rssrc))
                }
    sub op_restore() {                    ; rewind the DATA cursor to the first item
                    dataptr = database
                }
    sub op_sdim() {                       ; DIM A$(...): allocate a BASIC string array
                    ubyte sdslot = @(pcbase + pc)
                    ubyte sdnd = @(pcbase + pc + 2)
                    pc += 3
                    uword sdtot = dim_setup(sarr_dims, sdslot, sdnd, SARR_MAXELEM)
                    if sdtot != 0 and bstr.sarr_alloc(sdslot, sdtot, sdnd) {
                        sarr_len[sdslot] = sdtot
                        sarr_ndims[sdslot] = sdnd
                    } else {
                        sarr_len[sdslot] = 0                  ; too big / out of memory -> unusable
                    }
                }
    sub op_saload() {                     ; A$(i[,j..]): push the element's descriptor ("" if out of range)
                    ubyte slslot = @(pcbase + pc)
                    ubyte slnd = @(pcbase + pc + 2)
                    pc += 3
                    uword sloff = index_of(sarr_dims, slslot, slnd, sp - slnd, sarr_len[slslot])
                    sp -= slnd
                    if sloff != $ffff {
                        sstack[ssp] = bstr.sarr_desc(slslot, sloff)   ; a live, self-relocating GC root
                        ssp++
                    } else {
                        push_empty()                                  ; out of range reads as ""
                    }
                }
    sub op_sastore() {                    ; A$(i[,j..])=v$: store the element (dropped if out of range)
                    ubyte ssslot = @(pcbase + pc)
                    ubyte ssnd = @(pcbase + pc + 2)
                    pc += 3
                    ssp--
                    uword ssval = sstack[ssp]                ; the string value, pushed after the subscripts
                    uword ssoff = index_of(sarr_dims, ssslot, ssnd, sp - ssnd, sarr_len[ssslot])
                    sp -= ssnd
                    if ssoff != $ffff
                        bstr.store_desc(bstr.sarr_desc(ssslot, ssoff), ssval)   ; heap-copy / steal-temp
                    else
                        bstr.free_temp_if_top(ssval)         ; store dropped, but still free a temp value
                }
    sub op_rdnum() {                      ; READ into an array element: push the item as a number
                    stack[sp] = floats.parse(data_next())
                    sp++
                }
    sub op_rdstr() {                      ; READ into a string-array element: push the item text
                    push_cstr(data_next())               ; off-heap DATA text -> scratch descriptor
                }
    sub op_scmp() {                       ; compare two strings -> numeric truth (-1/0)
                    ubyte scid = @(pcbase + pc)
                    pc++
                    ssp--
                    uword scb = sstack[ssp]              ; right operand (pushed last)
                    ssp--
                    uword sca = sstack[ssp]              ; left operand
                    byte rel = bstr.bcompare(sca, scb)   ; -1 if a<b, 0 if equal, 1 if a>b (length-counted)
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
                    bstr.free_temp_if_top(scb)           ; free operand temps top-first
                    bstr.free_temp_if_top(sca)
                }
    sub op_open() {                        ; OPEN lfn,dev,sa,"name"
                    sp--
                    ubyte o_sa  = lsb(stack[sp] as uword)
                    sp--
                    ubyte o_dev = lsb(stack[sp] as uword)
                    sp--
                    ubyte o_lfn = lsb(stack[sp] as uword)
                    ssp--
                    uword o_name = sstack[ssp]
                    cbm.SETNAM(bstr.dlen(o_name), bstr.dptr(o_name))
                    cbm.SETLFS(o_lfn, o_dev, o_sa)
                    void cbm.OPEN()
                    bstr.free_temp_if_top(o_name)
                }
    sub op_close() {                       ; CLOSE lfn
                    sp--
                    cbm.CLOSE(lsb(stack[sp] as uword))
                }
    sub op_getch() {                       ; GET#lfn,v$ : one byte -> a 0/1-char string
                    sp--
                    void cbm.CHKIN(lsb(stack[sp] as uword))
                    ubyte g_ch = cbm.CHRIN()
                    cbm.CLRCHN()
                    if g_ch == 0 {
                        push_empty()                      ; no byte available -> ""
                    } else {
                        uword g_res = bstr.chr_temp(g_ch) ; a 1-char temp
                        if str_error()
                            return
                        sstack[ssp] = g_res
                        ssp++
                    }
                }
    sub op_status() {                      ; ST : the KERNAL I/O status word
                    stack[sp] = cbm.READST() as float
                    sp++
                }
    sub op_chkout() {                      ; PRINT#lfn : redirect the following PRINTs
                    sp--
                    cbm.CHKOUT(lsb(stack[sp] as uword))
                }
    sub op_chkin() {                       ; INPUT#lfn : redirect the following INPUT
                    sp--
                    void cbm.CHKIN(lsb(stack[sp] as uword))
                }
    sub op_clrch() {                       ; end a PRINT#/INPUT#, restore default I/O
                    cbm.CLRCHN()
                }
    sub op_pow() {                    ; a ^ b  (float power via ROM's FPWR)
                    sp--
                    stack[sp-1] = floats.pow(stack[sp-1], stack[sp])
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
