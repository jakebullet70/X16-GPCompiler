# GPC Speed Benchmarks — compiled vs. uncompiled

How much faster does a program run after compiling it with the **Greased Piglet Compiler**
than it does interpreted by the stock **Commander X16 BASIC V2** ROM?

Seven small programs are run **both ways** and timed. Each program is byte-for-byte identical in
both modes (except the timing prologue) so the comparison is apples-to-apples. An eighth entry
(`07_intmath.int`) rewrites one program with GPC's native-integer (`%`) types — a dialect stock
BASIC does not have — to show the additional win from the integer subsystem.

## Results

Time is **emulated X16 time in jiffies** (1 jiffy = 1/60 s), so the numbers are independent of how
fast the host PC is. Lower is faster.

| Benchmark        | What it stresses                    | Uncompiled | Compiled | **Speedup** |
|------------------|-------------------------------------|-----------:|---------:|:-----------:|
| `01_forloop`     | empty `FOR…NEXT` (loop dispatch)    |    285 j   |  206 j   |  **1.4×**   |
| `02_floatmath`   | float expr `X=I*1.5+2` per iter     |    572 j   |  299 j   |  **1.9×**   |
| `03_nested`      | nested loops, `K=K+1`               |    772 j   |  548 j   |  **1.4×**   |
| `04_sieve`       | Sieve of Eratosthenes, float array  |    318 j   |  305 j   |  **1.0×**   |
| `05_string`      | `A$=CHR$(65)+CHR$(66)+"X"` + GC     |    216 j   |  151 j   |  **1.4×**   |
| `06_peek`        | `PEEK(I)` in a loop                 |    176 j   |  119 j   |  **1.5×**   |
| `07_intmath`     | `K=I-1` loop, 20 000×               |    669 j   |  491 j   |  **1.4×**   |
| **`07_intmath.int`** | same loop with **`I% / K%`** (native int) | — | **119 j** | **5.6× vs stock** |

Averaged over the identical-source (float) tests, compiling gives **~1.5×**. Where the program can
use native integers, it jumps to **5.6×** over stock BASIC (and **4.1×** over the same program
compiled with float variables).

## How to read this

GPC is a **P-code (bytecode) compiler**, not a native-code compiler. It compiles each BASIC line
once into a compact opcode stream that a small VM executes. So the speedup comes almost entirely
from **eliminating the interpreter's per-statement work** — re-scanning the line, re-tokenizing,
re-parsing the expression, and looking variables up by name — on *every* iteration. The actual
arithmetic still runs through the same ROM math routines in both modes.

That model explains every row:

- **Loop / dispatch-bound code (`01`, `03`, `07`) → ~1.4×.** The body is cheap; the win is skipping
  the interpreter's line-scan each pass.
- **Expression-heavy float code (`02`) → 1.9×.** More operators per line = more parsing the
  interpreter repeats and GPC does once. This is the sweet spot for float code.
- **ROM-bound float code (`04_sieve`) → 1.0×.** Time is dominated by float array indexing and float
  comparisons, which call the *same* ROM routines in both modes — so there is almost nothing left
  for the compiler to save. **Compiling does not speed up floating-point math itself.**
- **Native integers (`07_intmath.int`) → 5.6×.** This is the real lever. With `%` variables GPC
  emits native 16-bit integer opcodes and bypasses the ROM floating-point library entirely. Stock
  BASIC has no integer `FOR` and evaluates everything as 40-bit float, so the gap is large.

**Takeaway:** compiling a typical BASIC program with GPC makes it ~1.5× faster for free; rewriting
its hot loops to use integer (`%`) variables where possible is what unlocks the 4–6× range.

## Method

- **Metric:** the 60 Hz KERNAL jiffy timer, bracketing only the workload (setup/teardown excluded).
  Uncompiled reads it via `TI`; compiled reads the timer bytes directly (`PEEK` of `$A8B5/$A8B6`
  in RAM bank 0 — GPC has no `TI`). Both read the same clock, so the counts are directly comparable.
- **Non-warp, non-testbench.** The jiffy IRQ only advances in real-time video mode (it is frozen
  under `-warp` and `-testbench` — the same reason `SLEEP` hangs headless), so timing runs must be
  real-time. Jiffies still measure *emulated* time, so results are host-speed independent.
- Each program ends with `POWEROFF` so the emulator exits promptly and flushes captured output.
- Numbers are stable to ±1–2 jiffies across repeated runs.

Run it yourself: `bash bench/run-bench.sh` (needs `build/gpc.prg` + `build/vm_runtime*.prg`).

## The programs

All sources are in `bench/*.bas`. Example — `04_sieve.bas` (float) and its native-int twin:

```basic
100 DIM F(2000)                         100 DIM F%(2000)
110 FOR I=2 TO 2000                     110 FOR I%=2 TO 2000
120 IF F(I)<>0 THEN 170                 120 IF F%(I%)<>0 THEN 170
130 IF I+I>2000 THEN 170                130 IF I%+I%>2000 THEN 170
140 FOR J=I+I TO 2000 STEP I            140 FOR J%=I%+I% TO 2000 STEP I%
150 F(J)=1                              150 F%(J%)=1
160 NEXT J                              160 NEXT J%
170 NEXT I                              170 NEXT I%
```

> Aside: the float sieve exposed a semantic difference — because CBM `FOR` always runs its body once,
> `FOR J=I+I …` with `I+I>2000` would touch `F(2002)`. Stock BASIC bounds-checks and stops with
> `?BAD SUBSCRIPT`; **GPC does not bounds-check arrays**, so it runs on into adjacent memory. The
> `IF I+I>2000 THEN …` guard makes the sieve correct in both.
