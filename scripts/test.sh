#!/usr/bin/env bash
# Run all Blitz-X16 milestone tests. Exits non-zero if any fail.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/env.sh"
cd "$ROOT"

fail=0

echo "== build compiler + VM + runtime once =="
bash "$DIR/build.sh" selftest >/dev/null
bash "$DIR/build.sh" runtime  >/dev/null
bash "$DIR/build.sh" gpc   >/dev/null
bash "$DIR/build.sh" gpc prompt >/dev/null   # INTERACTIVE variant for the filename-prompt test
echo "  ok"

echo
echo "== M0: VM dispatch selftest ((5+3)*2-1 = 15) =="
bash "$DIR/assert-mailbox.sh" build/vm_selftest.prg 0400=0f 0401=0 0402=aa || fail=1

echo
echo "== M1: compile & run PRINT <number> =="
bash "$DIR/check-basic.sh" "10 PRINT 42"  0400=2a 0401=0 || fail=1
bash "$DIR/check-basic.sh" "10 PRINT 300" 0400=2c 0401=1 || fail=1

echo
echo "== M2: integer expressions (precedence + parens) =="
bash "$DIR/check-basic.sh" "10 PRINT 2+3*4"    0400=0e || fail=1   # 14
bash "$DIR/check-basic.sh" "10 PRINT (2+3)*4"  0400=14 || fail=1   # 20
bash "$DIR/check-basic.sh" "10 PRINT 100-7*3"  0400=4f || fail=1   # 79
bash "$DIR/check-basic.sh" "10 PRINT 2*3+4*5"  0400=1a || fail=1   # 26
bash "$DIR/check-out.sh"   "10 PRINT 100/9"    "11.1111111" || fail=1   # real float division
bash "$DIR/check-basic.sh" "10 PRINT (8-2)/(1+2)" 0400=2 || fail=1 # 2
bash "$DIR/check-basic.sh" "10 PRINT -5+8"     0400=3            || fail=1  # unary minus
bash "$DIR/check-basic.sh" "10 PRINT 10*-2"    0400=ec 0401=ff || fail=1  # -20

echo
echo "== M3: variables + LET =="
bash "$DIR/check-basic.sh" "10 A=5:PRINT A"            0400=5  || fail=1
bash "$DIR/check-basic.sh" "10 A=5:B=A*2:PRINT B"      0400=0a || fail=1  # 10
bash "$DIR/check-basic.sh" "10 LET X=7:PRINT X+X"      0400=0e || fail=1  # 14
bash "$DIR/check-basic.sh" "10 PRINT Q"               0400=0  || fail=1  # unset var = 0
bash "$DIR/check-basic.sh" "10 A1=3:A2=4:PRINT A1*A2"  0400=0c || fail=1  # 12
bash "$DIR/check-basic.sh" "10 N=10:N=N+5:PRINT N"     0400=0f || fail=1  # 15 (reassign)

echo
echo "== M4: comparisons =="
bash "$DIR/check-basic.sh" "10 PRINT 3<5"  0400=ff 0401=ff || fail=1  # true = -1
bash "$DIR/check-basic.sh" "10 PRINT 5<3"  0400=0  0401=0  || fail=1  # false = 0
bash "$DIR/check-basic.sh" "10 PRINT 5=5"  0400=ff 0401=ff || fail=1
bash "$DIR/check-basic.sh" "10 PRINT 7<>7" 0400=0            || fail=1
bash "$DIR/check-basic.sh" "10 PRINT 4>=4" 0400=ff 0401=ff || fail=1

echo
echo "== M4: IF / THEN =="
bash "$DIR/check-basic.sh" "10 IF 1 THEN PRINT 42"  0400=2a || fail=1  # taken
bash "$DIR/check-basic.sh" "10 IF 0 THEN PRINT 42"  0400=0  || fail=1  # skipped -> 0
# "IF cond GOTO n" shorthand (no THEN) == IF cond THEN GOTO n
bash "$DIR/check-basic.sh" "10 X=5:IF X>0 GOTO 30\n20 X=99\n30 PRINT X" 0400=5 || fail=1  # GOTO taken, skips 20
bash "$DIR/check-basic.sh" "10 X=0:IF X>0 GOTO 30\n20 X=7\n30 PRINT X"  0400=7 || fail=1  # not taken, falls through

echo
echo "== M4: GOTO + forward-reference pass-2 fixup =="
# forward GOTO 30 (line 30 not yet seen at emit time) skips line 20:
bash "$DIR/check-basic.sh" "10 GOTO 30\n20 PRINT 99\n30 PRINT 7"  0400=7 || fail=1
# backward loop: sum 1..5 = 15
bash "$DIR/check-basic.sh" "10 S=0:I=1\n20 S=S+I:I=I+1\n30 IF I<=5 THEN GOTO 20\n40 PRINT S" 0400=0f || fail=1
# count down 5..1, last printed = 1
bash "$DIR/check-basic.sh" "10 I=5\n20 PRINT I\n30 I=I-1\n40 IF I>0 THEN GOTO 20" 0400=1 || fail=1
# undefined line -> compile error, nothing runs (mailbox result stays 0)
bash "$DIR/check-basic.sh" "10 GOTO 999" 0400=0 || fail=1

echo
echo "== M5: FOR / NEXT =="
# sum 1..10 = 55
bash "$DIR/check-basic.sh" "10 S=0\n20 FOR I=1 TO 10\n30 S=S+I\n40 NEXT I\n50 PRINT S" 0400=37 || fail=1
# STEP: 0+2+4+6+8+10 = 30
bash "$DIR/check-basic.sh" "10 S=0\n20 FOR I=0 TO 10 STEP 2\n30 S=S+I\n40 NEXT\n50 PRINT S" 0400=1e || fail=1
# negative STEP countdown: last I printed = 1
bash "$DIR/check-basic.sh" "10 FOR I=5 TO 1 STEP -1\n20 PRINT I\n30 NEXT I" 0400=1 || fail=1
# nested loops: count iterations 3*4 = 12
bash "$DIR/check-basic.sh" "10 C=0\n20 FOR A=1 TO 3\n30 FOR B=1 TO 4\n40 C=C+1\n50 NEXT B\n60 NEXT A\n70 PRINT C" 0400=0c || fail=1

