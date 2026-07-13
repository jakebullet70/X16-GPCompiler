# C64 Blitz! Speed Benchmarks — compiled vs. uncompiled

The same experiment we ran for GPC on the Commander X16 (`bench/RESULTS.md`), run here on a
**Commodore 64** with the vintage **Blitz!** (Skyles Electric Works) BASIC compiler under VICE `x64sc`.

Seven small programs are run **both ways** — interpreted by the stock **C64 BASIC V2** ROM, and after
compiling them with **Blitz!** — and timed. Each program is byte-for-byte identical in both modes.
These are the C64 ports of `bench/01..07` (float variables throughout; the native-integer showcase is
X16/GPC-only and is omitted here — C64 BASIC has no integer `FOR`, and Blitz compiles the same V2 dialect).

## Results

Time is **emulated C64 time in jiffies** (1 jiffy = 1/60 s), read from the KERNAL `TI` clock, which
**Blitz-compiled code still supports** — so the counts are directly comparable and host-speed independent.
Lower is faster.

| Benchmark   | What it stresses                    | Uncompiled | Compiled | **Speedup** |
|-------------|-------------------------------------|-----------:|---------:|:-----------:|
| `b1` forloop  | empty `FOR…NEXT` (loop dispatch)  |   2238 j   |  1781 j  |  **1.3×**   |
| `b2` floatmath| float expr `X=I*1.5+2` per iter   |   4742 j   |  1721 j  |  **2.8×**   |
| `b3` nested   | nested loops, `K=K+1`             |   6124 j   |  2199 j  |  **2.8×**   |
| `b4` sieve    | Sieve of Eratosthenes, float array|   2508 j   |   817 j  |  **3.1×**   |
| `b5` string   | `A$=CHR$(65)+CHR$(66)+"X"` + GC   |   1782 j   |   433 j  |  **4.1×**   |
| `b6` peek     | `PEEK(I)` in a loop               |   1335 j   |   519 j  |  **2.6×**   |
| `b7` intmath  | `K=I-1` loop, 20 000×             |   5366 j   |  1984 j  |  **2.7×**   |

Averaged over all seven, Blitz gives roughly **2.6×**. The one outlier is the empty loop (`b1`, 1.3×):
with no expression body there is almost nothing for the compiler to save — the cost is `FOR`/`NEXT`
bookkeeping that Blitz still routes through the ROM. Every program that does real work per iteration
lands in the **2.6–4.1×** band.

## How this compares to GPC on the X16

