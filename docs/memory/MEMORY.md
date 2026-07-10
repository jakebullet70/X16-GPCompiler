# Memory Index

- [GPC project](gpc-project.md) — what the Greased Piglet Compiler is + locked design decisions
- [GPC increment 2 design](gpc-inc2-design.md) — 2a int-compare/IJZ + 2b int-FOR + 2c int-arrays (DIM A%()) all SHIPPED; banked-RAM tables kept
- [GPC array-load-loop bug](gpc-array-load-loop-bug.md) — RESOLVED: was DIM not zero-initing elements; garbage float hung ROM FOUT on PRINT. Fixed in op_dim.
- [GPC print-large-number bug](gpc-print-large-number-bug.md) — RESOLVED: PRINT of any n>=32768 crashed ?ILLEGAL QUANTITY; op_printi's range-checked float->word mailbox cast. Guarded.
- [GPC gating requirement](gpc-gating-requirement.md) — GARBAG + pass-through must work (no-go otherwise); both PROVEN on R49
- [GPC X16-BASIC look/act](gpc-x16basic-look-act.md) — compiled .prg LISTs as `10 SYS ..` + screen-preserving startup; no_sysinit+IOINIT/RESTOR gotchas
- [X16 ROM internal calls](x16-rom-internal-calls.md) — verified R49 dispatcher/GC addresses + ZP pointers for GPC
- [X16 toolchain](x16-toolchain.md) — prog8c/64tass/x16emu paths + headless testbench recipe
- [Prog8 PETSCII char literals](prog8-petscii-charlits.md) — cx16 'a'..'z' = $C1..$DA; guard >= $80 before is_alpha on tokens
- [Blitz-X16 prior attempt](blitz-x16-prior-attempt.md) — the ~90%-done sibling compiler GPC ports proven code from
- [GPC runtime asm conversion](gpc-runtime-asm-conversion.md) — branch runtime-asm: Prog8->hand-asm VM, phases/sizes; P7b string handlers + Tier-1 slab-relocation (C.DIR 80->52 blocks); ~8-9KB floor
- [GPC engine shrink](gpc-engine-shrink.md) — branch engine-shrink: 3-phase tiered runtime (universal base tighten + nosarr auto-tier + noint compiler-mode tier); build_tier strip mechanism; PCODE_BASE is the size lever
- [GPC X16 BASIC coverage](gpc-x16-basic-coverage.md) — what GPC compiles vs real X16 BASIC; 7 lexer blockers FIXED (hex/bin/dot/big-int/exp/long-name/reversed-relops); remaining function gaps (TAB/SPC/MOD/GET); passthru covers the rest
- [GPC IF semantics](gpc-if-semantics.md) — false IF skips the whole LINE (CBM V2); verified against ref/x16-rom ROM source
- [Memory is git-tracked](memory-is-git-tracked.md) — this memory folder is a junction into the repo (docs/memory); notes auto-version with the project
