#!/usr/bin/env bash
# Run a prg headless and assert memory-mailbox bytes equal expected hex values.
#
# Usage: assert-mailbox.sh <prg> <addr>=<hex> [<addr>=<hex> ...]
#   e.g. assert-mailbox.sh build/gpc.prg 0400=2a 0401=0 0402=aa
#
# The .prg entry point is derived automatically. Exits 0 iff every read matches.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/env.sh"
cd "$ROOT"

PRG="$1"; shift
ENTRY="$(bash "$DIR/entry-addr.sh" "$PRG")"

norm() { echo "$1" | tr 'A-Z' 'a-z' | sed 's/^0*\([0-9a-f]\)/\1/'; }

addrs=(); expects=()
for pair in "$@"; do
    addrs+=("${pair%%=*}")
    expects+=("$(norm "${pair#*=}")")
done

extra=()
[ -n "$FSROOT" ] && extra=(-fsroot "$FSROOT")     # HostFS root for on-disk source
cmds=$(printf 'RUN %s\n' "$ENTRY"; for a in "${addrs[@]}"; do printf 'RQM %s\n' "$a"; done)
raw=$(echo "$cmds" | timeout 30 "$X16EMU" -testbench -warp "${extra[@]}" -prg "$PRG" 2>&1 | tr -d '\r')
# RQM responses come AFTER the STP marker; program output (also hex-ish) precedes it.
# STP may share a line with un-terminated program output (e.g. "15STP"), so match STP$.
after=$(echo "$raw" | sed -n '/STP$/,$p' | tail -n +2)
mapfile -t got < <(echo "$after" | grep -iE '^[0-9a-f]+$')

ok=1
for i in "${!addrs[@]}"; do
    g="$(norm "${got[$i]:-none}")"
    if [[ "$g" == "${expects[$i]}" ]]; then
        echo "  ok   \$${addrs[$i]} = $g"
    else
        echo "  FAIL \$${addrs[$i]} = $g (expected ${expects[$i]})"
        ok=0
    fi
done

if [[ $ok -eq 1 ]]; then echo "PASS"; exit 0; else echo "FAIL"; echo "--- raw ---"; echo "$raw"; exit 1; fi