echo
echo "== M5: GOSUB / RETURN =="
# sum 1..5 via FOR that GOSUBs an adder subroutine = 15
bash "$DIR/check-basic.sh" "10 S=0\n20 FOR I=1 TO 5\n30 GOSUB 100\n40 NEXT I\n50 PRINT S\n60 END\n100 S=S+I:RETURN" 0400=0f || fail=1
# nested GOSUB: 100 calls 200; result 21 = 6+15
bash "$DIR/check-basic.sh" "10 GOSUB 100:PRINT R:END\n100 R=6:GOSUB 200:RETURN\n200 R=R+15:RETURN" 0400=15 || fail=1
# END before subroutine prevents fall-through (else R would be doubled)
bash "$DIR/check-basic.sh" "10 R=0:GOSUB 100:PRINT R:END\n100 R=9:RETURN" 0400=9 || fail=1

echo
echo "== M6: error reporting (\$0403 = err_code category, \$0404/5 = err_line) =="
# a clean compile leaves err_code = 0 (no false positives)
bash "$DIR/check-basic.sh" "10 PRINT 42"                    0400=2a 0403=0  || fail=1
# SYNTAX (1): a stray ')' where a value was expected, on line 20
bash "$DIR/check-basic.sh" "20 PRINT )"                     0403=1 0404=14 || fail=1
# UNDEF'D STATEMENT (2): GOTO a nonexistent line -> pass-2 xref blames its own line (30)
bash "$DIR/check-basic.sh" "10 X=1\n20 X=2\n30 GOTO 999"    0403=2 0404=1e || fail=1
# TYPE MISMATCH (3): string value into a numeric var, and a number into a string var
bash "$DIR/check-basic.sh" '10 A="HI"'                      0403=3 0404=0a || fail=1
bash "$DIR/check-basic.sh" "10 A\$=5"                       0403=3 0404=0a || fail=1
# NEXT WITHOUT FOR (5)
bash "$DIR/check-basic.sh" "10 NEXT"                        0403=5 0404=0a || fail=1
# FORMULA TOO COMPLEX (6): 33 nested '(' overflow the 32-slot operator stack
COMPLEX="10 PRINT $(printf '(%.0s' $(seq 33))1$(printf ')%.0s' $(seq 33))"
bash "$DIR/check-basic.sh" "$COMPLEX"                       0403=6 0404=0a || fail=1
# OUT OF MEMORY (4): enough P-code to overflow the 16 KB banked P-code ceiling -- 250 lines x 15
# PRINTs (~19 KB). Each line is a realistic length (<=160 chars), so it fits the per-line buffer.
OOM=""; for i in $(seq 1 250); do OOM="$OOM$i $(printf 'PRINT 1:%.0s' $(seq 1 14))PRINT 1\n"; done
bash "$DIR/check-basic.sh" "$OOM"                           0403=4 || fail=1

echo
echo "== M7: strings (output-checked) =="
bash "$DIR/check-out.sh" '10 PRINT "HELLO"'                 "HELLO"      || fail=1
bash "$DIR/check-out.sh" '10 A$="HI":PRINT A$'              "HI"         || fail=1
bash "$DIR/check-out.sh" '10 A$="FOO":B$="BAR":PRINT A$+B$' "FOOBAR"     || fail=1
bash "$DIR/check-out.sh" '10 PRINT "A";"B";"C"'             "ABC"        || fail=1
bash "$DIR/check-out.sh" '10 PRINT "X=";5+2'                "X=7"        || fail=1
bash "$DIR/check-out.sh" '10 A$="NAME":PRINT "HI ";A$;"!"'  "HI NAME!"   || fail=1
# numbers still print correctly through the new output path
bash "$DIR/check-out.sh" '10 PRINT 6*7'                     "42"         || fail=1
# string var reused, concatenation chain
bash "$DIR/check-out.sh" '10 A$="AB":A$=A$+"CD":A$=A$+"EF":PRINT A$' "ABCDEF" || fail=1

echo
echo "== String garbage collection (ROM garba2 reclaims abandoned concat temporaries) =="
# 200-char accumulation: without GC this OOM'd at ~45 chars (heap full of dead intermediates); garba2 reclaims
bash "$DIR/check-basic.sh" '10 B$="X"\n20 FOR I=1 TO 200\n30 A$=A$+B$\n40 NEXT\n50 PRINT LEN(A$)' 0400=c8 0401=00 || fail=1
# grows right up to BASIC's 255-char string ceiling
bash "$DIR/check-basic.sh" '10 B$="X"\n20 FOR I=1 TO 255\n30 A$=A$+B$\n40 NEXT\n50 PRINT LEN(A$)' 0400=ff 0401=00 || fail=1
# past 255 is a clean ?STRING TOO LONG (as the ROM does), not a heap overrun / hang
bash "$DIR/check-out.sh"   '10 B$="X"\n20 FOR I=1 TO 300\n30 A$=A$+B$\n40 NEXT\n50 PRINT LEN(A$)' '?STRING TOO LONG' || fail=1
# aliasing: C$=A$ shares A$'s heap string; as A$ grows through many collections, C$ must stay pinned to "HELLO"
bash "$DIR/check-basic.sh" '10 B$="HELLO"\n20 A$=B$+""\n30 C$=A$\n40 FOR I=1 TO 100\n50 A$=A$+"Z"\n60 NEXT\n70 PRINT LEN(C$)' 0400=05 || fail=1
# content survives compaction byte-for-byte: MID$(A$,2,1) is still 'B' ($42) after 150 collections
bash "$DIR/check-basic.sh" '10 A$="ABC"\n20 FOR I=1 TO 150\n30 A$=A$+"."\n40 NEXT\n50 PRINT ASC(MID$(A$,2,1))' 0400=42 || fail=1

echo
echo "== M8: machine access (POKE / PEEK / SYS) =="
# POKE writes a byte to memory ($0500); PEEK reads it back
bash "$DIR/check-basic.sh" "10 POKE 1280,65:PRINT PEEK(1280)"     0400=41 0500=41 || fail=1
# PEEK composes inside expressions: 10*2+1 = 21
bash "$DIR/check-basic.sh" "10 POKE 1280,10:PRINT PEEK(1280)*2+1" 0400=15         || fail=1
# POKE and PEEK take arbitrary expression operands
bash "$DIR/check-basic.sh" "10 A=1280:POKE A,7:PRINT PEEK(A)"     0400=7          || fail=1
# SYS calls machine code: POKE a routine (LDA #$5A; STA $0510; RTS) at $0500, then SYS it
POKESYS="10 POKE 1280,169:POKE 1281,90:POKE 1282,141:POKE 1283,16:POKE 1284,5:POKE 1285,96:SYS 1280"
bash "$DIR/check-basic.sh" "$POKESYS"                             0510=5a         || fail=1

