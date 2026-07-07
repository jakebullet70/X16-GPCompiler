; strvar.p8 -- Phase 2 Stage 1 foundation proof.
; GPC (not pass-through) builds a BASIC string variable A$ directly, stores 10 growing
; bodies into it via ROM getspa (orphaning the old ones), then calls ROM garba2. Proves
; GPC can own BASIC-format string storage and reuse the ROM allocator+collector.
;   getspa=$DC35  garba2=$DC70  MEMTOP=$FF99  (BASIC ROM bank 4 = $01=4)

%zeropage basicsafe

main {
    uword f1
    uword f2

    sub start() {
        %asm {{
            ; --- BASIC string environment ---
            lda  $01
            pha
            stz  $01                 ; KERNAL bank
            sec
            jsr  $ff99               ; MEMTOP -> X=lo, Y=hi
            pla
            sta  $01
            stx  $03e9               ; memsiz
            sty  $03ea
            stx  $03e7               ; fretop = memsiz (empty heap)
            sty  $03e8
            lda  #$00
            sta  $03e1               ; vartab = $5000
            lda  #$50
            sta  $03e2
            ; string variable "A$" at $5000 : name['A', $80=string-type], desc[len,ptr,ptr], pad,pad
            lda  #$41
            sta  $5000
            lda  #$80
            sta  $5001
            lda  #0
            sta  $5002
            sta  $5003
            sta  $5004
            sta  $5005
            sta  $5006
            lda  #$07
            sta  $03e3               ; arytab = $5007
            sta  $03e5               ; strend = $5007
            lda  #$50
            sta  $03e4
            sta  $03e6
            lda  #$d6
            sta  $03de               ; temppt = tempst (empty)
            lda  #10
            sta  $03eb               ; curlin
            lda  #0
            sta  $03ec
        }}

        ubyte i
        for i in 1 to 10 {
            @($02) = i               ; r0L = length
            %asm {{
                lda  $01
                pha
                lda  #4
                sta  $01
                lda  $02             ; len
                jsr  $dc35           ; getspa -> A=len, X=ptrlo, Y=ptrhi
                sta  $5002           ; A$ descriptor: len
                stx  $5003           ; ptr lo
                stx  $04             ; stash ptr for the fill loop
                sty  $5004           ; ptr hi
                sty  $05
                pla
                sta  $01
            }}
            ubyte k
            for k in 0 to i-1 {
                @(peekw($04) + k) = $58      ; fill body with 'X'
            }
        }

        f1 = peekw($03e7)            ; fretop before GC (= MEMTOP - 55)
        %asm {{
            lda  $01
            pha
            lda  #4
            sta  $01
            jsr  $dc70               ; garba2
            pla
            sta  $01
        }}
        f2 = peekw($03e7)            ; fretop after GC (= MEMTOP - 10)

        uword reclaimed = f2 - f1                 ; expect 45 = $2D
        ubyte firstch = @(peekw($5003))           ; A$ body first char after GC: 'X' = $58

        @($0400) = lsb(reclaimed)
        @($0401) = msb(reclaimed)
        @($0402) = firstch
        @($0403) = $aa
        %asm {{ stp }}
    }
}
