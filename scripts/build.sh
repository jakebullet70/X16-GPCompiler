#!/usr/bin/env bash
# Build a Blitz-X16 target.
#   build.sh <target> [visual]
#     target: selftest (VM regression) | runtime (bundled standalone VM) | gpc (the compiler)
#     visual: flip the TESTBENCH const off so the program returns to BASIC READY
set -e
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$ROOT"

TARGET="$1"; MODE="${2:-test}"
case "$TARGET" in
    selftest) SRC="src/runtime/vm_selftest.p8"; BASE="vm_selftest" ;;
    runtime)  SRC="src/runtime/vm_runtime.p8";  BASE="vm_runtime" ;;
    gpc)   SRC="src/compiler/gpc.p8";     BASE="gpc" ;;
    *) echo "unknown target: '$TARGET' (use: selftest | runtime | gpc)"; exit 1 ;;
esac

# Prog8 splits -srcdirs on the OS path separator (';' on Windows).
SRCDIRS="src/shared;src/runtime;src/compiler"

# fresh gen dir: it's auto-searched for imports, so stale copies must not linger
case "$MODE" in
    visual)
        # TESTBENCH off: return to the BASIC READY prompt instead of mailbox+STP
        rm -rf build/gen && mkdir -p build/gen
        sed 's/const bool TESTBENCH = true/const bool TESTBENCH = false/' "$SRC" > "build/gen/$BASE.p8"
        "$JAVA" -jar "$PROG8C" -target cx16 -srcdirs "$SRCDIRS" -out build "build/gen/$BASE.p8"
        echo "built: build/$BASE.prg (visual)"
        ;;
    interactive)
        # real on-device use: prompt for the file names AND return to READY (no mailbox/STP)
        rm -rf build/gen && mkdir -p build/gen
        sed -e 's/const bool TESTBENCH = true/const bool TESTBENCH = false/' \
            -e 's/const bool INTERACTIVE = false/const bool INTERACTIVE = true/' "$SRC" > "build/gen/$BASE.p8"
        "$JAVA" -jar "$PROG8C" -target cx16 -srcdirs "$SRCDIRS" -out build "build/gen/$BASE.p8"
        echo "built: build/$BASE.prg (interactive)"
        ;;
    prompt)
        # headless test variant: prompt for names (INTERACTIVE) but keep the mailbox+STP (TESTBENCH),
        # under a distinct name so it doesn't clobber the normal build/$BASE.prg
        rm -rf build/gen && mkdir -p build/gen
        sed 's/const bool INTERACTIVE = false/const bool INTERACTIVE = true/' "$SRC" > "build/gen/${BASE}_prompt.p8"
        "$JAVA" -jar "$PROG8C" -target cx16 -srcdirs "$SRCDIRS" -out build "build/gen/${BASE}_prompt.p8"
        echo "built: build/${BASE}_prompt.prg (prompt-test)"
        ;;
    *)
        "$JAVA" -jar "$PROG8C" -target cx16 -srcdirs "$SRCDIRS" -out build "$SRC"
        echo "built: build/$BASE.prg (test)"
        ;;
esac

# Guard the PCODE_BASE invariant for the shipped standalone VM image. The runtime's
# low-RAM footprint must end below PCODE_BASE or standalone P-code is silently corrupted
# (see scripts/assert-pcode-base.sh). Only the 'runtime' target produces that image.
if [ "$TARGET" = "runtime" ]; then
    LISTBASE="$BASE"
    [ "$MODE" = "prompt" ] && LISTBASE="${BASE}_prompt"
    bash "$(dirname "${BASH_SOURCE[0]}")/assert-pcode-base.sh" "build/$LISTBASE.vice-mon-list"
fi
