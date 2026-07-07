#!/usr/bin/env bash
# Verify the INTERACTIVE filename prompt HEADLESSLY. The prompt build reads a source name and an
# output name from the keyboard, so we prime the keyboard queue via kbdbuf_put ($FEC3), then JMP
# into the compiler. It reads the source file "A" off HostFS, writes the output, and runs the
# program in-process; we assert the resulting mailbox AND that the output file was actually written.
#   check-prompt.sh          "<basic>" <addr>=<hex> ...   ; types  A <CR> B <CR>   -> writes "B"
#   check-prompt.sh default  "<basic>" <addr>=<hex> ...   ; types  A <CR>   <CR>   -> writes "c.A"
# Requires build/gpc_prompt.prg (INTERACTIVE=true, TESTBENCH=true) and build/vm_runtime.prg.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/env.sh"; cd "$ROOT"

MODE="named"
case "$1" in default|correction) MODE="$1"; shift;; esac
SRCLINE="$1"; shift
FS="$(mktemp -d)"
printf '%b\n' "$SRCLINE" | python "$DIR/tokenize.py" > "$FS/A"     # source, named "A"
cp build/vm_runtime.prg "$FS/runtime.prg"                          # bundled VM (fixed name)

if [ "$MODE" = "default" ]; then
    KEYS="65 13 13"                     # 'A' CR  CR  (empty output name -> default "c.A")
    LABEL="A -> (default c.A)"
elif [ "$MODE" = "correction" ]; then
    # Type 'X', DELETE it, then 'A' -> the name resolves to "A". A pre-fix read_name stored the
    # DELETE byte ($14 = 20) into the name, so f_open saw "X<DEL>A" and failed with FILE NOT FOUND.
    KEYS="88 20 65 13 66 13"            # 'X' DEL 'A' CR 'B' CR  (source "A" via a correction) -> 'B'
    LABEL="X<DEL>A -> B"
    rm -f "$FS/B"
else
    KEYS="65 13 66 13"                  # 'A' CR 'B' CR
    LABEL="A -> B"
    rm -f "$FS/B"
fi
echo "  prompt  \"$SRCLINE\"  (names typed: $LABEL)"

CENTRY="$(bash "$DIR/entry-addr.sh" build/gpc_prompt.prg)"
clo=$(( 0x$CENTRY & 0xff )); chi=$(( (0x$CENTRY >> 8) & 0xff ))

# routine @ $0500: kbdbuf_put each key, then JMP the compiler entry
gen_route() {
    local a=$((0x0500))
    emit() { printf 'STM %04X %s\n' "$a" "$1"; a=$((a+1)); }
    for c in $KEYS; do
        emit A9; emit "$(printf '%02X' "$c")"; emit 20; emit C3; emit FE
    done
    emit 4C; emit "$(printf '%02X' "$clo")"; emit "$(printf '%02X' "$chi")"   # JMP compiler entry
}
CMDS="$(gen_route; echo "RUN 0500"; for p in "$@"; do printf 'RQM %s\n' "${p%%=*}"; done)"
raw=$(echo "$CMDS" | timeout 30 "$X16EMU" -testbench -warp -fsroot "$FS" -prg build/gpc_prompt.prg 2>&1 | tr -d '\r')

# was the output file produced? (default name is case-insensitive on the host)
prod=0
if [ "$MODE" = "default" ]; then
    ls "$FS" | grep -qiE '^c\.a$' && prod=1
else
    [ -s "$FS/B" ] && prod=1
fi
rm -rf "$FS"

norm() { echo "$1" | tr 'A-Z' 'a-z' | sed 's/^0*\([0-9a-f]\)/\1/'; }
after=$(echo "$raw" | sed -n '/STP$/,$p' | tail -n +2)     # RQM responses follow the single STP
mapfile -t got < <(echo "$after" | grep -iE '^[0-9a-f]+$')
rc=0; i=0
for p in "$@"; do
    g="$(norm "${got[$i]:-none}")"; e="$(norm "${p#*=}")"
    if [ "$g" = "$e" ]; then echo "  ok   \$${p%%=*} = $g"; else echo "  FAIL \$${p%%=*} = $g (expected $e)"; rc=1; fi
    i=$((i+1))
done
if [ "$prod" = 1 ]; then echo "  ok   wrote the output file"; else echo "  FAIL: output file not written"; rc=1; fi
[ $rc -eq 0 ] && echo PASS || { echo FAIL; echo "--- raw ---"; echo "$raw" | tail -20; }
exit $rc
