---
name: gpc-x16-basic-coverage
description: what GPC can/can't compile vs real X16 BASIC — lexer gaps (fixed) + remaining function gaps
metadata:
  type: project
---

A docs-driven audit (docs/x16/X16 Reference - 04 - BASIC.md vs gpc.p8, workflow x16-basic-gap-audit)
mapped where GPC fails on VALID ordinary X16 BASIC. Key framing: GPC's statement coverage is broad
because any unrecognized keyword-first statement becomes OP_PASSTHRU and is run by ROM BASIC at
runtime (parse_statement else-arm) — so CLS/COLOR/sound/sprites/VERA-graphics all effectively work.
The real gaps are only (a) the LEXER and (b) expression-position FUNCTIONS (which can't pass through,
being inside compiled expressions).

**7 lexer blockers — ALL FIXED (commit 36fb6e3), all in next_token():**
1. hex literals `$FF`/`$A000` — were ?SYNTAX ERROR. (single highest-impact: POKE/SYS/VPOKE addrs)
2. binary literals `%1010` — a leading `%` is a literal; the `A%` int-var SUFFIX is separate/unaffected.
3. leading-dot floats `.5`/`.01`.
4. decimal >= 65536 — SILENTLY WRAPPED mod 65536 (1000000 -> 16960); now routes to the float path.
5. scientific notation `9.2E5`.
6. identifiers > 7 chars — split into two tokens; now the over-long tail is drained (NAMELEN-1=7 significant).
7. reversed relationals `=< => ><` — CBM/X16 folds `< = >` in ANY order; all six orderings now recombine.
Hex/binary emit an ordinary T_NUM (reuse the existing literal path; works in full AND noint builds).
Added is_hexdigit/hexval. Tests: test.sh "M2b" block. NOTE: PRINT of a value >32767 leaves the
mailbox 0 by design (op_printi), so assert those via printed output, not the mailbox.

**4 common function/statement gaps — ALL FIXED (commit 8277fca):**
- `MOD(a,b)` — an X16 two-arg numeric function ($CE $DE). Just added $DE to is_xfunc: it rides the
  existing OP_CALLX/frmevl path (ROM evaluates it). This also FIXED a latent OP_CALLX bug for EVERY
  xfunc: a negative arg's sign was formatted as raw ASCII '-', which frmevl (reads TOKENS) can't parse
  as unary minus → it wedged. xbuild now emits the tokenized MINUS ($AB); the doc example MOD(-17,5) works.
- `TAB(` / `SPC(` — PRINT-context cursor control. New UNIVERSAL opcodes OP_TAB (93) / OP_SPC (94);
  handled in print_items via parse_index (the '(' is baked into the $A3/$A6 token). TAB reads the live
  cursor column via KERNAL PLOT ($FFF0); both take a 0..255 byte arg (clamp_byte).
- plain `GET var[,var...]` — new UNIVERSAL opcode OP_GETKEY (92): GETIN (non-blocking → ""/0 idle).
  String target → OP_STORS; numeric/int target → OP_STRNUM(VAL) [→ OP_FTOI/ISTORV]. GET# unchanged.
New opcodes sit AFTER op_iastore in _optab so the nosarr/noint strip ranges miss them (all tiers keep
them); dispatch gate raised to <95. tokenize.py learns TAB(/SPC(. Tests: test.sh MOD/TAB-SPC/GET blocks.

**Still missing — niche expression-position functions:** `FRE` `POS` `USR` `POINTER` `STRPTR`, and the
pi glyph constant. These need per-function parser/codegen work (POINTER/STRPTR need a var ADDRESS, not
its value, so OP_CALLX can't carry them). Low priority — rarely hit ordinary programs.

**Correctly omitted (these WORK via OP_PASSTHRU to ROM):** all FM/PSG sound, sprites, VERA bitmap
graphics (SCREEN/LINE/RECT/...), VPOKE/TILE/VLOAD, BLOAD/BSAVE, tooling (LIST/MON/EXEC/BASLOAD/DOS).

**X16FONTS.PRG campaign** (492-line BASLOAD font editor, renumbered 1..492, full of $hex + TAB(/SPC(/GET).
Progress via the $0403 err-cat / $0404-5 err-line mailbox, one capacity/gap ceiling at a time (commit 05eeb1b):
- line 129: **MAXLINES=128** line-number map (NOT CODE_CAP — I mis-diagnosed that first; growing CODE_CAP
  16->32 KB did NOT move line 129). Fixed: MAXLINES 128->512 (nlines/find_line_addr index -> uword, banked
  line-map pointers grow to 1 KB each). Also grew CODE_CAP 16->32 KB anyway (banks 7..10, NAMES_BANK 9->11).
- line 149: **IF..THEN + an X16 keyword** was ?SYNTAX (parse_then_body had no OP_PASSTHRU else-arm like
  parse_statement). Fixed: THEN routes unknown keyword-first stmts to pass-through; false guard still skips.
- line ~363: **LIT_SIZE=768** string-literal pool (X16FONTS totals 828 literal bytes; cumulative crosses
  768 at line 362). NOT yet fixed. Ruled out: ~25 vars (<127), 70 fwd-refs (<128 MAXFIX), 0 DATA.

**The wall (architectural, [[gpc-project]] locked-design territory):** litpool + datapool (768 B each) live
in the compiler's LOW RAM, which is EXHAUSTED — the self-hosted compiler leaves only ~1 KB (progend..MEMTOP
$9F00), and that same ~1 KB IS the in-process string heap. Growing litpool shrinks that heap, which spirals
the in-process string-GC stress tests smaller (already had to recalibrate them: 255-char ceiling + >255
overflow moved to the STANDALONE path, in-process kept at 180 concats). Even the uword MAXLINES code cost
~80 B of heap. So further X16FONTS progress needs the pools (and/or the in-process heap) MOVED to banked RAM
— a moderate vm.p8 + gpc.p8 change (make in-process litbase/database access bank-aware). NOTE: this heap
limit is an IN-PROCESS (testbench) artifact only — the interactive compiler + standalone output have the
whole free RAM. See [[gpc-project]] [[gpc-engine-shrink]].