echo
echo "== Command pass-through: X16 keywords GPC doesn't compile, run via ROM BASIC (OP_PASSTHRU) =="
# VPOKE (X16 escape token \$CE\$84) writes 66 to VRAM \$1234 through the ROM interpreter; read it back
# via VERA ADDR0/DATA0 with native POKE/PEEK.  \$9F25=CTRL \$9F20/21/22=ADDR0 \$9F23=DATA0.
VPT='10 VPOKE 0,4660,66\n20 POKE 40741,0\n30 POKE 40736,52\n40 POKE 40737,18\n50 POKE 40738,0\n60 PRINT PEEK(40739)'
bash "$DIR/check-basic.sh"      "$VPT" 0400=42 || fail=1
# a passed-through statement mid-line, then native code continues on the same line (colon-separated)
bash "$DIR/check-basic.sh" '10 VPOKE 0,4661,77:PRINT 5' 0400=5 || fail=1
# standalone: the tokenized statement is bundled into out.prg and run via ROM BASIC, no compiler present
bash "$DIR/check-standalone.sh" mail "$VPT" 0400=42 || fail=1
# pass-through statements can see GPC variables: the compiler substitutes each scalar numeric var with a
# marker the runtime expands to the var's current value, so VPOKE's A reaches the ROM as 4660 (not the
# ROM's own undefined A=0). End-to-end: A drives BOTH a pass-through statement (VPOKE) and a VPEEK.
bash "$DIR/check-basic.sh" '10 A=4660:VPOKE 0,A,66:PRINT VPEEK(0,A)' 0400=42 || fail=1
# a variable inside an expression argument: the ROM still does the arithmetic on the substituted value
bash "$DIR/check-basic.sh" '10 B=100:VPOKE 0,B*40,55:PRINT VPEEK(0,4000)' 0400=37 || fail=1
# a literal $-hex argument is NOT mistaken for a variable (its A-F digits are copied verbatim) -> $FF=255
bash "$DIR/check-basic.sh" '10 VPOKE 0,4660,$FF:PRINT VPEEK(0,4660)' 0400=ff || fail=1
# standalone: variable substitution happens in the runtime, so it works with no compiler present too
bash "$DIR/check-standalone.sh" mail '10 A=4660:VPOKE 0,A,66:PRINT VPEEK(0,A)' 0400=42 || fail=1

echo
echo "== X16 expression functions: VPEEK/JOY/... run via ROM frmevl in expression context (OP_CALLX) =="
# VPEEK reads back through the ROM function evaluator a byte VPOKE wrote to VRAM -> 66 = \$42
bash "$DIR/check-basic.sh" '10 VPOKE 0,4660,66:PRINT VPEEK(0,4660)' 0400=42 || fail=1
# a GPC variable as the address argument: proves the runtime passes the COMPUTED value to frmevl (GPC's
# own variables are not in BASIC's table, so a whole VPEEK(0,A) can't just be handed to the ROM -- the
# compiler evaluates A itself and OP_CALLX formats the value into the call).
bash "$DIR/check-basic.sh" '10 VPOKE 0,4660,99:A=4660:PRINT VPEEK(0,A)'  0400=63 || fail=1
# an arithmetic expression as an argument compiles and is evaluated by GPC before the call
bash "$DIR/check-basic.sh" '10 VPOKE 0,4660,55:PRINT VPEEK(0,4096+564)' 0400=37 || fail=1
# the VPEEK result feeds back into a GPC expression (numeric round-trip both directions)
bash "$DIR/check-basic.sh" '10 VPOKE 0,4660,40:PRINT VPEEK(0,4660)+2' 0400=2a || fail=1
# standalone: VPEEK bundled into out.prg and evaluated via ROM frmevl with no compiler present
bash "$DIR/check-standalone.sh" mail '10 VPOKE 0,4660,66:PRINT VPEEK(0,4660)' 0400=42 || fail=1

echo
echo "== X16 string functions: HEX\$/BIN\$ run via ROM frmevl, result adopted as a GPC string (OP_CALLXS) =="
# HEX$ returns a string temp from the ROM; the runtime frees the BASIC temp and copies the body into a GPC temp
bash "$DIR/check-out.sh" '10 PRINT HEX$(255)'   "FF"       || fail=1
bash "$DIR/check-out.sh" '10 PRINT HEX$(4660)'  "1234"     || fail=1
bash "$DIR/check-out.sh" '10 PRINT BIN$(5)'     "00000101" || fail=1
# a GPC variable as the (numeric) argument
bash "$DIR/check-out.sh" '10 A=255:PRINT HEX$(A)' "FF"     || fail=1
# the result flows into GPC string machinery: assignment, concatenation (two temps), comparison
bash "$DIR/check-out.sh"   '10 A$=HEX$(255):PRINT A$'        "FF"    || fail=1
bash "$DIR/check-out.sh"   '10 PRINT HEX$(255)+HEX$(16)'     "FF10"  || fail=1
bash "$DIR/check-basic.sh" '10 IF HEX$(255)="FF" THEN PRINT 7' 0400=7 || fail=1
# standalone: HEX$ bundled and run with no compiler present
bash "$DIR/check-standalone.sh" out '10 PRINT HEX$(4660)' "1234" || fail=1

