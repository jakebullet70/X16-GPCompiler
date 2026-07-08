; sarr_spike.p8 -- prove BASIC-format string arrays are walked+relocated by ROM garba2.
; DIM A$(3) [4 elems]; set elems to distinct bodies (owning heap copies); set a scalar A$="Z";
; then A$=A$+"Q" x40 in a tiny heap to force many collections. If garba2 walks the array header
; correctly, all 4 element bodies survive byte-exact through every GC.

%import bstr
%zeropage basicsafe

main {
    ubyte[2] bodyAA   = [$41, $41]           ; elem 0 = "AA"
    ubyte[3] bodyBBB  = [$42, $42, $42]       ; elem 1 = "BBB"
    ubyte[1] bodyC    = [$43]                 ; elem 2 = "C"
    ubyte[4] bodyDDDD = [$44, $44, $44, $44]   ; elem 3 = "DDDD"
    ubyte[1] bodyZ    = [$5a]                 ; scalar seed "Z"
    ubyte[1] bodyQ    = [$51]                 ; concat tail "Q"
    ubyte[3] dQ                               ; scratch descriptor over the literal "Q"

    sub start() {
        bstr.init($9c00)

        void bstr.sarr_alloc(0, 4, 1)         ; DIM A$(3)  -> 4 elements, 1 dimension

        uword t
        t = bstr.mem_to_temp(&bodyAA, 2)   bstr.store_desc(bstr.sarr_desc(0, 0), t)
        t = bstr.mem_to_temp(&bodyBBB, 3)  bstr.store_desc(bstr.sarr_desc(0, 1), t)
        t = bstr.mem_to_temp(&bodyC, 1)    bstr.store_desc(bstr.sarr_desc(0, 2), t)
        t = bstr.mem_to_temp(&bodyDDDD, 4) bstr.store_desc(bstr.sarr_desc(0, 3), t)

        bstr.var_from_mem(0, &bodyZ, 1)       ; scalar A$ = "Z"

        dQ[0] = 1
        dQ[1] = lsb(&bodyQ)
        dQ[2] = msb(&bodyQ)

        ubyte i
        for i in 1 to 40 {
            uword tt = bstr.concat_temp(bstr.vdesc(0), &dQ)   ; A$ = A$ + "Q"  (forces GCs)
            bstr.store_var(0, tt)
        }

        @($0400) = bstr.dlen(bstr.sarr_desc(0, 1))            ; elem 1 len = 3
        @($0401) = @(bstr.dptr(bstr.sarr_desc(0, 1)))         ; elem 1 [0] = 'B' = $42
        @($0402) = @(bstr.dptr(bstr.sarr_desc(0, 3)) + 3)     ; elem 3 [3] = 'D' = $44
        @($0403) = bstr.dlen(bstr.vdesc(0))                   ; scalar len = 1 + 40 = 41 = $29
        @($0404) = $aa
        %asm {{ stp }}
    }
}
