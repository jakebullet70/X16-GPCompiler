#!/usr/bin/env bash
# Print the machine-code entry point (hex, 4 digits) of a cx16 .prg.
# The entry is the decimal SYS address in the BASIC stub. Rather than assume a fixed
# offset, find the SYS token ($9e = 158), skip any spaces, and read the ASCII digits
# until a non-digit. Robust to the line number's digit count and to GPC's rebranded
# stub ("10 SYS <e>", where a $00 line terminator follows the address). Uses od (not
# python) so it works with MSYS-style paths passed by the build scripts.
prg="$1"
addr=$(od -An -tu1 -N 32 "$prg" | tr -s ' ' '\n' | grep -v '^$' | awk '
  BEGIN{sys=0; d=""; done=0}
  { b=$1+0
    if(sys==0){ if(b==158) sys=1; next }   # 158 = $9e SYS token
    if(b==32 && d==""){ next }             # skip spaces before the address
    if(b>=48 && b<=57){ d=d sprintf("%c",b); next }   # 48..57 = ASCII 0..9
    if(d!=""){ done=1; exit }              # first non-digit after the address: stop (exit runs END)
  }
  END{ if(d!="") print d }')
printf '%04X\n' "$addr"
