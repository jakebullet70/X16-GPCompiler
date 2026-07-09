#!/usr/bin/env bash
# Verify a BASIC program that uses INPUT, feeding keyboard input HEADLESSLY.
#
#   1. Compile source.prg -> standalone out.prg. (The compiler also runs the program
#      in-process, which blocks on INPUT waiting for a key; out.prg is written before that,
#      so a short timeout still leaves us the file.)
#   2. In ONE emulator RUN, execute a small routine at $0500 that primes the X16 keyboard
#      queue via kbdbuf_put ($FEC3) with the given characters + RETURN, then JMPs straight
#      into out.prg. Doing it in a single RUN (rather than a separate prime RUN then a program
#      RUN) avoids a testbench state quirk where a prior RUN disturbs the next one. out.prg's
#      INPUT then reads the primed queue via GETIN.
#
#   check-input.sh "<input>" "<basic>" mail <addr>=<hex> ...   (assert VM numeric mailbox)
#   check-input.sh "<input>" "<basic>" out  "<expected text>"  (assert printed output)
#
# Requires build/gpc.prg and build/vm_runtime.prg.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/env.sh"; cd "$ROOT"

INPUT="$1"; SRCLINE="$2"; MODE="$3"; shift 3
FS="$(mktemp -d)"
printf '%b\n' "$SRCLINE" | python "$DIR/tokenize.py" > "$FS/source.prg"
cp build/vm_runtime.prg "$FS/gpc.runtime.bin"
[ -f build/vm_runtime_core.prg ] && cp build/vm_runtime_core.prg "$FS/gpc.rt.core.bin"   # core tier
[ -f build/vm_runtime_str.prg ]  && cp build/vm_runtime_str.prg  "$FS/gpc.rt.str.bin"    # str tier
rm -f "$FS/out.prg"
echo "  input='$INPUT'  \"$SRCLINE\""

# 1) compile to out.prg (tolerate the in-process INPUT block: out.prg is already written)
CENTRY="$(bash "$DIR/entry-addr.sh" build/gpc.prg)"
printf 'RUN %s\n' "$CENTRY" | timeout 8 "$X16EMU" -testbench -warp -fsroot "$FS" -prg build/gpc.prg >/dev/null 2>&1
if [ ! -s "$FS/out.prg" ]; then echo "  FAIL: compiler did not write out.prg"; rm -rf "$FS"; exit 1; fi
OENTRY="$(bash "$DIR/entry-addr.sh" "$FS/out.prg")"
olo=$(( 0x$OENTRY & 0xff )); ohi=$(( (0x$OENTRY >> 8) & 0xff ))

# routine @ $0500: kbdbuf_put each char (INPUT text then CR), then JMP OENTRY
gen_route() {
    local a=$((0x0500)) i c
    emit() { printf 'STM %04X %s\n' "$a" "$1"; a=$((a+1)); }
    for (( i=0; i<${#INPUT}; i++ )); do
        c=$(printf '%d' "'${INPUT:$i:1}")
        emit A9; emit "$(printf '%02X' "$c")"; emit 20; emit C3; emit FE
    done
    emit A9; emit 0D; emit 20; emit C3; emit FE          # RETURN
    emit 4C; emit "$(printf '%02X' "$olo")"; emit "$(printf '%02X' "$ohi")"   # JMP OENTRY
}

CMDS="$(gen_route; echo "RUN 0500"
        if [ "$MODE" = mail ]; then for p in "$@"; do printf 'RQM %s\n' "${p%%=*}"; done; fi)"
raw=$(echo "$CMDS" | timeout 30 "$X16EMU" -testbench -warp -prg "$FS/out.prg" 2>&1 | tr -d '\r')
rm -rf "$FS"

norm() { echo "$1" | tr 'A-Z' 'a-z' | sed 's/^0*\([0-9a-f]\)/\1/'; }
rc=0
if [ "$MODE" = mail ]; then
    after=$(echo "$raw" | sed -n '/STP$/,$p' | tail -n +2)     # RQM responses follow the single STP
    mapfile -t got < <(echo "$after" | grep -iE '^[0-9a-f]+$')
    i=0
    for p in "$@"; do
        g="$(norm "${got[$i]:-none}")"; e="$(norm "${p#*=}")"
        if [ "$g" = "$e" ]; then echo "  ok   \$${p%%=*} = $g"; else echo "  FAIL \$${p%%=*} = $g (expected $e)"; rc=1; fi
        i=$((i+1))
    done
else
    got=$(echo "$raw" | grep -vxE 'Testbench mode\.\.\.|RDY|STP|Exit testbench\.|')
    exp=$(printf '%b' "$1")
    if [ "$got" = "$exp" ]; then echo "  ok   output = [$got]"; else echo "  FAIL output = [$got] expected [$exp]"; rc=1; fi
fi
[ $rc -eq 0 ] && echo PASS || { echo FAIL; echo "--- raw ---"; echo "$raw" | grep -vE 'Rockwell|instructions until|relaunch|suppress|only warning|65C816|65C02|does not support|Future Commander|This will be'; }
exit $rc
