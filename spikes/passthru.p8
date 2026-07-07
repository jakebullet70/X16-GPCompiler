; passthru.p8 -- SPIKE 2 proof: command pass-through to ROM BASIC mid-program.
;
; Proves a compiled program can hand a *tokenized* BASIC statement to the ROM
; interpreter and get control back. We build the token stream for `POKE 1040,66`
; ($0410 <- 66), point TXTPTR at it, page in BASIC ROM (bank 4), prime CHRGET,
; and JSR the statement dispatcher `gone3`. The POKE handler runs and RTSes back
; to us; we then read $0410 into the testbench mailbox.
;
; Addresses are from the emulator's basic.sym (matches its rom.bin):
;   gone3  = $CC63   chrget = $00E7   txtptr = $00EE   curlin = $03EB
;   ROM bank register = $01 ; BASIC = bank 4
;
; Tokenized statement: [dummy][POKE=$97]["1040,66" ascii][$00]. TXTPTR points at
; the dummy byte because CHRGET pre-increments before it reads the first token.

%zeropage basicsafe

main {
    ; ':'  POKE  '1' '0' '4' '0'  ','  '6' '6'  <eol>
    ubyte[] stmt = [$3A, $97, $31,$30,$34,$30, $2C, $36,$36, $00]

    sub start() {
        @($0410) = 0                 ; clear the POKE target

        @($00EE) = lsb(&stmt)        ; TXTPTR lo
        @($00EF) = msb(&stmt)        ; TXTPTR hi
        @($03EB) = 10                ; curlin = 10 (not direct-mode $FFxx)
        @($03EC) = 0

        %asm {{
            lda  $01                 ; save ROM bank
            pha
            lda  #4                  ; page in BASIC ROM
            sta  $01
            jsr  $00e7               ; CHRGET -> A = first token ($97 POKE)
            jsr  $cc63               ; gone3: dispatch+execute the statement, RTS back
            pla                      ; restore ROM bank
            sta  $01
        }}

        @($0400) = @($0410)          ; mailbox: the poked value (expect 66 = $42)
        @($0401) = 0
        @($0402) = $aa               ; ran-sentinel
        %asm {{
            stp
        }}
    }
}
