#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

#define RVMODEL_DATA_SECTION

##### STARTUP #####

#define RVMODEL_ENTRY_SMODE
#define RVMODEL_BOOT

##### TERMINATION #####

#define RVMODEL_HALT_PASS \
  li a0, 0            ;   \
  ebreak

#define RVMODEL_HALT_FAIL \
  li a0, 1            ;   \
  ebreak

##### IO #####

/*
 * Restore the board-proven UART path used by the working scheduler builds.
 * Tests print RVCP-SUMMARY through this block before issuing PASS/FAIL ebreak.
 * OpenSBI keeps S-mode ecall for SBI handling on this board; breakpoint traps
 * are delegated back to S-mode and are therefore catchable by the scheduler.
 */
.EQU UART_BASE_ADDR, 0xd4017000
.EQU UART_THR, (UART_BASE_ADDR + (0 << 2))
.EQU UART_LCR, (UART_BASE_ADDR + (3 << 2))
.EQU UART_LSR, (UART_BASE_ADDR + (5 << 2))

#define RVMODEL_IO_INIT(_R1, _R2, _R3) \
  li _R1, UART_LCR                 ;   \
  li _R2, 0x03                     ;   \
  sb _R2, 0(_R1)

#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR) \
1: ;                                                   \
  lbu _R1, 0(_STR_PTR)                                 ;\
  beqz _R1, 3f                                         ;\
  li _R3, 10                                           ;\
  beq _R1, _R3, 5f                                     ;\
2: ;                                                   \
  li _R2, UART_LSR                                     ;\
4: ;                                                   \
  lbu _R3, 0(_R2)                                      ;\
  andi _R3, _R3, 0x20                                  ;\
  beqz _R3, 4b                                         ;\
  li _R2, UART_THR                                     ;\
  sb _R1, 0(_R2)                                       ;\
  addi _STR_PTR, _STR_PTR, 1                           ;\
  j 1b                                                 ;\
5: ;                                                   \
  li _R2, UART_LSR                                     ;\
6: ;                                                   \
  lbu _R3, 0(_R2)                                      ;\
  andi _R3, _R3, 0x20                                  ;\
  beqz _R3, 6b                                         ;\
  li _R2, UART_THR                                     ;\
  li _R3, 13                                           ;\
  sb _R3, 0(_R2)                                       ;\
  j 2b                                                 ;\
3:

##### Access Fault #####

#define RVMODEL_ACCESS_FAULT_ADDRESS rvmodel_access_fault_addr
.EQU rvmodel_access_fault_addr, 0x0000000080010000

##### Machine Timer #####

#define RVMODEL_MTIME_ADDRESS rvmodel_mtime_addr
#define RVMODEL_MTIMECMP_ADDRESS rvmodel_mtimecmp_addr
.EQU rvmodel_mtime_addr, 0x00000000e400bff8
.EQU rvmodel_mtimecmp_addr, 0x00000000e4004000

##### Machine Interrupts #####

#define RVMODEL_INTERRUPT_LATENCY 10
#define RVMODEL_TIMER_INT_SOON_DELAY 100

#define CLINT_BASE_ADDRESS rvmodel_clint_base_addr
#define MSIP_ADDRESS rvmodel_msip_addr
.EQU rvmodel_clint_base_addr, 0x00000000e4000000
.EQU rvmodel_msip_addr, (rvmodel_clint_base_addr + 0x0)

#define RVMODEL_SET_MEXT_INT(_R1, _R2)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)

#define RVMODEL_SET_MSW_INT(_R1, _R2) \
  li _R1, 1                       ;   \
  li _R2, MSIP_ADDRESS            ;   \
  sw _R1, 0(_R2)

#define RVMODEL_CLR_MSW_INT(_R1, _R2) \
  li _R2, MSIP_ADDRESS            ;   \
  sw zero, 0(_R2)

##### Supervisor Interrupts #####

#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)
#define RVMODEL_SET_SSW_INT(_R1, _R2)
#define RVMODEL_CLR_SSW_INT(_R1, _R2)

#endif // _RVMODEL_MACROS_H
