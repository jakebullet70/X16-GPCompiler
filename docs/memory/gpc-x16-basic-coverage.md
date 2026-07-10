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

Reality check: X16FONTS.PRG (a 492-line BASLOAD font editor: renumbered 1..492, full of $hex + TAB(/SPC(/
GET) failed on its FIRST code line before any fix. After the 7 lexer fixes + MOD/TAB/SPC/GET it compiles
through **line 129** and then hits err_code 4 (OUT OF MEMORY) — a CAPACITY ceiling, NOT a language gap.
Diagnosed (via the $0403 err-cat / $0404-5 err-line mailbox): it overflows the **16 KB P-code buffer
(CODE_CAP, gpc.p8 ~line 78, "2 x 8 KB banks")**. Ruled out the other E_MEM limits: only ~25 distinct vars
in lines 1..128 (SCRATCH_SLOT=127) and 113 total GOTO/GOSUB (MAXFIX=128 forward-refs). So the remaining
X16FONTS work is GROWING the P-code buffer (more banked RAM), a memory-layout change in [[gpc-project]]'s
locked-design territory — not more feature/lexer work. See [[gpc-project]] [[gpc-engine-shrink]].
