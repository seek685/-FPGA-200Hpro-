.section .text.start
.globl _start
_start:
    lui sp, 0x80140
    addi sp, sp, -16
    call main
    lui t0, 0x80200
    li t1, 0x6d
    sw t1, 0x40(t0)
1:  j 1b
