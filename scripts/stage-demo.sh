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
rm -f "$DEMO"/gpc.prg "$DEMO"/gpc.runtime.bin "$DEMO"/gpc.rt.core.bin "$DEMO"/gpc.rt.str.bin "$DEMO"/gpc.runtime.prg "$DEMO"/runtime.prg "$DEMO"/c.* "$DEMO"/C.* "$DEMO"/blitzc*.prg "$DEMO"/source.prg
for f in "$SRCDIR"/*.bas; do rm -f "$DEMO/$(basename "$f" .bas)"; done

# Compile a tokenized-BASIC .prg (already at demo/) to a self-contained standalone via the headless
# (testbench) compiler, bundling the VISUAL runtime so the emitted program returns to READY.
# Fixed on-disk names source.prg/gpc.runtime.bin -> out.prg; mirrors scripts/check-standalone.sh.
#   compile_standalone <input-prg-basename> <output-basename>
compile_standalone() {
    local in="$1" out="$2"
    local fs; fs="$(mktemp -d)"
    cp "$DEMO/$in" "$fs/source.prg"
    cp "$ROOT/build/vm_runtime.prg" "$fs/gpc.runtime.bin"
    [ -f "$ROOT/build/vm_runtime_core.prg" ] && cp "$ROOT/build/vm_runtime_core.prg" "$fs/gpc.rt.core.bin"
    [ -f "$ROOT/build/vm_runtime_str.prg" ]  && cp "$ROOT/build/vm_runtime_str.prg"  "$fs/gpc.rt.str.bin"
    rm -f "$fs/out.prg"
    local centry; centry="$(bash "$DIR/entry-addr.sh" "$ROOT/build/gpc.prg")"
    printf 'RUN %s\n' "$centry" | timeout 40 "$X16EMU" -testbench -warp -fsroot "$fs" -prg "$ROOT/build/gpc.prg" >/dev/null 2>&1 || true
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
bash "$DIR/build.sh" runtime core visual >/dev/null          # core tier (feature-free programs), visual
cp "$ROOT/build/vm_runtime_core.prg" "$DEMO/gpc.rt.core.bin"
bash "$DIR/build.sh" runtime str visual >/dev/null           # str tier (strings-only programs), visual
cp "$ROOT/build/vm_runtime_str.prg" "$DEMO/gpc.rt.str.bin"

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

echo "== build gpc INTERACTIVE -> demo/gpc.prg (the on-device compiler that prompts) =="
bash "$DIR/build.sh" gpc interactive >/dev/null
cp "$ROOT/build/gpc.prg" "$DEMO/gpc.prg"

echo "== restore build/gpc.prg to the default testbench build (dev/test state) =="
bash "$DIR/build.sh" gpc >/dev/null

echo
echo "staged demo/ :"
ls -1 "$DEMO" | sed 's/^/  /'
echo
echo "try it:  $X16EMU -fsroot demo -prg demo/gpc.prg -run"
echo "  at 'compile file:' type  SQUARES   then RETURN at 'write to:'  -> writes c.SQUARES"
echo "  back at READY:  LOAD \"C.SQUARES\",8  then  RUN"