Same experiment, two different compilers on two different machines. The **speedup ratios** (compiled vs.
its own machine's interpreter) are what's comparable — not the raw jiffy magnitudes, since the CPUs,
ROMs, and loop counts differ.

| Workload         | GPC / X16 | Blitz / C64 |
|------------------|:---------:|:-----------:|
| empty loop       |   1.4×    |   1.3×      |
| float expression |   1.9×    |   2.8×      |
| nested loop      |   1.4×    |   2.8×      |
| **float array (sieve)** | **1.0×** | **3.1×** |
| string + GC      |   1.4×    |   4.1×      |
| PEEK loop        |   1.5×    |   2.6×      |
| integer-ish loop |   1.4×    |   2.7×      |
| **typical**      | **~1.5×** | **~2.6×**   |

**Blitz wins across the board, and the gap is widest exactly where GPC is weakest.** Two rows tell the
story:

- **The sieve.** GPC gets **1.0×** — float array indexing and float compares call the *same* ROM
  routines whether interpreted or run through GPC's P-code VM, so there is nothing to save. Blitz gets
  **3.1×** because it **compiles the array-element address computation inline**, cutting out the ROM's
  variable search and the re-evaluation (`FRMEVL`) of the subscript expression on every access — the
  part GPC leaves on the table.
- **Strings.** GPC **1.4×** vs Blitz **4.1×**. Both still lean on the ROM for the actual concatenation
  and garbage collection, but Blitz's per-statement overhead is so much lower that the fixed cost around
  each ROM call nearly vanishes.

The reason is architectural. **GPC is a P-code (bytecode) compiler**: it emits a compact opcode stream
that a small VM interprets, so it removes the *interpreter's* per-line re-scan/re-parse work but keeps a
dispatch loop and still calls ROM for arithmetic and indexing. **Blitz is a threaded/native-style
compiler**: it resolves variable and array addresses at compile time and emits code much closer to the
metal, so it removes not just line-parsing but most of the per-operation glue too. That is why a mature
1985 commercial compiler still comfortably out-accelerates our P-code VM — and it's a useful yardstick
for where GPC could go next (see *Takeaways* below).

None of this makes GPC's numbers "wrong": ~1.5× for free on unmodified BASIC is real, and GPC's native
`%` integer path (5.6× on the X16, which Blitz has no equivalent of) beats Blitz on integer-heavy code.
But for stock float BASIC, Blitz sets the bar higher than GPC currently reaches.

## Factoring in CPU clock speed

The speedup *ratios* above are already clock-independent (each compiler is measured against its own
machine's interpreter), so clock speed can't flatter either compiler there. But raw jiffies *between*
machines aren't comparable — the X16's 65C02 runs at **8.0 MHz** and the C64's 6510 at **~1.023 MHz**
(NTSC). To compare the two honestly we normalize all the way down to **CPU cycles per iteration**.
This is possible because both suites run **byte-identical workloads with identical iteration counts**
(30 000 / 8 000 / 150² / 3 000 / 6 001 / 20 000), so:

```text
cycles/iter = jiffies × (cpu_hz / jiffy_hz) / iterations
   X16: 8 000 000 / 60 = 133 333 cyc per jiffy
   C64: 1 022 727 / 60 =  17 045 cyc per jiffy   (NTSC, ~60 Hz TI)
```

Columns: uncompiled cycles/iter for each machine's ROM BASIC (+ their ratio), then compiled cycles/iter
for GPC vs Blitz (+ how many fewer cycles Blitz uses).

| Bench          | X16 BASIC | C64 BASIC | unc. ratio | GPC  | Blitz | Blitz uses…       |
|----------------|----------:|----------:|:----------:|-----:|------:|:------------------|
| `01` forloop   |     1267  |     1272  |    1.00    |  916 |  1012 | 0.90× (GPC wins)  |
| `02` floatmath |     9533  |    10104  |    1.06    | 4983 |  3667 | **1.36× fewer**   |
| `03` nested    |     4575  |     4639  |    1.01    | 3247 |  1666 | **1.95× fewer**   |
| `05` string    |     9600  |    10125  |    1.05    | 6711 |  2460 | **2.73× fewer**   |
| `06` peek      |     3910  |     3792  |    0.97    | 2644 |  1474 | **1.79× fewer**   |
| `07` intmath   |     4460  |     4573  |    1.03    | 3273 |  1691 | **1.94× fewer**   |

Two conclusions:

1. **Uncompiled, the two machines are the same computer at different clock speeds.** Per CPU cycle,
   stock X16 BASIC and stock C64 BASIC agree to within ±6% (ratio ~1.00) — unsurprising, since they are
   the *same-lineage CBM/Microsoft ROM interpreter*. So the ~8× wall-clock gap between them is **entirely
   clock speed** (8.0 / 1.023 = 7.8×), nothing about the software. (The near-1.00 match also validates the
   measurement: a 50 Hz `TI` assumption for the C64 would have skewed the ratio to ~0.83, so the numbers
   confirm the C64 was ticking a ~60 Hz jiffy.)

2. **The Blitz-vs-GPC gap survives clock normalization — it is real compiler quality, not the slow C64
   "looking good."** Measured in raw CPU cycles, Blitz-compiled code does the same work in **1.4×–2.7×
   fewer cycles** than GPC on every benchmark with a real body. The one exception is the empty loop
   (`01`, 0.90×), where GPC's bare-`NEXT` dispatch is actually a touch tighter than Blitz's. Factoring
   clock speed therefore *sharpens* rather than softens the verdict: per cycle, Blitz genuinely emits
   better code, and the widest cycles-per-iteration gaps are the same string/array/dispatch rows called
   out below.

## Takeaways for GPC

The two rows where Blitz pulls furthest ahead point straight at GPC's highest-value optimizations:

1. **Compile array indexing.** The sieve gap (1.0× → 3.1×) is entirely array-access overhead. Emitting
   an inline element-address opcode (base + index·elsize) instead of calling the ROM array routine is
   the single biggest available win, and it targets the exact workload GPC currently can't accelerate.
2. **Tighten VM dispatch.** Blitz's blanket ~2.6× vs GPC's ~1.5× is mostly the cost of the P-code
   dispatch loop itself (fetch/decode/branch per opcode). This is the "Optimize VM dispatch" task the
   user already selected on the X16 side — the C64 comparison quantifies its ceiling.

## Method

- **Emulator:** VICE `x64sc` 3.8, `-warp`, drive 8 attached (`-8`), programs and the Blitz compiler on
  one `.d64`. Input driven via `-keybuf`; final screen captured with `-exitscreenshot` and the `R=` line
  read from the PNG.
- **Metric:** the C64 60 Hz KERNAL jiffy clock via `TI`, bracketing only the workload
  (`1 TS=TI` … `9000 PRINT "R=";TI-TS`). Blitz-compiled code preserves `TI`, so both modes read the same
  clock. Under `-warp` the emulator runs fast in wall-clock but the *emulated* jiffy count is unaffected,
  so the numbers are host-independent.
- **Compiling with Blitz:** `LOAD"BLITZ",8` / `RUN` → menu `1` (single file) → filename `bN` → two-pass
  compile writes `c/bN` (the runnable ~24-block compiled program, a `SYS 2076` stub + Blitz runtime) and
  a `z/bN` scratch file. Each compile is ~400 M emulated cycles (Blitz is disk-heavy — it spills temp
  files during compilation), ~90 s wall at warp. Compiles were fanned out across separate disk images in
  parallel.
- Numbers are stable across repeated runs.

## The programs

Sources are in `bench/c64/b1.bas … b7.bas` — the same workloads as `bench/01..07`, with `9010 END`
instead of the X16's `POWEROFF` and `TI` timing kept in both modes. Example — `b4` (sieve):

```basic
1 TS=TI
100 DIM F(2000)
110 FOR I=2 TO 2000
120 IF F(I)<>0 THEN 170
130 IF I+I>2000 THEN 170       : REM guard: CBM FOR always runs body once
140 FOR J=I+I TO 2000 STEP I
150 F(J)=1
160 NEXT J
170 NEXT I
9000 PRINT "R=";TI-TS
9010 END
```
