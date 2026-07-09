---
name: gpc-runtime-size-floor
description: Why the GPC runtime is near its size floor — 64tass .proc DCE, prog8 cx16 floats are already ROM wrappers
metadata:
  type: project
---

Investigated (2026-07-09) how much smaller the bundled VM runtime can get. Conclusions, all measured:

**64tass already dead-strips unreferenced `.proc` blocks.** prog8 emits library modules (`floats`,
`strings`, cx16 `syslib`, long-math like `sqrt_long`/`multiply_longs`/`func_sort_w`/`enable_irq_handlers`)
into the `.asm` even when unused, but 64tass omits any `.proc` whose label is unreferenced — it emits ZERO
bytes. So the `.asm` text is NOT the shipped binary. PROOF: deleting the 728-line unreferenced `strings`
block from the `.asm` and re-assembling gave a byte-identical `.prg`. A hand-written asm-DCE pass over the
`.asm` (tried, then deleted `scripts/dce-asm.py`) is therefore redundant and wins nothing.

**prog8's cx16 `floats` module is already thin ROM wrappers — there is no software-math bloat to convert.**
`floats.parse` = check for ROM VAL_1 ($FE09) then `jmp VAL_1`; `floats.tostr` = `jsr FOUT`($FE06)+trim;
`floats.floor` = `MOVFM`+`jmp INT`. The float ARITHMETIC handlers (op_add/sub/mul/div/neg/cmp*/pow/pushf/
callfn/itof) are ALREADY hand-asm calling the $FE00 ROM table directly. So "convert the floats to ROM" is
already done; an earlier report that called it a ~KB lever was WRONG. The only prog8 `sub`s left in the
float path are op_printi (~98 B) and op_ftoi (~21 B) — converting them saves only tens of bytes and sits
exactly in the historically bug-prone FOUT/word-cast path ([[gpc-print-large-number-bug]]). Not worth it.

**Standalone re-assembly recipe (validated byte-identical to prog8's own output):**
`64tass --ascii --case-sensitive --long-branch --cbm-prg -o out.prg file.asm` (the `--ascii` matters —
prog8 emits a `π` constant that fails without it).

**Real size levers that DID land** (see [[gpc-inc2-design]] / runtime-tiers branch): feature-tiered runtime
+ per-tier PCODE_BASE. A standalone `.PRG` floor is `PCODE_BASE - $0801`, so lowering the base is the only
thing that shrinks programs; shrinking runtime code below the base just grows filler. THREE tiers now, the
compiler auto-picks the lowest whose feature set covers `features_used`:
- core @ $1D00 (float/control/PRINT only; features_used==0)
- str  @ $2A20 (core + strings/bstr; features_used==FEAT_STR) -> strings-only program saves ~4.7 KB /
  ~18 blocks vs full (HELLO 13508->8804 B). String programs are common, so this hits the frequent case.
- full @ $3C80 (everything else)

Mechanism (build.sh `build_tier` helper): stub the tier's excluded opcodes in _optab -> _unimpl AND collapse
their asmsub bodies to `rts` (prog8 never DCEs `asmsub`s), which drops the footprint enough to claim a lower
PCODE_BASE; each tier's base is set empirically from its build's `prog8_program_end` (assert-pcode-base
guards it, needs >=256 B margin). Next rung would be +ARR (numeric arrays). Further shrink of a GIVEN tier
needs deep hand-asm of the dispatch/live handlers — diminishing returns. See [[gpc-runtime-asm-conversion]].
