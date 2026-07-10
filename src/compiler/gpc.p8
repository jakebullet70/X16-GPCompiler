; gpc.p8 -- Greased Piglet Compiler (GPC) for the Commander X16.
;
; Tokenize X16 BASIC (loaded from disk), parse it (two passes), emit P-code, then
; either run it in-process with the VM module or write a standalone out.prg with the
; runtime VM bundled in (a program that runs with no compiler present).
;
; Errors are categorized (SYNTAX, TYPE MISMATCH, UNDEF'D STATEMENT, NEXT WITHOUT FOR,
; FORMULA TOO COMPLEX, OUT OF MEMORY) and printed "?<MSG> ERROR IN <line>" with the
; original BASIC line number.
;
; Grammar so far:
;     program  := line (newline line)*
;     line     := [linenum] statement (":" statement)*
;     statement:= PRINT expr | [LET] lvalue "=" expr
;               | GOTO linenum | IF expr THEN (linenum | statement)
;               | FOR ident "=" expr TO expr [STEP expr] | NEXT [ident]
;               | GOSUB linenum | RETURN | END
;               | POKE expr "," expr | SYS expr                       ; machine access
;               | DIM (ident|ident$) "(" subs ")" ("," ...)*          ; arrays (N-D; numeric or string)
;               | INPUT [string ";"] (ident | ident$)                 ; keyboard input
;     subs     := expr ("," expr)*                         ; 1..MAXDIMS array subscripts (row-major)
;     lvalue   := ident | ident$ | ident "(" subs ")" | ident$ "(" subs ")"  ; scalar/string/array elem
;     expr     := cmp (("="|"<"|">"|"<="|">="|"<>") cmp)*  ; comparisons -> 0 / -1
;     cmp      := term (("+"|"-") term)*                   ; all parsed by shunting-yard
;     term     := factor (("*"|"/") factor)*              ;   (iterative, no recursion)
;     factor   := number | ident | "(" expr ")" | ident "(" subs ")"     ; number = int or float
;               | PEEK "(" expr ")" | fn "(" expr ")"   ; fn = INT ABS SGN SQR RND SIN COS TAN ATN LOG
;               | (LEN|ASC|VAL) "(" string_expr ")"    ; string->number (crosses the type boundary)
;     string_expr   := string_factor ("+" string_factor)*
;     string_factor := "literal" | ident$ | ident$ "(" subs ")" | (CHR$|STR$) "(" expr ")"
;               | (LEFT$|RIGHT$) "(" string_expr "," expr ")"
;               | MID$ "(" string_expr "," expr ["," expr] ")"
;
; Pass 1 emits P-code and records a linenum->offset map; forward GOTO/THEN targets
; emit a placeholder + a fixup. Pass 2 backpatches the fixups (the Blitz model).

%import textio
%import strings
%import diskio
%import floats
%import pcode_format
%import vm
%option no_sysinit          ; skip Prog8's screen reset (80x60 + yellow-on-black clear); we replay only
                            ; the KERNAL half it needs in start() so the caller's screen is left as-is
%zeropage basicsafe

