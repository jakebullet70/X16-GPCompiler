#!/usr/bin/env bash
# Benchmark harness: run each bench/NN_*.bas both UNCOMPILED (stock X16 BASIC ROM) and
# GPC-COMPILED (standalone), measuring EMULATED X16 time in 60Hz jiffies (host-speed independent;
# 60 jiffies = 1 emulated second).
#
# Timing MUST run non-warp (the 60Hz timer IRQ is frozen under -warp / -testbench -- the same reason
# SLEEP hangs headless) and non-testbench (needs real VERA VSYNC IRQs). Each program POWEROFFs when
# done so the emulator exits promptly and flushes its (block-buffered) -echo stdout.
#   uncompiled: line 1 = "TS=TI", line 9000 = 'PRINT "R=";TI-TS'   (TI works in ROM BASIC)
#   compiled  : those lines are rewritten to read the jiffy timer via bank-0 PEEK (GPC has no TI)
#   *.int.bas : GPC native-integer (%) variant -- stock BASIC has NO integer FOR, so compiled-only.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOTB="$(cd "$DIR/.." && pwd)"
source "$ROOTB/scripts/env.sh"; cd "$ROOTB"
GPC=build/gpc.prg
CE="$(bash scripts/entry-addr.sh "$GPC")"
C1='1 BK=PEEK(0):POKE 0,0:TS=PEEK(43189)*256+PEEK(43190):POKE 0,BK'
C9='9000 POKE 0,0:TE=PEEK(43189)*256+PEEK(43190):POKE 0,BK:PRINT "R=";TE-TS'
FS="$(mktemp -d)"; trap 'rm -rf "$FS"' EXIT
cp build/vm_runtime.prg "$FS/gpc.runtime.bin"; cp build/vm_runtime_nosarr.prg "$FS/gpc.rt.nosarr.bin"

run_prg(){ timeout 40 "$X16EMU" -echo raw -run -prg "$1" 2>&1 | tr -d '\r' | grep -aoE 'R= *[0-9]+' | head -1 | grep -oE '[0-9]+'; }
compile(){ python scripts/tokenize.py < "$1" > "$FS/source.prg"; rm -f "$FS/out.prg"; printf 'RUN %s\n' "$CE" | timeout 60 "$X16EMU" -testbench -warp -fsroot "$FS" -prg "$GPC" >/dev/null 2>&1 || true; [ -s "$FS/out.prg" ]; }

printf '%-16s %10s %10s %9s %8s %8s\n' BENCHMARK UNCOMP_j COMP_j SPEEDUP UNC_sec CMP_sec
printf '%-16s %10s %10s %9s %8s %8s\n' "----------------" "--------" "------" "-------" "------" "------"
for bas in bench/0[1-7]_*.bas; do
  case "$bas" in *.int.bas) continue;; esac
  name="$(basename "$bas" .bas)"
  python scripts/tokenize.py < "$bas" > "$FS/uc.prg"; UJ="$(run_prg "$FS/uc.prg" || true)"
  sed -e "s|^1 TS=TI\$|$C1|" -e "s|^9000 PRINT \"R=\";TI-TS\$|$C9|" "$bas" > "$FS/c.bas"
  if compile "$FS/c.bas"; then CJ="$(run_prg "$FS/out.prg" || true)"; else CJ=""; fi
  US="$(awk "BEGIN{printf \"%.2f\", ${UJ:-0}/60}")"; CS="$(awk "BEGIN{printf \"%.2f\", ${CJ:-0}/60}")"
  SP="n/a"; [ -n "$UJ" ] && [ -n "$CJ" ] && [ "${CJ:-0}" -gt 0 ] && SP="$(awk "BEGIN{printf \"%.1fx\", $UJ/$CJ}")"
  printf '%-16s %10s %10s %9s %8s %8s\n' "$name" "${UJ:-ERR}" "${CJ:-ERR}" "$SP" "$US" "$CS"
done
# native-integer showcase (compiled-only). Compare its jiffies to 07_intmath's stock-float uncompiled.
for bas in bench/*.int.bas; do
  [ -e "$bas" ] || continue
  name="$(basename "$bas" .bas)"
  if compile "$bas"; then CJ="$(run_prg "$FS/out.prg" || true)"; else CJ="COMPILE-FAIL"; fi
  CS="$(awk "BEGIN{printf \"%.2f\", ${CJ:-0}/60}" 2>/dev/null || echo -)"
  printf '%-16s %10s %10s %9s %8s %8s\n' "$name" "(none)" "${CJ:-ERR}" "int-only" "-" "$CS"
done
