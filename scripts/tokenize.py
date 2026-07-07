#!/usr/bin/env python3
# Tokenize text BASIC (on stdin) into a canonical CBM/X16 tokenized .prg (stdout).
#
# Canonical form (what the Blitzkrieg compiler's lexer expects):
#   - 2-byte load address $0801
#   - per line: 2-byte link to next line, 2-byte line number (LE),
#               tokenized bytes, $00 terminator
#   - $00 $00 end marker
#   - keywords/operators -> single tokens ($80+); letters/digits/punctuation -> ASCII
#
# Only the subset the compiler understands is tokenized; anything else is copied
# through as ASCII (uppercased for letters).
import sys

TOKENS = {
    'END': 0x80, 'FOR': 0x81, 'NEXT': 0x82, 'DATA': 0x83, 'INPUT': 0x85,
    'DIM': 0x86, 'READ': 0x87, 'LET': 0x88, 'GOTO': 0x89, 'RUN': 0x8a,
    'IF': 0x8b, 'RESTORE': 0x8c, 'GOSUB': 0x8d, 'RETURN': 0x8e, 'REM': 0x8f,
    'STOP': 0x90, 'ON': 0x91, 'WAIT': 0x92, 'DEF': 0x96, 'FN': 0xa5,
    'POKE': 0x97, 'PRINT': 0x99, 'SYS': 0x9e,
    # channel / file I/O.  'PRINT#'/'INPUT#' are single tokens (incl. the '#'); 'GET' is separate
    # from a following '#'.  Sorted longest-first below, so 'PRINT#' wins over 'PRINT'.
    'OPEN': 0x9f, 'CLOSE': 0xa0, 'GET': 0xa1, 'PRINT#': 0x98, 'INPUT#': 0x84,
    'TO': 0xa4, 'THEN': 0xa7, 'STEP': 0xa9,
    'NOT': 0xa8, 'AND': 0xaf, 'OR': 0xb0,
    # built-in functions
    'SGN': 0xb4, 'INT': 0xb5, 'ABS': 0xb6, 'SQR': 0xba, 'RND': 0xbb, 'LOG': 0xbc,
    'EXP': 0xbd, 'COS': 0xbe, 'SIN': 0xbf, 'TAN': 0xc0, 'ATN': 0xc1, 'PEEK': 0xc2,
    # string functions
    'LEN': 0xc3, 'STR$': 0xc4, 'VAL': 0xc5, 'ASC': 0xc6, 'CHR$': 0xc7,
    'LEFT$': 0xc8, 'RIGHT$': 0xc9, 'MID$': 0xca,
}
OPS = {'+': 0xaa, '-': 0xab, '*': 0xac, '/': 0xad, '^': 0xae, '>': 0xb1, '=': 0xb2, '<': 0xb3}
KW = sorted(TOKENS, key=len, reverse=True)   # greedy longest-match, like CBM


def tokenize_line(text):
    out = bytearray()
    i, in_str = 0, False
    in_rem = False        # after REM: raw to end of line (never tokenized)
    in_data = False       # inside DATA: raw until ':' (a keyword substring like OR is NOT a token)
    dq = False            # inside a quote within DATA (so a ':' there doesn't end the statement)
    while i < len(text):
        c = text[i]
        if in_rem:                         # REM body: copy verbatim
            out.append(ord(c) & 0xff)
            i += 1
            continue
        if in_str:                         # quoted string: copy verbatim
            out.append(ord(c) & 0xff)
            if c == '"':
                in_str = False
            i += 1
            continue
        if in_data:                        # DATA body: copy verbatim until an unquoted ':'
            if c == '"':
                dq = not dq
            elif c == ':' and not dq:
                in_data = False
            out.append(ord(c) & 0xff)
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(0x22)
            i += 1
            continue
        up = text[i:].upper()
        for k in KW:
            if up.startswith(k):
                out.append(TOKENS[k])
                i += len(k)
                if k == 'REM':
                    in_rem = True
                elif k == 'DATA':
                    in_data = True
                break
        else:
            if c in OPS:
                out.append(OPS[c])
            elif c.isalpha():
                out.append(ord(c.upper()))
            else:
                out.append(ord(c) & 0xff)
            i += 1
    return out


segs = []
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    num, _, rest = raw.partition(' ')
    seg = bytearray([int(num) & 0xff, (int(num) >> 8) & 0xff])
    seg += tokenize_line(rest)
    seg.append(0x00)
    segs.append(seg)

prg = bytearray([0x01, 0x08])
cur = 0x0801
for seg in segs:
    nxt = cur + 2 + len(seg)
    prg += bytes([nxt & 0xff, (nxt >> 8) & 0xff])
    prg += seg
    cur = nxt
prg += bytes([0x00, 0x00])
sys.stdout.buffer.write(prg)