echo
echo "== X16 string function RPT\$(byte,count): repeat a byte N times, via ROM frmevl (OP_CALLXS, 2 args) =="
# RPT$ takes TWO numeric args (byte value, repeat count); xbuild formats both into the synthesized call
bash "$DIR/check-out.sh" '10 PRINT RPT$(65,3)'             "AAA"   || fail=1   # byte 65='A' repeated 3x
# LEN of the result is the count (robust: does not depend on how a raw byte renders)
bash "$DIR/check-basic.sh" '10 PRINT LEN(RPT$(65,10))'     0400=0a || fail=1
# variable args -- both evaluated by GPC and passed by value (not in BASIC's var table)
bash "$DIR/check-out.sh" '10 A=66:B=4:PRINT RPT$(A,B)'     "BBBB"  || fail=1
# result flows into the GPC string machinery: assignment then LEN
bash "$DIR/check-basic.sh" '10 A$=RPT$(65,5):PRINT LEN(A$)' 0400=5 || fail=1
# concatenation keeps two live string temps straight
bash "$DIR/check-out.sh" '10 PRINT RPT$(65,2)+RPT$(66,2)'  "AABB"  || fail=1
# a 200-byte result exercises the 256-byte xbuf -- a 128-byte buffer would overflow on the result copy
bash "$DIR/check-basic.sh" '10 PRINT LEN(RPT$(88,200))'    0400=c8 || fail=1
# arity is enforced at compile time -> SYNTAX (1): RPT$ needs 2 args, HEX$ needs 1
bash "$DIR/check-basic.sh" '20 PRINT RPT$(65)'             0403=1  || fail=1
bash "$DIR/check-basic.sh" '20 A$=HEX$(1,2):PRINT A$'      0403=1  || fail=1
# standalone: the 200-byte result works with no compiler present (buffer fix in the bundled runtime)
bash "$DIR/check-standalone.sh" mail '10 PRINT LEN(RPT$(88,200))' 0400=c8 || fail=1

echo
echo "== Integer-first arithmetic (Phase 5): % integer variables compile to native 16-bit opcodes =="
# integer accumulation: S%=S%+I% loop, all integer ops (ILOADV/IADD/ISTORV, no ROM float): 1+..+10 = 55
bash "$DIR/check-basic.sh" '10 S%=0:I%=1\n20 S%=S%+I%:I%=I%+1\n30 IF I%<=10 THEN GOTO 20\n40 PRINT S%' 0400=37 || fail=1
# integer multiply and subtract; a negative integer result
bash "$DIR/check-basic.sh" '10 A%=7:B%=6:PRINT A%*B%'        0400=2a || fail=1     # 42
bash "$DIR/check-out.sh"   '10 A%=100:PRINT A%-150'          "-50"   || fail=1
# an integer literal combines with a % var as an integer op; X%*X%+X% = 9+3 = 12
bash "$DIR/check-basic.sh" '10 X%=3:PRINT X%*X%+X%'          0400=0c || fail=1
# mixed int/float: '/' is always float, so A%/4 keeps the fraction
bash "$DIR/check-out.sh"   '10 A%=10:PRINT A%/4'            "2.5"   || fail=1
# a float RHS truncates TOWARD ZERO into a % var (CBM semantics): 7/2 -> 3, not 4
bash "$DIR/check-basic.sh" '10 A%=7/2:PRINT A%'             0400=3  || fail=1
# A (float) and A% (integer) are SEPARATE variables; they compose in a mixed expression -> 5+9 = 14
bash "$DIR/check-basic.sh" '10 A=5:A%=9:PRINT A+A%'         0400=0e || fail=1
# documented divergence: integer arithmetic is 16-bit and WRAPS (the % opt-in). 30000+30000 -> -5536
bash "$DIR/check-out.sh"   '10 A%=30000:PRINT A%+30000'     "-5536" || fail=1
# standalone: an integer-accumulation loop bundled and run with no compiler present -> 2*100 = 200
bash "$DIR/check-standalone.sh" mail '10 S%=0\n20 FOR I=1 TO 100\n30 S%=S%+2\n40 NEXT\n50 PRINT S%' 0400=c8 || fail=1

echo
echo "== Channel / file I/O (OPEN / CLOSE / PRINT# / GET# / ST, via the KERNAL device API) =="
# round-trip: write "AB" to a file with PRINT#, read it back a byte at a time with GET#, count to EOF (ST)
CIO='10 OPEN 1,8,1,"CIO,S,W"\n20 PRINT#1,"AB";\n30 CLOSE 1\n40 OPEN 1,8,0,"CIO"\n50 GET#1,A$:N=N+1:IF ST=0 GOTO 50\n70 PRINT N\n80 CLOSE 1'
bash "$DIR/check-basic.sh" "$CIO" 0400=2 || fail=1                                                # 2 bytes (incl. EOF read)
# GET# yields the actual bytes: write "XY", read first byte back -> ASC = 88 ('X')
bash "$DIR/check-basic.sh" '10 OPEN 1,8,1,"CI2,S,W"\n20 PRINT#1,"XY";\n30 CLOSE 1\n40 OPEN 1,8,0,"CI2"\n50 GET#1,A$\n60 PRINT ASC(A$)\n70 CLOSE 1' 0400=58 || fail=1
# ST reaches EOF ($40=64) after reading a 3-byte file to the end (standalone can't test this: no HostFS)
bash "$DIR/check-basic.sh" '10 OPEN 1,8,1,"CI3,S,W"\n20 PRINT#1,"ABC";\n30 CLOSE 1\n40 OPEN 1,8,0,"CI3"\n50 GET#1,A$:IF ST=0 GOTO 50\n60 PRINT ST\n70 CLOSE 1' 0400=40 || fail=1

echo
echo "== Arrays: DIM + element load/store =="
# store then read back an element
bash "$DIR/check-basic.sh" "10 DIM A(5):A(2)=42:PRINT A(2)"                      0400=2a || fail=1
# fill with a FOR loop (expression index), read one back: A(4) = 4*4 = 16
bash "$DIR/check-basic.sh" "10 DIM A(10)\n20 FOR I=0 TO 5\n30 A(I)=I*I\n40 NEXT I\n50 PRINT A(4)" 0400=10 || fail=1
# two arrays declared in one DIM; elements compose in expressions
bash "$DIR/check-basic.sh" "10 DIM A(3),B(3):A(0)=5:B(0)=7:PRINT A(0)+B(0)"      0400=0c || fail=1
# a nested array index: A(B(0))
bash "$DIR/check-basic.sh" "10 DIM A(5):DIM B(2):B(0)=3:A(3)=99:PRINT A(B(0))"   0400=63 || fail=1
# scalar A and array A(...) are separate namespaces (PRINT A reads the scalar)
bash "$DIR/check-basic.sh" "10 A=7:DIM A(3):A(0)=9:PRINT A"                      0400=7  || fail=1
# out-of-range element reads as 0 (no corruption)
bash "$DIR/check-basic.sh" "10 DIM A(2):PRINT A(9)"                              0400=0  || fail=1

