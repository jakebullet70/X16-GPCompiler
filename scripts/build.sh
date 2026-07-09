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
    core)
        # feature-stripped "core" runtime tier: float arith + control flow + PRINT + CALLFN +
        # int-literal coercion (IPUSHI/INEG/ITOF) only. Repoint every optional-family opcode in
        # _optab to a halting stub so prog8 dead-strips its handlers, and lower PCODE_BASE so
        # core-tier compiled programs load far lower. Overrides the vm.p8 + pcode_format.p8 imports
        # via build/gen (placed first on -srcdirs). Only meaningful for the runtime target.
        [ "$TARGET" = "runtime" ] || { echo "core mode only applies to the runtime target"; exit 1; }
        rm -rf build/gen && mkdir -p build/gen
        # NOTE the core int boundary: IPUSHI/INEG/ITOF/ITOF2/FTOI (literal coercion) AND IJZ (a bare
        # integer-literal IF condition -- "IF 0" -- branches via IJZ, no % var needed) are CORE. Only
        # %-variable ops (iloadv/istorv/iadd.../icmp*/iand/ior/inot/ifor*/int-arrays) are opt-in.
        STRIP='prints|pushs|loads|stors|concat|poke|peek|sys|dim|aload|astore|inputv|inputs|strnum|numstr|lefts|rights|mids|read|reads|restore|sdim|saload|sastore|rdnum|rdstr|scmp|open|close|getch|status|chkout|chkin|clrch|wait|passthru|callx|callxs|iloadv|istorv|iadd|isub|imul|icmpeq|icmpne|icmplt|icmpgt|icmple|icmpge|iand|ior|inot|iforpush|ifornext|idim|iaload|iastore'
        sed '/^_optab:/i\_unimpl:\n            pla\n            pla\n            jmp  _end' src/runtime/vm.p8 \
          | sed -E "/^_optab:/,/p8s_op_iastore/ s/p8b_vm\.p8s_op_($STRIP)\b/_unimpl/g" \
          | sed -E 's/^( *)bstr\.init\(image_top, varsf\)/\1; core tier: bstr.init(image_top, varsf)/' \
          > build/gen/vm.p8
        sed 's/const uword PCODE_BASE = \$3C80/const uword PCODE_BASE = \$2000/' src/shared/pcode_format.p8 > build/gen/pcode_format.p8
        # build under a distinct main name so prog8 writes vm_runtime_core.prg directly -- it must
        # NOT clobber the full build/vm_runtime.prg (build order would otherwise matter). A 3rd arg
        # "visual" flips TESTBENCH off (READY-returning core runtime for the on-device demo), mirroring
        # the full runtime's test-vs-visual split.
        if [ "$3" = "visual" ]; then
            sed 's/const bool TESTBENCH = true/const bool TESTBENCH = false/' src/runtime/vm_runtime.p8 > build/gen/vm_runtime_core.p8
        else
            cp src/runtime/vm_runtime.p8 build/gen/vm_runtime_core.p8
        fi
        "$JAVA" -jar "$PROG8C" -target cx16 -srcdirs "build/gen;$SRCDIRS" -out build build/gen/vm_runtime_core.p8
        echo "built: build/vm_runtime_core.prg (core tier${3:+ $3})"
        bash "$(dirname "${BASH_SOURCE[0]}")/assert-pcode-base.sh" build/vm_runtime_core.vice-mon-list build/gen/pcode_format.p8
        exit 0
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
