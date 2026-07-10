#!/usr/bin/env bash
# Stage the on-device GPC demo into demo/ (the emulator/SD-card HostFS root).
#
# Populates demo/ deterministically from the canonical BASIC sources in demo/src/*.bas:
#   demo/gpc.prg       - the resident compiler, built INTERACTIVE (prompts for file names)
#   demo/gpc.runtime.bin   - the VM runtime the compiler bundles (opened as gpc.runtime.bin) into a standalone build
#   demo/<NAME>        - each src/<NAME>.bas tokenized to classic BASIC (what you type at
#                        the "compile file:" prompt), e.g. HELLO, SQUARES, INTMATH, ...
#   demo/c.HELLO       - a ready-to-run standalone: HELLO already compiled (LOAD + RUN it
#                        with no compiler present), so the demo shows the payoff immediately
#   demo/DIR.PRG       - a plain-BASIC file lister (LOAD"DIR.PRG":RUN) -- source preserved, not built here
#   demo/C.DIR.PRG     - DIR.PRG pre-compiled to a standalone (the "same but MUCH faster" payoff),
#                        rebuilt here so it always carries the current runtime
#   demo/README        - hand-maintained (not regenerated here)
#
# Run it whenever the compiler or runtime changes so the demo never goes stale again.
#   scripts/stage-demo.sh
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/env.sh"
cd "$ROOT"

DEMO="$ROOT/demo"
SRCDIR="$DEMO/src"
[ -d "$SRCDIR" ] || { echo "no demo/src/ with .bas sources"; exit 1; }

