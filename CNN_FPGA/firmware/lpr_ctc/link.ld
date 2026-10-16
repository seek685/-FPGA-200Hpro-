OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
    ROM (rx) : ORIGIN = 0x80000000, LENGTH = 4K
    RAM (rw) : ORIGIN = 0x80100000, LENGTH = 4K
}
SECTIONS {
    .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) } > ROM
    .data : { *(.data*) *(.sdata*) } > RAM
    .bss (NOLOAD) : { *(.bss*) *(.sbss*) *(COMMON) } > RAM
    /DISCARD/ : { *(.comment*) *(.riscv.attributes*) }
}
ASSERT(SIZEOF(.data) == 0, "startup does not copy initialized data")
ASSERT(SIZEOF(.bss) == 0, "startup does not zero BSS")
