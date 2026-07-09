#!/usr/bin/env bash
# Build a target in visual mode and launch it in x16emu to watch it run.
#   run.sh selftest                 -> runs the VM self-test
#   run.sh [gpc] ["<basic>"]     -> compiles the given BASIC from disk and runs it in-process
#   run.sh standalone ["<basic>"]   -> compiles to a standalone out.prg, then runs out.prg ALONE
#   run.sh interactive ["<basic>"]  -> the real on-device compiler: it PROMPTS you for the file
#                                      names (type "source.prg" then "out.prg" at the prompts)
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/env.sh"
cd "$ROOT"

TARGET="${1:-gpc}"
if [ "$TARGET" = "selftest" ]; then
    bash "$DIR/build.sh" selftest visual
    "$X16EMU" -run -prg build/vm_selftest.prg
    exit 0
fi

DEMO="10 A\$=\"HELLO\":PRINT A\$+\" WORLD\"\n20 FOR I=1 TO 3\n30 PRINT \"I=\";I\n40 NEXT I"
FS="build/disk"; mkdir -p "$FS"

if [ "$TARGET" = "interactive" ]; then
    BASIC="${2:-$DEMO}"
    bash "$DIR/build.sh" runtime     visual
    bash "$DIR/build.sh" gpc  interactive
    printf '%b\n' "$BASIC" | python "$DIR/tokenize.py" > "$FS/source.prg"
    cp build/vm_runtime.prg "$FS/gpc.runtime.bin"
    [ -f build/vm_runtime_core.prg ] && cp build/vm_runtime_core.prg "$FS/gpc.rt.core.bin"
    [ -f build/vm_runtime_str.prg ]  && cp build/vm_runtime_str.prg  "$FS/gpc.rt.str.bin"
    [ -f build/vm_runtime_arr.prg ]  && cp build/vm_runtime_arr.prg  "$FS/gpc.rt.arr.bin"
    rm -f "$FS/out.prg"
    echo "launching the interactive compiler; at its prompts type:  source.prg  then  out.prg"
    "$X16EMU" -run -prg build/gpc.prg -fsroot "$FS"
    exit 0
fi

if [ "$TARGET" = "standalone" ]; then
    BASIC="${2:-$DEMO}"
    bash "$DIR/build.sh" runtime visual
    bash "$DIR/build.sh" gpc  visual
    printf '%b\n' "$BASIC" | python "$DIR/tokenize.py" > "$FS/source.prg"
    cp build/vm_runtime.prg "$FS/gpc.runtime.bin"        # the compiler bundles this into out.prg
    [ -f build/vm_runtime_core.prg ] && cp build/vm_runtime_core.prg "$FS/gpc.rt.core.bin"
    [ -f build/vm_runtime_str.prg ]  && cp build/vm_runtime_str.prg  "$FS/gpc.rt.str.bin"
    [ -f build/vm_runtime_arr.prg ]  && cp build/vm_runtime_arr.prg  "$FS/gpc.rt.arr.bin"
    rm -f "$FS/out.prg"
    echo "compiling to a standalone out.prg:"; printf '%b\n' "$BASIC"
    "$X16EMU" -run -prg build/gpc.prg -fsroot "$FS"
    if [ ! -s "$FS/out.prg" ]; then echo "compiler did not produce out.prg"; exit 1; fi
    echo "now running out.prg with NO compiler present ($(wc -c < "$FS/out.prg") bytes):"
    "$X16EMU" -run -prg "$FS/out.prg"
    exit 0
fi

BASIC="${2:-$DEMO}"
bash "$DIR/build.sh" gpc visual
printf '%b\n' "$BASIC" | python "$DIR/tokenize.py" > "$FS/source.prg"
echo "compiling this program (from $FS/source.prg):"; printf '%b\n' "$BASIC"
"$X16EMU" -run -prg build/gpc.prg -fsroot "$FS"