echo
echo "== Multi-dimensional & string arrays =="
# 2-D numeric: store an element and read it back
bash "$DIR/check-basic.sh" "10 DIM A(2,3):A(1,2)=7:PRINT A(1,2)"                 0400=7  || fail=1
# 2-D fill via nested FOR (a multiplication table); read one cell back: M(3,4) = 12
bash "$DIR/check-basic.sh" "10 DIM M(4,4)\n20 FOR I=1 TO 4\n30 FOR J=1 TO 4\n40 M(I,J)=I*J\n50 NEXT J\n60 NEXT I\n70 PRINT M(3,4)" 0400=0c || fail=1
# row-major layout: A(0,1) and A(1,0) are DISTINCT cells (a wrong layout would alias them)
bash "$DIR/check-basic.sh" "10 DIM A(2,2):A(0,1)=5:A(1,0)=9:PRINT A(1,0)"        0400=9  || fail=1
# a 3-D array
bash "$DIR/check-basic.sh" "10 DIM A(2,2,2):A(1,1,1)=42:PRINT A(1,1,1)"          0400=2a || fail=1
# an out-of-range subscript reads 0 (per-dimension bounds check, no corruption)
bash "$DIR/check-basic.sh" "10 DIM A(2,2):PRINT A(5,1)"                          0400=0  || fail=1
# a nested array index inside a subscript: A(I(0),I(0)) -- exercises the re-entrant subscript parse
bash "$DIR/check-basic.sh" "10 DIM A(3,3):DIM I(2):I(0)=2:A(2,2)=7:PRINT A(I(0),I(0))" 0400=7 || fail=1
# READ fills a numeric array from a DATA table: 10+20+30 = 60
bash "$DIR/check-basic.sh" "10 DIM A(3)\n20 FOR I=0 TO 2\n30 READ A(I)\n40 NEXT I\n50 PRINT A(0)+A(1)+A(2)\n60 DATA 10,20,30" 0400=3c || fail=1
# string array: store an element and read it back
bash "$DIR/check-out.sh"   '10 DIM A$(3):A$(1)="HI":PRINT A$(1)'                 "HI"     || fail=1
# string-array elements compose in string expressions (concatenation)
bash "$DIR/check-out.sh"   '10 DIM A$(2):A$(0)="FOO":A$(1)="BAR":PRINT A$(0)+A$(1)' "FOOBAR" || fail=1
# an unset string-array element reads "" (elements initialize empty)
bash "$DIR/check-out.sh"   '10 DIM A$(3):PRINT "["+A$(2)+"]"'                    "[]"     || fail=1
# a 2-D string array
bash "$DIR/check-out.sh"   '10 DIM A$(2,2):A$(1,2)="X":PRINT A$(1,2)'            "X"      || fail=1
# READ fills a string array from a DATA table (the classic name-table idiom)
bash "$DIR/check-out.sh"   '10 DIM N$(2)\n20 FOR I=0 TO 2\n30 READ N$(I)\n40 NEXT I\n50 PRINT N$(0);N$(2)\n60 DATA A,B,C' "AC" || fail=1
# standalone: a 2-D numeric array survives bundling, no compiler present -> A(3,3) = 9
bash "$DIR/check-standalone.sh" mail "10 DIM A(3,3)\n20 FOR I=1 TO 3\n30 FOR J=1 TO 3\n40 A(I,J)=I*J\n50 NEXT J\n60 NEXT I\n70 PRINT A(3,3)" 0400=9 || fail=1
# standalone: a string array filled by READ from the bundled DATA pool
bash "$DIR/check-standalone.sh" out '10 DIM N$(1)\n20 READ N$(0),N$(1)\n30 PRINT N$(0)+N$(1)\n40 DATA HI,BYE' "HIBYE" || fail=1

echo
echo "== INPUT (keyboard fed headlessly by priming the queue via kbdbuf_put) =="
# read a number, print it back
bash "$DIR/check-input.sh" "42" "10 INPUT A:PRINT A"       mail 0400=2a         || fail=1
# the entered value flows into an expression: 21*2 = 42
bash "$DIR/check-input.sh" "21" "10 INPUT A:PRINT A*2"     mail 0400=2a         || fail=1
# a signed value
bash "$DIR/check-input.sh" "-7" "10 INPUT A:PRINT A"       mail 0400=f9 0401=ff || fail=1
# an optional prompt string before the input
bash "$DIR/check-input.sh" "5"  '10 INPUT "AGE";A:PRINT A' mail 0400=5          || fail=1
# a string variable
bash "$DIR/check-input.sh" "HI" '10 INPUT A$:PRINT A$'     out  "HI"            || fail=1
# a floating-point value entered at the prompt
bash "$DIR/check-input.sh" "2.5" "10 INPUT A:PRINT A*2"    out  "5"             || fail=1

echo
echo "== Floats: real numbers via the ROM Math library =="
# float literals and BASIC-style formatting
bash "$DIR/check-out.sh" "10 PRINT 3.14"                   "3.14"      || fail=1
bash "$DIR/check-out.sh" "10 PRINT 1/2"                    ".5"        || fail=1
# division is real now (not integer): 10/4 = 2.5, 100/9 = 11.1111111
bash "$DIR/check-out.sh" "10 PRINT 10/4"                   "2.5"       || fail=1
# float arithmetic and float variables
bash "$DIR/check-out.sh" "10 PRINT 3.14*2"                 "6.28"      || fail=1
bash "$DIR/check-out.sh" "10 A=1.5:B=2.5:PRINT A+B"        "4"         || fail=1
# array elements hold floats too
bash "$DIR/check-out.sh" "10 DIM A(2):A(0)=1.5:PRINT A(0)" "1.5"       || fail=1

