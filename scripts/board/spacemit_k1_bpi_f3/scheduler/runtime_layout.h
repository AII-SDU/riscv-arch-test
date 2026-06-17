#ifndef K1_SCHEDULER_RUNTIME_LAYOUT_H
#define K1_SCHEDULER_RUNTIME_LAYOUT_H

#define SCHEDULER_ECALL_PASS    0UL
#define SCHEDULER_ECALL_FAIL    1UL

#define SCHEDULER_EXPECT_EXIT_CASE_COMPLETION 1UL

#define SCHEDULER_EVENT_NONE             0UL
#define SCHEDULER_EVENT_PASS_COMPLETION  1UL
#define SCHEDULER_EVENT_FAIL_COMPLETION  2UL
#define SCHEDULER_EVENT_PASS_ECALL       SCHEDULER_EVENT_PASS_COMPLETION
#define SCHEDULER_EVENT_FAIL_ECALL       SCHEDULER_EVENT_FAIL_COMPLETION
#define SCHEDULER_EVENT_UNEXPECTED_TRAP  3UL
#define SCHEDULER_EVENT_TIMEOUT_INTERRUPT 4UL
#define SCHEDULER_EVENT_UNEXPECTED_RETURN 5UL

#define SCHEDULER_RAW_TRAP_ORIGINAL_SP  0
#define SCHEDULER_RAW_TRAP_RA           8
#define SCHEDULER_RAW_TRAP_GP          16
#define SCHEDULER_RAW_TRAP_TP          24
#define SCHEDULER_RAW_TRAP_T1          32
#define SCHEDULER_RAW_TRAP_T2          40
#define SCHEDULER_RAW_TRAP_T3          48
#define SCHEDULER_RAW_TRAP_T4          56
#define SCHEDULER_RAW_TRAP_T5          64
#define SCHEDULER_RAW_TRAP_T6          72
#define SCHEDULER_RAW_TRAP_A0          80
#define SCHEDULER_RAW_TRAP_A1          88
#define SCHEDULER_RAW_TRAP_A2          96
#define SCHEDULER_RAW_TRAP_A3         104
#define SCHEDULER_RAW_TRAP_A4         112
#define SCHEDULER_RAW_TRAP_A5         120
#define SCHEDULER_RAW_TRAP_A6         128
#define SCHEDULER_RAW_TRAP_A7         136
#define SCHEDULER_RAW_TRAP_SCAUSE     144
#define SCHEDULER_RAW_TRAP_SEPC       152
#define SCHEDULER_RAW_TRAP_STVAL      160
#define SCHEDULER_RAW_TRAP_SSTATUS    168
#define SCHEDULER_RAW_TRAP_STVEC      176
#define SCHEDULER_RAW_TRAP_SSCRATCH   184
#define SCHEDULER_RAW_TRAP_SIE        192
#define SCHEDULER_RAW_TRAP_SIZE       200

#ifndef __ASSEMBLER__

#include <stddef.h>
#include <stdint.h>

enum scheduler_event_kind {
    SCHEDULER_EVENT_KIND_NONE = SCHEDULER_EVENT_NONE,
    SCHEDULER_EVENT_KIND_PASS_COMPLETION = SCHEDULER_EVENT_PASS_COMPLETION,
    SCHEDULER_EVENT_KIND_FAIL_COMPLETION = SCHEDULER_EVENT_FAIL_COMPLETION,
    SCHEDULER_EVENT_KIND_PASS_ECALL = SCHEDULER_EVENT_PASS_COMPLETION,
    SCHEDULER_EVENT_KIND_FAIL_ECALL = SCHEDULER_EVENT_FAIL_COMPLETION,
    SCHEDULER_EVENT_KIND_UNEXPECTED_TRAP = SCHEDULER_EVENT_UNEXPECTED_TRAP,
    SCHEDULER_EVENT_KIND_TIMEOUT_INTERRUPT = SCHEDULER_EVENT_TIMEOUT_INTERRUPT,
    SCHEDULER_EVENT_KIND_UNEXPECTED_RETURN = SCHEDULER_EVENT_UNEXPECTED_RETURN,
};

struct scheduler_raw_trap_frame {
    uintptr_t original_sp;
    uintptr_t ra;
    uintptr_t gp;
    uintptr_t tp;
    uintptr_t t1;
    uintptr_t t2;
    uintptr_t t3;
    uintptr_t t4;
    uintptr_t t5;
    uintptr_t t6;
    uintptr_t a0;
    uintptr_t a1;
    uintptr_t a2;
    uintptr_t a3;
    uintptr_t a4;
    uintptr_t a5;
    uintptr_t a6;
    uintptr_t a7;
    uintptr_t scause;
    uintptr_t sepc;
    uintptr_t stval;
    uintptr_t sstatus;
    uintptr_t stvec;
    uintptr_t sscratch;
    uintptr_t sie;
};

_Static_assert(offsetof(struct scheduler_raw_trap_frame, original_sp) == SCHEDULER_RAW_TRAP_ORIGINAL_SP, "original_sp offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, ra) == SCHEDULER_RAW_TRAP_RA, "ra offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, gp) == SCHEDULER_RAW_TRAP_GP, "gp offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, tp) == SCHEDULER_RAW_TRAP_TP, "tp offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, t1) == SCHEDULER_RAW_TRAP_T1, "t1 offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, t2) == SCHEDULER_RAW_TRAP_T2, "t2 offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, t3) == SCHEDULER_RAW_TRAP_T3, "t3 offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, t4) == SCHEDULER_RAW_TRAP_T4, "t4 offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, t5) == SCHEDULER_RAW_TRAP_T5, "t5 offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, t6) == SCHEDULER_RAW_TRAP_T6, "t6 offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, a0) == SCHEDULER_RAW_TRAP_A0, "a0 offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, a1) == SCHEDULER_RAW_TRAP_A1, "a1 offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, a2) == SCHEDULER_RAW_TRAP_A2, "a2 offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, a3) == SCHEDULER_RAW_TRAP_A3, "a3 offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, a4) == SCHEDULER_RAW_TRAP_A4, "a4 offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, a5) == SCHEDULER_RAW_TRAP_A5, "a5 offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, a6) == SCHEDULER_RAW_TRAP_A6, "a6 offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, a7) == SCHEDULER_RAW_TRAP_A7, "a7 offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, scause) == SCHEDULER_RAW_TRAP_SCAUSE, "scause offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, sepc) == SCHEDULER_RAW_TRAP_SEPC, "sepc offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, stval) == SCHEDULER_RAW_TRAP_STVAL, "stval offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, sstatus) == SCHEDULER_RAW_TRAP_SSTATUS, "sstatus offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, stvec) == SCHEDULER_RAW_TRAP_STVEC, "stvec offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, sscratch) == SCHEDULER_RAW_TRAP_SSCRATCH, "sscratch offset mismatch");
_Static_assert(offsetof(struct scheduler_raw_trap_frame, sie) == SCHEDULER_RAW_TRAP_SIE, "sie offset mismatch");
_Static_assert(sizeof(struct scheduler_raw_trap_frame) == SCHEDULER_RAW_TRAP_SIZE, "raw trap frame size mismatch");

#endif

#endif
