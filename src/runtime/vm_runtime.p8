; vm_runtime.p8 -- Blitz-X16 standalone runtime host.
;
; This is the bundled runtime that ships INSIDE every compiled program. The
; compiler emits a standalone .PRG shaped like:
;
;     [$0801 BASIC stub + this runtime's code]  ...  [pcode @ PCODE_BASE]
;
; i.e. this program's own image, then the compiled P-code placed at a fixed
; address well above the runtime's code and variables. On RUN, the BASIC stub
; SYSes into start(), which simply interprets the P-code sitting at PCODE_BASE.
; No compiler is present -- this is what makes a compiled program self-contained.
;
; Built once into runtime.prg; the compiler loads that file and prepends it to
; the P-code to produce out.prg. Keep this small: it must fit (code + variables)
; below PCODE_BASE.

%import textio
%import pcode_format
%import vm
%zeropage basicsafe

main {
    const bool TESTBENCH = true            ; build-time flag; flipped to false for visual builds
    const uword MAILBOX = $0400            ; $0400=result lo, +1=hi, +2=ran-sentinel

    sub start() {
        ; the 6-byte header at PCODE_BASE locates the bundled literal + data pools; P-code follows
        vm.litbase  = peekw(pcode.PCODE_BASE)          ; +0: literal-pool address
        vm.database = peekw(pcode.PCODE_BASE + 2)      ; +2: data-pool address
        vm.datatop  = vm.database + peekw(pcode.PCODE_BASE + 4)   ; +4: data-pool length
        vm.run(pcode.PCODE_BASE + pcode.HEADER_SIZE)
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