echo
echo "== Built-in functions (INT/ABS/SGN/SQR/RND + trig, via the ROM Math library) =="
bash "$DIR/check-out.sh" "10 PRINT INT(3.7)"     "3"   || fail=1
bash "$DIR/check-out.sh" "10 PRINT INT(-2.5)"    "-3"  || fail=1   # floor toward -infinity
bash "$DIR/check-out.sh" "10 PRINT ABS(-5)"      "5"   || fail=1
bash "$DIR/check-out.sh" "10 PRINT SGN(-3)"      "-1"  || fail=1
bash "$DIR/check-out.sh" "10 PRINT SGN(0)"       "0"   || fail=1
bash "$DIR/check-out.sh" "10 PRINT SQR(9)"       "3"   || fail=1
bash "$DIR/check-out.sh" "10 PRINT SIN(0)"       "0"   || fail=1
bash "$DIR/check-out.sh" "10 PRINT COS(0)"       "1"   || fail=1
# functions nest and compose in expressions
bash "$DIR/check-out.sh" "10 PRINT INT(SQR(50))" "7"   || fail=1
bash "$DIR/check-out.sh" "10 PRINT ABS(-2)*3"    "6"   || fail=1
# RND is in [0,1), so INT(RND(1)) is always 0
bash "$DIR/check-out.sh" "10 PRINT INT(RND(1))"  "0"   || fail=1

echo
echo "== String functions (LEN/ASC/VAL string->number, CHR\$/STR\$ number->string, LEFT\$/RIGHT\$/MID\$) =="
# string -> number
bash "$DIR/check-basic.sh" '10 PRINT LEN("HELLO")'          0400=5  || fail=1
bash "$DIR/check-basic.sh" '10 A$="CAT":PRINT LEN(A$)'      0400=3  || fail=1
bash "$DIR/check-basic.sh" '10 PRINT ASC("A")'             0400=41 || fail=1   # 65
bash "$DIR/check-basic.sh" '10 PRINT VAL("123")'           0400=7b || fail=1   # 123
bash "$DIR/check-basic.sh" '10 PRINT VAL("42")+VAL("8")'   0400=32 || fail=1   # 50, VAL composes
# number -> string
bash "$DIR/check-out.sh"   '10 PRINT CHR$(65)'             "A"      || fail=1
bash "$DIR/check-out.sh"   '10 PRINT CHR$(72)+CHR$(73)'    "HI"     || fail=1   # producer concat
bash "$DIR/check-basic.sh" '10 PRINT LEN(STR$(5))'         0400=1  || fail=1   # "5": lead space stripped
bash "$DIR/check-out.sh"   '10 PRINT "["+STR$(-3)+"]"'     "[-3]"   || fail=1   # STR$ keeps the sign
# slicing
bash "$DIR/check-out.sh"   '10 PRINT LEFT$("HELLO",3)'     "HEL"    || fail=1
bash "$DIR/check-out.sh"   '10 PRINT RIGHT$("HELLO",2)'    "LO"     || fail=1
bash "$DIR/check-out.sh"   '10 PRINT MID$("HELLO",2,3)'    "ELL"    || fail=1
bash "$DIR/check-out.sh"   '10 PRINT MID$("HELLO",3)'      "LLO"    || fail=1   # 2-arg MID$ = rest
# type round-trips across the boundary
bash "$DIR/check-basic.sh" '10 PRINT ASC(CHR$(66))'        0400=42 || fail=1   # 66: num->str->num
bash "$DIR/check-basic.sh" '10 PRINT LEN(LEFT$("HELLO",3))' 0400=3 || fail=1   # str->str->num
# re-entrancy: a pending operator ('2*') must survive the nested string-arg parse
bash "$DIR/check-basic.sh" '10 PRINT 2*LEN(CHR$(65))'      0400=2  || fail=1   # 2*1 = 2
# re-entrancy: a producer's id (CHR$) must survive a nested producer (STR$) -> "5"
bash "$DIR/check-out.sh"   '10 PRINT CHR$(ASC(STR$(5)))'   "5"      || fail=1

echo
echo "== Logical operators (AND / OR / NOT) & string comparison =="
# AND/OR are bitwise on the 16-bit value (5 AND 3 = 1, 5 OR 2 = 7)
bash "$DIR/check-basic.sh" "10 PRINT 5 AND 3"                       0400=1  || fail=1
bash "$DIR/check-basic.sh" "10 PRINT 5 OR 2"                        0400=7  || fail=1
# with truth values (-1 / 0) they act as logical AND / OR / NOT
bash "$DIR/check-basic.sh" "10 PRINT (1<2) AND (3<4)"               0400=ff 0401=ff || fail=1  # T AND T = -1
bash "$DIR/check-basic.sh" "10 PRINT (1>2) OR (3<4)"                0400=ff 0401=ff || fail=1  # F OR T  = -1
bash "$DIR/check-basic.sh" "10 PRINT NOT (1<2)"                     0400=0  || fail=1          # NOT T = 0
bash "$DIR/check-basic.sh" "10 PRINT NOT (1>2)"                     0400=ff 0401=ff || fail=1  # NOT F = -1
# precedence: comparisons bind tighter than AND, AND binds tighter than OR
bash "$DIR/check-basic.sh" "10 PRINT 1<2 AND 3<4"                   0400=ff 0401=ff || fail=1  # (1<2) AND (3<4)
bash "$DIR/check-basic.sh" "10 PRINT 1=1 OR 2=3 AND 4=5"            0400=ff 0401=ff || fail=1  # T OR (F AND F)
# AND / OR / NOT inside IF conditions
bash "$DIR/check-basic.sh" "10 A=5:IF A>0 AND A<10 THEN PRINT 42"   0400=2a || fail=1
bash "$DIR/check-basic.sh" "10 A=5:IF A>10 OR A<9 THEN PRINT 42"    0400=2a || fail=1
bash "$DIR/check-basic.sh" "10 A=5:IF NOT A>10 THEN PRINT 42"       0400=2a || fail=1
bash "$DIR/check-basic.sh" "10 A=5:IF A>0 AND A>10 THEN PRINT 7"    0400=0  || fail=1          # AND false -> skipped
# string comparison: = <> < > (lexicographic) -> a numeric truth value
bash "$DIR/check-basic.sh" '10 A$="YES":IF A$="YES" THEN PRINT 42'  0400=2a || fail=1
bash "$DIR/check-basic.sh" '10 A$="NO":IF A$="YES" THEN PRINT 42'   0400=0  || fail=1
bash "$DIR/check-basic.sh" '10 PRINT "ABC"="ABC"'                   0400=ff 0401=ff || fail=1
bash "$DIR/check-basic.sh" '10 PRINT "A"<"B"'                       0400=ff 0401=ff || fail=1  # lexicographic
bash "$DIR/check-basic.sh" '10 PRINT "X"<>"Y"'                      0400=ff 0401=ff || fail=1
# the headline: a string test AND a numeric test in one condition
bash "$DIR/check-basic.sh" '10 A$="Y":N=5:IF A$="Y" AND N>0 THEN PRINT 99'  0400=63 || fail=1
# string-comparison operands can be functions / concatenations
bash "$DIR/check-basic.sh" '10 IF LEFT$("HELLO",1)="H" THEN PRINT 1'  0400=1 || fail=1
bash "$DIR/check-basic.sh" '10 A$="AB":IF A$+"C"="ABC" THEN PRINT 7'  0400=7 || fail=1
# standalone: logical + string comparison bundled and run with no compiler present
bash "$DIR/check-standalone.sh" mail '10 A$="HI":IF A$="HI" AND 1<2 THEN PRINT 42' 0400=2a || fail=1
bash "$DIR/check-standalone.sh" mail "10 IF 3>1 AND 2>1 THEN PRINT 7"              0400=7  || fail=1

