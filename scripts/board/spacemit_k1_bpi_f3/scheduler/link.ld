OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x00200000;

  .text : ALIGN(0x1000) {
    *(.text.init)
    *(.text .text.*)
  }

  .rodata : ALIGN(0x1000) {
    *(.rodata .rodata.*)
  }

  .data : ALIGN(0x1000) {
    PROVIDE(__global_pointer$ = . + 0x800);
    *(.data .data.*)
    *(.sdata .sdata.*)
  }

  .bss : ALIGN(0x1000) {
    __bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    __bss_end = .;
  }

  . = ALIGN(16);
  __stack_bottom = .;
  . += 0x00008000;
  __stack_top = .;

  . = ALIGN(16);
  __trap_stack_bottom = .;
  . += 0x00004000;
  __trap_stack_top = .;

  _end = .;
}
