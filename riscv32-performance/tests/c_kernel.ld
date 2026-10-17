ENTRY(_start)
MEMORY {
    ROM (rx) : ORIGIN = 0x80000000, LENGTH = 64K
    RAM (rw) : ORIGIN = 0x80100000, LENGTH = 256K
}
SECTIONS {
    .text : { *(.text.start) *(.text*) } > ROM
    .rodata : { *(.rodata*) } > ROM
    .data : { *(.data*) *(.sdata*) } > RAM
    .bss (NOLOAD) : { *(.bss*) *(.sbss*) *(COMMON) } > RAM
}
