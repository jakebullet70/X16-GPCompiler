#!/usr/bin/env bash
# Run a prg headless and assert its printed text (echoed via EMU_CHROUT) matches.
#   assert-output.sh <prg> "<expected>"     (\n in expected = newline)
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/env.sh"
cd "$ROOT"

PRG="$1"; EXPECT="$2"
ENTRY="$(bash "$DIR/entry-addr.sh" "$PRG")"

extra=()
[ -n "$FSROOT" ] && extra=(-fsroot "$FSROOT")
# RUN executes to STP; the program's EMU_CHROUT bytes appear on stdout (host LF).
raw=$(printf 'RUN %s\n' "$ENTRY" | timeout 30 "$X16EMU" -testbench -warp "${extra[@]}" -prg "$PRG" 2>&1 | tr -d '\r')
# drop the testbench protocol/administrative lines; what remains is program output
got=$(echo "$raw" | grep -vxE 'Testbench mode\.\.\.|RDY|STP|Exit testbench\.|')
exp=$(printf '%b' "$EXPECT")

if [[ "$got" == "$exp" ]]; then
    echo "  ok   output = [$got]"
    echo "PASS"; exit 0
else
    echo "  FAIL output = [$got]  expected [$exp]"
    echo "--- raw ---"; echo "$raw"
    exit 1
fi