main {
    const bool TESTBENCH = true          ; headless: write a result mailbox and halt with STP
    const bool INTERACTIVE = false        ; prompt the user for the file names (real-hardware use)
    ; INTSUPPORT=false builds the "noint" compiler: `%` integer vars/literals degrade to float and NO
    ; native-integer opcode (67..91) is ever emitted, so its output bundles the smaller noint runtime at
    ; a lower base. It works by rerouting the only two int SOURCES -- integer literals and `%` variables
    ; (the tokenizer stops producing T_IVAR) -- to float; every is_intish() path is then naturally dead.
    const bool INTSUPPORT = true          ; native 16-bit integer subsystem (A%, FOR I%, int literals)
    const uword MAILBOX = $0400

    ; --- source: tokenized BASIC loaded into BANKED RAM ($A000-$BFFF over banks 1..), so a program
    ;     can far exceed low RAM. The compiler walks it one line at a time into a small low-RAM
    ;     line buffer, so the lexer (and the whole rest of the pipeline) never sees the banking. ---
    const ubyte SRC_BANK0 = 1            ; first RAM bank holding source (bank 0 is system-reserved)
    const ubyte MAXSRCBANKS = 6          ; up to 6 banks = 48 KB of tokenized source
    const uword BRAM = $A000             ; banked-RAM window base
    const uword BRAM_END = $C000         ; one past the window ($A000..$BFFF = 8 KB per bank)
    ubyte[256] linebuf                   ; the current BASIC line, copied out of banked RAM
    ubyte srd_bank                       ; source reader: current bank
    uword srd_ptr                        ; source reader: pointer within the bank window

    ; --- file names (fixed for the headless harness; prompted for when INTERACTIVE) ---
    ubyte[32] src_name                   ; tokenized BASIC to compile
    ubyte[32] out_name                   ; standalone .prg to write (room for a "c."+source default)

    ; --- emitted P-code lives in BANKED RAM (banks PCODE_BANK0.., just above the source banks), so a
    ;     compiled program can far exceed low RAM. There is NO low-RAM copy: an in-process run points the
    ;     VM straight at the P-code bank window ($A000, bank PCODE_BANK0), so a program up to one 8 KB bank
    ;     runs in place. A program larger than that is a standalone job anyway (out.prg is written). This
    ;     is what reclaimed the old ~4 KB `codebuf` slab back to the $9F00 ceiling. ---
    const ubyte PCODE_BANK0 = SRC_BANK0 + MAXSRCBANKS     ; first RAM bank holding emitted P-code (= 7)
    const uword CODE_CAP = 16384                          ; 2 * 8 KB banks of P-code; overflow -> OUT OF MEMORY
    const uword RUN_CAP = 8000                            ; in-process run must fit ONE bank window (with a
                                                          ; margin for operand over-reads); bigger -> standalone
    uword code_len                                        ; emitted P-code length (bytes, into banked RAM)

    ; --- string-literal pool; OP_PUSHS stores pool-relative offsets (vm.litbase resolves
    ;     them), so the same P-code works in-process and in a standalone out.prg ---
    const uword LIT_SIZE = 768            ; string-literal pool (low RAM freed by banked-RAM name tables)
    uword litpool_ptr = memory("gpc_lit", LIT_SIZE, 0)
    uword lit_len
    ubyte[64] tokstr               ; string-literal text when tok == T_STRLIT (also DATA-item text)

    ; --- DATA pool: item texts (null-terminated, in line order) that READ walks at run time.
    ;     Bundled after the literal pool in a standalone out.prg; resolved via vm.database. ---
    const uword DATA_SIZE = 768           ; DATA-item pool (low RAM freed by banked-RAM name tables)
    uword datapool_ptr = memory("gpc_data", DATA_SIZE, 0)
    uword data_len

    ; --- resident in-process VM slabs. The VM's five slabs are host-assigned pointers now (a standalone
    ;     program parks them above its P-code); the compiler is too big to spare RAM above progend, so it
    ;     keeps them in this low buffer and pre-sets the VM's pointers before vm.run. ---
    uword vmslabs = memory("gpc_vmslabs", vm.SLAB_BYTES, 0)

    ; --- tokenizer state ---
    uword sptr                     ; cursor into source
    uword tok_start                ; sptr at the first byte of the current token (for OP_PASSTHRU)
    ubyte tok                      ; current token type
    word  tok_num                  ; value when tok == T_NUM (integer literal)
    float tok_fnum                 ; value when tok == T_FLOAT (has a decimal point)
    ubyte tok_funcid               ; function id (FN_*) when tok == T_FUNC
    ubyte[24] numbuf               ; the numeric literal's characters, for parsing
    bool  had_error

    ; --- M6 error reporting ---
    uword cur_line                 ; BASIC line number currently being compiled
    ubyte err_code                 ; first error's category (0 = none); see E_* below
    uword err_line                 ; BASIC line number where the first error occurred

    ; --- standalone output ---
    bool  wrote_output             ; did this run emit a standalone out.prg?

    ; --- Phase 2 runtime-tier: string arrays (DIM A$()) are a removable runtime feature. A program that
    ; never DIMs a string array bundles the smaller "nosarr" runtime (sarr handlers + sarr_alloc/sarr_desc
    ; stripped, ~0.8-1 KB), which loads its P-code at a LOWER base -- shrinking the whole compiled .PRG.
    ; Tracked at the sole string-array choke point (intern_sarr); the auto-select is correct BY
    ; CONSTRUCTION because every OP_SDIM/SALOAD/SASTORE/RDSTR emit site is gated behind intern_sarr().
    ; NOSARR_PCODE_BASE must clear the nosarr runtime's own footprint (build.sh runtime nosarr asserts it).
    bool  uses_sarr                ; did this program DIM any string array? (true => needs the full runtime)
    const uword NOSARR_PCODE_BASE = $3740   ; nosarr footprint tops ~$360f; $3740 = +305 B margin (guard-checked)

    ; --- Phase 3 runtime-tier: the native-integer subsystem (opcodes 67..91) is a removable feature. The
    ; noint compiler (INTSUPPORT=false) never emits any of them, so its output bundles the smaller noint
    ; runtime at NOINT_PCODE_BASE. Unlike nosarr this is NOT auto-selected per program (nearly every
    ; program has an int literal, which the full compiler emits as OP_IPUSHI) -- it is a whole-compiler
    ; mode. NOINT_PCODE_BASE must clear the noint runtime's footprint (build.sh runtime noint asserts it).
    const uword NOINT_PCODE_BASE = $3400    ; noint footprint tops $32d7 (testbench); $3400 = +297 B margin

    ; one-shot: when set, parse_expr stops at a top-level ')' instead of erroring, leaving it
    ; for the caller to consume (used to parse an array index we've already opened with '(')
    bool  expr_stop_rparen

    const ubyte NAMELEN = 8        ; 7 usable chars (names truncate past that for now)
    ubyte[NAMELEN] tokname         ; identifier text when tok == T_IDENT (zero-terminated)
    ubyte[NAMELEN] pend_name       ; an identifier held across one lookahead (scalar vs array)

    ; --- symbol tables: the name -> slot maps live in BANKED RAM (NAMES_BANK's $A000 window), freeing
    ;     ~2.4 KB of low RAM so the self-hosted compiler fits under MEMTOP $9f00 with room for Phase-5
    ;     integer typing. Only the intern_*() lookups touch these tables, and each pages NAMES_BANK in
    ;     first; every P-code emit (pc_poke) and source read (next_src_line) re-asserts ITS own bank, so
    ;     the switch is self-correcting. The tables are compile-time only (a run reads P-code by slot,
    ;     never by name), so clobbering NAMES_BANK during the standalone output pass would be harmless. ---
    const ubyte NAMES_BANK = PCODE_BANK0 + 2     ; = 9: a free bank above source (1..6) and P-code (7..8)
    ; byte offsets of each table within the NAMES_BANK window (BRAM = $A000); NAMELEN bytes per entry:
    const uword varnames_ptr  = BRAM + 0         ; MAXVARS  128 * 8 = 1024  -> $A000..$A3FF
    const uword ivarnames_ptr = BRAM + 1024      ; MAXIVARS  64 * 8 =  512  -> $A400..$A5FF
    const uword svarnames_ptr = BRAM + 1536      ; MAXSVARS  64 * 8 =  512  -> $A600..$A7FF
    const uword arrnames_ptr  = BRAM + 2048      ; MAXARRS   32 * 8 =  256  -> $A800..$A8FF
    const uword sarrnames_ptr = BRAM + 2304      ; MAXSARRS  32 * 8 =  256  -> $A900..$A9FF
    ; compile-time-only maps also live in the bank (same reason -- a run never reads them):
    const uword linenums_ptr  = BRAM + 2560      ; MAXLINES 128 * 2 =  256  -> $AA00..$AAFF  (GOTO/THEN map)
    const uword lineaddrs_ptr = BRAM + 2816      ; MAXLINES 128 * 2 =  256  -> $AB00..$ABFF
    const uword fnnames_bptr  = BRAM + 3072      ; MAXFNS    16 * 8 =  128  -> $AC00..$AC7F  (DEF FN names)
    const uword iarrnames_ptr = BRAM + 3200      ; MAXIARRS  32 * 8 =  256  -> $AC80..$AD7F  (DIM A%() names)
                                                 ; (3456 bytes used of the 8 KB bank -- room to grow caps)
    const ubyte MAXVARS = 128            ; VM has word[128] vars
    const ubyte SCRATCH_SLOT = 127       ; top numeric slot reserved for the compiler (ON selector temp)
    ubyte nvars

    const ubyte MAXIVARS = 64            ; integer (`%`) variables: own namespace + VM storage (vm.ivarsf)
    ubyte niv

    ; --- DEF FN user functions: name -> (pcode entry offset, parameter var slot). Reuses OP_GOSUB/
    ;     OP_RET at runtime; a call emits STORV param + GOSUB entry. DEF must precede use (textually). ---
    const ubyte MAXFNS = 16
    ; fnnames lives in NAMES_BANK (fnnames_bptr); fn_entry/fn_param stay in low RAM (small, hot in a run's setup)
    uword[MAXFNS] fn_entry               ; pcode offset of each function body
    ubyte[MAXFNS] fn_param               ; the numeric var slot bound to the parameter
    ubyte nfns

    const ubyte MAXSVARS = 64            ; string variables (name incl. '$'); VM has uword[64] svars
    ubyte nsvars

    const ubyte MAXARRS = 32             ; numeric arrays (DIM); slot must fit the VM's 32 descriptors
    ubyte narr

    const ubyte MAXIARRS = 32            ; integer arrays (DIM A%()); own namespace + VM iarr descriptors (32)
    ubyte niarr

    const ubyte MAXSARRS = 32            ; string arrays (DIM A$(), name incl. '$'); the VM keeps 32 too
    ubyte nsarr

    ; --- line-number map (linenum -> pcode offset) for GOTO / THEN targets; lives in NAMES_BANK
    ;     (linenums_ptr/lineaddrs_ptr) -- record_line/find_line_addr page it in, compile-time only ---
    const ubyte MAXLINES = 128
    ubyte nlines

    ; --- IF guard patches for the current source line ---
    ; CBM/X16 BASIC V2: a FALSE `IF` skips to the end of the LINE (the ROM runs the same
    ; `remn` REM-skip; see ref/x16-rom/basic/code5.s `if`), not just past the THEN body.
    ; So EVERY guard JZ/IJZ on a line -- whether from a leading "IF a THEN IF b" chain
    ; (nested) or from colon-separated "IF a THEN .. : IF b THEN .." -- is backpatched to
    ; the SAME end-of-line target by the line loop, not locally in parse_if. parse_if only
    ; appends each guard's operand slot here; the loop resolves them all when the line ends.
    const ubyte MAXIFLINE = 16
    uword[MAXIFLINE] if_line_patch  ; pcode offsets of each guard's JZ/IJZ operand
    ubyte n_if_line                 ; guards collected on the current line

    ; --- forward-reference fixups, backpatched in pass 2 (Blitz style two-pass core) ---
    const ubyte MAXFIX = 128
    uword[MAXFIX] fix_addr         ; pcode offset of a placeholder jump operand
    uword[MAXFIX] fix_line         ; the target line number to resolve
    uword[MAXFIX] fix_srcline      ; BASIC line the forward ref appears on (for error reports)
    ubyte nfix

    ; --- compile-time FOR stack (to match each NEXT to its FOR) ---
    const ubyte MAXFOR = 8
    ubyte[MAXFOR] for_slots        ; loop-variable slot of each open FOR
    bool[MAXFOR]  for_is_int       ; true if that FOR's counter is a `%` integer var (Phase 5 inc 2)
    ubyte for_depth

    const ubyte T_EOF     = 0
    const ubyte T_EOL     = 1      ; ':' statement separator
    const ubyte T_NUM     = 2
    const ubyte T_PRINT   = 3
    const ubyte T_PLUS    = 4
    const ubyte T_MINUS   = 5
    const ubyte T_STAR    = 6
    const ubyte T_SLASH   = 7
    const ubyte T_LPAREN  = 8
    const ubyte T_RPAREN  = 9
    const ubyte T_IDENT   = 10     ; variable name
    const ubyte T_LET     = 11
    const ubyte T_EQ      = 12     ; '=' : assignment, or equality inside an expression
    const ubyte T_NEWLINE = 13     ; end of a physical line (a line number may follow)
    const ubyte T_LT      = 14
    const ubyte T_GT      = 15
    const ubyte T_LE      = 16
    const ubyte T_GE      = 17
    const ubyte T_NE      = 18
    const ubyte T_GOTO    = 19
    const ubyte T_IF      = 20
    const ubyte T_THEN    = 21
    const ubyte T_FOR     = 22
    const ubyte T_TO      = 23
    const ubyte T_STEP    = 24
    const ubyte T_NEXT    = 25
    const ubyte T_GOSUB   = 26
    const ubyte T_RETURN  = 27
    const ubyte T_END     = 28
    const ubyte T_NEG     = 29     ; unary minus (internal; never produced by the tokenizer)
    const ubyte T_STRLIT  = 30     ; "string literal" (text in tokstr)
    const ubyte T_STRVAR  = 31     ; string variable (name incl. '$' in tokname)
    const ubyte T_SEMI    = 32     ; ';' PRINT separator
    const ubyte T_COMMA   = 33     ; ',' PRINT separator
    const ubyte T_POKE    = 34     ; POKE addr, val        (M8: machine access)
    const ubyte T_PEEK    = 35     ; PEEK(addr)            (function, used in expressions)
    const ubyte T_SYS     = 36     ; SYS addr              (call machine-language routine)
    const ubyte T_DIM     = 37     ; DIM name(size)        (declare an array)
    ; (token id 38 was T_ALOAD; array access is now parsed inline, not as an operator-stack unary op)
    const ubyte T_INPUT   = 39     ; INPUT [prompt;] var   (read from the keyboard)
    const ubyte T_FLOAT   = 40     ; floating-point literal (value in tok_fnum)
    const ubyte T_FUNC    = 41     ; built-in function call (fn id in tok_funcid)
    const ubyte T_SNFUNC  = 42     ; string->number fn: LEN/ASC/VAL  (SN_* id in tok_funcid)
    const ubyte T_NSFUNC  = 43     ; number->string fn: CHR$/STR$    (NS_* id in tok_funcid)
    const ubyte T_STRSLICE= 44     ; LEFT$/RIGHT$/MID$               (SL_* id in tok_funcid)
    const ubyte T_DATA    = 45     ; DATA const, const, ...   (declares data, emits no code)
    const ubyte T_READ    = 46     ; READ var, var, ...       (consume the next DATA items)
    const ubyte T_RESTORE = 47     ; RESTORE                  (rewind the DATA cursor)
    const ubyte T_AND     = 48     ; AND  (bitwise/logical, binary; below comparisons)
    const ubyte T_OR      = 49     ; OR   (bitwise/logical, binary; lowest precedence)
    const ubyte T_NOT     = 50     ; NOT  (bitwise/logical, unary prefix; below comparisons)
    const ubyte T_OPEN    = 51     ; OPEN lfn,dev,sa,"name"   (channel / file I/O)
    const ubyte T_CLOSE   = 52     ; CLOSE lfn
    const ubyte T_GET     = 53     ; GET#lfn, v$              (read one byte from a channel)
    const ubyte T_PRINTCH = 54     ; PRINT#lfn, item ; item   (write to a channel)
    const ubyte T_INPUTCH = 55     ; INPUT#lfn, var
    const ubyte T_HASH    = 56     ; '#'  (channel marker, e.g. after GET)
    const ubyte T_ST      = 57     ; ST   (reserved variable: the KERNAL I/O status word)
    const ubyte T_STOP    = 58     ; STOP                     (halt; same as END here -- CONT is out of scope)
    const ubyte T_ON      = 59     ; ON expr GOTO/GOSUB n,... (computed branch)
    const ubyte T_WAIT    = 60     ; WAIT addr,mask[,xor]     (spin until a memory bit is set)
    const ubyte T_DEF     = 61     ; DEF FN name(var)=expr    (define a user function)
    const ubyte T_FN      = 62     ; FN name(arg)             (call a user function; in expressions)
    const ubyte T_POW     = 63     ; ^  power operator        (binds tighter than * /)
    const ubyte T_XFUNC   = 64     ; X16 escape function (numeric): VPEEK/JOY/MX/... ($CE sub-token in tok_funcid)
    const ubyte T_XSFUNC  = 65     ; X16 escape function (string-returning): HEX$/BIN$ ($CE sub-token in tok_funcid)
    const ubyte T_IVAR    = 66     ; integer variable A% (name incl. '%' in tokname; own namespace, Phase 5)
    const ubyte T_BAD     = 255

    ; sub-ids for T_STRSLICE (compiler-only; each maps to its own VM opcode)
    const ubyte SL_LEFT   = 0
    const ubyte SL_RIGHT  = 1
    const ubyte SL_MID    = 2

    ; --- M6 error categories (classic CBM wording) ---
    const ubyte E_SYNTAX  = 1      ; "SYNTAX"
    const ubyte E_UNDEF   = 2      ; "UNDEF'D STATEMENT"
    const ubyte E_TYPE    = 3      ; "TYPE MISMATCH"
    const ubyte E_MEM     = 4      ; "OUT OF MEMORY"
    const ubyte E_NEXT    = 5      ; "NEXT WITHOUT FOR"
    const ubyte E_COMPLEX = 6      ; "FORMULA TOO COMPLEX"
    const ubyte E_NOFILE  = 7      ; "FILE NOT FOUND"

    sub start() {
        %asm {{
            ; With no_sysinit, Prog8's init_system (which ALSO clears + recolors the screen) is skipped.
            ; Replay only its KERNAL half so the ROM string GC still works, but leave the screen alone.
            sei
            jsr  $ff84          ; IOINIT : (re)init CIA/VIA + the default IRQ
            jsr  $ff8a          ; RESTOR : restore the KERNAL indirect vectors
            cli
        }}
        txt.print("\n\ngreased piglet compiler! v1.0 build:100\n")
        setup_names()                             ; decide what to compile and where to write it
        if INTERACTIVE and not TESTBENCH and src_name[0] == 0
            return                                ; blank name at "compile file:" -> quit to READY (no error)
        compile()
        wrote_output = false
        if had_error {
            txt.print("compile failed\n")
        } else {
            wrote_output = write_output()         ; emit standalone out.prg (if gpc.runtime.bin present)
            if INTERACTIVE and not TESTBENCH {
                report_output()                   ; a real compile run: name the file, don't auto-run
            } else {
                vm.litbase = litpool_ptr             ; literals + DATA live in our own pools in-process
                vm.database = datapool_ptr
                vm.datatop = datapool_ptr + data_len
                vm.varsf     = vmslabs               ; pre-place the VM slabs in our low buffer (layout
                vm.ivarsf    = vmslabs + 640         ; must match vm.SLAB_BYTES / vm.run's standalone layout)
                vm.arrheap   = vmslabs + 896
                vm.arr_dims  = vmslabs + 2944
                vm.sarr_dims = vmslabs + 3200
                vm.iarrheap  = vmslabs + 3456
                vm.iarr_dims = vmslabs + 4480
                vm.heapfloor = sys.progend()         ; heapfloor != 0 -> in-process regime: string heap
                                                     ; owns the free RAM from progend up to MEMTOP
                if code_len <= RUN_CAP {
                    vm.host_echo = TESTBENCH         ; host-console mirror only in the headless test build
                    cx16.rambank(PCODE_BANK0)        ; select the P-code bank; the VM never switches it,
                    txt.print("run:\n")              ; so it reads the P-code straight from the $A000 window
                    vm.run(BRAM)
                } else {
                    ; too big to run alongside the resident compiler -- it's a standalone job (out.prg written)
                    txt.print("too big to run\n")
                }
            }
        }
        if TESTBENCH {
            @(MAILBOX)     = lsb(vm.last_printed as uword)
            @(MAILBOX + 1) = msb(vm.last_printed as uword)
            @(MAILBOX + 2) = $AA
            @(MAILBOX + 3) = err_code                 ; M6: 0 = ok, else E_* category
            @(MAILBOX + 4) = lsb(err_line)            ; M6: original BASIC line of first error
            @(MAILBOX + 5) = msb(err_line)
            @(MAILBOX + 6) = wrote_output as ubyte    ; standalone: 1 if out.prg was written
            %asm {{
                stp
            }}
        }
    }

    ; decide the source and output file names. The headless harness always uses fixed names
    ; (so the 100+ automated checks need no keyboard); a real on-device build prompts for them.
    sub setup_names() {
        if INTERACTIVE {
            txt.print("compile file: ")
            read_name(&src_name)
            if src_name[0] == 0
                return                        ; blank name -> quit (start() exits); skip the output prompt
            txt.print("write to: ")
            read_name(&out_name)
            if out_name[0] == 0 {
                default_out_name()            ; just RETURN pressed -> auto-name the output
            }
        } else {
            void strings.copy("source.prg", &src_name)
            void strings.copy("out.prg", &out_name)
        }
    }

    ; No output name entered: default to "c." + the source name (the classic on-device "compiled"
    ; naming). f_open_w fails on an existing file, so a stale build of that name is deleted first --
    ; letting you just hit RETURN to recompile in place.
    sub default_out_name() {
        out_name[0] = 'c'
        out_name[1] = '.'
        void strings.copy(&src_name, &out_name + 2)     ; "c." then the source name (null-terminated)
        txt.print("-> ")
        txt.print(&out_name)
        txt.nl()
        if diskio.exists(&out_name)
            diskio.delete(&out_name)                    ; remove the stale build so f_open_w can create it
    }

    ; read one file name from the keyboard into dst (null-terminated), echoing to the screen.
    ; The raw PETSCII bytes are stored as typed; the KERNAL/host file system match case-insensitively.
    ; DELETE erases the last character (screen + buffer); other control keys (cursor moves, function
    ; keys) are ignored -- otherwise a correction or stray keypress would silently corrupt the name
    ; (the cursor moves back on screen so the name still LOOKS right, but f_open sees garbage bytes).
    sub read_name(uword dst) {
        ubyte n = 0
        repeat {
            ubyte ch = cbm.GETIN2()
            if ch == 0
                continue                          ; queue empty: wait for a key
            if ch == 13
                break                             ; RETURN ends the name
            if ch == 20 {                         ; DELETE ($14): rub out the last character
                if n != 0 {
                    n--
                    cbm.CHROUT(20)                ; echo DEL so the screen erases it too
                }
                continue
            }
            if ch >= 32 and ch < 128 and n < 23 { ; store printable ASCII only (cursor/ctrl keys are >=128 or <32)
                @(dst + n) = ch
                cbm.CHROUT(ch)
                n++
            }
        }
        @(dst + n) = 0
        cbm.CHROUT(13)
    }

    ; interactive mode: report what was written (a real compiler produces a file, not a run)
    sub report_output() {
        if wrote_output {
            txt.print("wrote ")
            txt.print(&out_name)
            txt.nl()
        } else {
            txt.print("no gpc.runtime.bin?\n")
        }
    }

    ; ---- pass 1: load tokenized BASIC, walk its lines, emit P-code + fixups ----
    sub compile() {
        code_len = 0
        lit_len = 0
        data_len = 0
        nvars = 0
        niv = 0
        nsvars = 0
        narr = 0
        niarr = 0
        nsarr = 0
        nfns = 0
        nlines = 0
        nfix = 0
        for_depth = 0
        opsp = 0                                 ; operator + frame stacks empty (a prior aborted
        fr_sp = 0                                ; compile may have left them mid-expression)
        tsp = 0                                  ; type stack empty
        expr_depth = 0
        expr_keep_int = false
        had_error = false
        err_code = 0
        err_line = 0
        cur_line = 0
        uses_sarr = false                       ; runtime-tier tracker: no string arrays until intern_sarr proves otherwise

        ; load the tokenized program from disk (HostFS device 8) into banked RAM
        if not load_source() {
            error(E_NOFILE)
            emit_byte(pcode.OP_END)
            return
        }

        ; walk the tokenized lines, copying each out of banked RAM into linebuf and lexing that:
        ;   [load addr] then per line: [link:2][linenum:2][tokens...][$00], ends [$00 $00]
        srd_reset()                             ; position the source reader past the load address
        repeat {
            if had_error {
                break
            }
            if not next_src_line() {
                break                            ; $00 $00 end-of-program marker
            }
            record_line(cur_line, code_len)      ; cur_line was set by next_src_line
            sptr = &linebuf                      ; the lexer runs over the low-RAM copy
            next_token()
            n_if_line = 0                         ; no IF guards collected on this line yet
            repeat {
                if had_error {
                    break
                }
                if tok == T_NEWLINE or tok == T_EOF {
                    break                        ; end of this line
                }
                if tok == T_EOL {
                    next_token()                 ; ':' -> next statement on the same line
                } else {
                    parse_statement()
                }
            }
            ; end of line: a false IF condition skips the WHOLE rest of the line (CBM V2),
            ; so backpatch every guard collected on this line to here (start of next line).
            if not had_error and n_if_line != 0 {
                ubyte gi
                for gi in 0 to n_if_line - 1 {
                    pc_poke(if_line_patch[gi],     lsb(code_len))
                    pc_poke(if_line_patch[gi] + 1, msb(code_len))
                }
            }
        }
        emit_byte(pcode.OP_END)
        if not had_error {
            resolve_fixups()                    ; pass 2
        }
    }

    ; ---- banked-source reader ----
    ; Load the whole tokenized program into banked RAM, one 8 KB bank per f_read (diskio wraps the
    ; buffer pointer safely at the $C000 window edge, so each read fills exactly one bank). Returns
    ; false if the file is empty/absent, or reports OUT OF MEMORY if it needs more than MAXSRCBANKS.
    sub load_source() -> bool {
        if src_name[0] == 0                     ; empty name (RETURN at the prompt): nothing to open --
            return false                        ; report FILE NOT FOUND cleanly instead of compiling junk
        if not diskio.f_open(&src_name)
            return false
        ubyte bank = SRC_BANK0
        uword total = 0
        bool ok = true
        repeat {
            cx16.rambank(bank)
            uword got = diskio.f_read(BRAM, 8192)
            total += got
            if got < 8192
                break                            ; short read == end of file (f_read closed it)
            bank++
            if bank == SRC_BANK0 + MAXSRCBANKS {
                ok = false                       ; source too large for the banks we reserve
                break
            }
        }
        diskio.f_close()                         ; harmless no-op if f_read already hit EOF
        if not ok
            error(E_MEM)
        return total != 0 and ok
    }

    ; position the reader at the first line (skip the 2-byte load address)
    sub srd_reset() {
        srd_bank = SRC_BANK0
        srd_ptr = BRAM
        cx16.rambank(srd_bank)
        void srd_byte()
        void srd_byte()
    }

    ; next source byte, advancing across bank boundaries ($BFFF -> next bank's $A000)
    sub srd_byte() -> ubyte {
        ubyte b = @(srd_ptr)
        srd_ptr++
        if srd_ptr == BRAM_END {
            srd_ptr = BRAM
            srd_bank++
            cx16.rambank(srd_bank)
        }
        return b
    }

    ; copy the next tokenized line into linebuf, setting cur_line; false at the $00 $00 end marker
    sub next_src_line() -> bool {
        cx16.rambank(srd_bank)                   ; re-assert our bank (defensive)
        ubyte link_lo = srd_byte()
        ubyte link_hi = srd_byte()
        if link_lo == 0 and link_hi == 0
            return false                         ; end of program
        ubyte lnum_lo = srd_byte()
        ubyte lnum_hi = srd_byte()
        cur_line = mkword(lnum_hi, lnum_lo)      ; M6: errors report this line number
        ubyte n = 0
        repeat {
            ubyte b = srd_byte()
            if b == 0
                break                            ; line terminator
            if n < 255 {
                linebuf[n] = b
                n++
            }
        }
        linebuf[n] = 0
        return true
    }

    ; ---- standalone output: write out.prg = [runtime][ @PCODE_BASE: litaddr:2, pcode, litpool ] ----
    ; The bundled runtime (gpc.runtime.bin) is loaded from disk and prepended to the compiled
    ; P-code, producing a self-contained program that runs with no compiler present -- the
    ; whole point of a compiler. A 6-byte header at PCODE_BASE tells the runtime where the literal
    ; and data pools ended up (both float right after the P-code, keeping the file compact). The
    ; P-code itself lives in banked RAM now, so it's streamed out bank by bank (write_pcode).
    ; Returns false (and simply skips) if gpc.runtime.bin is absent, so plain compile-and-run
    ; keeps working when there's nothing to bundle.
    sub write_output() -> bool {
        ; The compile is done, so reuse the source banks (SRC_BANK0..) as scratch to hold the runtime
        ; image while we prepend it to the P-code. The runtime has OUTGROWN a single 8 KB bank, so it
        ; must be read across banks -- a short read marks end-of-file and gives the true total length.
        ; (Reading only one bank silently truncated the bundled runtime, hanging every standalone .prg.)
        ; Pick the runtime tier + its P-code base. The noint compiler always bundles the noint runtime;
        ; otherwise a program that never DIMs a string array gets the smaller "nosarr" runtime and a
        ; DIM A$() program gets the full runtime. Any missing tier image falls back to the full runtime at
        ; the full base -- never fail a compile over a missing tier file (a noint/nosarr program still runs
        ; correctly on the full runtime, just loaded higher).
        uword pbase = pcode.PCODE_BASE
        bool opened
        if not INTSUPPORT {
            pbase = NOINT_PCODE_BASE
            opened = diskio.f_open("gpc.rt.noint.bin")
            if not opened {
                pbase = pcode.PCODE_BASE
                opened = diskio.f_open("gpc.runtime.bin")
            }
        } else if uses_sarr {
            opened = diskio.f_open("gpc.runtime.bin")
        } else {
            pbase = NOSARR_PCODE_BASE
            opened = diskio.f_open("gpc.rt.nosarr.bin")
            if not opened {
                pbase = pcode.PCODE_BASE
                opened = diskio.f_open("gpc.runtime.bin")
            }
        }
        if not opened                            ; fixed internal dependency, not a user file
            return false
        uword rt_len = 0
        ubyte rbank = SRC_BANK0
        repeat {
            cx16.rambank(rbank)
            uword got = diskio.f_read(BRAM, 8192)
            rt_len += got
            if got != 8192
                break                           ; short read == end of file
            rbank++
        }
        diskio.f_close()
        if rt_len < 3
            return false                        ; not a real .prg
        uword rt_body_len = rt_len - 2          ; drop the 2-byte load address
        if $0801 + rt_body_len > pbase
            return false                        ; runtime would overlap the P-code region
        debrand_stub()                          ; make the bundled BASIC stub LIST like X16 BASIC, not Prog8

        if not diskio.f_open_w(&out_name)
            return false
        ubyte[2] prg_hdr = [$01, $08]           ; cx16 load address $0801, little-endian
        void diskio.f_write(&prg_hdr, 2)
        ; runtime body -> $0801.. : stream it back out of the scratch banks, skipping the 2-byte load
        ; address in the first bank. The body may span more than one bank, so walk them.
        uword rem = rt_body_len
        ubyte wbank = SRC_BANK0
        uword woff = 2                          ; first bank: skip the load address; later banks: 0
        while rem != 0 {
            uword chunk = 8192 - woff
            if chunk > rem
                chunk = rem
            cx16.rambank(wbank)
            void diskio.f_write(BRAM + woff, chunk)
            rem -= chunk
            wbank++
            woff = 0
        }
        write_filler(pbase - ($0801 + rt_body_len))              ; pad up to the tier's base
        ; 6-byte header at PCODE_BASE: litpool addr, data-pool addr, data-pool length. Both pools
        ; float right after the P-code (litpool then data pool), so the file stays compact.
        uword litaddr  = pbase + pcode.HEADER_SIZE + code_len
        uword dataaddr = litaddr + lit_len
        ubyte[6] hdr
        hdr[0] = lsb(litaddr)
        hdr[1] = msb(litaddr)
        hdr[2] = lsb(dataaddr)
        hdr[3] = msb(dataaddr)
        hdr[4] = lsb(data_len)
        hdr[5] = msb(data_len)
        void diskio.f_write(&hdr, 6)                             ; -> PCODE_BASE
        write_pcode()                                            ; banked P-code -> PCODE_BASE+6..
        if lit_len != 0
            void diskio.f_write(litpool_ptr, lit_len)            ; literal pool -> litaddr..
        if data_len != 0
            void diskio.f_write(datapool_ptr, data_len)          ; data pool -> dataaddr..
        diskio.f_close_w()
        return true
    }

    ; A compiled program is [runtime][pcode], so its first BASIC line is the runtime's Prog8 launcher
    ; stub -- "2026 SYS <e> :REM PROG8" -- which brands the output as Prog8 when LISTed. Rewrite it in
    ; place (in the scratch bank holding the runtime image) into a plain X16 BASIC loader, "10 SYS <e>",
    ; so our compiled .prg LISTs like normal X16 BASIC. The SYS address and everything from the code
    ; entry on are left byte-for-byte identical, so nothing moves: we only renumber the line to 10 and
    ; end the program right after the address (the leftover ":REM PROG8" bytes fall after the end-of-
    ; program marker, so LIST never shows them and SYS jumps straight past them into the code).
    sub debrand_stub() {
        cx16.rambank(SRC_BANK0)                 ; runtime image lives here; stub at BRAM+2 (BRAM+0,1=load addr)
        if @(BRAM + 6) != $9e                   ; SYS token where we expect it? if not, leave the stub alone
            return
        @(BRAM + 4) = 10                         ; line number -> 10 (was the Prog8 build year, 2026)
        @(BRAM + 5) = 0
        uword q = BRAM + 7                       ; just past the SYS token
        while @(q) == ' '                        ; skip spaces before the address
            q++
        while @(q) >= '0' and @(q) <= '9'        ; skip the SYS address digits (kept intact)
            q++
        @(q) = 0                                 ; end this BASIC line right after the address
        @(q + 1) = 0                             ; two nulls = end-of-program (a null next-line link)
        @(q + 2) = 0
        uword endaddr = $0801 + (q + 1 - (BRAM + 2))    ; memory address of the end-of-program marker
        @(BRAM + 2) = lsb(endaddr)               ; the line's link now points at end-of-program
        @(BRAM + 3) = msb(endaddr)
    }

    ; stream the banked P-code (code_len bytes, laid out contiguously from offset 0 across banks
    ; PCODE_BANK0..) to the open output file, one bank-sized chunk at a time. In out.prg the P-code
    ; lands FLAT at PCODE_BASE, so a standalone program's VM reads it directly with no banking.
    sub write_pcode() {
        uword remaining = code_len
        ubyte bank = PCODE_BANK0
        while remaining != 0 {
            uword chunk = remaining
            if chunk > 8192
                chunk = 8192                        ; one 8 KB window per bank
            cx16.rambank(bank)
            void diskio.f_write(BRAM, chunk)
            remaining -= chunk
            bank++
        }
    }

    ; write `count` throwaway bytes to the open output file. Filler lands in the runtime's
    ; BSS region (which its own startup re-zeroes), so the content is irrelevant -- we source
    ; it from the literal pool simply because that's valid, readable low RAM.
    sub write_filler(uword count) {
        while count != 0 {
            uword chunk = count
            if chunk > LIT_SIZE
                chunk = LIT_SIZE
            void diskio.f_write(litpool_ptr, chunk)
            count -= chunk
        }
    }

    ; dispatch one statement (tok is on its first token)
    sub parse_statement() {
        when tok {
            T_PRINT -> parse_print()
            T_LET -> {
                next_token()
                parse_assign()
            }
            T_IDENT -> parse_assign()
            T_STRVAR -> parse_assign()
            T_IVAR -> parse_assign()
            T_GOTO -> parse_goto()
            T_IF -> parse_if()
            T_FOR -> parse_for()
            T_NEXT -> parse_next()
            T_GOSUB -> parse_gosub()
            T_POKE -> parse_poke()
            T_SYS -> parse_sys()
            T_OPEN -> parse_open()
            T_CLOSE -> parse_close()
            T_GET -> parse_get()
            T_PRINTCH -> parse_printch()
            T_DIM -> parse_dim()
            T_INPUT -> parse_input()
            T_DATA -> parse_data()
            T_READ -> parse_read()
            T_RESTORE -> parse_restore()
            T_RETURN -> {
                emit_byte(pcode.OP_RET)
                next_token()
            }
            T_END -> {
                emit_byte(pcode.OP_END)
                next_token()
            }
            T_STOP -> {                             ; STOP: halt (CONT is out of scope, so == END)
                emit_byte(pcode.OP_END)
                next_token()
            }
            T_ON -> parse_on()
            T_WAIT -> parse_wait()
            T_DEF -> parse_def()
            else -> {
                ; a statement whose first token is a BASIC keyword GPC doesn't compile (the X16
                ; VERA/sound/graphics/disk extensions, tokenized $CE $8x) -> pass it to ROM BASIC.
                ; A non-keyword first byte (stray punctuation) is a genuine syntax error.
                if @(tok_start) >= $80
                    parse_passthru()
                else
                    error(E_SYNTAX)
            }
        }
    }

    ; Emit OP_PASSTHRU carrying the current statement's raw tokenized bytes (from its first token to
    ; the next unquoted ':' or the end of line). At run time the VM hands these to the ROM interpreter.
    ; Emit a statement GPC doesn't compile (an X16 $CE escape) as OP_PASSTHRU, to be run by the ROM
    ; interpreter at run time. We copy the tokenized statement bytes verbatim EXCEPT scalar numeric
    ; variable references: the ROM would look those up in BASIC's variable table, where GPC's variables
    ; don't live (they sit in the VM's private slab), so `VPOKE 0,A,V` would silently read the ROM's
    ; undefined A=0. Instead each scalar-numeric-var name is replaced by a $01<slot> marker; the runtime
    ; splices in the variable's current value as ASCII, so the ROM sees `VPOKE 0,4660,66`. The ROM still
    ; does all the arithmetic, so `VPOKE 0,B*40,V` works too. NOT substituted (copied verbatim, so still
    ; unsupported -- but no regression): quoted strings, hex/binary literals ($FF / %1010), string vars
    ; (A$), integer vars (A%), and array/function arguments (A(I)) -- a name followed by $ % or '('.
    sub parse_passthru() {
        uword s = tok_start                     ; first byte of the statement (in low-RAM linebuf)
        uword e = s
        bool inq = false
        repeat {
            ubyte ch = @(e)
            if ch == 0
                break                           ; end of line
            if ch == '"'
                inq = not inq
            else if ch == ':' and not inq
                break                           ; next statement on the line
            e++
        }
        emit_byte(pcode.OP_PASSTHRU)
        uword lenpos = code_len                 ; the (marker-encoded) length byte, backpatched below
        emit_byte(0)
        uword enc = 0                           ; encoded byte count (markers make it differ from e-s)
        uword p = s
        inq = false
        while p < e {
            ubyte c = @(p)
            if inq {
                emit_byte(c)
                enc++
                if c == '"'
                    inq = false
                p++
            } else if c >= $80 {                ; a BASIC keyword/operator token ($CE VPOKE, ...) -- copy
                emit_byte(c)                    ; verbatim; it can never be a variable (names are ASCII)
                enc++
                p++
            } else if c == '"' {
                emit_byte(c)
                enc++
                inq = true
                p++
            } else if c == '$' or c == '%' {    ; hex/binary literal: copy prefix + alnum body verbatim
                emit_byte(c)                    ; (so A-F digits in $1A2B aren't read as a variable)
                enc++
                p++
                while p < e and (is_alpha(@(p)) or is_digit(@(p))) {
                    emit_byte(@(p))
                    enc++
                    p++
                }
            } else if is_alpha(c) {             ; a variable name (keywords are >= $80 tokens, not letters)
                uword rs = p
                while p < e and (is_alpha(@(p)) or is_digit(@(p)))
                    p++
                ubyte nxt = 0
                if p < e
                    nxt = @(p)
                if nxt == '$' or nxt == '%' or nxt == '(' {
                    while rs < p {              ; string/integer var or array/fn arg -> copy verbatim
                        emit_byte(@(rs))
                        enc++
                        rs++
                    }
                } else {                        ; scalar numeric variable -> $01<slot> marker
                    ubyte nl = 0
                    while rs < p and nl < NAMELEN-1 {
                        tokname[nl] = @(rs)
                        nl++
                        rs++
                    }
                    tokname[nl] = 0
                    emit_byte($01)
                    emit_byte(intern_var())
                    enc += 2
                }
            } else {
                emit_byte(c)
                enc++
                p++
            }
            if enc > 254 {                      ; too long for the runtime passbuf (dummy + 254 + $00)
                error(E_SYNTAX)
                return
            }
        }
        pc_poke(lenpos, lsb(enc))               ; backpatch the real encoded length
        sptr = e                                ; resume the lexer at the terminator
        next_token()                            ; -> T_EOL (':') or T_NEWLINE ($00)
    }

    ; POKE addr, val  -- write a byte to memory (stack: addr then val, OP_POKE pops val first)
    sub parse_poke() {
        next_token()
        parse_expr()                            ; address
        if tok != T_COMMA {
            error(E_SYNTAX)
            return
        }
        next_token()
        parse_expr()                            ; value
        emit_byte(pcode.OP_POKE)
    }

    ; SYS addr  -- call a machine-language routine
    sub parse_sys() {
        next_token()
        parse_expr()                            ; address
        emit_byte(pcode.OP_SYS)
    }

    ; --- channel / file I/O statements (thin wrappers over the KERNAL device API) ---

    ; OPEN lfn, dev [, sa [, "name"]]  -- a missing secondary address defaults to 0, a missing name to "".
    sub parse_open() {
        next_token()
        parse_expr()                            ; logical file number
        if tok != T_COMMA {
            error(E_SYNTAX)
            return
        }
        next_token()
        parse_expr()                            ; device number
        if tok == T_COMMA {                     ; optional secondary address
            next_token()
            parse_expr()
        } else {
            emit_byte(pcode.OP_PUSHI)           ; default secondary address 0
            emit_imm16(0)
        }
        if tok == T_COMMA {                     ; optional filename
            next_token()
            parse_string_expr()
        } else {
            push_empty_string()                 ; default name ""
        }
        emit_byte(pcode.OP_OPEN)
    }

    ; CLOSE lfn
    sub parse_close() {
        next_token()
        parse_expr()                            ; logical file number
        emit_byte(pcode.OP_CLOSE)
    }

    ; GET#lfn, v$  -- read one byte from a channel into a string variable ("" at end of file / null byte)
    sub parse_get() {
        next_token()
        if tok != T_HASH {                      ; only GET# (from a channel) is supported, not plain GET
            error(E_SYNTAX)
            return
        }
        next_token()
        parse_expr()                            ; logical file number -> numeric stack
        if tok != T_COMMA {
            error(E_SYNTAX)
            return
        }
        next_token()
        if tok != T_STRVAR {
            error(E_SYNTAX)
            return
        }
        ubyte gslot = intern_svar()
        next_token()
        emit_byte(pcode.OP_GETCH)               ; pop lfn, push the 0/1-char string
        emit_byte(pcode.OP_STORS)
        emit_imm16(gslot as uword)
    }

    ; PRINT#lfn [, item ; item ...]  -- redirect PRINT output to a channel, then restore default I/O
    sub parse_printch() {
        next_token()
        parse_expr()                            ; logical file number
        emit_byte(pcode.OP_CHKOUT)              ; redirect output to the channel (pops lfn)
        if tok == T_COMMA or tok == T_SEMI
            next_token()                        ; the separator after lfn is syntax, not a printed item
        print_items()                           ; the items (+ trailing CR) go to the channel
        emit_byte(pcode.OP_CLRCH)               ; restore default I/O
    }

    ; push an empty string literal "" onto the string stack (used as OPEN's default filename)
    sub push_empty_string() {
        tokstr[0] = 0
        emit_byte(pcode.OP_PUSHS)
        emit_imm16(store_literal())
    }

    ; DIM name(d0[,d1..]) [, name(...)]*  -- allocate 1-D or N-D arrays; a '$'-suffixed name is a
    ; string array. Each dimension d is a max index, so the runtime reserves d+1 elements along it.
    sub parse_dim() {
        next_token()
        repeat {
            ubyte dkind = 0                     ; 0 = float array, 1 = string array, 2 = integer array
            ubyte dslot
            if tok == T_STRVAR {
                dkind = 1
                dslot = intern_sarr()
            } else if tok == T_IVAR {
                dkind = 2                        ; DIM A%(..) -> integer array (GPC extension)
                dslot = intern_iarr()
            } else {
                if tok == T_IDENT {
                    dslot = intern_arr()
                } else {
                    error(E_SYNTAX)
                    return
                }
            }
            next_token()
            if tok != T_LPAREN {
                error(E_SYNTAX)
                return
            }
            next_token()                        ; consume '('
            ubyte nd = read_subscripts()        ; push each dimension's size, consume through ')'
            if had_error
                return
            when dkind {
                1 -> emit_byte(pcode.OP_SDIM)
                2 -> emit_byte(pcode.OP_IDIM)
                else -> emit_byte(pcode.OP_DIM)
            }
            emit_imm16(dslot as uword)
            emit_byte(nd)                       ; number of dimensions
            if tok != T_COMMA
                break                           ; done, or another DIM item follows
            next_token()
        }
    }

    ; parse an expression that ends at the matching ')' we already consumed the '(' for,
    ; leaving that ')' as the current token (see expr_stop_rparen)
    sub parse_index() {
        expr_stop_rparen = true
        parse_expr()
    }

    ; INPUT ["prompt";] var   -- read a line from the keyboard into a numeric or string variable
    sub parse_input() {
        next_token()
        if tok == T_STRLIT {                    ; optional prompt string, printed before reading
            emit_byte(pcode.OP_PUSHS)
            emit_imm16(store_literal())
            emit_byte(pcode.OP_PRINTS)
            next_token()
            if tok == T_SEMI
                next_token()
        }
        if tok == T_STRVAR {
            emit_byte(pcode.OP_INPUTS)
            emit_imm16(intern_svar() as uword)
            next_token()
        } else {
            if tok == T_IDENT {
                emit_byte(pcode.OP_INPUTV)
                emit_imm16(intern_var() as uword)
                next_token()
            } else {
                error(E_SYNTAX)
            }
        }
    }

    ; DATA const, const, ...  -- declares constants; emits NO code. Items are collected in line
    ; order into the data pool as raw null-terminated text (numbers and strings alike), which READ
    ; parses on demand -- exactly the classic BASIC model. We scan the raw line here (bypassing the
    ; lexer's number parsing) so a numeric item keeps its original text for VAL-style parsing.
    sub parse_data() {
        repeat {
            while @(sptr) == ' '                        ; skip leading spaces
                sptr++
            ubyte c = @(sptr)
            if c == 0 or c == ':'
                break                                   ; end of the DATA statement
            ubyte n = 0
            if c == '"' {                               ; quoted item: the text between the quotes
                sptr++
                c = @(sptr)
                while c != 0 and c != '"' {
                    if n < 63 {
                        tokstr[n] = c
                        n++
                    }
                    sptr++
                    c = @(sptr)
                }
                if c == '"'
                    sptr++
            } else {                                    ; bare item: up to ',' / ':' / end, right-trimmed
                while c != 0 and c != ',' and c != ':' {
                    if n < 63 {
                        tokstr[n] = c
                        n++
                    }
                    sptr++
                    c = @(sptr)
                }
                while n != 0 and tokstr[n-1] == ' '
                    n--
            }
            tokstr[n] = 0
            store_data()                                ; append tokstr to the data pool
            while @(sptr) == ' '
                sptr++
            if @(sptr) != ',' {
                break
            }
            sptr++                                      ; comma: another item follows
        }
        next_token()                                    ; resync the lexer (now at ':' or end-of-line)
    }

    ; append the null-terminated item currently in tokstr to the data pool
    sub store_data() {
        uword need = strings.length(&tokstr) as uword
        need++                                          ; the terminating null
        if data_len + need > DATA_SIZE {
            error(E_MEM)
            return
        }
        ubyte n = strings.copy(&tokstr, datapool_ptr + data_len)
        data_len += n
        data_len++
    }

    ; READ target (, target)*  -- consume the next DATA item(s) into scalar variables OR array
    ; elements. An array target (name followed by '(') pushes its subscripts, then a push-variant
    ; reads the next DATA item onto the stack, then an array-store writes it -- exactly the pieces
    ; the compiler already emits for A(i)=... , just with the value coming from DATA.
    sub parse_read() {
        next_token()
        repeat {
            if tok == T_STRVAR {
                void strings.copy(&tokname, &pend_name)         ; peek for '(': element vs scalar
                next_token()
                if tok == T_LPAREN {
                    void strings.copy(&pend_name, &tokname)
                    ubyte saslot = intern_sarr()
                    next_token()                                ; consume '('
                    ubyte snd = read_subscripts()               ; push subscripts, consume through ')'
                    emit_byte(pcode.OP_RDSTR)                   ; next DATA item -> string stack
                    emit_byte(pcode.OP_SASTORE)                ; store into the element
                    emit_imm16(saslot as uword)
                    emit_byte(snd)
                } else {
                    void strings.copy(&pend_name, &tokname)
                    emit_byte(pcode.OP_READS)
                    emit_imm16(intern_svar() as uword)          ; scalar string var (tok already advanced)
                }
            } else {
                if tok == T_IDENT {
                    void strings.copy(&tokname, &pend_name)      ; peek for '(': element vs scalar
                    next_token()
                    if tok == T_LPAREN {
                        void strings.copy(&pend_name, &tokname)
                        ubyte aslot = intern_arr()
                        next_token()                            ; consume '('
                        ubyte nd = read_subscripts()            ; push subscripts, consume through ')'
                        emit_byte(pcode.OP_RDNUM)              ; next DATA item -> numeric stack
                        emit_byte(pcode.OP_ASTORE)            ; store into the element
                        emit_imm16(aslot as uword)
                        emit_byte(nd)
                    } else {
                        void strings.copy(&pend_name, &tokname)
                        emit_byte(pcode.OP_READ)
                        emit_imm16(intern_var() as uword)       ; scalar numeric var (tok already advanced)
                    }
                } else {
                    error(E_SYNTAX)
                    return
                }
            }
            if had_error
                return
            if tok != T_COMMA
                break
            next_token()
        }
    }

    ; parse a subscript list after its '(' has been consumed, up to and INCLUDING the ')', pushing
    ; each subscript's value; return the count and leave tok just past ')'. Statement context only
    ; (DIM/READ do not re-enter parse_expr the way the expression parser must guard against).
    sub read_subscripts() -> ubyte {
        ubyte n = 0
        repeat {
            parse_index()
            n++
            if had_error
                return n
            if tok != T_COMMA
                break
            next_token()
        }
        if tok != T_RPAREN {
            error(E_SYNTAX)
            return n
        }
        next_token()                                            ; consume ')'
        return n
    }

    ; RESTORE  -- rewind the DATA cursor to the first item (no-argument, CBM V2 form)
    sub parse_restore() {
        emit_byte(pcode.OP_RESTORE)
        next_token()
    }

    ; FOR ident "=" start TO limit [STEP step]   (ident may be a `%` integer var -> a native integer FOR)
    ; runtime stack layout for (I)FORPUSH: push limit, then step (popped step-first)
    sub parse_for() {
        next_token()
        bool is_int = tok == T_IVAR             ; FOR I%=.. : integer counter (GPC extension; V2 rejects it)
        ubyte slot
        if is_int {
            slot = intern_ivar()
        } else if tok == T_IDENT {
            slot = intern_var()
        } else {
            error(E_SYNTAX)
            return
        }
        next_token()
        if tok != T_EQ {
            error(E_SYNTAX)
            return
        }
        next_token()
        for_operand(is_int)                     ; start value
        if is_int
            emit_byte(pcode.OP_ISTORV)          ; ... into the integer loop variable
        else
            emit_byte(pcode.OP_STORV)           ; ... into the float loop variable
        emit_imm16(slot as uword)
        if tok != T_TO {
            error(E_SYNTAX)
            return
        }
        next_token()
        for_operand(is_int)                     ; limit -> left on the stack
        if tok == T_STEP {
            next_token()
            for_operand(is_int)                 ; step -> on top of limit
        } else {
            if is_int
                emit_byte(pcode.OP_IPUSHI)      ; default STEP 1
            else
                emit_byte(pcode.OP_PUSHI)
            emit_imm16(1)
        }
        if is_int
            emit_byte(pcode.OP_IFORPUSH)
        else
            emit_byte(pcode.OP_FORPUSH)
        emit_imm16(slot as uword)
        if for_depth == MAXFOR {
            error(E_MEM)
            return
        }
        for_slots[for_depth] = slot
        for_is_int[for_depth] = is_int
        for_depth++
    }

    ; parse one FOR sub-expression (start / limit / step); an integer FOR truncates a float bound to int
    sub for_operand(bool is_int) {
        if is_int {
            expr_keep_int = true
            parse_expr()
            if expr_type == TY_FLOAT
                emit_byte(pcode.OP_FTOI)        ; a float bound truncates toward zero into the int counter
        } else {
            parse_expr()
        }
    }

    ; NEXT [ident]   -- steps the innermost FOR (the VM tracks the frame). The counter's kind (int/float)
    ; is known from the open FOR, so the matching integer or float NEXT opcode is emitted.
    sub parse_next() {
        next_token()
        if for_depth == 0 {
            error(E_NEXT)
            return
        }
        for_depth--
        if for_is_int[for_depth] {
            if tok == T_IVAR {                  ; optional counter: must match the open integer FOR
                if intern_ivar() != for_slots[for_depth]
                    error(E_NEXT)
                next_token()
            }
            emit_byte(pcode.OP_IFORNEXT)
        } else {
            if tok == T_IDENT {                 ; optional variable: must match the open FOR
                if intern_var() != for_slots[for_depth]
                    error(E_NEXT)
                next_token()
            }
            emit_byte(pcode.OP_FORNEXT)
        }
    }

    sub parse_gosub() {
        next_token()
        if tok != T_NUM {
            error(E_SYNTAX)
            return
        }
        emit_jump(pcode.OP_GOSUB, tok_num as uword)
        next_token()
    }

    ; ON expr GOTO n1,n2,...   /   ON expr GOSUB n1,n2,...
    ; Desugars to: eval selector -> INT -> scratch slot, then a compare chain. For each k-th target:
    ;   LOADV scratch; PUSHI k; CMPEQ; JZ skip; <JMP nk | GOSUB nk; JMP end>; skip:
    ; A GOTO leaves permanently (no end-jump needed); a GOSUB returns, so it JMPs past the rest.
    ; Out-of-range selector falls through, exactly like ROM BASIC.
    sub parse_on() {
        next_token()                                ; consume ON
        parse_expr()                                ; the selector value
        emit_byte(pcode.OP_CALLFN)                  ; ON uses the integer part of the selector
        emit_byte(pcode.FN_INT)
        emit_byte(pcode.OP_STORV)
        emit_imm16(SCRATCH_SLOT as uword)
        bool is_gosub = false
        if tok == T_GOSUB {
            is_gosub = true
        } else if tok != T_GOTO {
            error(E_SYNTAX)
            return
        }
        next_token()                                ; consume GOTO / GOSUB
        uword[MAXFNS] endpatch                       ; reuse a modest cap for the GOSUB end-jumps
        ubyte nend = 0
        ubyte idx = 1
        repeat {
            if tok != T_NUM {
                error(E_SYNTAX)
                return
            }
            uword linek = tok_num as uword
            next_token()
            emit_byte(pcode.OP_LOADV)
            emit_imm16(SCRATCH_SLOT as uword)
            emit_byte(pcode.OP_PUSHI)
            emit_imm16(idx as uword)
            emit_byte(pcode.OP_CMPEQ)
            emit_byte(pcode.OP_JZ)
            uword skip_patch = code_len
            emit_imm16(0)
            if is_gosub {
                emit_jump(pcode.OP_GOSUB, linek)
                emit_byte(pcode.OP_JMP)             ; after the sub returns, skip the remaining cases
                if nend == MAXFNS {
                    error(E_COMPLEX)
                    return
                }
                endpatch[nend] = code_len
                nend++
                emit_imm16(0)
            } else {
                emit_jump(pcode.OP_JMP, linek)
            }
            if not had_error {
                pc_poke(skip_patch,     lsb(code_len))
                pc_poke(skip_patch + 1, msb(code_len))
            }
            if tok != T_COMMA
                break
            next_token()
            idx++
        }
        ubyte i = 0
        while i < nend {
            pc_poke(endpatch[i],     lsb(code_len))
            pc_poke(endpatch[i] + 1, msb(code_len))
            i++
        }
    }

    ; WAIT addr, mask [, xor]  -- spin until (peek(addr) XOR xor) AND mask is nonzero. Default xor=0.
    sub parse_wait() {
        next_token()                                ; consume WAIT
        parse_expr()                                ; address
        if tok != T_COMMA {
            error(E_SYNTAX)
            return
        }
        next_token()
        parse_expr()                                ; mask
        if tok == T_COMMA {
            next_token()
            parse_expr()                            ; optional xor
        } else {
            emit_byte(pcode.OP_PUSHI)               ; default xor = 0
            emit_imm16(0)
        }
        emit_byte(pcode.OP_WAIT)
    }

    ; DEF FN name(param) = expr  -- define a user function. Emits the body inline, jumped over during
    ; normal flow; a later FN call binds the argument into `param` and GOSUBs the body (see parse_expr).
    sub parse_def() {
        next_token()                                ; consume DEF
        if tok != T_FN {
            error(E_SYNTAX)
            return
        }
        next_token()                                ; consume FN
        if tok != T_IDENT {
            error(E_SYNTAX)
            return
        }
        ubyte fslot = intern_fn()                   ; function name -> table slot
        next_token()
        if tok != T_LPAREN {
            error(E_SYNTAX)
            return
        }
        next_token()
        if tok != T_IDENT {
            error(E_SYNTAX)
            return
        }
        ubyte pslot = intern_var()                  ; the parameter's numeric var slot
        next_token()
        if tok != T_RPAREN {
            error(E_SYNTAX)
            return
        }
        next_token()
        if tok != T_EQ {
            error(E_SYNTAX)
            return
        }
        next_token()
        emit_byte(pcode.OP_JMP)                     ; skip the body during straight-line execution
        uword over_patch = code_len
        emit_imm16(0)
        uword entry = code_len
        parse_expr()                                ; the body (leaves its result on the stack)
        emit_byte(pcode.OP_RET)
        if not had_error {
            pc_poke(over_patch,     lsb(code_len))
            pc_poke(over_patch + 1, msb(code_len))
            fn_entry[fslot] = entry
            fn_param[fslot] = pslot
        }
    }

    sub intern_fn() -> ubyte {
        cx16.rambank(NAMES_BANK)            ; fn names are banked; next emit/read re-asserts its bank
        ubyte i = 0
        while i < nfns {
            if strings.compare(&tokname, fn_ptr(i)) == 0
                return i
            i++
        }
        if nfns == MAXFNS {
            error(E_MEM)
            return 0
        }
        void strings.copy(&tokname, fn_ptr(nfns))
        nfns++
        return nfns - 1
    }

    ; find a defined function by the name in `tokname`; $ff if undefined (FN used before its DEF)
    sub lookup_fn() -> ubyte {
        cx16.rambank(NAMES_BANK)            ; fn names are banked; next emit/read re-asserts its bank
        ubyte i = 0
        while i < nfns {
            if strings.compare(&tokname, fn_ptr(i)) == 0
                return i
            i++
        }
        return $ff
    }

    sub fn_ptr(ubyte idx) -> uword {
        return fnnames_bptr + (idx as uword) * NAMELEN
    }

    ; the body after THEN. Nested "IF a THEN IF b THEN body" is handled by parse_if's
    ; guard loop (not here), so a leading IF never reaches this dispatch.
    sub parse_then_body() {
        when tok {
            T_NUM -> {                          ; IF cond THEN <linenum>  ==  GOTO linenum
                emit_jump(pcode.OP_JMP, tok_num as uword)
                next_token()
            }
            T_GOTO -> parse_goto()
            T_GOSUB -> parse_gosub()
            T_PRINT -> parse_print()
            T_POKE -> parse_poke()
            T_SYS -> parse_sys()
            T_READ -> parse_read()
            T_RESTORE -> parse_restore()
            T_LET -> {
                next_token()
                parse_assign()
            }
            T_IDENT -> parse_assign()
            T_STRVAR -> parse_assign()
            T_IVAR -> parse_assign()
            T_RETURN -> {
                emit_byte(pcode.OP_RET)
                next_token()
            }
            T_END -> {
                emit_byte(pcode.OP_END)
                next_token()
            }
            T_STOP -> {                             ; IF cond THEN STOP
                emit_byte(pcode.OP_END)
                next_token()
            }
            T_ON -> parse_on()                      ; IF cond THEN ON x GOTO ...
            else -> error(E_SYNTAX)
        }
    }

    sub parse_goto() {
        next_token()                            ; expect a line number
        if tok != T_NUM {
            error(E_SYNTAX)
            return
        }
        emit_jump(pcode.OP_JMP, tok_num as uword)
        next_token()
    }

    ; IF expr THEN body  --  emit a guard JZ per leading IF, then the THEN body. The guards
    ; are NOT backpatched here: a false condition must skip the whole rest of the LINE (CBM V2),
    ; so each guard's operand slot is appended to if_line_patch[] and the line loop backpatches
    ; them all to end-of-line. This makes both "IF a THEN IF b THEN body" (nested, handled by the
    ; loop below without recursion -- Prog8 has none) and "IF a THEN .. : IF b THEN .." (colon-
    ; separated, each a fresh parse_if that just appends more guards) fold into the same target.
    sub parse_if() {
        next_token()                            ; consume the (outer) IF
        repeat {
            uword before = code_len
            expr_keep_int = true                ; keep an integer condition raw so we can branch with IJZ
            parse_expr()
            if code_len == before {
                error(E_SYNTAX)
                return
            }
            ; the condition is followed by THEN, or the classic "IF cond GOTO n" shorthand (== THEN GOTO n).
            if tok == T_THEN {
                next_token()
            } else {
                if tok != T_GOTO {
                    error(E_SYNTAX)
                    return
                }
                ; leave the GOTO as the current token; parse_then_body parses it as the THEN body
            }
            if is_intish(expr_type)             ; integer condition -> branch off the int stack
                emit_byte(pcode.OP_IJZ)
            else
                emit_byte(pcode.OP_JZ)
            if n_if_line == MAXIFLINE {          ; too many IF guards on one line
                error(E_SYNTAX)
                return
            }
            if_line_patch[n_if_line] = code_len ; operand slot; the line loop backpatches to end-of-line
            n_if_line++
            emit_imm16(0)
            ; another IF right after THEN? -> nested guard; consume it and loop for its condition.
            if tok != T_IF
                break
            next_token()                        ; consume the nested IF
        }
        parse_then_body()
    }

    ; ---- line map + forward-reference fixups ----

    ; emit a jump whose operand is the pcode address of a BASIC line: backward
    ; targets resolve now, forward targets get a placeholder + a pass-2 fixup.
    sub emit_jump(ubyte opcode, uword target_line) {
        emit_byte(opcode)
        uword addr = find_line_addr(target_line)
        if addr == $ffff {
            add_fixup(code_len, target_line)
            emit_imm16(0)
        } else {
            emit_imm16(addr)
        }
    }

    sub record_line(uword num, uword addr) {
        if nlines == MAXLINES {
            error(E_MEM)
            return
        }
        cx16.rambank(NAMES_BANK)                ; line map is banked; next emit/read re-asserts its bank
        pokew(linenums_ptr  + (nlines as uword) * 2, num)
        pokew(lineaddrs_ptr + (nlines as uword) * 2, addr)
        nlines++
    }

    sub find_line_addr(uword num) -> uword {
        cx16.rambank(NAMES_BANK)                ; line map is banked; caller re-asserts its bank on the next emit
        ubyte i = 0
        while i < nlines {
            if peekw(linenums_ptr + (i as uword) * 2) == num
                return peekw(lineaddrs_ptr + (i as uword) * 2)
            i++
        }
        return $ffff
    }

    sub add_fixup(uword operand_addr, uword target_line) {
        if nfix == MAXFIX {
            error(E_MEM)
            return
        }
        fix_addr[nfix] = operand_addr
        fix_line[nfix] = target_line
        fix_srcline[nfix] = cur_line        ; remember where the GOTO/GOSUB was, for errors
        nfix++
    }

    ; pass 2: backpatch every forward reference now that all line addresses are known
    sub resolve_fixups() {
        ubyte i = 0
        while i < nfix {
            uword addr = find_line_addr(fix_line[i])
            if addr == $ffff {
                cur_line = fix_srcline[i]           ; report the line the bad ref lives on
                error(E_UNDEF)
            } else {
                pc_poke(fix_addr[i],     lsb(addr))
                pc_poke(fix_addr[i] + 1, msb(addr))
            }
            i++
        }
    }

    ; PRINT item (";"|"," item)* [";"|","]
    ; items are printed with no separators between them; a trailing ';'/',' suppresses
    ; the final newline. String items go through the string path, numbers through PRINTI.
    sub parse_print() {
        next_token()
        print_items()
    }

    ; emit the items of a PRINT / PRINT# from the current token to end-of-statement (';'/','
    ; separate items and suppress the trailing newline). Shared by PRINT and PRINT#.
    sub print_items() {
        bool suppress_nl = false
        repeat {
            if tok == T_EOL or tok == T_NEWLINE or tok == T_EOF {
                break
            }
            if tok == T_SEMI or tok == T_COMMA {
                suppress_nl = true
                next_token()
            } else {
                suppress_nl = false
                if is_str_start(tok) {
                    parse_string_expr()
                    if is_cmp(tok) {                    ; PRINT A$="X" prints the truth value, not the string
                        ubyte pcmp = cmp_id(tok)
                        next_token()
                        parse_string_expr()
                        emit_byte(pcode.OP_SCMP)
                        emit_byte(pcmp)
                        emit_byte(pcode.OP_PRINTI)
                    } else {
                        emit_byte(pcode.OP_PRINTS)
                    }
                } else {
                    uword before = code_len
                    parse_expr()
                    if code_len == before {
                        error(E_SYNTAX)
                        return
                    }
                    emit_byte(pcode.OP_PRINTI)
                }
            }
        }
        if not suppress_nl {
            emit_byte(pcode.OP_NEWLINE)
        }
    }

    ; assignment: numeric  ident "=" expr   or   string  ident$ "=" string_expr   or  int  ident% "=" expr
    sub parse_assign() {
        if tok == T_IVAR {                          ; integer (`%`) variable assignment (Phase 5)
            void strings.copy(&tokname, &pend_name)
            next_token()
            if tok == T_LPAREN {                    ; A%(i)=v -> integer array element store
                void strings.copy(&pend_name, &tokname)
                ubyte iaslot = intern_iarr()
                next_token()                        ; consume '('
                ubyte ind = read_subscripts()       ; push subscripts (numeric), consume through ')'
                if had_error
                    return
                if tok != T_EQ {
                    error(E_SYNTAX)
                    return
                }
                next_token()
                expr_keep_int = true                ; keep the RHS int; coerce a float RHS below
                parse_expr()
                if expr_type == TY_FLOAT
                    emit_byte(pcode.OP_FTOI)        ; float RHS truncates toward zero into the int element
                emit_byte(pcode.OP_IASTORE)
                emit_imm16(iaslot as uword)
                emit_byte(ind)
                return
            }
            void strings.copy(&pend_name, &tokname)
            ubyte islot = intern_ivar()
            if tok != T_EQ {
                error(E_SYNTAX)
                return
            }
            next_token()
            uword ibefore = code_len
            expr_keep_int = true                    ; keep the RHS's raw type; coerce below if it's float
            parse_expr()
            if code_len == ibefore {                ; empty RHS: a string value is a type error, else syntax
                if is_str_start(tok)
                    error(E_TYPE)
                else
                    error(E_SYNTAX)
                return
            }
            if expr_type == TY_FLOAT
                emit_byte(pcode.OP_FTOI)            ; a float RHS truncates toward zero into the int var
            emit_byte(pcode.OP_ISTORV)
            emit_imm16(islot as uword)
            return
        }
        if tok == T_STRVAR {
            ; peek past the name: 'A$(' is a string-array element store, plain 'A$' is a scalar
            void strings.copy(&tokname, &pend_name)
            next_token()
            if tok == T_LPAREN {
                void strings.copy(&pend_name, &tokname)
                ubyte saslot = intern_sarr()
                next_token()                    ; consume '('
                ubyte snd = read_subscripts()   ; push subscripts, consume through ')'
                if had_error
                    return
                if tok != T_EQ {
                    error(E_SYNTAX)
                    return
                }
                next_token()
                parse_string_expr()             ; value string -> string stack (subscripts already numeric)
                emit_byte(pcode.OP_SASTORE)
                emit_imm16(saslot as uword)
                emit_byte(snd)
                return
            }
            void strings.copy(&pend_name, &tokname)   ; restore for the scalar case
            ubyte sslot = intern_svar()
            ; tok has already advanced past the string variable
            if tok != T_EQ {
                error(E_SYNTAX)
                return
            }
            next_token()
            parse_string_expr()
            emit_byte(pcode.OP_STORS)
            emit_imm16(sslot as uword)
            return
        }
        if tok != T_IDENT {
            error(E_SYNTAX)
            return
        }
        ; peek past the identifier: 'A(' is an array element store, plain 'A' is a scalar
        void strings.copy(&tokname, &pend_name)
        next_token()
        if tok == T_LPAREN {
            void strings.copy(&pend_name, &tokname)
            ubyte aslot = intern_arr()
            next_token()                        ; consume '('
            ubyte nd = read_subscripts()        ; push subscripts, consume through ')'
            if had_error
                return
            if tok != T_EQ {
                error(E_SYNTAX)
                return
            }
            next_token()
            parse_expr()                        ; value -> stack
            emit_byte(pcode.OP_ASTORE)
            emit_imm16(aslot as uword)
            emit_byte(nd)
            return
        }
        void strings.copy(&pend_name, &tokname)
        ubyte slot = intern_var()               ; tok already advanced past the identifier
        if tok != T_EQ {
            error(E_SYNTAX)
            return
        }
        next_token()
        uword before = code_len
        parse_expr()
        if code_len == before {
            ; a numeric variable assigned a string value is a type error, not syntax
            if is_str_start(tok) {
                error(E_TYPE)
            } else {
                error(E_SYNTAX)
            }
            return
        }
        emit_byte(pcode.OP_STORV)
        emit_imm16(slot as uword)
    }

    ; does this token begin a string-valued expression? (a literal, string var, or a
    ; string-producing function). Used to route PRINT items and to diagnose type errors.
    sub is_str_start(ubyte t) -> bool {
        return t == T_STRLIT or t == T_STRVAR or t == T_NSFUNC or t == T_STRSLICE or t == T_XSFUNC
    }

    ; is this token a relational operator? (used to spot a string comparison: strexpr <cmp> strexpr)
    sub is_cmp(ubyte t) -> bool {
        return t == T_EQ or t == T_LT or t == T_GT or t == T_LE or t == T_GE or t == T_NE
    }

    ; map a relational token to its OP_SCMP relation id (pcode.SC_*)
    sub cmp_id(ubyte t) -> ubyte {
        when t {
            T_EQ -> return pcode.SC_EQ
            T_NE -> return pcode.SC_NE
            T_LT -> return pcode.SC_LT
            T_GT -> return pcode.SC_GT
            T_LE -> return pcode.SC_LE
            T_GE -> return pcode.SC_GE
        }
        return pcode.SC_EQ
    }

    ; string_expr := string_factor ("+" string_factor)*   (concatenation)
    sub parse_string_expr() {
        emit_string_factor()
        while tok == T_PLUS {
            next_token()
            emit_string_factor()
            emit_byte(pcode.OP_CONCAT)
        }
    }

    sub emit_string_factor() {
        when tok {
            T_STRLIT -> {
                emit_byte(pcode.OP_PUSHS)
                emit_imm16(store_literal())
                next_token()
            }
            T_STRVAR -> {
                ; peek past the name: 'A$(' is a string-array element, plain 'A$' is a scalar
                void strings.copy(&tokname, &pend_name)
                next_token()
                if tok == T_LPAREN {
                    void strings.copy(&pend_name, &tokname)
                    ; A$(i,j,..): parse the subscript list here (each re-enters parse_expr), holding
                    ; the array slot + a running count on the frame stack, out of the nested parse's reach
                    if fr_sp == EXPRNEST {
                        error(E_COMPLEX)
                        return
                    }
                    fr_slot[fr_sp] = intern_sarr()
                    fr_nd[fr_sp] = 0
                    fr_sp++
                    next_token()                    ; consume '('
                    repeat {
                        parse_index()               ; subscript; stops at ',' or ')'
                        fr_nd[fr_sp-1]++
                        if had_error
                            return
                        if tok != T_COMMA
                            break
                        next_token()
                    }
                    fr_sp--
                    ubyte slslot = fr_slot[fr_sp]
                    ubyte slnd = fr_nd[fr_sp]
                    if tok != T_RPAREN {
                        error(E_SYNTAX)
                        return
                    }
                    next_token()                    ; consume ')'
                    emit_byte(pcode.OP_SALOAD)
                    emit_imm16(slslot as uword)
                    emit_byte(slnd)
                    type_popn(slnd)                 ; consumed slnd numeric subscripts (string result)
                } else {
                    void strings.copy(&pend_name, &tokname)   ; restore for the scalar case
                    emit_byte(pcode.OP_LOADS)
                    emit_imm16(intern_svar() as uword)
                    ; tok has already advanced past the string variable
                }
            }
            T_NSFUNC -> {                       ; CHR$(n) / STR$(n): numeric arg -> a string value
                if fr_sp == EXPRNEST {
                    error(E_COMPLEX)
                    return
                }
                fr_id[fr_sp] = tok_funcid       ; hold the fn id across the nested numeric parse
                fr_sp++
                next_token()                    ; consume the function keyword
                if tok != T_LPAREN {
                    error(E_SYNTAX)
                    return
                }
                next_token()                    ; consume '('
                parse_index()                   ; numeric argument, stops at ')' (re-enters parse_expr)
                ubyte nsid = fr_id[fr_sp - 1]
                fr_sp--
                if tok != T_RPAREN {
                    error(E_SYNTAX)
                    return
                }
                next_token()                    ; consume ')'
                emit_byte(pcode.OP_NUMSTR)
                emit_byte(nsid)
                type_popn(1)                    ; consumed one numeric arg (string result)
            }
            T_XSFUNC -> {                       ; HEX$(n)/BIN$(n) (1 arg) or RPT$(byte,count) (2 args) -> string
                ; All args are numeric; GPC evaluates each here and the runtime formats the computed
                ; values into a synthesized frmevl call (op_callxs). Mirrors the numeric T_XFUNC list
                ; parse: hold the sub-token + a running count on the frame stack across the nested parses.
                if fr_sp == EXPRNEST {
                    error(E_COMPLEX)
                    return
                }
                fr_id[fr_sp] = tok_funcid       ; the $CE sub-token ($D5/$D6/$DA)
                fr_nd[fr_sp] = 0                ; argument count
                fr_sp++
                next_token()                    ; consume the function keyword
                if tok != T_LPAREN {
                    error(E_SYNTAX)
                    return
                }
                next_token()                    ; consume '('
                repeat {
                    parse_index()               ; one numeric arg; stops at ',' or ')' (re-enters parse_expr)
                    fr_nd[fr_sp-1]++
                    if had_error
                        return
                    if tok != T_COMMA
                        break
                    next_token()
                }
                fr_sp--
                ubyte xssub = fr_id[fr_sp]
                ubyte xsn = fr_nd[fr_sp]
                if tok != T_RPAREN {
                    error(E_SYNTAX)
                    return
                }
                next_token()                    ; consume ')'
                ; arity: RPT$ ($DA) needs exactly 2 args; HEX$/BIN$ exactly 1
                if xssub == $da {
                    if xsn != 2 {
                        error(E_SYNTAX)
                        return
                    }
                } else {
                    if xsn != 1 {
                        error(E_SYNTAX)
                        return
                    }
                }
                emit_byte(pcode.OP_CALLXS)
                emit_byte(xssub)
                emit_byte(xsn)
                type_popn(xsn)                  ; consumed xsn numeric args (string result)
            }
            T_STRSLICE -> emit_slice()          ; LEFT$/RIGHT$/MID$
            else -> error(E_TYPE)
        }
    }

    ; LEFT$(s,n) / RIGHT$(s,n) / MID$(s,start[,len]): a string, then one or two numeric args.
    ; Emission order (source string, then the numbers) matches the VM's stack discipline; the
    ; 2-arg MID$ form supplies a default length of 255, which the runtime clamps to what's left.
    sub emit_slice() {
        ; the source string and the numeric args are all nested parses, so hold which slice
        ; this is (LEFT$/RIGHT$/MID$) on the frame stack rather than in a clobber-prone local.
        if fr_sp == EXPRNEST {
            error(E_COMPLEX)
            return
        }
        fr_id[fr_sp] = tok_funcid
        fr_sp++
        next_token()                            ; consume LEFT$/RIGHT$/MID$
        if tok != T_LPAREN {
            error(E_SYNTAX)
            return
        }
        next_token()                            ; consume '('
        parse_string_expr()                     ; the source string (may nest)
        if tok != T_COMMA {
            error(E_SYNTAX)
            return
        }
        next_token()                            ; consume ','
        parse_index()                           ; count (LEFT$/RIGHT$) or start (MID$); stops at ',' or ')'
        if fr_id[fr_sp - 1] == SL_MID {
            if tok == T_COMMA {
                next_token()
                parse_index()                   ; explicit length, stops at ')'
            } else {
                emit_byte(pcode.OP_PUSHI)       ; 2-arg MID$: default length = rest of string
                emit_imm16(255)
                type_push(TY_FLOAT)             ; keep the type stack mirrored (a numeric value was pushed)
            }
        }
        ubyte slid = fr_id[fr_sp - 1]
        fr_sp--
        if tok != T_RPAREN {
            error(E_SYNTAX)
            return
        }
        next_token()                            ; consume ')'
        ; each slice op consumes its numeric args (the string source is balanced by parse_string_expr)
        when slid {
            SL_LEFT  -> { emit_byte(pcode.OP_LEFTS)  type_popn(1) }
            SL_RIGHT -> { emit_byte(pcode.OP_RIGHTS) type_popn(1) }
            SL_MID   -> { emit_byte(pcode.OP_MIDS)   type_popn(2) }
        }
    }

    ; copy the current string literal (tokstr) into the pool; return its pool-relative
    ; OFFSET. OP_PUSHS stores the offset and the VM adds vm.litbase at run time, so the
    ; literal resolves correctly whether the pool sits in the compiler or in out.prg.
    sub store_literal() -> uword {
        uword need = strings.length(&tokstr) as uword
        need++                          ; room for the terminating null too
        if lit_len + need > LIT_SIZE {
            error(E_MEM)                ; literal pool full
            return 0                    ; safe offset; had_error aborts before running
        }
        uword off = lit_len             ; offset of this literal within the pool
        ubyte n = strings.copy(&tokstr, litpool_ptr + off)
        lit_len += n
        lit_len++                       ; the terminating null
        return off
    }

    ; string variable slot (separate namespace from numeric vars)
    sub intern_svar() -> ubyte {
        cx16.rambank(NAMES_BANK)            ; name tables live in banked RAM; next emit/read re-asserts its bank
        ubyte i = 0
        while i < nsvars {
            if strings.compare(&tokname, svar_ptr(i)) == 0
                return i
            i++
        }
        if nsvars == MAXSVARS {
            error(E_MEM)
            return 0
        }
        void strings.copy(&tokname, svar_ptr(nsvars))
        nsvars++
        return nsvars - 1
    }

    sub svar_ptr(ubyte idx) -> uword {
        return svarnames_ptr + (idx as uword) * NAMELEN
    }

    ; find the slot for the identifier currently in `tokname`, defining it if new
    sub intern_var() -> ubyte {
        cx16.rambank(NAMES_BANK)            ; name tables live in banked RAM; next emit/read re-asserts its bank
        ubyte i = 0
        while i < nvars {
            if strings.compare(&tokname, name_ptr(i)) == 0
                return i
            i++
        }
        if nvars == SCRATCH_SLOT {          ; slot 127 is reserved for the compiler (ON temp)
            error(E_MEM)
            return 0
        }
        void strings.copy(&tokname, name_ptr(nvars))
        nvars++
        return nvars - 1
    }

    sub name_ptr(ubyte idx) -> uword {
        return varnames_ptr + (idx as uword) * NAMELEN
    }

    ; slot for the integer (`%`) variable in `tokname` (name incl. '%'; its own namespace + VM storage)
    sub intern_ivar() -> ubyte {
        cx16.rambank(NAMES_BANK)            ; name tables live in banked RAM; next emit/read re-asserts its bank
        ubyte i = 0
        while i < niv {
            if strings.compare(&tokname, iname_ptr(i)) == 0
                return i
            i++
        }
        if niv == MAXIVARS {
            error(E_MEM)
            return 0
        }
        void strings.copy(&tokname, iname_ptr(niv))
        niv++
        return niv - 1
    }

    sub iname_ptr(ubyte idx) -> uword {
        return ivarnames_ptr + (idx as uword) * NAMELEN
    }

    ; --- compile-time type stack helpers (Phase 5 integer typing) ---
    sub is_intish(ubyte t) -> bool {
        return t == TY_INT or t == TY_ILIT
    }
    sub type_push(ubyte t) {
        if tsp == TSTACK_SIZE {
            error(E_COMPLEX)
            return
        }
        tstack[tsp] = t
        tsp++
    }
    sub type_pop() -> ubyte {
        if tsp == 0
            return TY_FLOAT                      ; defensive: desync -> treat as float (never on valid input)
        tsp--
        return tstack[tsp]
    }
    sub type_popn(ubyte n) {                     ; drop n operand types (an atom that consumes n values)
        while n != 0 and tsp != 0 {
            tsp--
            n--
        }
    }

    ; array slot for the identifier in `tokname` (separate namespace from scalars/strings)
    sub intern_arr() -> ubyte {
        cx16.rambank(NAMES_BANK)            ; name tables live in banked RAM; next emit/read re-asserts its bank
        ubyte i = 0
        while i < narr {
            if strings.compare(&tokname, arr_ptr(i)) == 0
                return i
            i++
        }
        if narr == MAXARRS {
            error(E_MEM)
            return 0
        }
        void strings.copy(&tokname, arr_ptr(narr))
        narr++
        return narr - 1
    }

    sub arr_ptr(ubyte idx) -> uword {
        return arrnames_ptr + (idx as uword) * NAMELEN
    }

    ; integer-array slot for the identifier in `tokname` (name includes the '%'; own namespace)
    sub intern_iarr() -> ubyte {
        cx16.rambank(NAMES_BANK)            ; name tables live in banked RAM; next emit/read re-asserts its bank
        ubyte i = 0
        while i < niarr {
            if strings.compare(&tokname, iarr_ptr(i)) == 0
                return i
            i++
        }
        if niarr == MAXIARRS {
            error(E_MEM)
            return 0
        }
        void strings.copy(&tokname, iarr_ptr(niarr))
        niarr++
        return niarr - 1
    }

    sub iarr_ptr(ubyte idx) -> uword {
        return iarrnames_ptr + (idx as uword) * NAMELEN
    }

    ; string-array slot for the identifier in `tokname` (name includes the '$'; own namespace)
    sub intern_sarr() -> ubyte {
        uses_sarr = true                    ; DIM A$()/A$(i) => this program needs the full runtime (sarr tier)
        cx16.rambank(NAMES_BANK)            ; name tables live in banked RAM; next emit/read re-asserts its bank
        ubyte i = 0
        while i < nsarr {
            if strings.compare(&tokname, sarr_ptr(i)) == 0
                return i
            i++
        }
        if nsarr == MAXSARRS {
            error(E_MEM)
            return 0
        }
        void strings.copy(&tokname, sarr_ptr(nsarr))
        nsarr++
        return nsarr - 1
    }

    sub sarr_ptr(ubyte idx) -> uword {
        return sarrnames_ptr + (idx as uword) * NAMELEN
    }

    ; --- shared expression-parser state ---
    ; The operator stack is a SINGLE global stack, not a per-call local, because parse_expr is
    ; re-entrant: a string function's argument is itself an expression, so the call graph loops
    ; parse_expr -> parse_string_expr -> parse_index -> parse_expr. With Prog8's static locals a
    ; private stack would be corrupted by the nested call; a shared stack with a per-invocation
    ; floor (mybase) is safe -- each level only ever pops down to the height it found on entry.
    const ubyte OPSTK_SIZE = 32                  ; 32 pending operators (33 nested '(' -> too complex)
    ubyte[OPSTK_SIZE] opstack                    ; operator tokens (shared across nesting)
    ubyte[OPSTK_SIZE] opslot                     ; parallel: fn id for T_FUNC (unused entry for T_PEEK)
    ubyte opsp                                   ; global operator-stack height

    ; A tiny frame stack that preserves the few scalars which must outlive a nested parse: the
    ; operator floor + stop-at-')' flag for parse_expr, and a held function sub-id for the string
    ; functions. Nesting past EXPRNEST is reported as FORMULA TOO COMPLEX rather than corrupting.
    const ubyte EXPRNEST = 10
    ubyte[EXPRNEST] fr_base                      ; parse_expr operator floor (opsp on entry)
    bool[EXPRNEST]  fr_stoprp                    ; parse_expr stop-at-')' flag
    ubyte[EXPRNEST] fr_id                        ; a held function sub-id (snid/nsid/slid)
    ubyte[EXPRNEST] fr_slot                      ; a held array slot across a nested subscript-list parse
    ubyte[EXPRNEST] fr_nd                        ; running subscript count of an array access
    ; parse_expr's type-stack base + keep-int flag ALSO outlive a nested parse: they are static locals
    ; that the recursive subscript/argument parse_expr overwrites, so every nested-parse site saves them
    ; here and restores them after (without this, an integer expression containing an array/func load
    ; mis-types its result -- the exit ITOF/type would use the inner parse's clobbered values).
    ubyte[EXPRNEST] fr_tbase                     ; saved parse_expr `tbase`
    bool[EXPRNEST]  fr_keepint                   ; saved parse_expr `keep_int`
    ubyte fr_sp                                  ; frame-stack pointer

    ; --- integer-first arithmetic (Phase 5): a compile-time TYPE STACK that mirrors the runtime numeric
    ;     stack. Each value atom pushes its type; emit_op pops operand types, decides integer vs float
    ;     opcodes, inserts coercions, and pushes the result type. TY_ILIT (integer literal <=32767) and
    ;     TY_INT (a `%` variable) are the two integer flavours; an integer op fires only when a real INT
    ;     is involved, so any program without `%` variables emits the same float semantics as before. ---
    const ubyte TY_FLOAT = 0                     ; value lives in the float stack cell
    const ubyte TY_INT   = 1                     ; value lives in the int cell, from a `%` variable
    const ubyte TY_ILIT  = 2                     ; integer literal (int cell) that may still go either way
    const ubyte TSTACK_SIZE = 32
    ubyte[TSTACK_SIZE] tstack                    ; type of each pending numeric value (mirrors the VM stack)
    ubyte tsp                                    ; type-stack height
    ubyte expr_type                              ; type of parse_expr's result (set at its exit)
    bool  expr_keep_int                          ; one-shot: caller wants the raw (maybe int) result, no auto-ITOF
    ubyte expr_depth                             ; parse_expr nesting depth (0 at a top-level call -> reset tsp)

    ; Shunting-yard expression parser. Iterative (Prog8 has no call stack, so no recursive
    ; descent): numbers emit PUSHI immediately, operators wait on the operator stack until a
    ; lower/equal-precedence operator or ')' flushes them. The postfix order this produces is
    ; exactly what the stack VM consumes. Re-entrant -- see the shared state above.
    sub parse_expr() {
        bool stop_rp = expr_stop_rparen             ; one-shot: stop at a top-level ')'
        expr_stop_rparen = false
        ; --- type-stack bookkeeping (Phase 5). A top-level call (depth 0) resets the type stack; nested
        ;     calls build on top. keep_int captures the caller's one-shot "don't auto-coerce" request. ---
        if expr_depth == 0
            tsp = 0
        expr_depth++
        ubyte tbase = tsp                           ; this expression's single result will land here
        bool keep_int = expr_keep_int
        expr_keep_int = false                       ; one-shot
        ubyte mybase = opsp                         ; my operators live at opstack[mybase..]
        bool expect_value = true                    ; true when a value/'('/unary-op may come next
        repeat {
            when tok {
                T_NUM -> {
                    if INTSUPPORT and tok_num >= 0 {  ; 0..32767: an integer literal (may combine with %)
                        emit_byte(pcode.OP_IPUSHI)
                        emit_imm16(tok_num as uword)
                        type_push(TY_ILIT)
                    } else {                         ; 32768..65535 wrapped -ve, or noint: a float literal.
                        emit_byte(pcode.OP_PUSHI)    ; OP_PUSHI pushes the UNSIGNED imm word as a float,
                        emit_imm16(tok_num as uword) ; so 0..65535 all land correctly on the float stack
                        type_push(TY_FLOAT)
                    }
                    expect_value = false
                    next_token()
                }
                T_FLOAT -> {
                    emit_byte(pcode.OP_PUSHF)
                    emit_float(tok_fnum)
                    type_push(TY_FLOAT)
                    expect_value = false
                    next_token()
                }
                T_IVAR -> {                          ; integer (`%`) variable: scalar load -> INT (Phase 5)
                    void strings.copy(&tokname, &pend_name)
                    next_token()
                    if tok == T_LPAREN {             ; A%(i,j,..): integer array element load -> INT
                        void strings.copy(&pend_name, &tokname)   ; restore name for intern
                        ; each subscript re-enters parse_expr; stash the operator floor + stop flag +
                        ; slot + count on the frame stack, out of the nested parse's reach (as OP_ALOAD does)
                        if fr_sp == EXPRNEST {
                            error(E_COMPLEX)
                            return
                        }
                        fr_base[fr_sp] = mybase
                        fr_stoprp[fr_sp] = stop_rp
                        fr_tbase[fr_sp] = tbase
                        fr_keepint[fr_sp] = keep_int
                        fr_slot[fr_sp] = intern_iarr()
                        fr_nd[fr_sp] = 0
                        fr_sp++
                        next_token()                              ; consume '('
                        repeat {
                            parse_index()                         ; one subscript; stops at ',' or ')'
                            fr_nd[fr_sp-1]++
                            if had_error
                                return
                            if tok != T_COMMA
                                break
                            next_token()
                        }
                        fr_sp--
                        mybase = fr_base[fr_sp]
                        stop_rp = fr_stoprp[fr_sp]
                        tbase = fr_tbase[fr_sp]
                        keep_int = fr_keepint[fr_sp]
                        ubyte iaslot = fr_slot[fr_sp]
                        ubyte indim = fr_nd[fr_sp]
                        if tok != T_RPAREN {
                            error(E_SYNTAX)
                            return
                        }
                        next_token()                              ; consume ')'
                        emit_byte(pcode.OP_IALOAD)
                        emit_imm16(iaslot as uword)
                        emit_byte(indim)
                        type_popn(indim)                          ; IALOAD consumes indim subscripts,
                        type_push(TY_INT)                         ; pushes one int element
                        expect_value = false
                    } else {
                        void strings.copy(&pend_name, &tokname)
                        emit_byte(pcode.OP_ILOADV)
                        emit_imm16(intern_ivar() as uword)
                        type_push(TY_INT)
                        expect_value = false
                        ; tok already advanced past the identifier
                    }
                }
                T_ST -> {                            ; ST: the KERNAL I/O status word (a read-only number)
                    emit_byte(pcode.OP_STATUS)
                    type_push(TY_FLOAT)
                    expect_value = false
                    next_token()
                }
                T_IDENT -> {
                    ; peek past the identifier: 'A(' is an array element, plain 'A' is a scalar
                    void strings.copy(&tokname, &pend_name)
                    next_token()
                    if tok == T_LPAREN {
                        void strings.copy(&pend_name, &tokname)   ; restore name for intern
                        ; A(i,j,..): parse the whole subscript list here and emit one OP_ALOAD. Each
                        ; subscript re-enters parse_expr, so stash my operator floor + stop flag + the
                        ; array slot + a running subscript count on the frame stack, out of its reach.
                        if fr_sp == EXPRNEST {
                            error(E_COMPLEX)
                            return
                        }
                        fr_base[fr_sp] = mybase
                        fr_stoprp[fr_sp] = stop_rp
                        fr_tbase[fr_sp] = tbase
                        fr_keepint[fr_sp] = keep_int
                        fr_slot[fr_sp] = intern_arr()
                        fr_nd[fr_sp] = 0
                        fr_sp++
                        next_token()                              ; consume '('
                        repeat {
                            parse_index()                         ; one subscript; stops at ',' or ')'
                            fr_nd[fr_sp-1]++
                            if had_error
                                return
                            if tok != T_COMMA
                                break
                            next_token()
                        }
                        fr_sp--
                        mybase = fr_base[fr_sp]
                        stop_rp = fr_stoprp[fr_sp]
                        tbase = fr_tbase[fr_sp]
                        keep_int = fr_keepint[fr_sp]
                        ubyte aslot = fr_slot[fr_sp]
                        ubyte ndim = fr_nd[fr_sp]
                        if tok != T_RPAREN {
                            error(E_SYNTAX)
                            return
                        }
                        next_token()                              ; consume ')'
                        emit_byte(pcode.OP_ALOAD)
                        emit_imm16(aslot as uword)
                        emit_byte(ndim)
                        type_popn(ndim)                           ; ALOAD consumes ndim subscripts,
                        type_push(TY_FLOAT)                       ; pushes one float element
                        expect_value = false
                    } else {
                        void strings.copy(&pend_name, &tokname)   ; restore name for intern
                        emit_byte(pcode.OP_LOADV)
                        emit_imm16(intern_var() as uword)
                        type_push(TY_FLOAT)
                        expect_value = false
                        ; tok already advanced past the identifier
                    }
                }
                T_PEEK, T_FUNC -> {                  ; PEEK(addr) / fn(x): unary prefix operators
                    if not expect_value {
                        error(E_SYNTAX)
                        return
                    }
                    if opsp == OPSTK_SIZE {
                        error(E_COMPLEX)
                        return
                    }
                    opslot[opsp] = tok_funcid        ; the fn id (unused when tok == T_PEEK)
                    opstack[opsp] = tok
                    opsp++
                    expect_value = true              ; the '(' expr ')' follows
                    next_token()
                }
                T_NOT -> {                           ; NOT: unary prefix logical operator (below comparisons)
                    if not expect_value {
                        error(E_SYNTAX)
                        return
                    }
                    if opsp == OPSTK_SIZE {
                        error(E_COMPLEX)
                        return
                    }
                    opstack[opsp] = T_NOT            ; pushed without flushing -> right-associative prefix
                    opsp++
                    expect_value = true              ; a value follows NOT
                    next_token()
                }
                T_SNFUNC -> {                        ; LEN/ASC/VAL: string arg -> a numeric value
                    ; the argument is a STRING expression, so this can't ride the operator stack
                    ; like fn(x) does; parse it inline and emit the crossing op as a value-atom.
                    ; parse_string_expr() below re-enters parse_expr, so stash the state it would
                    ; clobber (my floor, my stop flag, my fn id) on the frame stack first.
                    if not expect_value {
                        error(E_SYNTAX)
                        return
                    }
                    if fr_sp == EXPRNEST {
                        error(E_COMPLEX)
                        return
                    }
                    fr_base[fr_sp] = mybase
                    fr_stoprp[fr_sp] = stop_rp
                    fr_tbase[fr_sp] = tbase
                    fr_keepint[fr_sp] = keep_int
                    fr_id[fr_sp] = tok_funcid
                    fr_sp++
                    next_token()                     ; consume the function keyword
                    if tok != T_LPAREN {
                        error(E_SYNTAX)
                        return
                    }
                    next_token()                     ; consume '('
                    parse_string_expr()              ; the string argument (re-enters parse_expr)
                    fr_sp--
                    mybase = fr_base[fr_sp]
                    stop_rp = fr_stoprp[fr_sp]
                    tbase = fr_tbase[fr_sp]
                    keep_int = fr_keepint[fr_sp]
                    ubyte snid = fr_id[fr_sp]
                    if tok != T_RPAREN {
                        error(E_SYNTAX)
                        return
                    }
                    next_token()                     ; consume ')'
                    emit_byte(pcode.OP_STRNUM)
                    emit_byte(snid)
                    type_push(TY_FLOAT)              ; string arg is balanced by parse_string_expr; result is numeric
                    expect_value = false             ; a value now sits on the numeric stack
                }
                T_FN -> {                            ; FN name(arg): call a DEF FN user function
                    if not expect_value {
                        error(E_SYNTAX)
                        return
                    }
                    next_token()                     ; consume FN
                    if tok != T_IDENT {
                        error(E_SYNTAX)
                        return
                    }
                    ubyte fidx = lookup_fn()
                    if fidx == $ff {
                        error(E_UNDEF)               ; FN used before its DEF (textually)
                        return
                    }
                    next_token()
                    if tok != T_LPAREN {
                        error(E_SYNTAX)
                        return
                    }
                    ; the argument is a numeric expression; stash the state parse_index would clobber
                    if fr_sp == EXPRNEST {
                        error(E_COMPLEX)
                        return
                    }
                    fr_base[fr_sp] = mybase
                    fr_stoprp[fr_sp] = stop_rp
                    fr_tbase[fr_sp] = tbase
                    fr_keepint[fr_sp] = keep_int
                    fr_slot[fr_sp] = fidx
                    fr_sp++
                    next_token()                     ; consume '('
                    parse_index()                    ; the argument (stops at ')'); re-enters parse_expr
                    fr_sp--
                    mybase = fr_base[fr_sp]
                    stop_rp = fr_stoprp[fr_sp]
                    tbase = fr_tbase[fr_sp]
                    keep_int = fr_keepint[fr_sp]
                    ubyte f2 = fr_slot[fr_sp]
                    if had_error
                        return
                    if tok != T_RPAREN {
                        error(E_SYNTAX)
                        return
                    }
                    next_token()                     ; consume ')'
                    emit_byte(pcode.OP_STORV)        ; bind the argument into the parameter slot
                    emit_imm16(fn_param[f2] as uword)
                    emit_byte(pcode.OP_GOSUB)        ; run the body; RET leaves its result on the stack
                    emit_imm16(fn_entry[f2])
                    type_popn(1)                     ; STORV consumed the numeric arg; GOSUB result...
                    type_push(TY_FLOAT)              ; ...is a float on the stack
                    expect_value = false
                }
                T_XFUNC -> {                         ; X16 escape function: VPEEK/JOY/MX/... -> ROM at run time
                    ; Arguments are numeric, passed BY VALUE: GPC evaluates each here (its variables
                    ; aren't in BASIC's table, so the runtime must hand frmevl the computed values, not
                    ; the source). Emit each arg, count them, then OP_CALLX <sub-token> <argcount>. Zero
                    ; args (MX/MY/MB/MWHEEL) come with no parens. Mirrors the array-subscript list parse:
                    ; each arg re-enters parse_expr, so stash my floor/stop/sub-token/count on the frame.
                    if not expect_value {
                        error(E_SYNTAX)
                        return
                    }
                    ubyte xsub = tok_funcid          ; the $CE sub-token byte ($D0..)
                    next_token()                     ; consume the function token
                    ubyte xn = 0
                    if tok == T_LPAREN {
                        if fr_sp == EXPRNEST {
                            error(E_COMPLEX)
                            return
                        }
                        fr_base[fr_sp] = mybase
                        fr_stoprp[fr_sp] = stop_rp
                        fr_tbase[fr_sp] = tbase
                        fr_keepint[fr_sp] = keep_int
                        fr_slot[fr_sp] = xsub
                        fr_nd[fr_sp] = 0
                        fr_sp++
                        next_token()                 ; consume '('
                        repeat {
                            parse_index()            ; one numeric arg; stops at ',' or ')'
                            fr_nd[fr_sp-1]++
                            if had_error
                                return
                            if tok != T_COMMA
                                break
                            next_token()
                        }
                        fr_sp--
                        mybase = fr_base[fr_sp]
                        stop_rp = fr_stoprp[fr_sp]
                        tbase = fr_tbase[fr_sp]
                        keep_int = fr_keepint[fr_sp]
                        xsub = fr_slot[fr_sp]
                        xn = fr_nd[fr_sp]
                        if tok != T_RPAREN {
                            error(E_SYNTAX)
                            return
                        }
                        next_token()                 ; consume ')'
                        if xn > pcode.MAX_XARGS {
                            error(E_COMPLEX)         ; more args than the runtime's xargs buffer holds
                            return
                        }
                    }
                    emit_byte(pcode.OP_CALLX)
                    emit_byte(xsub)
                    emit_byte(xn)
                    type_popn(xn)                    ; CALLX consumed xn numeric args...
                    type_push(TY_FLOAT)              ; ...and left one float result
                    expect_value = false             ; a numeric value now sits on the stack
                }
                T_LPAREN -> {
                    if opsp == OPSTK_SIZE {
                        error(E_COMPLEX)
                        return
                    }
                    opstack[opsp] = T_LPAREN
                    opsp++
                    expect_value = true
                    next_token()
                }
                T_RPAREN -> {
                    while opsp != mybase and opstack[opsp-1] != T_LPAREN {
                        opsp--
                        emit_op(opstack[opsp], opslot[opsp])
                    }
                    if opsp == mybase {
                        if stop_rp
                            break                   ; this ')' closes an array index; leave it
                        error(E_SYNTAX)
                        return
                    }
                    opsp--                          ; discard the matching '('
                    expect_value = false
                    next_token()
                }
                T_PLUS, T_MINUS, T_STAR, T_SLASH, T_POW, T_EQ, T_LT, T_GT, T_LE, T_GE, T_NE, T_AND, T_OR -> {
                    ubyte thisop = tok
                    if expect_value {
                        ; operator in value position -> unary
                        if thisop == T_MINUS {
                            thisop = T_NEG          ; unary minus
                        } else {
                            error(E_SYNTAX)         ; ^ etc. cannot start a value
                            return
                        }
                    }
                    ubyte prec = op_prec(thisop)
                    ubyte popprec = prec
                    if thisop == T_POW {
                        popprec = prec + 1          ; right-associative: flush only STRICTLY higher precedence
                    }
                    while opsp != mybase and opstack[opsp-1] != T_LPAREN and op_prec(opstack[opsp-1]) >= popprec {
                        opsp--
                        emit_op(opstack[opsp], opslot[opsp])
                    }
                    if opsp == OPSTK_SIZE {
                        error(E_COMPLEX)
                        return
                    }
                    opstack[opsp] = thisop
                    opsp++
                    expect_value = true
                    next_token()
                }
                else -> {
                    ; a string factor here (value position, numeric context) begins a STRING COMPARISON:
                    ;   strexpr <cmp> strexpr -> a numeric truth value. Both sides are string exprs that
                    ;   re-enter parse_expr for any string-fn args, so stash my operator floor + stop flag
                    ;   + the relation id on the frame stack, where the nested parse can't clobber them.
                    if not (expect_value and is_str_start(tok)) {
                        break                       ; anything else ends the expression
                    }
                    if fr_sp == EXPRNEST {
                        error(E_COMPLEX)
                        return
                    }
                    fr_base[fr_sp] = mybase
                    fr_stoprp[fr_sp] = stop_rp
                    fr_tbase[fr_sp] = tbase
                    fr_keepint[fr_sp] = keep_int
                    fr_sp++
                    parse_string_expr()             ; left string operand
                    if not is_cmp(tok) {
                        error(E_TYPE)               ; a string with no relational operator in a numeric context
                        return
                    }
                    fr_id[fr_sp - 1] = cmp_id(tok)  ; hold the relation across the right operand's parse
                    next_token()
                    parse_string_expr()             ; right string operand
                    fr_sp--
                    mybase = fr_base[fr_sp]
                    stop_rp = fr_stoprp[fr_sp]
                    tbase = fr_tbase[fr_sp]
                    keep_int = fr_keepint[fr_sp]
                    emit_byte(pcode.OP_SCMP)
                    emit_byte(fr_id[fr_sp])
                    type_push(TY_FLOAT)             ; SCMP consumes two strings; result is a numeric truth value
                    expect_value = false            ; a numeric truth value now sits on the stack
                }
            }
        }
        while opsp != mybase {
            opsp--
            if opstack[opsp] == T_LPAREN {
                error(E_SYNTAX)
                return
            }
            emit_op(opstack[opsp], opslot[opsp])
        }
        ; --- type-stack epilogue (Phase 5): the result is the top of the type stack. Auto-coerce it to
        ;     float unless the caller wants the raw type (integer-variable assignment). Then collapse to a
        ;     single entry at tbase -- defensive against a miscount leaking across statements. ---
        if tsp > tbase
            expr_type = tstack[tsp-1]
        else
            expr_type = TY_FLOAT
        if not keep_int and is_intish(expr_type) {
            emit_byte(pcode.OP_ITOF)
            expr_type = TY_FLOAT
        }
        tstack[tbase] = expr_type
        tsp = tbase + 1
        expr_depth--
    }

    ; Emit one operator, choosing integer or float opcodes from the operand types on the compile-time
    ; type stack (Phase 5). Integer +,-,*,unary- fire only when a real INT (`%` var) is involved; two
    ; integer LITERALS fall to float, so `%`-free code is byte-for-byte value-identical to before. Any
    ; int operand feeding a float op is coerced (ITOF top / ITOF2 second-from-top) before the op.
    sub emit_op(ubyte op, ubyte slot) {
        ubyte t1                                   ; operand types (Prog8 locals are sub-scoped, declare once)
        ubyte t2
        when op {
            T_PLUS, T_MINUS, T_STAR -> {           ; integer-capable binary arithmetic
                t2 = type_pop()                    ; right operand (stack top)
                t1 = type_pop()                    ; left operand (second-from-top)
                if is_intish(t1) and is_intish(t2) and (t1 == TY_INT or t2 == TY_INT) {
                    when op {
                        T_PLUS  -> emit_byte(pcode.OP_IADD)
                        T_MINUS -> emit_byte(pcode.OP_ISUB)
                        T_STAR  -> emit_byte(pcode.OP_IMUL)
                    }
                    type_push(TY_INT)
                } else {
                    if is_intish(t1)  emit_byte(pcode.OP_ITOF2)   ; coerce left
                    if is_intish(t2)  emit_byte(pcode.OP_ITOF)    ; coerce right
                    when op {
                        T_PLUS  -> emit_byte(pcode.OP_ADD)
                        T_MINUS -> emit_byte(pcode.OP_SUB)
                        T_STAR  -> emit_byte(pcode.OP_MUL)
                    }
                    type_push(TY_FLOAT)
                }
            }
            T_NEG -> {                             ; unary negate: stays integer if the operand is
                t1 = type_pop()
                if is_intish(t1) {
                    emit_byte(pcode.OP_INEG)
                    type_push(t1)
                } else {
                    emit_byte(pcode.OP_NEG)
                    type_push(TY_FLOAT)
                }
            }
            T_PEEK -> {                            ; unary float ops: coerce an int operand first
                t1 = type_pop()
                if is_intish(t1)  emit_byte(pcode.OP_ITOF)
                emit_byte(pcode.OP_PEEK)
                type_push(TY_FLOAT)
            }
            T_FUNC -> {
                t1 = type_pop()
                if is_intish(t1)  emit_byte(pcode.OP_ITOF)
                emit_byte(pcode.OP_CALLFN)
                emit_byte(slot)
                type_push(TY_FLOAT)
            }
            T_NOT -> {                             ; unary logical: stays integer if the operand is
                t1 = type_pop()
                if is_intish(t1) {
                    emit_byte(pcode.OP_INOT)
                    type_push(t1)                  ; preserve the flavour (like INEG)
                } else {
                    emit_byte(pcode.OP_NOT)
                    type_push(TY_FLOAT)
                }
            }
            else -> {                              ; binary ops: /, ^, comparisons, AND, OR
                t2 = type_pop()
                t1 = type_pop()
                ubyte fop = pcode.OP_DIV            ; the float opcode for this operator
                when op {
                    T_SLASH -> fop = pcode.OP_DIV
                    T_POW   -> fop = pcode.OP_POW
                    T_EQ    -> fop = pcode.OP_CMPEQ
                    T_LT    -> fop = pcode.OP_CMPLT
                    T_GT    -> fop = pcode.OP_CMPGT
                    T_LE    -> fop = pcode.OP_CMPLE
                    T_GE    -> fop = pcode.OP_CMPGE
                    T_NE    -> fop = pcode.OP_CMPNE
                    T_AND   -> fop = pcode.OP_AND
                    T_OR    -> fop = pcode.OP_OR
                }
                ; comparisons + AND/OR (float opcodes 11..18, a contiguous block) go integer under the
                ; usual rule: both intish, >=1 real INT. The integer twin is a fixed opcode offset above
                ; the float one (CMP*: +66, AND/OR: +67), so no second cascade is needed. DIV/POW (9/62)
                ; are outside the block -> always float. Result of a compare/logic is an INT truth value.
                if fop >= pcode.OP_CMPEQ and fop <= pcode.OP_OR and is_intish(t1) and is_intish(t2) and (t1 == TY_INT or t2 == TY_INT) {
                    if fop <= pcode.OP_CMPGE
                        emit_byte(fop + (pcode.OP_ICMPEQ - pcode.OP_CMPEQ))
                    else
                        emit_byte(fop + (pcode.OP_IAND - pcode.OP_AND))
                    type_push(TY_INT)
                } else {
                    if is_intish(t1)  emit_byte(pcode.OP_ITOF2)
                    if is_intish(t2)  emit_byte(pcode.OP_ITOF)
                    emit_byte(fop)
                    type_push(TY_FLOAT)
                }
            }
        }
    }

    sub op_prec(ubyte op) -> ubyte {
        if op == T_POW
            return 8                ; power ^ : right-associative, binds tightest (above unary minus)
        if op == T_NEG or op == T_PEEK or op == T_FUNC
            return 7                ; unary arithmetic (negate / PEEK / fn) binds tightest
        if op == T_STAR or op == T_SLASH
            return 6
        if op == T_PLUS or op == T_MINUS
            return 5
        if op == T_EQ or op == T_LT or op == T_GT or op == T_LE or op == T_GE or op == T_NE
            return 4                ; relational operators
        if op == T_NOT
            return 3                ; unary logical NOT (binds looser than comparisons)
        if op == T_AND
            return 2
        return 1                    ; T_OR: lowest precedence
    }

    ; ---- emitter ----
    ; The pcode buffer is a CODE_SIZE slab (banked RAM would grow it further). Overflow is a
    ; clean OUT OF MEMORY rather than silent corruption.
    sub emit_byte(ubyte b) {
        if code_len >= CODE_CAP {
            error(E_MEM)
            return
        }
        pc_poke(code_len, b)
        code_len++
    }

    ; --- banked P-code access: the emitted P-code is addressed by a flat byte offset; 8 KB per bank,
    ;     so offset>>13 selects the bank (msb>>5) and offset & $1FFF the slot in the $A000 window.
    ;     The compiler only ever appends (emit_byte) or backpatches (pc_poke) -- it never reads the
    ;     P-code back during a compile -- so a random banked WRITE is all the emitter needs. ---
    sub pc_poke(uword off, ubyte b) {
        cx16.rambank(PCODE_BANK0 + (msb(off) >> 5))
        @(BRAM + (off & $1fff)) = b
    }
    sub pc_peek(uword off) -> ubyte {
        cx16.rambank(PCODE_BANK0 + (msb(off) >> 5))
        return @(BRAM + (off & $1fff))
    }
    ; copy `nbytes` of banked P-code down into a flat buffer, for an in-process run
    sub emit_imm16(uword v) {
        emit_byte(lsb(v))
        emit_byte(msb(v))
    }

    ; emit a 5-byte float constant (the ROM MFLPT bytes, as the VM's peekf will read them)
    sub emit_float(float f) {
        ubyte i
        for i in 0 to 4 {
            emit_byte(@(&f + i))
        }
    }

    ; Report a compile error in classic CBM form: "?<MSG> ERROR IN <line>".
    ; The first error wins (its category + line are latched for the mailbox); later
    ; cascade errors still print but don't overwrite it. Sets had_error so the driver
    ; unwinds and the VM is never run on broken pcode.
    sub error(ubyte ecode) {
        if err_code == 0 {
            err_code = ecode
            err_line = cur_line
        }
        ; Message text is LOWERCASE in source on purpose: the rest of the UI (banner, "compile
        ; failed", the prompts) is lowercase too, and GPC preserves the caller's charset/case mode
        ; (no_sysinit -- see start()). Uppercase-in-source letters render as PETSCII graphics in the
        ; mode most callers are in, so an uppercase error line came out garbled; lowercase matches the
        ; rest and renders as plain readable text (the ROM shows it in whatever case mode is active).
        txt.chrout('?')
        when ecode {
            E_SYNTAX  -> txt.print("syntax")
            E_UNDEF   -> txt.print("undef'd statement")
            E_TYPE    -> txt.print("type mismatch")
            E_MEM     -> txt.print("out of memory")
            E_NEXT    -> txt.print("next without for")
            E_COMPLEX -> txt.print("formula too complex")
            else      -> txt.print("file not found")
        }
        txt.print(" error in ")
        txt.print_uw(cur_line)
        txt.nl()
        had_error = true
    }

    ; ---- lexer over TOKENIZED BASIC ----
    ; Input is a tokenized program line (see the linked-list walk in compile()):
    ; keywords and operators are single bytes >= $80; numbers, variable names,
    ; string contents and the punctuation ( ) ; , : are ASCII.
    sub next_token() {
        ubyte c = @(sptr)
        while c == ' ' {                        ; skip spaces ($20)
            sptr++
            c = @(sptr)
        }
        tok_start = sptr                        ; first byte of this token (OP_PASSTHRU copies from here)
        if c == 0 {                             ; $00 terminates the line
            sptr++
            tok = T_NEWLINE
            return
        }
        if c == $8f {                           ; REM -> ignore the rest of the line
            while @(sptr) != 0 {
                sptr++
            }
            sptr++
            tok = T_NEWLINE
            return
        }
        if c >= $80 {                           ; a BASIC keyword / operator token
            sptr++
            if c == $ce {                       ; X16 escape token: $CE <sub>. In expression context
                ubyte esub = @(sptr)            ; only the FUNCTIONS ($D0..) are valid (statements are
                sptr++                          ; routed to OP_PASSTHRU at statement position instead).
                if is_xfunc(esub) {
                    tok = T_XFUNC               ; numeric-result function (VPEEK/JOY/...)
                    tok_funcid = esub
                } else if is_xsfunc(esub) {
                    tok = T_XSFUNC              ; string-returning function (HEX$/BIN$)
                    tok_funcid = esub
                } else {
                    tok = T_BAD                 ; a statement token / unsupported fn where a value is due
                }
                return
            }
            ubyte fid = func_id(c)              ; built-in function? (SGN/INT/ABS/SQR/...)
            if fid != $ff {
                tok = T_FUNC
                tok_funcid = fid
                return
            }
            ubyte sfid = str_func(c)            ; string function? (LEN/VAL/ASC/STR$/CHR$/LEFT$/...)
            if sfid != $ff {
                tok_funcid = sfid & $0f         ; low nibble = the SN_/NS_/SL_ sub-id
                when sfid & $f0 {               ; high nibble selects the token class
                    $00 -> tok = T_SNFUNC
                    $10 -> tok = T_NSFUNC
                    else -> tok = T_STRSLICE
                }
                return
            }
            tok = map_token(c)
            ; relational operators are stored as token pairs: <= is '<' '=', etc.
            if tok == T_LT {
                ubyte n2 = @(sptr)
                if n2 == $b2 {
                    sptr++
                    tok = T_LE
                } else {
                    if n2 == $b1 {
                        sptr++
                        tok = T_NE
                    }
                }
            } else {
                if tok == T_GT {
                    if @(sptr) == $b2 {
                        sptr++
                        tok = T_GE
                    }
                }
            }
            return
        }
        if c == ':' {
            sptr++
            tok = T_EOL
            return
        }
        if c == '"' {
            sptr++
            c = @(sptr)
            ubyte sn = 0
            while c != 0 and c != '"' and sn < 63 {
                tokstr[sn] = c
                sn++
                sptr++
                c = @(sptr)
            }
            tokstr[sn] = 0
            if c == '"' {
                sptr++                          ; consume the closing quote
            }
            tok = T_STRLIT
            return
        }
        if is_digit(c) {
            ; collect the literal; a '.' makes it a float (a second '.' ends the number)
            ubyte ni = 0
            bool isflt = false
            while (is_digit(c) or c == '.') and ni < 23 {
                if c == '.' {
                    if isflt
                        break
                    isflt = true
                }
                numbuf[ni] = c
                ni++
                sptr++
                c = @(sptr)
            }
            numbuf[ni] = 0
            if isflt {
                tok_fnum = floats.parse(&numbuf)
                tok = T_FLOAT
            } else {
                word n = 0
                ubyte di = 0
                while numbuf[di] != 0 {
                    n *= 10
                    n += (numbuf[di] - '0') as word
                    di++
                }
                tok_num = n
                tok = T_NUM
            }
            return
        }
        if is_alpha(c) {
            ubyte nlen = 0
            while (is_alpha(c) or is_digit(c)) and nlen < NAMELEN-1 {
                tokname[nlen] = c
                nlen++
                sptr++
                c = @(sptr)
            }
            if c == '$' {                       ; '$' suffix -> string variable
                if nlen < NAMELEN-1 {
                    tokname[nlen] = c
                    nlen++
                }
                sptr++
                tokname[nlen] = 0
                tok = T_STRVAR
                return
            }
            if c == '%' {                       ; '%' suffix -> integer variable (Phase 5)
                if nlen < NAMELEN-1 {
                    tokname[nlen] = c
                    nlen++
                }
                sptr++
                tokname[nlen] = 0
                if INTSUPPORT {
                    tok = T_IVAR
                } else {
                    tok = T_IDENT               ; noint build: `%` var degrades to a distinct float var
                }                               ; (name still carries the '%', so A% stays separate from A)
                return
            }
            tokname[nlen] = 0
            if nlen == 2 and tokname[0] == $53 and tokname[1] == $54 {
                tok = T_ST                      ; "ST" is reserved: the KERNAL I/O status word
                return
            }
            tok = T_IDENT                       ; keywords are tokens now; this is a variable
            return
        }
        ubyte optok = single_char_op(c)         ; ( ) ; ,  (not tokenized in the file)
        if optok != T_BAD {
            sptr++
            tok = optok
            return
        }
        sptr++
        tok = T_BAD
    }

    ; map a CBM/X16 BASIC token byte to our internal token
    sub map_token(ubyte c) -> ubyte {
        when c {
            $80 -> return T_END
            $90 -> return T_STOP            ; STOP  (C64 token; halt)
            $91 -> return T_ON              ; ON    (C64 token; computed GOTO/GOSUB)
            $92 -> return T_WAIT            ; WAIT  (C64 token)
            $96 -> return T_DEF             ; DEF   (C64 token; DEF FN)
            $a5 -> return T_FN              ; FN    (C64 token; user-function call)
            $ae -> return T_POW             ; ^     (C64 token; power operator)
            $81 -> return T_FOR
            $82 -> return T_NEXT
            $83 -> return T_DATA
            $87 -> return T_READ
            $8c -> return T_RESTORE
            $88 -> return T_LET
            $89 -> return T_GOTO
            $8b -> return T_IF
            $8d -> return T_GOSUB
            $85 -> return T_INPUT
            $86 -> return T_DIM
            $8e -> return T_RETURN
            $97 -> return T_POKE
            $99 -> return T_PRINT
            $9e -> return T_SYS
            $9f -> return T_OPEN
            $a0 -> return T_CLOSE
            $a1 -> return T_GET             ; GET / GET# (the '#' follows as a separate byte)
            $98 -> return T_PRINTCH         ; PRINT# is its own token (not PRINT + '#')
            $84 -> return T_INPUTCH         ; INPUT# is its own token
            $a4 -> return T_TO
            $a7 -> return T_THEN
            $a9 -> return T_STEP
            $a8 -> return T_NOT
            $af -> return T_AND
            $b0 -> return T_OR
            $aa -> return T_PLUS
            $ab -> return T_MINUS
            $ac -> return T_STAR
            $ad -> return T_SLASH
            $b1 -> return T_GT
            $b2 -> return T_EQ
            $b3 -> return T_LT
            $c2 -> return T_PEEK
        }
        return T_BAD
    }

    ; map a BASIC function-token byte to a VM function id (FN_*), or $ff if it isn't one
    sub func_id(ubyte c) -> ubyte {
        when c {
            $b4 -> return pcode.FN_SGN
            $b5 -> return pcode.FN_INT
            $b6 -> return pcode.FN_ABS
            $ba -> return pcode.FN_SQR
            $bb -> return pcode.FN_RND
            $bc -> return pcode.FN_LOG
            $bd -> return pcode.FN_EXP
            $be -> return pcode.FN_COS
            $bf -> return pcode.FN_SIN
            $c0 -> return pcode.FN_TAN
            $c1 -> return pcode.FN_ATN
        }
        return $ff
    }

    ; classify a string-function token byte, or $ff if it isn't one. The result packs the
    ; token class in the high nibble (0=T_SNFUNC, 1=T_NSFUNC, 2=T_STRSLICE) and the sub-id
    ; (SN_*/NS_*/SL_*) in the low nibble, so next_token() can set tok + tok_funcid in one step.
    sub str_func(ubyte c) -> ubyte {
        when c {
            $c3 -> return $00 | pcode.SN_LEN     ; LEN   -> T_SNFUNC
            $c5 -> return $00 | pcode.SN_VAL     ; VAL   -> T_SNFUNC
            $c6 -> return $00 | pcode.SN_ASC     ; ASC   -> T_SNFUNC
            $c4 -> return $10 | pcode.NS_STR     ; STR$  -> T_NSFUNC
            $c7 -> return $10 | pcode.NS_CHR     ; CHR$  -> T_NSFUNC
            $c8 -> return $20 | SL_LEFT          ; LEFT$ -> T_STRSLICE
            $c9 -> return $20 | SL_RIGHT         ; RIGHT$-> T_STRSLICE
            $ca -> return $20 | SL_MID           ; MID$  -> T_STRSLICE
        }
        return $ff
    }

    ; classify an X16 escape sub-token ($CE <sub>) as a supported expression FUNCTION. We accept only
    ; the numeric-result functions whose arguments are plain numbers passed by value (or that take no
    ; arguments), since OP_CALLX evaluates the args itself and reads back a numeric FAC. Deliberately
    ; NOT accepted: the string-returning HEX$/BIN$/RPT$ ($D5/$D6/$DA), and POINTER/STRPTR ($D8/$D9)
    ; which need a variable's address rather than its value; and the bannex TDATA/TATTR/MOD ($DC..$DE).
    ; Anything rejected here becomes T_BAD -> a clean SYNTAX error instead of a wrong-typed result.
    sub is_xfunc(ubyte s) -> bool {
        when s {
            $d0,        ; VPEEK(bank,addr)
            $d1, $d2, $d3,  ; MX / MY / MB          (no arguments)
            $d4,        ; JOY(n)
            $d7,        ; I2CPEEK(dev,addr)
            $db -> return true  ; MWHEEL             (no arguments)
        }
        return false
    }

    ; classify a $CE sub-token as a supported STRING-returning X16 function: HEX$($D5) / BIN$($D6),
    ; each taking one numeric arg, and RPT$($DA) = RPT$(<byte>,<count>) which repeats <byte> <count>
    ; times (two numeric args -- no string argument, per the ROM). All route through the string-
    ; expression parser -> OP_CALLXS, whose xbuild already formats N comma-separated numeric args.
    sub is_xsfunc(ubyte s) -> bool {
        return s == $d5 or s == $d6 or s == $da
    }

    sub single_char_op(ubyte c) -> ubyte {
        when c {
            '(' -> return T_LPAREN
            ')' -> return T_RPAREN
            ';' -> return T_SEMI
            ',' -> return T_COMMA
            '#' -> return T_HASH
        }
        return T_BAD
    }

    sub is_digit(ubyte c) -> bool {
        return c >= '0' and c <= '9'
    }

    sub is_alpha(ubyte c) -> bool {
        return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')
    }
}
