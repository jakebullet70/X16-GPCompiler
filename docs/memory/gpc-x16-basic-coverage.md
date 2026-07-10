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

**Still missing (NOT yet fixed) — expression-position functions that can't pass through:**
- COMMON: `TAB(` `SPC(` (PRINT formatting), `MOD` (X16, actively rejected ~gpc.p8:3166), plain `GET`
  (rejected ~gpc.p8:948 — only GET# is compiled).
- niche: `FRE` `POS` `USR` `POINTER` `STRPTR`, and the pi glyph constant.
These need parser/codegen work, not just the lexer.

**Correctly omitted (these WORK via OP_PASSTHRU to ROM):** all FM/PSG sound, sprites, VERA bitmap
graphics (SCREEN/LINE/RECT/...), VPOKE/TILE/VLOAD, BLOAD/BSAVE, tooling (LIST/MON/EXEC/BASLOAD/DOS).

Reality check: X16FONTS.PRG (a 662-line BASLOAD font editor, full of $hex) failed on its FIRST code
line (3) before the fix; after it, compiles through to line 45. It's a deep program and will surface
more gaps — but the systematic lexer blockers are closed. See [[gpc-project]] [[gpc-engine-shrink]].
