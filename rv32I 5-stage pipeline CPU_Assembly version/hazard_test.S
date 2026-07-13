.section .text
.globl _start
.option norvc

_start:
    # EX/MEM forwarding: x1 is consumed immediately by the next instruction.
    addi x1, x0, 5
    addi x2, x1, 3

    # Complete the implemented R-type subset and create forwarding dependencies.
    sub  x12, x2, x1
    and  x13, x2, x1
    or   x14, x2, x1
    add  x3,  x2, x1

    # Load-use stall: ADD immediately consumes the loaded x4 value.
    lw   x4, 0(x0)
    add  x5, x4, x3

    # Store-data forwarding and memory write verification.
    sw   x5, 4(x0)

    # Taken BEQ must flush both sequential instructions below.
    beq  x1, x1, branch_target
    addi x6, x0, 9
    addi x6, x0, 8

branch_target:
    addi x7, x0, 7
    lui  x8, 0x12345

    # JAL writes PC+4 into x9 and flushes the following instruction.
    jal  x9, jump_target
    addi x10, x0, 111

jump_target:
    addi x11, x0, 42

    # x0 must remain zero even after an attempted write.
    addi x0, x0, 99

    # This CPU uses ECALL as its simulation halt instruction.
    ecall