echo
echo "== Core-language gaps: ^ power / STOP / ON..GOTO/GOSUB / DEF FN / WAIT =="
# ^ power operator: right-associative, binds tighter than unary minus; integer results are exact
bash "$DIR/check-basic.sh" "10 PRINT 2^3"        0400=8           || fail=1   # 8
bash "$DIR/check-basic.sh" "10 PRINT 2^10"       0400=00 0401=04  || fail=1   # 1024
bash "$DIR/check-basic.sh" "10 PRINT 2^3^2"      0400=00 0401=02  || fail=1   # 512  (2^(3^2), right-assoc)
bash "$DIR/check-basic.sh" "10 PRINT -2^2"       0400=fc 0401=ff  || fail=1   # -4   (^ tighter than unary -)
bash "$DIR/check-basic.sh" "10 PRINT 5^3"        0400=7d          || fail=1   # 125
bash "$DIR/check-out.sh"   "10 PRINT 3^2"        "9"              || fail=1
# STOP halts (CONT is out of scope, so it behaves like END): prints 3, never 9
bash "$DIR/check-basic.sh" "10 PRINT 3:STOP:PRINT 9"        0400=3 || fail=1
bash "$DIR/check-basic.sh" "10 PRINT 3:IF 1 THEN STOP\n20 PRINT 9" 0400=3 || fail=1   # STOP after THEN
# ON expr GOTO: 1-based computed branch; the integer part selects; out-of-range falls through
bash "$DIR/check-basic.sh" "10 X=2:ON X GOTO 100,200\n20 END\n100 PRINT 11:END\n200 PRINT 22" 0400=16 || fail=1  # ->22
bash "$DIR/check-basic.sh" "10 X=1:ON X GOTO 100,200\n20 END\n100 PRINT 11:END\n200 PRINT 22" 0400=0b || fail=1  # ->11
bash "$DIR/check-basic.sh" "10 X=9:ON X GOTO 100,200:PRINT 1:END\n100 PRINT 11:END\n200 PRINT 22" 0400=1 || fail=1  # OOR falls through
bash "$DIR/check-basic.sh" "10 X=2.9:ON X GOTO 100,200\n20 END\n100 PRINT 11:END\n200 PRINT 22" 0400=16 || fail=1  # INT(2.9)=2 ->22
# ON expr GOSUB: calls the k-th subroutine, then continues after the ON statement
bash "$DIR/check-basic.sh" "10 X=1:ON X GOSUB 100:PRINT 5:END\n100 A=9:RETURN" 0400=5 || fail=1
# DEF FN / FN: user function (reuses GOSUB/RET), composes in expressions
bash "$DIR/check-basic.sh" "10 DEF FN SQ(X)=X*X\n20 PRINT FN SQ(5)"  0400=19 || fail=1  # 25
bash "$DIR/check-basic.sh" "10 DEF FN D(X)=X*2\n20 PRINT FN D(3)+1"  0400=7  || fail=1  # 7
# FN used before its DEF (textually) is an UNDEF'D error, not a crash
bash "$DIR/check-basic.sh" "10 PRINT FN Q(3)"  0403=2 || fail=1
# WAIT addr,mask[,xor]: returns at once when the masked bit is already set (no spin/hang)
bash "$DIR/check-basic.sh" "10 POKE 1280,1:WAIT 1280,1:PRINT 42"    0400=2a || fail=1
bash "$DIR/check-basic.sh" "10 POKE 1280,4:WAIT 1280,4,0:PRINT 42"  0400=2a || fail=1
# standalone: the new ops survive bundling and run with no compiler present
bash "$DIR/check-standalone.sh" mail "10 PRINT 2^8"                          0400=00 0401=01 || fail=1  # 256
bash "$DIR/check-standalone.sh" mail "10 DEF FN T(X)=X+X+X\n20 PRINT FN T(7)" 0400=15 || fail=1  # 21
bash "$DIR/check-standalone.sh" mail "10 X=2:ON X GOTO 100,200\n20 END\n100 PRINT 1:END\n200 PRINT 9" 0400=9 || fail=1

echo
echo "== READ / DATA / RESTORE (classic BASIC data tables; DATA is collected in line order) =="
# READ several items into several variables
bash "$DIR/check-basic.sh" "10 DATA 3,4\n20 READ A,B\n30 PRINT A+B"                 0400=7  || fail=1
# READ in a loop over a DATA list: 1+2+3+4+5 = 15
bash "$DIR/check-basic.sh" "10 DATA 1,2,3,4,5\n20 FOR I=1 TO 5\n30 READ V\n40 S=S+V\n50 NEXT I\n60 PRINT S" 0400=f || fail=1
# RESTORE rewinds to the first item: READ 9, RESTORE, READ 9 again -> 18
bash "$DIR/check-basic.sh" "10 DATA 9,5\n20 READ A\n30 RESTORE\n40 READ B\n50 PRINT A+B" 0400=12 || fail=1
# reading past the end of DATA yields 0 (no crash)
bash "$DIR/check-basic.sh" "10 DATA 5\n20 READ A,B\n30 PRINT B"                     0400=0  || fail=1
# float DATA item
bash "$DIR/check-out.sh"   "10 DATA 3.5\n20 READ A\n30 PRINT A*2"                   "7"     || fail=1
# string DATA -- "WORLD" contains "OR", so this also checks DATA text is not keyword-tokenized
bash "$DIR/check-out.sh"   '10 DATA HELLO,WORLD\n20 READ A$:READ B$\n30 PRINT A$;B$' "HELLOWORLD" || fail=1
# a name/score table: mixed string+numeric READ in a loop, DATA placed after the code that reads it
bash "$DIR/check-out.sh"   '10 FOR I=1 TO 2:READ N$,S:PRINT N$;S:NEXT I\n20 DATA ANN,10,BOB,20' "ANN10\nBOB20" || fail=1
# standalone: the DATA pool is bundled into out.prg and read with no compiler present
bash "$DIR/check-standalone.sh" mail "10 DATA 6,7\n20 READ A,B\n30 PRINT A*B"       0400=2a || fail=1

