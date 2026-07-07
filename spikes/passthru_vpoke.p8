; passthru_vpoke.p8 -- SPIKE 2, escape-token path: pass through an X16-ONLY
; statement (VPOKE) that GPC will never natively compile.
;
; VPOKE is escape-statement index 4, so it tokenizes as $CE $84. We pass through
; `VPOKE 0,4660,66` -> writes 66 to VRAM $01234, then read it back through VERA
; ADDR0/DATA0 and put it in the mailbox. Proves the $CE/stmdsp2 dispatch path
; (all the VERA/sound/graphics keywords) is reachable and returns cleanly.
;
;   gone3 = $CC63   chrget = $00E7   txtptr = $00EE   ROM bank reg = $01 (BASIC=4)
;   VERA: CTRL $9F25, ADDR0 $9F20/$9F21/$9F22, DATA0 $9F23

%zeropage basicsafe

main {
    ; ':'  VPOKE($CE $84)  "0,4660,66"  <eol>
    ubyte[] stmt = [$3A, $CE,$84, $30,$2C, $34,$36,$36,$30, $2C, $36,$36, $00]

    sub start() {
        @($0410) = 0

        @($00EE) = lsb(&stmt)
        @($00EF) = msb(&stmt)
        @($03EB) = 10
        @($03EC) = 0

        %asm {{
            lda  $01
            pha
            lda  #4
            sta  $01
            jsr  $00e7               ; CHRGET -> A = $CE (escape token)
            jsr  $cc63               ; gone3 -> escape dispatch -> vpoke, RTS back
            pla
            sta  $01
            ; read VRAM $01234 back via VERA ADDR0 / DATA0
            stz  $9f25               ; CTRL: ADDRSEL=0, DCSEL=0
            lda  #$34
            sta  $9f20               ; ADDR low
            lda  #$12
            sta  $9f21               ; ADDR mid
            lda  #$00
            sta  $9f22               ; ADDR high (bank 0, no auto-increment)
            lda  $9f23               ; DATA0 -> the byte VPOKE wrote
            sta  $0410
        }}

        @($0400) = @($0410)          ; expect 66 = $42
        @($0401) = 0
        @($0402) = $aa
        %asm {{
            stp
        }}
    }
}
