; pcode_format.p8 -- the P-code instruction-set contract.
;
; This is the single load-bearing definition of the byte encoding, imported by
; BOTH the compiler's emitter and the runtime VM so the two can never drift.
; Encoding is byte-aligned: [opcode:1][inline operands, fixed width per opcode].
; Evaluation is stack based; cells are 16-bit signed words for the integer
; milestones (M0-M6).
;
; Operand-width column below is authoritative. "imm16" = 2 bytes, little-endian.

pcode {
    ; --- control ---
    const ubyte OP_END    = 0    ; ()          halt the VM
    const ubyte OP_JMP    = 1    ; (imm16 pc)  unconditional jump to pcode offset
    const ubyte OP_JZ     = 2    ; (imm16 pc)  pop; jump if zero

    ; --- stack / values ---
    const ubyte OP_PUSHI  = 3    ; (imm16 v)   push immediate word
    const ubyte OP_LOADV  = 4    ; (imm16 slot)push value of variable slot
    const ubyte OP_STORV  = 5    ; (imm16 slot)pop; store into variable slot

    ; --- arithmetic (pop 2, push result) ---
    const ubyte OP_ADD    = 6    ; ()
    const ubyte OP_SUB    = 7    ; ()
    const ubyte OP_MUL    = 8    ; ()
    const ubyte OP_DIV    = 9    ; ()
    const ubyte OP_NEG    = 10   ; ()          unary negate (pop 1, push 1)

    ; --- comparison (pop 2, push 0 / -1) ---
    const ubyte OP_CMPEQ  = 11   ; ()
    const ubyte OP_CMPNE  = 12   ; ()
    const ubyte OP_CMPLT  = 13   ; ()
    const ubyte OP_CMPGT  = 14   ; ()
    const ubyte OP_CMPLE  = 15   ; ()
    const ubyte OP_CMPGE  = 16   ; ()

    ; --- logical: CBM's AND/OR/NOT are BITWISE on the 16-bit integer value, which doubles as logical
    ;     because BASIC truth is true=-1 ($FFFF), false=0. Operands truncate float->word first. ---
    const ubyte OP_AND    = 17   ; ()          pop b,a; push (a & b)
    const ubyte OP_OR     = 18   ; ()          pop b,a; push (a | b)
    const ubyte OP_NOT    = 19   ; ()          unary: pop a; push ~a  (NOT x == -(x+1))

    ; --- output (items print with no trailing newline; PRINT emits NEWLINE itself) ---
    const ubyte OP_PRINTI = 20   ; ()          pop int stack; print word as decimal
    const ubyte OP_PRINTS = 21   ; ()          pop string stack; print the string
    const ubyte OP_NEWLINE= 22   ; ()          print a newline

    ; --- subroutines (VM keeps a separate call stack) ---
    const ubyte OP_GOSUB  = 23   ; (imm16 pc)  push return address, jump to pc
    const ubyte OP_RET    = 24   ; ()          pop return address, jump back

    ; --- FOR/NEXT (VM keeps a stack of loop frames) ---
    const ubyte OP_FORPUSH= 25   ; (imm16 slot) pop step then limit; open a FOR frame
    const ubyte OP_FORNEXT= 26   ; ()          step innermost FOR; loop to top or pop frame

    ; --- strings (separate string-value stack + heap in the VM) ---
    const ubyte OP_PUSHS  = 27   ; (imm16 off)  push litbase+off (offset into the literal pool)
    const ubyte OP_LOADS  = 28   ; (imm16 slot) push string variable's pointer
    const ubyte OP_STORS  = 29   ; (imm16 slot) pop string stack; store into string variable
    const ubyte OP_CONCAT = 30   ; ()          pop b, a; push heap-allocated a+b

    ; --- machine access (M8): direct memory + call, the workhorse "unknown statement" ops ---
    const ubyte OP_POKE   = 31   ; ()          pop val, addr; write low byte of val to addr
    const ubyte OP_PEEK   = 32   ; ()          pop addr; push the byte at addr (0..255)
    const ubyte OP_SYS    = 33   ; ()          pop addr; JSR to it (machine-language call)

    ; --- arrays (N-D numeric): DIM allocates from the VM array heap; index is a slot. The `ndims`
    ;     byte says how many subscripts were pushed; the element offset is row-major (see below) ---
    const ubyte OP_DIM    = 34   ; (imm16 slot)(ubyte nd) pop nd max-indices; allocate the array
    const ubyte OP_ALOAD  = 35   ; (imm16 slot)(ubyte nd) pop nd subscripts; push element (0 if out of range)
    const ubyte OP_ASTORE = 36   ; (imm16 slot)(ubyte nd) pop value then nd subscripts; store the element

    ; --- INPUT: read a line from the keyboard, parse, store into a variable slot ---
    const ubyte OP_INPUTV = 37   ; (imm16 slot) read a line, parse as number, store in numeric var
    const ubyte OP_INPUTS = 38   ; (imm16 slot) read a line, store as-is in string var (heap copy)

    ; --- floats: numeric cells are 5-byte ROM floats; OP_PUSHI still pushes an integer literal ---
    const ubyte OP_PUSHF  = 39   ; (float5) push a 5-byte float immediate

    ; --- built-in functions: replace top-of-stack x with fn(x); fn selected by the id byte ---
    const ubyte OP_CALLFN = 40   ; (ubyte fn) apply built-in function `fn` (see FN_* below)

    ; --- string functions: these cross the numeric<->string type boundary, moving a value
    ;     between the VM's numeric stack and its separate string stack ---
    const ubyte OP_STRNUM = 41   ; (ubyte id) pop a string, push a number  -- LEN/ASC/VAL
    const ubyte OP_NUMSTR = 42   ; (ubyte id) pop a number, push a string  -- CHR$/STR$
    const ubyte OP_LEFTS  = 43   ; ()  pop count, pop string; push the leftmost `count` chars
    const ubyte OP_RIGHTS = 44   ; ()  pop count, pop string; push the rightmost `count` chars
    const ubyte OP_MIDS   = 45   ; ()  pop len, pop start (1-based), pop string; push the substring

    ; --- READ / DATA / RESTORE: DATA items are collected (in line order) into a data pool of
    ;     null-terminated text; a runtime cursor walks it, READ parsing each item on demand ---
    const ubyte OP_READ    = 46  ; (imm16 slot) read next DATA item, parse as a number -> numeric var
    const ubyte OP_READS   = 47  ; (imm16 slot) read next DATA item text -> string var (heap copy)
    const ubyte OP_RESTORE = 48  ; ()           reset the DATA cursor to the first item
    ; the push-variants let READ target an array element: subscripts, then RD*, then A*STORE (below)
    const ubyte OP_RDNUM   = 52  ; ()           read next DATA item, parse as a number, push it
    const ubyte OP_RDSTR   = 53  ; ()           read next DATA item, push its text (points into the pool)

    ; --- string comparison: pop two strings, compare lexicographically, push a numeric truth value.
    ;     Lets IF A$="YES" / A$<B$ etc. cross from the string stack back to the numeric stack. ---
    const ubyte OP_SCMP    = 54  ; (ubyte id) pop b,a (strings); push (a <id> b) as -1/0 (id = SC_* below)

    ; --- channel / file I/O (M9): thin wrappers over the KERNAL device API (SETLFS/SETNAM/OPEN/CHKIN/
    ;     CHKOUT/CHRIN/CHROUT/CLRCHN/CLOSE/READST). A compiled program calls the KERNAL directly (it is
    ;     always present in ROM), so these all work standalone too. ---
    const ubyte OP_OPEN    = 55  ; ()  pop sa,dev,lfn (numeric) + name (string); SETNAM/SETLFS/OPEN
    const ubyte OP_CLOSE   = 56  ; ()  pop lfn (numeric); CLOSE
    const ubyte OP_GETCH   = 57  ; ()  pop lfn (numeric); CHKIN/CHRIN/CLRCHN; push a 0- or 1-char string (GET#)
    const ubyte OP_STATUS  = 58  ; ()  push the KERNAL I/O status (READST) as a number -- BASIC's ST
    const ubyte OP_CHKOUT  = 59  ; ()  pop lfn (numeric); CHKOUT -- redirect the next PRINTs to a channel (PRINT#)
    const ubyte OP_CHKIN   = 60  ; ()  pop lfn (numeric); CHKIN  -- redirect the next INPUT to a channel (INPUT#)
    const ubyte OP_CLRCH   = 61  ; ()  CLRCHN -- restore default I/O, ending a PRINT#/INPUT#

    ; --- string arrays (N-D): a separate namespace + heap from numeric arrays; each element is a
    ;     string pointer (into the string heap / "" when unset), so loads/stores use the string stack ---
    const ubyte OP_SDIM    = 49  ; (imm16 slot)(ubyte nd) pop nd max-indices; allocate a string array
    const ubyte OP_SALOAD  = 50  ; (imm16 slot)(ubyte nd) pop nd subscripts; push element string ("" if out of range)
    const ubyte OP_SASTORE = 51  ; (imm16 slot)(ubyte nd) pop string value then nd subscripts; store the element

    ; --- extended arithmetic + control (phase 2 "core-language gaps") ---
    const ubyte OP_POW     = 62  ; ()          pop b,a; push a ** b  (float power operator ^)
    const ubyte OP_WAIT    = 63  ; ()          pop xor,mask,addr; spin until (peek(addr) ^ xor) & mask != 0
    ; (STOP reuses OP_END; ON..GOTO/GOSUB desugars to LOADV/PUSHI/CMPEQ/JZ + JMP/GOSUB; DEF FN/FN
    ;  reuse OP_GOSUB/OP_RET with a compiler-side function table -- no new opcodes needed for those.)

    ; --- command pass-through (Phase 3): hand a tokenized BASIC statement to the ROM interpreter.
    ;     The runtime copies the bytes into a low-RAM buffer (prefixed with a ':' the ROM CHRGET skips,
    ;     suffixed with $00), points TXTPTR at it, pages in BASIC ROM (bank 4), and JSRs `gone3`; the
    ;     leaf/extension handler (VERA/sound/graphics/disk -- the $CE-escape keywords) runs and RTSes
    ;     back. This gives a compiled program all of X16 BASIC's statements GPC doesn't compile itself. ---
    const ubyte OP_PASSTHRU = 64 ; (ubyte len)(len tokenized bytes) run the statement via ROM BASIC

    ; --- X16 expression functions (VPEEK/JOY/MX/...): the expression-context companion to OP_PASSTHRU.
    ;     The compiler evaluates each argument itself (GPC's own vars aren't in BASIC's table, so a
    ;     whole sub-expression can't just be handed to frmevl) and leaves the computed numeric values on
    ;     the stack. At run time OP_CALLX pops them, formats them as ASCII decimal into a synthesized
    ;     tokenized call [$CE][subtok]("("arg0","arg1...")"), points TXTPTR at it, pages in BASIC ROM and
    ;     JSRs frmevl -- the ROM function handler runs and returns a numeric result in FAC1, which MOVMF
    ;     packs back onto the stack. `subtok` is the $CE escape sub-token ($D0=VPEEK..$DE=MOD); `nargs`
    ;     is how many argument values were pushed (0 for the no-paren mouse functions MX/MY/MB/MWHEEL). ---
    const ubyte OP_CALLX = 65    ; (ubyte subtok)(ubyte nargs) call an X16 ROM function via frmevl

    ; --- string-returning X16 functions (HEX$/BIN$): like OP_CALLX but frmevl leaves a STRING result.
    ;     Same synthesized-call setup (numeric args formatted into the tokenized call); afterwards the
    ;     runtime calls the ROM's `frestr` to fetch the result descriptor (len + heap body) and free the
    ;     BASIC temp, copies the body off-heap, and adopts it into a GPC string temp (bstr.mem_to_temp),
    ;     pushing it on the string stack. `subtok` is the $CE sub-token ($D5=HEX$, $D6=BIN$). ---
    const ubyte OP_CALLXS = 66   ; (ubyte subtok)(ubyte nargs) call a string-returning X16 ROM function

    ; --- integer-first arithmetic (Phase 5): Blitz-style COMPILE-TIME integer typing. The compiler
    ;     tracks the type (INT vs FLOAT) of every subexpression and emits these integer opcodes for
    ;     integer-typed work, avoiding the ROM float round-trip. Integers are 16-bit SIGNED and WRAP on
    ;     overflow (the `%`-variable opt-in -- documented divergence from float's unbounded range). The
    ;     runtime keeps a parallel `istack` of 16-bit words that SHARES the numeric stack pointer `sp`:
    ;     a given stack slot holds EITHER a float (in `stack[sp]`) or an int (in `istack[sp]`), and which
    ;     one is live is fixed at compile time by the opcode stream -- so no runtime type tag is needed.
    ;     Coercion opcodes bridge the two representations at the boundaries the compiler inserts them. ---
    const ubyte OP_IPUSHI = 67   ; (imm16 v)    push a 16-bit integer immediate onto istack
    const ubyte OP_ILOADV = 68   ; (imm16 slot) push integer variable slot (own namespace from floats)
    const ubyte OP_ISTORV = 69   ; (imm16 slot) pop int; store into integer variable slot
    const ubyte OP_IADD   = 70   ; ()           pop b,a (int); push a+b   (16-bit, wraps)
    const ubyte OP_ISUB   = 71   ; ()           pop b,a (int); push a-b   (16-bit, wraps)
    const ubyte OP_IMUL   = 72   ; ()           pop b,a (int); push a*b   (low 16 bits, wraps)
    const ubyte OP_INEG   = 73   ; ()           unary: pop a (int); push -a
    const ubyte OP_ITOF   = 74   ; ()           coerce the TOP cell int->float (istack[sp-1] -> stack[sp-1])
    const ubyte OP_ITOF2  = 75   ; ()           coerce the SECOND-from-top cell int->float (for mixed a<op>b)
    const ubyte OP_FTOI   = 76   ; ()           coerce the TOP cell float->int, truncating toward zero

    ; --- integer comparison / logic / branch (Phase 5 increment 2): the compiler emits these for
    ;     integer-typed operands (same firing rule as the arithmetic ops -- both intish, >=1 real INT),
    ;     so integer conditionals and loop guards never touch the ROM float compare. Each comparison
    ;     pops two ints and pushes an int truth value (-1 true / 0 false, CBM convention). IAND/IOR/INOT
    ;     are bitwise on the 16-bit int (which is also logical, since truth is -1/0). IJZ is the integer
    ;     twin of OP_JZ: it pops the int stack (not the float stack) and branches when the value is 0. ---
    const ubyte OP_ICMPEQ = 77   ; ()           pop b,a (int); push (a==b) ? -1 : 0
    const ubyte OP_ICMPNE = 78   ; ()           pop b,a (int); push (a!=b) ? -1 : 0
    const ubyte OP_ICMPLT = 79   ; ()           pop b,a (int, signed); push (a<b)  ? -1 : 0
    const ubyte OP_ICMPGT = 80   ; ()           pop b,a (int, signed); push (a>b)  ? -1 : 0
    const ubyte OP_ICMPLE = 81   ; ()           pop b,a (int, signed); push (a<=b) ? -1 : 0
    const ubyte OP_ICMPGE = 82   ; ()           pop b,a (int, signed); push (a>=b) ? -1 : 0
    const ubyte OP_IJZ    = 83   ; (imm16 pc)   pop int; jump to pcode offset if it is zero
    const ubyte OP_IAND   = 84   ; ()           pop b,a (int); push (a & b)
    const ubyte OP_IOR    = 85   ; ()           pop b,a (int); push (a | b)
    const ubyte OP_INOT   = 86   ; ()           unary: pop a (int); push ~a  (NOT x == -(x+1))

    ; --- integer FOR/NEXT (Phase 5 inc 2): the twins of OP_FORPUSH/OP_FORNEXT for a `%` loop counter
    ;     (FOR I%=..). The counter, limit and step are 16-bit ints (stepped/compared without the ROM
    ;     float path). CBM V2 rejects `FOR I%`, so this is a pure GPC extension. Integer stepping WRAPS
    ;     at 16 bits like the other `%` ops -- a counter that crosses +-32767 wraps (documented divergence
    ;     from float FOR). The compiler statically pairs each I(FOR)PUSH with the matching I(FOR)NEXT, so
    ;     the runtime never needs a per-frame type tag: the opcode itself says int vs float. ---
    const ubyte OP_IFORPUSH = 87 ; (imm16 slot) pop step then limit (int); open an integer FOR frame
    const ubyte OP_IFORNEXT = 88 ; ()           step the innermost (integer) FOR; loop to top or pop frame

    ; --- integer arrays (Phase 5 inc 2c): DIM A%(...) -- the integer twins of OP_DIM/ALOAD/ASTORE. Each
    ;     element is a 16-bit word (2 bytes) in a separate int-array heap, addressed row-major by the same
    ;     dim_setup/index_of math as the float arrays (shared, generic). Loads push to the int stack and are
    ;     typed TY_INT by the compiler, so array reads join the native-integer fast path. V2 has no `A%()`,
    ;     so this is a pure GPC extension; out-of-range reads give 0 and out-of-range stores are dropped. ---
    const ubyte OP_IDIM    = 89  ; (imm16 slot)(ubyte nd) pop nd max-indices; allocate an integer array
    const ubyte OP_IALOAD  = 90  ; (imm16 slot)(ubyte nd) pop nd subscripts; push int element (0 if out of range)
    const ubyte OP_IASTORE = 91  ; (imm16 slot)(ubyte nd) pop int value then nd subscripts; store the element

    ; Element addressing for both array families is ROW-MAJOR over dimension SIZES s_j = (max index j)+1:
    ; for subscripts i_0..i_{nd-1}, offset = (((i_0)*s_1 + i_1)*s_2 + i_2)... (Horner). The compiler emits
    ; the same subscripts for DIM and for access, so the exact layout only has to be self-consistent.
    const ubyte MAXDIMS = 4      ; at most 4 subscripts per array (DIM A(a,b,c,d)); deeper -> a compile error
    const ubyte MAX_XARGS = 4    ; at most 4 arguments to an X16 escape function (OP_CALLX); the runtime's
                                 ; xargs buffer holds this many. Real X16 functions take <= 2-3.

    ; built-in function ids (operand of OP_CALLFN); all take one numeric arg, return a number
    const ubyte FN_SGN = 0       ; sign: -1, 0, or 1
    const ubyte FN_INT = 1       ; floor toward -infinity (BASIC INT)
    const ubyte FN_ABS = 2       ; absolute value
    const ubyte FN_SQR = 3       ; square root
    const ubyte FN_RND = 4       ; random number
    const ubyte FN_SIN = 5
    const ubyte FN_COS = 6
    const ubyte FN_TAN = 7
    const ubyte FN_ATN = 8       ; arctangent
    const ubyte FN_LOG = 9       ; natural logarithm
    const ubyte FN_EXP = 10      ; e ** x

    ; OP_STRNUM ids (string -> number)
    const ubyte SN_LEN = 0       ; length of the string
    const ubyte SN_ASC = 1       ; PETSCII code of the first char (0 if the string is empty)
    const ubyte SN_VAL = 2       ; parse the leading number out of the string (BASIC VAL)
    ; OP_NUMSTR ids (number -> string)
    const ubyte NS_CHR = 0       ; one-character string CHR$(n)
    const ubyte NS_STR = 1       ; the number's printed form STR$(n)
    ; OP_SCMP ids (string comparison relation; result is BASIC truth -1/0)
    const ubyte SC_EQ = 0        ; a = b
    const ubyte SC_NE = 1        ; a <> b
    const ubyte SC_LT = 2        ; a < b
    const ubyte SC_GT = 3        ; a > b
    const ubyte SC_LE = 4        ; a <= b
    const ubyte SC_GE = 5        ; a >= b

    ; --- standalone-program memory layout (compiler emits it, runtime consumes it) ---
    ; A compiled .PRG is:
    ;     [$0801 runtime code ...] [ @PCODE_BASE: 6-byte header, then P-code, litpool, data pool ]
    ; The P-code is position-independent (jumps are relative offsets, vars are slot indices); only the
    ; string-literal pool and the DATA pool need absolute bases, supplied at runtime via vm.litbase /
    ; vm.database. The 6-byte HEADER at PCODE_BASE is three little-endian words:
    ;     +0 litpool address   +2 data-pool address   +4 data-pool length (bytes)
    ; Both pools float right after the P-code (litpool then data pool), so the file stays compact.
    ; The runtime reads the header, sets vm.litbase/database/datatop, and runs P-code at PCODE_BASE+6.
    const ubyte HEADER_SIZE = 6                       ; litaddr:2, dataaddr:2, datalen:2
    const uword PCODE_BASE = $3E00                    ; runtime finds the compiled program here. Must sit
                                                      ; ABOVE the bundled runtime's LOW-RAM footprint (code
                                                      ; + hot BSS: passbuf/xbuf pass-through buffers + VM
                                                      ; state) so its RAM never overlaps the loaded P-code.
                                                      ; Tier-1 layout: the five numeric/int/string slabs and
                                                      ; the BASIC string var table/heap park ABOVE the P-code
                                                      ; (see vm.run), so only code + hot BSS stays low --
                                                      ; topping ~$3b5a (testbench) / ~$3b42 (visual) after the
                                                      ; inc-2c integer arrays. PCODE_BASE clears that with
                                                      ; ~0.7 KB margin. INVARIANT: keep PCODE_BASE above the
                                                      ; runtime's BSS top -- if BSS grows past it, loaded
                                                      ; P-code is silently corrupted at run time (standalone
                                                      ; only; in-process runs P-code from banked RAM). The
                                                      ; build.sh runtime map's last BSS gap end is that top.
}