echo
echo "== Interactive filename prompt (source + output names typed at the keyboard, headless) =="
# the compiler prompts for names; we feed "A" then "B", it compiles source "A" and writes "B"
bash "$DIR/check-prompt.sh" "10 PRINT 42" 0400=2a || fail=1
# pressing RETURN for the output name defaults it to "c."+source (deleting any stale build first)
bash "$DIR/check-prompt.sh" default "10 PRINT 42" 0400=2a || fail=1
# correcting a mistyped name with DELETE must not corrupt it (the DEL byte used to be stored verbatim)
bash "$DIR/check-prompt.sh" correction "10 PRINT 42" 0400=2a || fail=1

echo
echo "== Standalone .prg: compiled programs run with NO compiler present =="
# each check compiles to out.prg (VM bundled in) then runs out.prg on its own
bash "$DIR/check-standalone.sh" mail "10 PRINT 6*7"                             0400=2a       || fail=1
# control flow + FOR/NEXT survive the base change (P-code is position-independent): sum 1..10 = 55
bash "$DIR/check-standalone.sh" mail "10 FOR I=1 TO 10\n20 S=S+I\n30 NEXT\n40 PRINT S" 0400=37 || fail=1
# GOSUB/RETURN standalone
bash "$DIR/check-standalone.sh" mail "10 GOSUB 100:PRINT R:END\n100 R=6:RETURN"  0400=6       || fail=1
# strings standalone: the literal pool is bundled and resolved via vm.litbase
bash "$DIR/check-standalone.sh" out  '10 PRINT "BLITZ"'                          "BLITZ"       || fail=1
bash "$DIR/check-standalone.sh" out  '10 A$="HI":PRINT A$+" THERE"'              "HI THERE"    || fail=1
# machine access standalone: POKE a routine and SYS it, no compiler present
bash "$DIR/check-standalone.sh" mail "$POKESYS"                                  0510=5a       || fail=1
# arrays standalone: DIM + FOR-fill + read back, no compiler present
bash "$DIR/check-standalone.sh" mail "10 DIM A(10)\n20 FOR I=0 TO 5\n30 A(I)=I*I\n40 NEXT I\n50 PRINT A(4)" 0400=10 || fail=1
# floats standalone (ROM Math bundled behavior): 10/4 = 2.5
bash "$DIR/check-standalone.sh" out "10 PRINT 10/4" "2.5" || fail=1
# a built-in function standalone: SQR(16) = 4
bash "$DIR/check-standalone.sh" out "10 PRINT SQR(16)" "4" || fail=1
# string functions standalone: LEFT$ of a bundled literal, no compiler present
bash "$DIR/check-standalone.sh" out '10 PRINT LEFT$("BLITZ",3)' "BLI" || fail=1
# standalone GC stress: 200-char accumulation forces many ROM garba2 collections above datatop, no compiler present
bash "$DIR/check-standalone.sh" mail '10 B$="X"\n20 FOR I=1 TO 200\n30 A$=A$+B$\n40 NEXT\n50 PRINT LEN(A$)' 0400=c8 0401=00 || fail=1
# standalone: string content survives collections byte-for-byte -> MID$ char still 'B' ($42) after 150 collections
bash "$DIR/check-standalone.sh" mail '10 A$="ABC"\n20 FOR I=1 TO 150\n30 A$=A$+"."\n40 NEXT\n50 PRINT ASC(MID$(A$,2,1))' 0400=42 || fail=1

echo
echo "== Capacity: programs past the old 256-byte / 48-line / 32-var limits =="
# 62 lines (old cap 48), ~430 bytes of P-code (old cap 256): S=0 then 60x S=S+1 -> 60
BIG="1 S=0"; for i in $(seq 2 61); do BIG="$BIG\n$i S=S+1"; done; BIG="$BIG\n62 PRINT S"
bash "$DIR/check-basic.sh"      "$BIG" 0400=3c || fail=1
# 45 distinct variables (old cap 32), spread over several realistic-length lines
VARS=""; n=0; for L in $(seq 1 5); do VARS="$VARS$L "; for k in $(seq 1 9); do VARS="${VARS}V$n=1:"; n=$((n+1)); done; VARS="$VARS\n"; done; VARS="${VARS}6 PRINT V44"
bash "$DIR/check-basic.sh"      "$VARS" 0400=1 || fail=1
# BANKED SOURCE: a >8 KB program (100 long REM lines) spans two RAM banks and still compiles+runs
BANKED=""; for i in $(seq 1 100); do BANKED="$BANKED$i REM $(printf 'X%.0s' $(seq 1 110))\n"; done; BANKED="${BANKED}200 PRINT 42"
bash "$DIR/check-basic.sh"      "$BANKED" 0400=2a || fail=1
# the same large program compiles to a standalone out.prg and runs with no compiler present
bash "$DIR/check-standalone.sh" mail "$BIG" 0400=3c || fail=1
# BANKED P-CODE: a program whose P-code exceeds the old 8 KB flat ceiling (now emitted to banked RAM).
# 100 lines x 12 "S=S+1" is ~12 KB of P-code -- too big to run alongside the resident compiler, so it
# is verified as a STANDALONE out.prg (which loads the P-code flat and runs it). S ends at 1200 = $04B0.
PBANK="1 S=0"; for i in $(seq 2 101); do PBANK="$PBANK\n$i $(printf 'S=S+1:%.0s' $(seq 1 11))S=S+1"; done; PBANK="$PBANK\n102 PRINT S"
bash "$DIR/check-standalone.sh" mail "$PBANK" 0400=b0 0401=4 || fail=1

echo
if [[ $fail -eq 0 ]]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; fi
exit $fail
