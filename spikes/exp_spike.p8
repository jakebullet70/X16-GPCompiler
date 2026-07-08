; exp_spike.p8 -- isolate the X16 ROM EXP ($fe3c) in the runtime's ROM context.
; Replicates vm_runtime startup (no_sysinit + IOINIT/RESTOR, BASIC ROM bank 4 left paged in),
; then computes EXP(0), EXP(1), EXP(2) via MOVFM/EXP/MOVMF and drops the truncated ints in the mailbox.
;   expect: $0400=1 (e^0), $0401=2 (e^1=2.718->2), $0402=7 (e^2=7.389->7), $0403=$AA
%import floats
%option no_sysinit
%zeropage basicsafe

main {
    float arg
    float res

    sub start() {
        %asm {{
            sei
            jsr  $ff84          ; IOINIT
            jsr  $ff8a          ; RESTOR
            cli
        }}
        @($0400) = expt(0.0)
        @($0401) = expt(1.0)
        @($0402) = expt(2.0)
        @($0403) = $AA
        %asm {{
            stp
        }}
    }

    sub expt(float x) -> ubyte {
        arg = x
        %asm {{
            lda  #<p8b_main.p8v_arg
            ldy  #>p8b_main.p8v_arg
            jsr  $fe63          ; MOVFM  FAC = arg
            jsr  $fe3c          ; EXP    FAC = e^arg
            ldx  #<p8b_main.p8v_res
            ldy  #>p8b_main.p8v_res
            jsr  $fe66          ; MOVMF  res = FAC
        }}
        return res as ubyte
    }
}
