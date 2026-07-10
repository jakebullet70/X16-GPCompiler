#!/usr/bin/env bash
# Compile a BASIC snippet to a STANDALONE out.prg (the runtime VM bundled in) and verify it
# runs with NO compiler present -- the Blitz payoff. Two emulator runs:
#   1. the compiler reads source.prg + gpc.runtime.bin from HostFS and writes out.prg
#   2. out.prg runs on its own (no -fsroot, no compiler) and we assert its result
#
#   check-standalone.sh mail "<basic>" <addr>=<hex> ...   (assert the VM numeric mailbox)
#   check-standalone.sh out  "<basic>" "<expected text>"  (assert the printed output)
#
# Requires build/gpc.prg and build/vm_runtime.prg (build them first). The compiler + bundled runtime
# are overridable via env for tier tests: GPC (compiler .prg), RT (runtime .prg), RTNAME (the on-disk
# name that compiler opens it as). Defaults exercise the full compiler + full runtime.
#   GPC=build/gpc_noint.prg RT=build/vm_runtime_noint.prg RTNAME=gpc.rt.noint.bin check-standalone.sh ...
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/env.sh"; cd "$ROOT"
GPC="${GPC:-build/gpc.prg}"; RT="${RT:-build/vm_runtime.prg}"; RTNAME="${RTNAME:-gpc.runtime.bin}"

MODE="$1"; SRCLINE="$2"; shift 2
FS="$(mktemp -d)"
printf '%b\n' "$SRCLINE" | python "$DIR/tokenize.py" > "$FS/source.prg"
cp "$RT" "$FS/$RTNAME"                              # the compiler opens the runtime under this name
[ -f build/vm_runtime_nosarr.prg ] && cp build/vm_runtime_nosarr.prg "$FS/gpc.rt.nosarr.bin"   # nosarr tier for no-DIM-A$() programs
rm -f "$FS/out.prg"
echo "  \"$SRCLINE\"  (standalone)"

# 1) run the compiler; it emits out.prg into the HostFS root
CENTRY="$(bash "$DIR/entry-addr.sh" "$GPC")"
printf 'RUN %s\n' "$CENTRY" | timeout 30 "$X16EMU" -testbench -warp -fsroot "$FS" -prg "$GPC" >/dev/null 2>&1
if [ ! -s "$FS/out.prg" ]; then
    echo "  FAIL: compiler did not write out.prg"; rm -rf "$FS"; exit 1
fi

# 2) run out.prg standalone (FSROOT deliberately unset -> no HostFS, no compiler) and assert
if [ "$MODE" = "out" ]; then
    bash "$DIR/assert-output.sh" "$FS/out.prg" "$1"
else
    bash "$DIR/assert-mailbox.sh" "$FS/out.prg" "$@"
fi
rc=$?
rm -rf "$FS"
exit $rc
