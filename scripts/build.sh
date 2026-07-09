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
# handler name matches <strip-regex> in _optab to a halting _unimpl stub AND collapses its asmsub body
# to a bare `rts` (prog8 never DCEs asmsubs, so stubbing _optab alone leaves the dead hand-asm handler
# in the image; collapsing it reclaims the space, which lets this tier claim a lower PCODE_BASE -- the
# real per-program win, since a standalone .PRG floor is PCODE_BASE-$0801). keep-bstr=no also comments
# out bstr.init so prog8 dead-strips all of bstr.p8 (string tiers keep it). Overrides vm.p8 +
# pcode_format.p8 via build/gen (placed first on -srcdirs). Writes under a distinct main name so it
# never clobbers the full build/vm_runtime.prg. visual flips TESTBENCH off (READY-returning, for demos).
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
    sed "s/const uword PCODE_BASE = \\\$3C80/const uword PCODE_BASE = ${pbase}/" src/shared/pcode_format.p8 > "$gen/pcode_format.p8"
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
    core|str|arr)
        # Feature-stripped runtime tiers (only meaningful for the runtime target). The compiler
        # auto-selects the lowest tier whose feature set covers what a program actually uses:
        #   core -- float arith + control flow + PRINT + CALLFN + int-literal coercion only.
        #   str  -- core PLUS strings (bstr + string handlers), for programs that use string
        #           literals/vars/functions but no arrays, %int, X16 keywords, I/O, or DATA.
        #   arr  -- core PLUS numeric arrays (DIM A()), for programs that use float arrays but no
        #           strings, %int, X16, I/O, or DATA.
        # NOTE the core int boundary: IPUSHI/INEG/ITOF/ITOF2/FTOI (literal coercion) AND IJZ (a bare
        # integer-literal IF condition -- "IF 0" -- branches via IJZ, no % var needed) are CORE. Only
        # %-variable ops (iloadv/istorv/iadd.../icmp*/iand/ior/inot/ifor*/int-arrays) are opt-in.
        [ "$TARGET" = "runtime" ] || { echo "$MODE mode only applies to the runtime target"; exit 1; }
        # The full optional set (everything the core tier strips):
        CORE_STRIP='prints|pushs|loads|stors|concat|poke|peek|sys|dim|aload|astore|inputv|inputs|strnum|numstr|lefts|rights|mids|read|reads|restore|sdim|saload|sastore|rdnum|rdstr|scmp|open|close|getch|status|chkout|chkin|clrch|wait|passthru|callx|callxs|iloadv|istorv|iadd|isub|imul|icmpeq|icmpne|icmplt|icmpgt|icmple|icmpge|iand|ior|inot|iforpush|ifornext|idim|iaload|iastore'
        # The str tier keeps the string opcodes (prints/pushs/loads/stors/concat/strnum/numstr/lefts/
        # rights/mids/sdim/saload/sastore/scmp) live; it strips arrays, %int, X16, I/O, DATA. inputs/
        # reads/rdstr stay stripped -- they couple strings to I/O or DATA, so any program using them
        # trips those feature bits and lands in the full tier anyway.
        STR_STRIP='poke|peek|sys|dim|aload|astore|inputv|inputs|read|reads|restore|rdnum|rdstr|open|close|getch|status|chkout|chkin|clrch|wait|passthru|callx|callxs|iloadv|istorv|iadd|isub|imul|icmpeq|icmpne|icmplt|icmpgt|icmple|icmpge|iand|ior|inot|iforpush|ifornext|idim|iaload|iastore'
        # The arr tier keeps the numeric-array opcodes (dim/aload/astore) live; it strips strings,
        # %int (incl. %int arrays idim/iaload/iastore), X16, I/O, DATA.
        ARR_STRIP='prints|pushs|loads|stors|concat|poke|peek|sys|inputv|inputs|strnum|numstr|lefts|rights|mids|read|reads|restore|sdim|saload|sastore|rdnum|rdstr|scmp|open|close|getch|status|chkout|chkin|clrch|wait|passthru|callx|callxs|iloadv|istorv|iadd|isub|imul|icmpeq|icmpne|icmplt|icmpgt|icmple|icmpge|iand|ior|inot|iforpush|ifornext|idim|iaload|iastore'
        case "$MODE" in
            core) build_tier core "$CORE_STRIP" no  '$1D00' "$3" ;;   # keep-bstr=no: core has no strings
            str)  build_tier str  "$STR_STRIP"  yes '$2A20' "$3" ;;   # keep-bstr=yes: str needs bstr; footprint ~$2907
            arr)  build_tier arr  "$ARR_STRIP"  no  '$2240' "$3" ;;   # keep-bstr=no: numeric arrays only; footprint ~$2126
        esac
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
