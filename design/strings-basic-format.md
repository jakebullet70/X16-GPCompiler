# GPC Phase 2 — BASIC-format strings with ROM garbage collection

## Goal

Replace the VM's private null-terminated string heap + custom mark-compact collector with
**BASIC-format string storage collected by the ROM `garba2`**. String scalars become real BASIC
variables, string arrays become BASIC arrays, expression temporaries become BASIC temp descriptors,
and all string bodies live on the BASIC string heap. Numeric storage (varsf, arrheap) is unchanged —
`garba2` only relocates strings, so numeric vars simply don't appear in the BASIC tables.

Verified feasible in `spikes/garbag.p8`. This spec is the implementation reference.

## String value model

A string VALUE is a 3-byte **descriptor** `[len(1)][ptr_lo(1)][ptr_hi(1)]`; the body is `len` bytes
(NOT null-terminated — length is explicit, max 255). Descriptors live in one of three places, all of
which `garba2` walks, so every live string is protected across a collection:

- **Scalar var:** a 7-byte BASIC simple-variable entry; descriptor at offset +2.
- **String-array element:** a 3-byte descriptor inside a BASIC array.
- **Temp:** a 3-byte entry on BASIC's temp-descriptor stack (base `tempst`=$00D6, **3 slots only**).

A literal's descriptor may point into the P-code literal pool (program text) rather than the heap;
`garba2` ignores pointers outside `[strend..memsiz]`, so literals are safe and never copied until
assigned (exactly BASIC's behavior via `strlit`).

The VM's `sstack` now holds **descriptor addresses** (into var table / temp stack / literal pool),
not raw body pointers.

## Reusable ROM routines (R49; BASIC ROM bank 4 = `$01=4`)

| Addr | Name | Use |
|------|------|-----|
| $D773 | `ptrget` | find/create a variable by name → `varpnt`; builds byte-perfect table entries |
| $DC35 | `getspa` | A=len → alloc `len` heap bytes, X/Y=ptr; GCs (via `garbag`) on collision |
| $DC07 | `putnew` | push a temp descriptor from `dsctmp`; `?FORMULA TOO COMPLEX` past 3 |
| $DBC0 | `strlit` | build a temp descriptor from a source string (copies if in program text) |
| $DDA5 | `cat` | string concatenation (BASIC's `+`) |
| $DDF0 | `movstr` / $DDE2 `movins` | copy string bytes |
| $DE4B | `fretms` / $DE0E `frestr` / $DE15 `fretmp` | free/pop a temp descriptor |
| $DC70 | `garba2` | the collector (also reachable inside `getspa`) |

FAC string convention: `valtyp=$FF`, `facmo/facmo+1` → the descriptor. (ZP: `dsctmp`, `facmo`,
`temppt`=$03DE, `tempst`=$00D6, `fretop`=$03E7, `memsiz`=$03E9, `vartab`=$03E1, `arytab`=$03E3,
`strend`=$03E5.)

## Memory map (maps onto BASIC's own model)

P-code = "program text". Set at VM init:

- `vartab` = just above the P-code region → string var table grows up.
- `arytab`/`strend` follow (arrays after scalars).
- `memsiz` = MEMTOP (`$FF99`); `fretop` = memsiz → string heap grows **down** from the top.
- `temppt` = `tempst` (empty temp stack).

The var/array tables (growing up) and the string heap (growing down) meet in the middle; `getspa`'s
existing `fretop`-vs-`strend` check yields `?OUT OF MEMORY` — no new logic. Standalone: P-code at
`$4800`, tables above it, heap below `$9F00`. In-process: compiler resident low, tables + heap in the
free region above it (bounded; smaller programs, as today).

## Staged implementation (re-green after each)

1. **Env setup + smoke.** VM init sets vartab/arytab/strend/fretop/memsiz/temppt. Smoke-test: create a
   var via `ptrget`, store a literal, force `garba2`, assert reclaim (VM-context version of `garbag.p8`).
2. **Scalars.** Per string slot: synthesize a unique 2-char name, `ptrget` once, cache `varpnt`.
   `OP_LOADS` = point at the var descriptor; `OP_STORS` = assign via ROM string-store (heap-copy semantics).
3. **Literals + temps.** `OP_PUSHS` via `strlit`; concat/slice results via `getspa`+`putnew`.
4. **CONCAT / substrings / CHR$ / STR$ / VAL / compare** using descriptors + getspa; print length-counted.
5. **String arrays** as BASIC arrays (element = 3-byte descriptor).
6. **INPUT / READ / GET#** produce heap descriptors.
7. **Remove** the custom `gc_ensure`/`gc_collect`/`gc_rewrite` and the private `heap` slab; getspa's
   internal `garbag` is the only collector.

## Risks

- Descriptor model changes `sstack` semantics → string opcodes convert together (big-bang for the
  string layer); mitigated by staging + the full 194-check corpus.
- 3-temp limit: verify GPC's max live string temporaries ≤ 3 (it should — BASIC itself is bounded at 3).
- Printing: bodies are length-counted; `print_cstr` and output paths must honor `len`, not a null.
