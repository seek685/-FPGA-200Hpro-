.section .text.start,"ax",@progbits
.globl _start
.option norvc
.option norelax
_start:
    lui sp, 0x80101
    call main
1:  j 1b
