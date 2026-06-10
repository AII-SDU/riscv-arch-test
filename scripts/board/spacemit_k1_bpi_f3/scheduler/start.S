#include "runtime_layout.h"

.section .text.init, "ax", @progbits

.equ JMPBUF_RA,   0
.equ JMPBUF_SP,   8
.equ JMPBUF_S0,  16
.equ JMPBUF_S1,  24
.equ JMPBUF_S2,  32
.equ JMPBUF_S3,  40
.equ JMPBUF_S4,  48
.equ JMPBUF_S5,  56
.equ JMPBUF_S6,  64
.equ JMPBUF_S7,  72
.equ JMPBUF_S8,  80
.equ JMPBUF_S9,  88
.equ JMPBUF_S10, 96
.equ JMPBUF_S11, 104

.globl _start
_start:
  .option push
  .option norelax
  la gp, __global_pointer$
  .option pop

  la sp, __stack_top

  la a0, __bss_start
  la a1, __bss_end
1:
  bgeu a0, a1, 2f
  sd zero, 0(a0)
  addi a0, a0, 8
  j 1b
2:
  la t0, scheduler_trap_entry
  csrw stvec, t0
  call scheduler_main
3:
  wfi
  j 3b

.align 2
.globl scheduler_setjmp
scheduler_setjmp:
  sd ra, JMPBUF_RA(a0)
  sd sp, JMPBUF_SP(a0)
  sd s0, JMPBUF_S0(a0)
  sd s1, JMPBUF_S1(a0)
  sd s2, JMPBUF_S2(a0)
  sd s3, JMPBUF_S3(a0)
  sd s4, JMPBUF_S4(a0)
  sd s5, JMPBUF_S5(a0)
  sd s6, JMPBUF_S6(a0)
  sd s7, JMPBUF_S7(a0)
  sd s8, JMPBUF_S8(a0)
  sd s9, JMPBUF_S9(a0)
  sd s10, JMPBUF_S10(a0)
  sd s11, JMPBUF_S11(a0)
  li a0, 0
  ret

.align 2
.globl scheduler_longjmp
scheduler_longjmp:
  ld ra, JMPBUF_RA(a0)
  ld sp, JMPBUF_SP(a0)
  ld s0, JMPBUF_S0(a0)
  ld s1, JMPBUF_S1(a0)
  ld s2, JMPBUF_S2(a0)
  ld s3, JMPBUF_S3(a0)
  ld s4, JMPBUF_S4(a0)
  ld s5, JMPBUF_S5(a0)
  ld s6, JMPBUF_S6(a0)
  ld s7, JMPBUF_S7(a0)
  ld s8, JMPBUF_S8(a0)
  ld s9, JMPBUF_S9(a0)
  ld s10, JMPBUF_S10(a0)
  ld s11, JMPBUF_S11(a0)
  mv a0, a1
  bnez a0, 1f
  li a0, 1
1:
  ret

.align 2
.globl scheduler_trap_entry
scheduler_trap_entry:
  la t0, g_scheduler_trap_frame
  sd sp, SCHEDULER_RAW_TRAP_ORIGINAL_SP(t0)
  sd ra, SCHEDULER_RAW_TRAP_RA(t0)
  sd gp, SCHEDULER_RAW_TRAP_GP(t0)
  sd tp, SCHEDULER_RAW_TRAP_TP(t0)
  sd t1, SCHEDULER_RAW_TRAP_T1(t0)
  sd t2, SCHEDULER_RAW_TRAP_T2(t0)
  sd t3, SCHEDULER_RAW_TRAP_T3(t0)
  sd t4, SCHEDULER_RAW_TRAP_T4(t0)
  sd t5, SCHEDULER_RAW_TRAP_T5(t0)
  sd t6, SCHEDULER_RAW_TRAP_T6(t0)
  sd a0, SCHEDULER_RAW_TRAP_A0(t0)
  sd a1, SCHEDULER_RAW_TRAP_A1(t0)
  sd a2, SCHEDULER_RAW_TRAP_A2(t0)
  sd a3, SCHEDULER_RAW_TRAP_A3(t0)
  sd a4, SCHEDULER_RAW_TRAP_A4(t0)
  sd a5, SCHEDULER_RAW_TRAP_A5(t0)
  sd a6, SCHEDULER_RAW_TRAP_A6(t0)
  sd a7, SCHEDULER_RAW_TRAP_A7(t0)

  csrr t1, scause
  sd t1, SCHEDULER_RAW_TRAP_SCAUSE(t0)
  csrr t1, sepc
  sd t1, SCHEDULER_RAW_TRAP_SEPC(t0)
  csrr t1, stval
  sd t1, SCHEDULER_RAW_TRAP_STVAL(t0)
  csrr t1, sstatus
  sd t1, SCHEDULER_RAW_TRAP_SSTATUS(t0)
  csrr t1, stvec
  sd t1, SCHEDULER_RAW_TRAP_STVEC(t0)
  csrr t1, sscratch
  sd t1, SCHEDULER_RAW_TRAP_SSCRATCH(t0)
  csrr t1, sie
  sd t1, SCHEDULER_RAW_TRAP_SIE(t0)

  la sp, __trap_stack_top
  .option push
  .option norelax
  la gp, __global_pointer$
  .option pop
  mv a0, t0
  call scheduler_trap_dispatch
1:
  wfi
  j 1b
