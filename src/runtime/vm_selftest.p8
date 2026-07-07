; vm_selftest.p8 -- M0 regression: run a hand-written P-code blob through the VM
; module and expose the result for the headless testbench harness.

%import textio
%import pcode_format
%import vm
%zeropage basicsafe

main {
    const bool TESTBENCH = true            ; build-time flag; flipped to false for visual builds
    const uword MAILBOX = $0400            ; $0400=result lo, +1=hi, +2=ran-sentinel

    ; (5 + 3) * 2 - 1 = 15
    ubyte[] program = [
        pcode.OP_PUSHI, 5, 0,
        pcode.OP_PUSHI, 3, 0,
        pcode.OP_ADD,
        pcode.OP_PUSHI, 2, 0,
        pcode.OP_MUL,
        pcode.OP_PUSHI, 1, 0,
        pcode.OP_SUB,
        pcode.OP_PRINTI,
        pcode.OP_NEWLINE,
        pcode.OP_END
    ]

    sub start() {
        txt.print("vm selftest\n")
        vm.run(&program)
        if TESTBENCH {
            @(MAILBOX)     = lsb(vm.last_printed as uword)
            @(MAILBOX + 1) = msb(vm.last_printed as uword)
            @(MAILBOX + 2) = $AA
            %asm {{
                stp
            }}
        }
    }
}
