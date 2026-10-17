OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
    ROM (rx)  : ORIGIN = 0x80000000, LENGTH = 32K
    RAM (rwx) : ORIGIN = 0x80100000, LENGTH = 64K
}
SECTIONS {
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > ROM
    .rodata : {
        *(.rodata .rodata.* .srodata .srodata.*)
        . = ALIGN(4);
    } > ROM
    .data : {
        __data_start = .;
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.sdata .sdata.* .data .data.*)
        . = ALIGN(4);
        __data_end = .;
    } > RAM AT > ROM
    __data_load = LOADADDR(.data);
    __rom_end = LOADADDR(.data) + SIZEOF(.data);
    .bss (NOLOAD) : {
        __bss_start = .;
        *(.sbss .sbss.* .bss .bss.* COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > RAM
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
    ASSERT(__rom_end <= ORIGIN(ROM) + LENGTH(ROM), "ROM overflow")
    ASSERT(__bss_end + 8192 <= __stack_top, "RAM must leave 8 KiB for stack")
    /DISCARD/ : { *(.comment .note.* .eh_frame .eh_frame_hdr) }
}
