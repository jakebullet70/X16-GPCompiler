#!/usr/bin/env bash
# Print the machine-code entry point (hex, 4 digits) of a Prog8 cx16 .prg.
# The entry is the decimal SYS address in the BASIC stub: the digits begin at
# file offset 8 (2 load-addr + 2 link + 2 linenum + 1 SYS-token + 1 space).
prg="$1"
addr=$(od -An -c -j 8 -N 6 "$prg" | tr -cd '0-9')
printf '%04X\n' "$addr"
