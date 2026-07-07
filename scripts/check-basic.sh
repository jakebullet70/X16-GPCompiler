#!/usr/bin/env bash
# Tokenize a BASIC snippet to disk, compile it with the (pre-built) gpc.prg,
# and assert the VM's numeric mailbox result.
#   check-basic.sh "<basic>" <addr>=<hex> [<addr>=<hex> ...]
# Requires build/gpc.prg (build once with build.sh gpc).
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCLINE="$1"; shift
FS="$(mktemp -d)"
printf '%b\n' "$SRCLINE" | python "$DIR/tokenize.py" > "$FS/source.prg"
echo "  \"$SRCLINE\""
FSROOT="$FS" bash "$DIR/assert-mailbox.sh" build/gpc.prg "$@"
rc=$?
rm -rf "$FS"
exit $rc
