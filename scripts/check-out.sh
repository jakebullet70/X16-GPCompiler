#!/usr/bin/env bash
# Tokenize a BASIC snippet to disk, compile it with the (pre-built) gpc.prg,
# and assert its printed text output.
#   check-out.sh "<basic>" "<expected output>"   (\n = newline)
# Requires build/gpc.prg (build once with build.sh gpc).
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCLINE="$1"; EXPECT="$2"
FS="$(mktemp -d)"
printf '%b\n' "$SRCLINE" | python "$DIR/tokenize.py" > "$FS/source.prg"
echo "  \"$SRCLINE\""
FSROOT="$FS" bash "$DIR/assert-output.sh" build/gpc.prg "$EXPECT"
rc=$?
rm -rf "$FS"
exit $rc
