; garbag.p8 -- SPIKE 1 proof: reuse the X16 ROM string garbage collector.
;
; We drive real BASIC string work through the (proven) pass-through path to build
; garbage, then call the ROM collector `garba2` directly and show it reclaims the
; orphaned heap space and preserves the live string.
;
; Setup: point BASIC's variable table at scratch $5000 (so it doesn't land on our
; prog8 code), and set memsiz/fretop to the real KERNAL MEMTOP so the allocator
; and garba2 (which re-reads MEMTOP) agree on the heap top.
;
; Work: pass through `A$=A$+"X"` x10. Each concat allocates a fresh body (sizes
; 1..10 = 55 bytes) and orphans the previous one (45 bytes of garbage); live = 10.
; garba2 must compact to leave exactly the 10 live bytes -> fretop rises by 45.
;
;   garba2 = $DC70   gone3 = $CC63   chrget = $00E7   txtptr = $00EE
;   memsiz = $03E9   fretop = $03E7   vartab = $03E1   arytab = $03E3
;   strend = $03E5   temppt = $03DE   tempst = $00D6   MEMTOP kernal = $FF99

%zeropage basicsafe

main {
    ; ':'  A $ = A $ + "X"  <eol>
    ubyte[] stmt = [$3A, $41,$24, $B2, $41,$24, $AA, $22,$58,$22, $00]
    uword f1
    uword f2

    sub start() {
        %asm {{
            ; real MEMTOP (KERNAL bank) -> memsiz and fretop (empty heap at top)
            lda  $01
            pha
            stz  $01                 ; KERNAL rom bank
            sec
            jsr  $ff99               ; MEMTOP read: X=lo, Y=hi
            pla
            sta  $01
            stx  $03e9
            sty  $03ea               ; memsiz = MEMTOP
            stx  $03e7
            sty  $03e8               ; fretop = MEMTOP (heap empty)
            ; vartab = arytab = strend = $5000  (scratch, off our code)
            lda  #$00
            sta  $03e1
            sta  $03e3
            sta  $03e5
            lda  #$50
            sta  $03e2
            sta  $03e4
            sta  $03e6
            lda  #$d6
            sta  $03de               ; temppt = tempst (no temp descriptors)
            lda  #10
            sta  $03eb               ; curlin = 10 (not direct mode)
            lda  #0
            sta  $03ec
        }}

        ubyte i
        for i in 0 to 9 {
            @($00EE) = lsb(&stmt)
            @($00EF) = msb(&stmt)
            %asm {{
                lda  $01
                pha
                lda  #4
                sta  $01
                jsr  $00e7           ; CHRGET
                jsr  $cc63           ; gone3 -> LET: A$ = A$ + "X"
                pla
                sta  $01
            }}
        }

        f1 = peekw($03E7)            ; fretop before GC  (= MEMTOP - 55)

        %asm {{
            lda  $01
            pha
            lda  #4
            sta  $01
            jsr  $dc70               ; garba2: compact the string heap
            pla
            sta  $01
        }}

        f2 = peekw($03E7)            ; fretop after GC   (= MEMTOP - 10)

        uword reclaimed = f2 - f1                 ; expect 45 = $2D
        ubyte firstch = @(peekw($5003))           ; A$ body first char after GC: 'X' = $58

        @($0400) = lsb(reclaimed)
        @($0401) = msb(reclaimed)
        @($0402) = firstch
        @($0403) = $aa
        ; debug: raw fretop before/after
        @($0404) = lsb(f1)
        @($0405) = msb(f1)
        @($0406) = lsb(f2)
        @($0407) = msb(f2)
        %asm {{
            stp
        }}
    }
}
