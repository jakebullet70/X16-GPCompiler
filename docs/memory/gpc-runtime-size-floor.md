---
name: gpc-runtime-size-floor
description: GPC runtime size — the 6-tier subset-selected ladder, per-tier PCODE_BASE mechanism, and why the floor is where it is (64tass .proc DCE, ROM floats, no on-device linker)
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

**Real size levers that DID land** (see [[gpc-inc2-design]] / runtime-tiers branch, unmerged as of 2026-07-09):
feature-tiered runtime + per-tier PCODE_BASE. A standalone `.PRG` floor is `PCODE_BASE - $0801`, so lowering
the base is the ONLY thing that shrinks programs; shrinking runtime code below the base just grows filler.
SIX tiers now; the compiler tracks a `features_used` bitmask (STR=1 ARR=2 INT=4 X16=8 IO=$10 DATA=$20) and
picks by SUBSET selection — lowest-base tier whose feature SET covers the program (`features_used & ~mask == 0`),
checked ascending, so a multi-feature program is never left paying full price when a covering tier exists:
- core       @ $1D00  (float/control/PRINT only; features_used==0)         saves ~45 blk vs full
- arr        @ $2240  ({ARR} numeric arrays)                               saves ~26 blk
- str        @ $2A20  ({STR} strings/bstr)                                 saves ~18 blk (HELLO 13508->8804 B)
- arrstr     @ $2CA0  ({ARR,STR})                                          saves ~15 blk
- arrstrdata @ $2D60  (subset of {ARR,STR,DATA}; e.g. DATA-only lands here) saves ~15 blk
- full       @ $3C80  (anything using INT/X16/IO, or a wider mix)

Mechanism (build.sh `build_tier <name> <strip-regex> <keep-bstr> <base> [visual]` helper): stub the tier's
excluded opcodes in _optab -> _unimpl AND collapse their asmsub bodies to `rts` (prog8 never DCEs `asmsub`s),
which drops the footprint enough to claim a lower PCODE_BASE; each base is set empirically from that build's
`prog8_program_end` (assert-pcode-base guards it, ~280 B margin). To add a tier: new STRIP list (all optional
opcodes MINUS the feature's families) + build_tier call + a `*_PCODE_BASE` const + a subset branch in gpc.p8
write_output + stage its gpc.rt.<name>.bin in every harness (check-standalone/input/prompt, run, stage-demo,
test.sh). Remaining rungs would be INT/X16/IO — narrower audiences, natural place to stop.

**True per-program custom runtimes would need an on-device linker.** The runtime is ONE pre-linked 64tass
image: handlers reference each other + shared VM state by absolute address, _optab holds absolute addresses,
BSS sits at the top. To include exactly what a program uses you'd have to re-link on the X16 (relocatable
handler fragments + reloc tables + a relocator in the compiler) OR redesign the layout for compile-time
truncation (BSS moved to a fixed low addr, optional handlers grouped/ordered high, cut after the last used
group). Both are real projects for only ~hundreds of bytes to ~1 KB over the nearest tier — the tiers ARE the
pragmatic substitute. Further shrink of a GIVEN tier needs deep hand-asm of the dispatch/live handlers —
diminishing returns. See [[gpc-runtime-asm-conversion]].
