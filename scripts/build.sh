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

# build_tier <name> <strip-regex> <keep-bstr:yes|no> <pcode-base:$XXXX> [visual]
# Build a feature-stripped runtime tier into build/vm_runtime_<name>.prg. Repoints every opcode whose
# handler name matches <strip-regex> in _optab to a halting _unimpl stub AND collapses its asmsub body to
# a bare `rts` (prog8 never DCEs asmsubs, so stubbing _optab alone would leave the dead hand-asm handler
# in the image; collapsing it reclaims the space, letting this tier claim a LOWER PCODE_BASE -- the real
# per-program win, since a standalone .PRG floor is PCODE_BASE-$0801). Once a handler body is gone, prog8
# DCEs the now-unreferenced helper subs it called (e.g. sarr_alloc/sarr_desc). keep-bstr=no also comments
# out bstr.init so prog8 dead-strips all of bstr.p8. Overrides vm.p8 + pcode_format.p8 via build/gen
# (placed FIRST on -srcdirs). Writes under a distinct main name so it never clobbers vm_runtime.prg.
build_tier() {
    local name="$1" strip="$2" keepbstr="$3" pbase="$4" visual="$5"
    local out="vm_runtime_${name}" gen="build/gen"
    rm -rf "$gen" && mkdir -p "$gen"
    local bstr_sed="s/^( *)bstr\\.init\\(image_top, varsf\\)/\\1; ${name} tier: bstr.init(image_top, varsf)/"
    [ "$keepbstr" = "no" ] || bstr_sed='b'      # keep-bstr: make the bstr sed a pass-through
    sed '/^_optab:/i\_unimpl:\n            pla\n            pla\n            jmp  _end' src/runtime/vm.p8 \
      | sed -E "/^_optab:/,/p8s_op_iastore/ s/p8b_vm\\.p8s_op_(${strip})\\b/_unimpl/g" \
      | sed -E "$bstr_sed" \
      | awk -v strip="$strip" '
          BEGIN { re = "^[[:space:]]*asmsub op_(" strip ")\\(\\)" }
          skip { if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) skip=0; next }
          $0 ~ re { print $0; print "        %asm {{"; print "            rts"; print "        }}"; print "    }"; skip=1; next }
          { print }
      ' \
      > "$gen/vm.p8"
    # lower PCODE_BASE for this tier (match the CURRENT full base, whatever hex it is -- not a fixed literal)
    sed -E "s/const uword PCODE_BASE = \\\$[0-9A-Fa-f]+/const uword PCODE_BASE = ${pbase}/" src/shared/pcode_format.p8 > "$gen/pcode_format.p8"
    if [ "$visual" = "visual" ]; then
        sed 's/const bool TESTBENCH = true/const bool TESTBENCH = false/' src/runtime/vm_runtime.p8 > "$gen/$out.p8"
    else
        cp src/runtime/vm_runtime.p8 "$gen/$out.p8"
    fi
    "$JAVA" -jar "$PROG8C" -target cx16 -srcdirs "$gen;$SRCDIRS" -out build "$gen/$out.p8"
    echo "built: build/$out.prg ($name tier${visual:+ $visual})"
    bash "$(dirname "${BASH_SOURCE[0]}")/assert-pcode-base.sh" "build/$out.vice-mon-list" "$gen/pcode_format.p8"
}

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
    nosarr)
        # Runtime tier = FULL minus string arrays (DIM A$()). The compiler bundles this for any program
        # that never DIMs a string array (the common case), so its P-code loads at NOSARR_PCODE_BASE
        # (gpc.p8) instead of the full base -- shrinking the whole compiled .PRG. Strips only the four
        # string-array opcodes; prog8 then DCEs sarr_alloc/sarr_desc. Keeps bstr (scalar strings + funcs),
        # numeric arrays, %int, I/O, X16, DATA -- everything else the full runtime has. keep-bstr=yes.
        # NOTE: the $3740 base MUST match NOSARR_PCODE_BASE in src/compiler/gpc.p8 (assert enforces the fit).
        [ "$TARGET" = "runtime" ] || { echo "nosarr mode only applies to the runtime target"; exit 1; }
        build_tier nosarr 'sdim|saload|sastore|rdstr' yes '$3740' "$3"
        exit 0
        ;;
    noint)
        # Phase 3 "int optional" -- two shapes by target:
        #  runtime: a tier that strips the 25 native-integer opcodes (67..91, ipushi..iastore). op_ftoi and
        #    op_idim are plain subs prog8 DCEs once the _optab repoint orphans them; the other 23 are asmsubs
        #    the awk collapses to rts. keep-bstr=yes (strings/float/numeric+string arrays all stay). Its
        #    P-code loads at NOINT_PCODE_BASE. NOTE: the $3400 base MUST match NOINT_PCODE_BASE in gpc.p8.
        #  gpc: the noint compiler (INTSUPPORT=false) -- `%` vars/literals degrade to float and no integer
        #    opcode is emitted, so its output bundles the noint runtime. Composes with visual/interactive ($3).
        if [ "$TARGET" = "runtime" ]; then
            build_tier noint 'ipushi|iloadv|istorv|iadd|isub|imul|ineg|itof2|itof|ftoi|icmpeq|icmpne|icmplt|icmpgt|icmple|icmpge|ijz|iand|ior|inot|iforpush|ifornext|idim|iaload|iastore' yes '$3400' "$3"
            exit 0
        fi
        [ "$TARGET" = "gpc" ] || { echo "noint mode only applies to the runtime or gpc target"; exit 1; }
        rm -rf build/gen && mkdir -p build/gen
        NISEDS='s/const bool INTSUPPORT = true/const bool INTSUPPORT = false/'
        case "$3" in
            visual)      NISEDS="$NISEDS; s/const bool TESTBENCH = true/const bool TESTBENCH = false/" ;;
            interactive) NISEDS="$NISEDS; s/const bool TESTBENCH = true/const bool TESTBENCH = false/; s/const bool INTERACTIVE = false/const bool INTERACTIVE = true/" ;;
        esac
        sed "$NISEDS" "$SRC" > "build/gen/${BASE}_noint.p8"
        "$JAVA" -jar "$PROG8C" -target cx16 -srcdirs "$SRCDIRS" -out build "build/gen/${BASE}_noint.p8"
        echo "built: build/${BASE}_noint.prg (noint${3:+ $3})"
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
