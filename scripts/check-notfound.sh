#!/usr/bin/env bash
# Verify the INTERACTIVE compiler checks the INPUT file exists BEFORE prompting for an output
# name / compiling. Regression guard: a typo'd (non-existent) input must report FILE NOT FOUND
# and must NOT delete a pre-existing c.<name> (default_out_name would otherwise wipe it).
#
#   check-notfound.sh   -> types a missing source name "Z", asserts err_code=7 ($0403) and that
#                          a pre-seeded stale "c.Z" survives untouched.
# Requires build/gpc_prompt.prg (INTERACTIVE=true, TESTBENCH=true) and build/vm_runtime.prg.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/env.sh"; cd "$ROOT"

FS="$(mktemp -d)"
cp build/vm_runtime.prg "$FS/gpc.runtime.bin"
printf '10 PRINT 1\n' | python "$DIR/tokenize.py" > "$FS/A"   # a real source (so the runtime loads fine)
STALE='STALE PRECIOUS BUILD'
printf '%s' "$STALE" > "$FS/c.Z"                              # a previous good build for name "Z"
echo "  notfound  (type missing input 'Z'; expect FILE NOT FOUND, c.Z preserved)"

CENTRY="$(bash "$DIR/entry-addr.sh" build/gpc_prompt.prg)"
clo=$(( 0x$CENTRY & 0xff )); chi=$(( (0x$CENTRY >> 8) & 0xff ))
# routine @ $0500: kbdbuf_put 'Z'(90) CR(13), then JMP the compiler entry
gen() { local a=$((0x0500)); emit(){ printf 'STM %04X %s\n' "$a" "$1"; a=$((a+1)); }
  for c in 90 13; do emit A9; emit "$(printf '%02X' "$c")"; emit 20; emit C3; emit FE; done
  emit 4C; emit "$(printf '%02X' "$clo")"; emit "$(printf '%02X' "$chi")"; }
raw=$( (gen; echo "RUN 0500"; echo "RQM 0403") | timeout 30 "$X16EMU" -testbench -warp -fsroot "$FS" -prg build/gpc_prompt.prg 2>&1 | tr -d '\r' )

# err_code is the first hex value after the STP marker
got=$(echo "$raw" | sed -n '/STP$/,$p' | tail -n +2 | grep -iE '^[0-9a-f]+$' | head -1)
survived=0; [ -f "$FS/c.Z" ] && [ "$(cat "$FS/c.Z")" = "$STALE" ] && survived=1
newout=0; ls "$FS" | grep -qiE '^z$' && newout=1
rm -rf "$FS"

rc=0
if [ "$(echo "$got" | tr 'A-F' 'a-f')" = "7" ]; then echo "  ok   \$0403 = 7 (FILE NOT FOUND)"; else echo "  FAIL \$0403 = ${got:-none} (expected 7)"; rc=1; fi
if [ "$survived" = 1 ]; then echo "  ok   stale c.Z preserved (no data loss)"; else echo "  FAIL: stale c.Z was deleted/changed"; rc=1; fi
if [ "$newout" = 0 ]; then echo "  ok   no spurious output written"; else echo "  FAIL: wrote output for a missing input"; rc=1; fi
[ $rc -eq 0 ] && echo PASS || { echo FAIL; echo "--- raw ---"; echo "$raw" | tail -20; }
exit $rc