echo "== clean stale demo payload (keep src/ and README) =="
# NB: DIR.PRG (the plain-BASIC source) is a hand-authored utility, NOT regenerated from src/ --
# it is deliberately preserved. Its COMPILED form C.DIR.PRG *is* rebuilt below.
# Globs are case-sensitive here, so remove both cases of the compiled outputs explicitly.
rm -f "$DEMO"/gpc.prg "$DEMO"/gpc.noint.prg "$DEMO"/gpc.runtime.bin "$DEMO"/gpc.rt.nosarr.bin "$DEMO"/gpc.rt.noint.bin "$DEMO"/gpc.runtime.prg "$DEMO"/runtime.prg "$DEMO"/c.* "$DEMO"/C.* "$DEMO"/blitzc*.prg "$DEMO"/source.prg
for f in "$SRCDIR"/*.bas; do rm -f "$DEMO/$(basename "$f" .bas)"; done

# Compile a tokenized-BASIC .prg (already at demo/) to a self-contained standalone via the headless
# (testbench) compiler, bundling the VISUAL runtime so the emitted program returns to READY.
# Fixed on-disk name source.prg -> out.prg; mirrors scripts/check-standalone.sh. The compiler +
# bundled runtime default to the full pair, but can be overridden to build a noint standalone:
#   compile_standalone <input-prg> <output> [compiler.prg] [runtime.prg] [runtime-on-disk-name]
compile_standalone() {
    local in="$1" out="$2"
    local gpc="${3:-$ROOT/build/gpc.prg}" rt="${4:-$ROOT/build/vm_runtime.prg}" rtname="${5:-gpc.runtime.bin}"
    local fs; fs="$(mktemp -d)"
    cp "$DEMO/$in" "$fs/source.prg"
    cp "$rt" "$fs/$rtname"                                   # the compiler opens the runtime under this name
    [ -f "$ROOT/build/vm_runtime_nosarr.prg" ] && cp "$ROOT/build/vm_runtime_nosarr.prg" "$fs/gpc.rt.nosarr.bin"
    rm -f "$fs/out.prg"
    local centry; centry="$(bash "$DIR/entry-addr.sh" "$gpc")"
    printf 'RUN %s\n' "$centry" | timeout 40 "$X16EMU" -testbench -warp -fsroot "$fs" -prg "$gpc" >/dev/null 2>&1 || true
    if [ -s "$fs/out.prg" ]; then
        cp "$fs/out.prg" "$DEMO/$out"
        echo "  $out ($(wc -c < "$DEMO/$out") bytes)"
    else
        echo "  WARNING: standalone compile of $in produced no out.prg; skipping $out"
    fi
    rm -rf "$fs"
}

echo "== build runtime (visual: a standalone build returns to READY, not mailbox+STP) =="
bash "$DIR/build.sh" runtime visual >/dev/null
cp "$ROOT/build/vm_runtime.prg" "$DEMO/gpc.runtime.bin"
bash "$DIR/build.sh" runtime nosarr visual >/dev/null       # nosarr tier: programs with no DIM A$() bundle this smaller runtime
cp "$ROOT/build/vm_runtime_nosarr.prg" "$DEMO/gpc.rt.nosarr.bin"
bash "$DIR/build.sh" runtime noint visual >/dev/null        # noint tier: the int-optional compiler bundles this (loads at $3400)
cp "$ROOT/build/vm_runtime_noint.prg" "$DEMO/gpc.rt.noint.bin"

echo "== tokenize demo/src/*.bas -> demo/<NAME> (classic BASIC the compiler reads) =="
for f in "$SRCDIR"/*.bas; do
    name="$(basename "$f" .bas)"
    python "$DIR/tokenize.py" < "$f" > "$DEMO/$name"
    echo "  $name"
done

echo "== pre-compile standalones (HELLO + the DIR.PRG file lister) =="
bash "$DIR/build.sh" gpc >/dev/null                       # testbench gpc (auto-runnable, fixed names)
compile_standalone HELLO   c.HELLO      # the payoff: a ready-to-run compiled program
compile_standalone DIR.PRG C.DIR.PRG    # "same as BASIC, MUCH faster" -- compiled directory lister
compile_standalone INTMATH C.INTMATH    # native-int build (% = 16-bit int ops), for the size compare below

echo "== int-optional (noint) compiler: same INTMATH, % degrades to float -> a SMALLER standalone =="
bash "$DIR/build.sh" gpc noint >/dev/null                 # testbench noint compiler (INTSUPPORT=false)
compile_standalone INTMATH C.INTMATH.NI "$ROOT/build/gpc_noint.prg" "$ROOT/build/vm_runtime_noint.prg" gpc.rt.noint.bin

echo "== build gpc INTERACTIVE -> demo/gpc.prg (the on-device compiler that prompts) =="
bash "$DIR/build.sh" gpc interactive >/dev/null
cp "$ROOT/build/gpc.prg" "$DEMO/gpc.prg"
echo "== build gpc INTERACTIVE (int-optional) -> demo/gpc.noint.prg =="
bash "$DIR/build.sh" gpc noint interactive >/dev/null
cp "$ROOT/build/gpc_noint.prg" "$DEMO/gpc.noint.prg"

echo "== restore build/gpc.prg + build/gpc_noint.prg to the default testbench builds (dev/test state) =="
bash "$DIR/build.sh" gpc >/dev/null
bash "$DIR/build.sh" gpc noint >/dev/null

echo
echo "staged demo/ :"
ls -1 "$DEMO" | sed 's/^/  /'
echo
echo "try it:  $X16EMU -fsroot demo -prg demo/gpc.prg -run"
echo "  at 'compile file:' type  SQUARES   then RETURN at 'write to:'  -> writes c.SQUARES"
echo "  back at READY:  LOAD \"C.SQUARES\",8  then  RUN"
echo
echo "int-optional (noint) compiler:  $X16EMU -fsroot demo -prg demo/gpc.noint.prg -run"
echo "  compiles the same BASIC but % vars/literals become float; its output bundles the smaller"
echo "  noint runtime. Compare block counts in DIR:  C.INTMATH (native int)  vs  C.INTMATH.NI (noint)"
