#!/usr/bin/env bash
# assert-pcode-base.sh <vice-mon-list>
#
# Guards the PCODE_BASE invariant (see docs/memory/gpc-runtime-asm-conversion.md):
#   A compiled .PRG is [$0801 runtime code + BSS][pcode @ PCODE_BASE]. The runtime's
#   low-RAM footprint (code + hot BSS) MUST end below PCODE_BASE, or STANDALONE loaded
#   P-code silently overlaps runtime RAM and is corrupted at run time. The in-process
#   compiler is immune (it runs P-code from banked RAM), so the corpus's check-basic
#   tests PASS while check-standalone silently breaks -- exactly the trap that bit int
#   arrays (2c). This turns that silent trap into a loud build failure.
#
# Authoritative top = the `prog8_program_end` label (end of code + all BSS + slabs)
# from the 64tass .vice-mon-list. PCODE_BASE is read from the frozen contract source.
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST="$1"
FMT="$ROOT/src/shared/pcode_format.p8"

if [ ! -f "$LIST" ]; then
    echo "assert-pcode-base: map not found: $LIST" >&2
    exit 1
fi

# prog8_program_end: 'al <hexaddr> .prog8_program_end'
TOP_HEX=$(awk '/\.prog8_program_end$/ {print $2; exit}' "$LIST")
if [ -z "$TOP_HEX" ]; then
    echo "assert-pcode-base: could not find prog8_program_end in $LIST" >&2
    exit 1
fi

# PCODE_BASE = $XXXX  (frozen contract const)
BASE_HEX=$(grep -oE 'PCODE_BASE[[:space:]]*=[[:space:]]*\$[0-9A-Fa-f]+' "$FMT" | grep -oE '\$[0-9A-Fa-f]+' | tr -d '$' | head -1)
if [ -z "$BASE_HEX" ]; then
    echo "assert-pcode-base: could not read PCODE_BASE from $FMT" >&2
    exit 1
fi

TOP=$((16#$TOP_HEX))
BASE=$((16#$BASE_HEX))
MARGIN=$((BASE - TOP))

printf 'PCODE_BASE guard: footprint top $%04x, PCODE_BASE $%04x, margin %d bytes\n' "$TOP" "$BASE" "$MARGIN"

if [ "$TOP" -ge "$BASE" ]; then
    echo "" >&2
    echo "  *** PCODE_BASE INVARIANT VIOLATED ***" >&2
    printf '  runtime footprint ends at $%04x, at/above PCODE_BASE $%04x (over by %d bytes).\n' "$TOP" "$BASE" "$((TOP - BASE))" >&2
    echo "  STANDALONE compiled programs would silently corrupt their loaded P-code." >&2
    printf '  Fix: raise PCODE_BASE in %s above $%04x (leave margin).\n' "src/shared/pcode_format.p8" "$TOP" >&2
    exit 1
fi

# Warn (do not fail) when the cushion gets thin -- gives a heads-up before the next
# opcode/BSS growth silently eats the whole margin.
if [ "$MARGIN" -lt 256 ]; then
    printf 'assert-pcode-base: WARNING margin is only %d bytes (<256) -- consider raising PCODE_BASE soon.\n' "$MARGIN" >&2
fi
