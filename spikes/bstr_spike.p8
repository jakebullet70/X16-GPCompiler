; bstr_spike.p8 -- exercise the bstr engine on the REAL VM path under GC pressure.
; A$="HE"; then A$=A$+"X" x60 compiled the way the VM emits it:
;   LOADS A$ / PUSHS "X" / CONCAT (concat_temp) / STORS A$ (store_var steals the temp)
; in a ~320-byte heap so getspa must GC many times. Assert A$ ends at len 62 with 'H' at [0]
; and 'X' at [2] -> store_var(literal copy + temp steal), concat_temp, getspa, garba2 all correct.

%import bstr
%zeropage basicsafe

main {
    ubyte[2] bodyHE = [$48, $45]             ; raw "HE" (encoding-agnostic)
    ubyte[1] bodyX  = [$58]                  ; raw "X"
    ubyte[3] dHE                             ; scratch descriptor over the literal "HE"
    ubyte[3] dX                              ; scratch descriptor over the literal "X"

    sub start() {
        bstr.init($9c00)                     ; tiny heap ($9c00 table, ~320-byte heap to MEMTOP)

        dHE[0] = 2
        dHE[1] = lsb(&bodyHE)
        dHE[2] = msb(&bodyHE)
        bstr.store_var(0, &dHE)              ; A$ = "HE"  (literal -> owned heap copy)

        dX[0] = 1
        dX[1] = lsb(&bodyX)
        dX[2] = msb(&bodyX)

        ubyte i
        for i in 1 to 60 {
            uword t = bstr.concat_temp(bstr.vdesc(0), &dX)   ; temp = A$ + "X"
            bstr.store_var(0, t)                             ; A$ = temp (steal body, pop temp)
        }

        uword vd = bstr.vdesc(0)
        @($0400) = bstr.dlen(vd)             ; expect 62 = $3e
        @($0401) = @(bstr.dptr(vd))          ; 'H' = $48
        @($0402) = @(bstr.dptr(vd) + 2)      ; 'X' = $58
        @($0403) = $aa
        %asm {{ stp }}
    }
}
