#include <stddef.h>
#include <stdint.h>

#include "runtime_layout.h"

#define UART_BASE_ADDR 0xd4017000UL
#define UART_THR       (UART_BASE_ADDR + (0UL << 2))
#define UART_LCR       (UART_BASE_ADDR + (3UL << 2))
#define UART_LSR       (UART_BASE_ADDR + (5UL << 2))

#define K1_TIMEBASE_HZ      24000000ULL

#define TEST_WINDOW_START 0x60000000UL
#define TEST_WINDOW_END   0x78000000UL

#define ELFCLASS64  2U
#define ELFDATA2LSB 1U
#define EV_CURRENT  1U
#define EM_RISCV    243U
#define PT_LOAD     1U

#define CAUSE_BREAKPOINT                 3UL
#define CAUSE_SUPERVISOR_ECALL           9UL
#define CAUSE_SUPERVISOR_TIMER_INTERRUPT ((1UL << ((sizeof(unsigned long) * 8U) - 1U)) | 5UL)

#define CSR_SSTATUS_SIE (1UL << 1)
#define CSR_SIE_STIE    (1UL << 5)

#ifndef SCHEDULER_TIMEOUT_MS
#define SCHEDULER_TIMEOUT_MS 10000UL
#endif

struct suite_case {
    const char *name;
    const char *path;
    const unsigned char *elf_start;
    const unsigned char *elf_end;
};

struct scheduler_jmpbuf {
    uintptr_t ra;
    uintptr_t sp;
    uintptr_t s[12];
};

enum case_status {
    CASE_STATUS_PENDING = 0,
    CASE_STATUS_PASS,
    CASE_STATUS_FAIL,
    CASE_STATUS_LOAD_ERROR,
    CASE_STATUS_UNEXPECTED_RETURN,
    CASE_STATUS_TIMEOUT,
};

struct scheduler_trap_baseline {
    uintptr_t stvec;
    uintptr_t sscratch;
    uintptr_t sie;
    uintptr_t sstatus;
    uintptr_t trap_stack_top;
    uint64_t timeout_ticks;
    uint64_t timer_armed;
};

struct scheduler_trap_expected {
    uint64_t active;
    uint64_t case_index;
    uintptr_t entry_pc;
    uintptr_t expected_exit_kind;
    uint64_t timeout_deadline_ticks;
    uintptr_t expected_stvec;
    uint64_t timeout_armed;
};

struct scheduler_trap_actual {
    enum scheduler_event_kind event_kind;
    uintptr_t original_sp;
    uintptr_t ra;
    uintptr_t gp;
    uintptr_t scause;
    uintptr_t sepc;
    uintptr_t stval;
    uintptr_t sstatus;
    uintptr_t stvec;
    uintptr_t sscratch;
    uintptr_t sie;
    uint64_t timestamp_ticks;
};

struct result_state {
    size_t index;
    const struct suite_case *current;
    enum case_status status;
    const char *reason;
    uintptr_t trap_cause;
    uintptr_t trap_epc;
    uintptr_t trap_tval;
    uintptr_t trap_arg0;
};

struct elf64_ehdr {
    unsigned char e_ident[16];
    uint16_t e_type;
    uint16_t e_machine;
    uint32_t e_version;
    uint64_t e_entry;
    uint64_t e_phoff;
    uint64_t e_shoff;
    uint32_t e_flags;
    uint16_t e_ehsize;
    uint16_t e_phentsize;
    uint16_t e_phnum;
    uint16_t e_shentsize;
    uint16_t e_shnum;
    uint16_t e_shstrndx;
};

struct elf64_phdr {
    uint32_t p_type;
    uint32_t p_flags;
    uint64_t p_offset;
    uint64_t p_vaddr;
    uint64_t p_paddr;
    uint64_t p_filesz;
    uint64_t p_memsz;
    uint64_t p_align;
};

extern const char k1_suite_name[];
extern const char k1_suite_scope[];
extern const struct suite_case k1_suite_cases[];
extern const struct suite_case k1_suite_cases_end[];
extern char __trap_stack_top[];

extern int scheduler_setjmp(struct scheduler_jmpbuf *buf);
extern void scheduler_longjmp(struct scheduler_jmpbuf *buf, int value) __attribute__((noreturn));
extern void scheduler_trap_entry(void);

struct scheduler_raw_trap_frame g_scheduler_trap_frame;

static struct scheduler_jmpbuf g_jmpbuf;
static struct result_state g_result;
static struct scheduler_trap_baseline g_trap_baseline;
static struct scheduler_trap_expected g_trap_expected;
static struct scheduler_trap_actual g_trap_actual;

static inline size_t suite_count(void)
{
    return (size_t)(k1_suite_cases_end - k1_suite_cases);
}

static inline void scheduler_restore_gp(void)
{
    __asm__ volatile(
        ".option push\n"
        ".option norelax\n"
        "la gp, __global_pointer$\n"
        ".option pop\n"
        :
        :
        : "gp");
}

static inline uintptr_t read_sstatus(void)
{
    uintptr_t value;
    __asm__ volatile("csrr %0, sstatus" : "=r"(value));
    return value;
}

static inline uintptr_t read_sie(void)
{
    uintptr_t value;
    __asm__ volatile("csrr %0, sie" : "=r"(value));
    return value;
}

static inline void write_sstatus(uintptr_t value)
{
    __asm__ volatile("csrw sstatus, %0" :: "r"(value) : "memory");
}

static inline void write_stvec(uintptr_t value)
{
    __asm__ volatile("csrw stvec, %0" :: "r"(value) : "memory");
}

static inline void write_sscratch(uintptr_t value)
{
    __asm__ volatile("csrw sscratch, %0" :: "r"(value) : "memory");
}

static inline void write_sie(uintptr_t value)
{
    __asm__ volatile("csrw sie, %0" :: "r"(value) : "memory");
}

static inline void write_stimecmp(uint64_t value)
{
    __asm__ volatile("csrw 0x14d, %0" :: "r"(value) : "memory");
}

static inline void mmio_write8(uintptr_t addr, uint8_t value)
{
    *(volatile uint8_t *)addr = value;
}

static inline uint8_t mmio_read8(uintptr_t addr)
{
    return *(volatile uint8_t *)addr;
}

static inline void mmio_write64(uintptr_t addr, uint64_t value)
{
    *(volatile uint64_t *)addr = value;
}

static inline uint64_t mmio_read64(uintptr_t addr)
{
    return *(volatile uint64_t *)addr;
}

static inline uint64_t scheduler_read_time(void)
{
    uint64_t value;
    __asm__ volatile("csrr %0, 0xc01" : "=r"(value));
    return value;
}

static void uart_init(void)
{
    mmio_write8(UART_LCR, 0x03);
}

static void uart_putc(char ch)
{
    while ((mmio_read8(UART_LSR) & 0x20U) == 0U) {
    }
    mmio_write8(UART_THR, (uint8_t)ch);
}

static void uart_puts(const char *text)
{
    if (!text) {
        return;
    }
    while (*text) {
        if (*text == '\n') {
            uart_putc('\r');
        }
        uart_putc(*text++);
    }
}

static void uart_put_newline(void)
{
    uart_putc('\r');
    uart_putc('\n');
}

static void uart_put_hex(unsigned long value)
{
    static const char digits[] = "0123456789abcdef";
    int shift;

    uart_puts("0x");
    for (shift = (int)(sizeof(unsigned long) * 8) - 4; shift >= 0; shift -= 4) {
        uart_putc(digits[(value >> shift) & 0xfU]);
    }
}

static void uart_put_dec(unsigned long value)
{
    char buffer[32];
    size_t index = 0;

    if (value == 0UL) {
        uart_putc('0');
        return;
    }

    while (value != 0UL) {
        buffer[index++] = (char)('0' + (value % 10UL));
        value /= 10UL;
    }

    while (index > 0U) {
        uart_putc(buffer[--index]);
    }
}

static void mem_copy(void *dest, const void *src, size_t size)
{
    size_t index;
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;

    for (index = 0; index < size; ++index) {
        d[index] = s[index];
    }
}

static void mem_zero(void *dest, size_t size)
{
    size_t index;
    unsigned char *d = (unsigned char *)dest;

    for (index = 0; index < size; ++index) {
        d[index] = 0;
    }
}

static void scheduler_fence_exec(void)
{
    __asm__ volatile("fence rw, rw" ::: "memory");
    __asm__ volatile("fence.i" ::: "memory");
}

static uint64_t scheduler_timeout_ticks_from_ms(uint64_t timeout_ms)
{
    if (timeout_ms == 0U) {
        return 0U;
    }
    return (timeout_ms * K1_TIMEBASE_HZ) / 1000U;
}

static void scheduler_disarm_timeout(void)
{
    write_stimecmp(UINT64_MAX);
    g_trap_baseline.timer_armed = 0U;
    g_trap_expected.timeout_armed = 0U;
    g_trap_expected.timeout_deadline_ticks = 0U;
}

static void scheduler_install_owned_trap_state(void)
{
    scheduler_restore_gp();
    write_stvec(g_trap_baseline.stvec);
    write_sscratch(g_trap_baseline.sscratch);
    write_sie(g_trap_baseline.sie);
    write_sstatus(g_trap_baseline.sstatus);
}

static void scheduler_restore_owned_state(void)
{
    scheduler_disarm_timeout();
    scheduler_install_owned_trap_state();
    g_trap_expected.active = 0U;
}

static void scheduler_prepare_case_runtime(uintptr_t entry)
{
    uint64_t now;
    uint64_t deadline;

    scheduler_restore_owned_state();
    mem_zero(&g_scheduler_trap_frame, sizeof(g_scheduler_trap_frame));
    mem_zero(&g_trap_actual, sizeof(g_trap_actual));
    mem_zero(&g_trap_expected, sizeof(g_trap_expected));

    g_trap_expected.active = 1U;
    g_trap_expected.case_index = (uint64_t)g_result.index;
    g_trap_expected.entry_pc = entry;
    g_trap_expected.expected_exit_kind = SCHEDULER_EXPECT_EXIT_CASE_COMPLETION;
    g_trap_expected.expected_stvec = g_trap_baseline.stvec;

    if (g_trap_baseline.timeout_ticks == 0U) {
        return;
    }

    now = scheduler_read_time();
    deadline = now + g_trap_baseline.timeout_ticks;
    if (deadline < now) {
        deadline = UINT64_MAX - 1U;
    }

    g_trap_expected.timeout_deadline_ticks = deadline;
    g_trap_expected.timeout_armed = 1U;
    g_trap_baseline.timer_armed = 1U;

    write_stimecmp(deadline);
    write_sie(g_trap_baseline.sie | CSR_SIE_STIE);
    write_sstatus(g_trap_baseline.sstatus | CSR_SSTATUS_SIE);
}

static void scheduler_capture_actual_from_raw(const struct scheduler_raw_trap_frame *raw)
{
    g_trap_actual.original_sp = raw->original_sp;
    g_trap_actual.ra = raw->ra;
    g_trap_actual.gp = raw->gp;
    g_trap_actual.scause = raw->scause;
    g_trap_actual.sepc = raw->sepc;
    g_trap_actual.stval = raw->stval;
    g_trap_actual.sstatus = raw->sstatus;
    g_trap_actual.stvec = raw->stvec;
    g_trap_actual.sscratch = raw->sscratch;
    g_trap_actual.sie = raw->sie;
    g_trap_actual.timestamp_ticks = scheduler_read_time();
}

static void scheduler_capture_unexpected_return(uintptr_t entry)
{
    mem_zero(&g_trap_actual, sizeof(g_trap_actual));
    g_trap_actual.event_kind = SCHEDULER_EVENT_KIND_UNEXPECTED_RETURN;
    g_trap_actual.sepc = entry;
    g_trap_actual.sstatus = read_sstatus();
    g_trap_actual.stvec = g_trap_baseline.stvec;
    g_trap_actual.sie = read_sie();
    g_trap_actual.timestamp_ticks = scheduler_read_time();
}

static void scheduler_commit_actual_to_result(uintptr_t arg0)
{
    g_result.trap_cause = g_trap_actual.scause;
    g_result.trap_epc = g_trap_actual.sepc;
    g_result.trap_tval = g_trap_actual.stval;
    g_result.trap_arg0 = arg0;
}

static const char *status_name(enum case_status status)
{
    switch (status) {
    case CASE_STATUS_PASS:
        return "PASS";
    case CASE_STATUS_FAIL:
        return "FAIL";
    case CASE_STATUS_LOAD_ERROR:
        return "LOAD_ERROR";
    case CASE_STATUS_UNEXPECTED_RETURN:
        return "UNEXPECTED_RETURN";
    case CASE_STATUS_TIMEOUT:
        return "TIMEOUT";
    case CASE_STATUS_PENDING:
    default:
        return "PENDING";
    }
}

static void log_prefix(const char *kind)
{
    uart_puts("ACT-SCHED: ");
    uart_puts(kind);
    uart_putc(' ');
}

static void log_case_boot(const struct suite_case *test_case, size_t index, size_t total)
{
    log_prefix("CASE");
    uart_puts("index=");
    uart_put_dec(index);
    uart_puts(" total=");
    uart_put_dec(total);
    uart_puts(" name=");
    uart_puts(test_case->name);
    uart_puts(" path=");
    uart_puts(test_case->path);
    uart_put_newline();
}

static void log_result_line(const struct suite_case *test_case, size_t index, size_t total)
{
    log_prefix("RESULT");
    uart_puts("index=");
    uart_put_dec(index);
    uart_puts(" total=");
    uart_put_dec(total);
    uart_puts(" name=");
    uart_puts(test_case->name);
    uart_puts(" status=");
    uart_puts(status_name(g_result.status));
    uart_put_newline();
}

static void log_error_line(const char *kind, const struct suite_case *test_case, size_t index)
{
    log_prefix(kind);
    uart_puts("index=");
    uart_put_dec(index);
    uart_puts(" name=");
    uart_puts(test_case->name);
    uart_puts(" path=");
    uart_puts(test_case->path);
    if (g_result.reason) {
        uart_puts(" reason=");
        uart_puts(g_result.reason);
    }
    if (g_result.trap_cause != 0U || g_result.trap_epc != 0U || g_result.trap_tval != 0U) {
        uart_puts(" cause=");
        uart_put_hex(g_result.trap_cause);
        uart_puts(" epc=");
        uart_put_hex(g_result.trap_epc);
        uart_puts(" tval=");
        uart_put_hex(g_result.trap_tval);
    }
    if (g_result.trap_arg0 != 0U) {
        uart_puts(" arg0=");
        uart_put_hex(g_result.trap_arg0);
    }
    uart_put_newline();
}

static int add_overflows(uint64_t a, uint64_t b, uint64_t *sum)
{
    *sum = a + b;
    return *sum < a;
}

static const char *load_elf_image(const struct suite_case *test_case, uintptr_t *entry_out)
{
    const struct elf64_ehdr *ehdr;
    const unsigned char *elf = test_case->elf_start;
    size_t size = (size_t)(test_case->elf_end - test_case->elf_start);
    uint64_t ph_end;
    uint16_t index;
    uint16_t load_count = 0U;

    if (size < sizeof(*ehdr)) {
        return "elf_too_small";
    }

    ehdr = (const struct elf64_ehdr *)elf;
    if (((uint32_t)ehdr->e_ident[0]) != 0x7fU ||
        ehdr->e_ident[1] != 'E' ||
        ehdr->e_ident[2] != 'L' ||
        ehdr->e_ident[3] != 'F') {
        return "bad_magic";
    }
    if (ehdr->e_ident[4] != ELFCLASS64) {
        return "bad_class";
    }
    if (ehdr->e_ident[5] != ELFDATA2LSB) {
        return "bad_endian";
    }
    if (ehdr->e_ident[6] != EV_CURRENT) {
        return "bad_ident_version";
    }
    if (ehdr->e_machine != EM_RISCV) {
        return "bad_machine";
    }
    if (ehdr->e_phentsize != sizeof(struct elf64_phdr)) {
        return "bad_phentsize";
    }
    if (add_overflows(ehdr->e_phoff, (uint64_t)ehdr->e_phnum * (uint64_t)ehdr->e_phentsize, &ph_end) ||
        ph_end > size) {
        return "bad_ph_table";
    }
    if (ehdr->e_entry < TEST_WINDOW_START || ehdr->e_entry >= TEST_WINDOW_END) {
        return "entry_out_of_range";
    }

    for (index = 0; index < ehdr->e_phnum; ++index) {
        const struct elf64_phdr *phdr;
        uintptr_t target;
        uint64_t segment_end;

        phdr = (const struct elf64_phdr *)(elf + ehdr->e_phoff + ((uint64_t)index * ehdr->e_phentsize));
        if (phdr->p_type != PT_LOAD) {
            continue;
        }

        ++load_count;
        if (phdr->p_filesz > phdr->p_memsz) {
            return "filesz_gt_memsz";
        }
        if (add_overflows(phdr->p_offset, phdr->p_filesz, &segment_end) || segment_end > size) {
            return "segment_data_oob";
        }

        target = (uintptr_t)(phdr->p_paddr != 0U ? phdr->p_paddr : phdr->p_vaddr);
        if (target < TEST_WINDOW_START) {
            return "segment_below_window";
        }
        if (add_overflows(target, phdr->p_memsz, &segment_end) || segment_end > TEST_WINDOW_END) {
            return "segment_above_window";
        }

        mem_copy((void *)target, elf + phdr->p_offset, (size_t)phdr->p_filesz);
        mem_zero((void *)(target + phdr->p_filesz), (size_t)(phdr->p_memsz - phdr->p_filesz));
    }

    if (load_count == 0U) {
        return "no_load_segments";
    }

    *entry_out = (uintptr_t)ehdr->e_entry;
    scheduler_fence_exec();
    return (const char *)0;
}

static void launch_entry(uintptr_t entry)
{
    void (*entry_fn)(void) = (void (*)(void))entry;
    entry_fn();
}

static void mark_load_error(const char *reason)
{
    g_result.status = CASE_STATUS_LOAD_ERROR;
    g_result.reason = reason;
}

static void mark_unexpected_return(void)
{
    g_result.status = CASE_STATUS_UNEXPECTED_RETURN;
    g_result.reason = "test_returned";
    scheduler_commit_actual_to_result(0U);
}

static int is_case_completion_trap(uintptr_t cause)
{
    return cause == CAUSE_BREAKPOINT || cause == CAUSE_SUPERVISOR_ECALL;
}

static void run_current_case(void)
{
    uintptr_t entry = 0U;
    const char *load_error = load_elf_image(g_result.current, &entry);

    if (load_error) {
        mark_load_error(load_error);
        return;
    }

    scheduler_prepare_case_runtime(entry);
    launch_entry(entry);
    scheduler_capture_unexpected_return(entry);
    scheduler_restore_owned_state();
    mark_unexpected_return();
}

void scheduler_trap_dispatch(const struct scheduler_raw_trap_frame *raw) __attribute__((noreturn));

void scheduler_trap_dispatch(const struct scheduler_raw_trap_frame *raw)
{
    g_result.reason = 0;
    scheduler_capture_actual_from_raw(raw);

    if (!g_trap_expected.active) {
        g_trap_actual.event_kind = SCHEDULER_EVENT_KIND_UNEXPECTED_TRAP;
        g_result.status = CASE_STATUS_TIMEOUT;
        g_result.reason = "trap_without_active_case";
    } else if (is_case_completion_trap(raw->scause)) {
        if (raw->a0 == SCHEDULER_ECALL_PASS) {
            g_trap_actual.event_kind = SCHEDULER_EVENT_KIND_PASS_COMPLETION;
            g_result.status = CASE_STATUS_PASS;
        } else if (raw->a0 == SCHEDULER_ECALL_FAIL) {
            g_trap_actual.event_kind = SCHEDULER_EVENT_KIND_FAIL_COMPLETION;
            g_result.status = CASE_STATUS_FAIL;
        } else {
            g_trap_actual.event_kind = SCHEDULER_EVENT_KIND_UNEXPECTED_TRAP;
            g_result.status = CASE_STATUS_TIMEOUT;
            g_result.reason = "unexpected_completion_arg0";
        }
    } else if (raw->scause == CAUSE_SUPERVISOR_TIMER_INTERRUPT && g_trap_expected.timeout_armed) {
        g_trap_actual.event_kind = SCHEDULER_EVENT_KIND_TIMEOUT_INTERRUPT;
        g_result.status = CASE_STATUS_TIMEOUT;
        g_result.reason = "supervisor_timer_timeout";
    } else {
        g_trap_actual.event_kind = SCHEDULER_EVENT_KIND_UNEXPECTED_TRAP;
        g_result.status = CASE_STATUS_TIMEOUT;
        g_result.reason = "unexpected_trap";
    }

    scheduler_commit_actual_to_result(raw->a0);
    scheduler_restore_owned_state();
    scheduler_longjmp(&g_jmpbuf, 1);
}

static void log_boot_banner(void)
{
    log_prefix("BOOT");
    uart_puts("name=");
    uart_puts(k1_suite_name);
    uart_puts(" scope=");
    uart_puts(k1_suite_scope);
    uart_puts(" total=");
    uart_put_dec(suite_count());
    uart_puts(" timeout_ms=");
    uart_put_dec((unsigned long)SCHEDULER_TIMEOUT_MS);
    uart_put_newline();
}

static void log_complete(void)
{
    log_prefix("COMPLETE");
    uart_puts("name=");
    uart_puts(k1_suite_name);
    uart_puts(" total=");
    uart_put_dec(suite_count());
    uart_put_newline();
}

static void log_current_result(size_t total)
{
    switch (g_result.status) {
    case CASE_STATUS_LOAD_ERROR:
        log_error_line("LOAD_ERROR", g_result.current, g_result.index);
        break;
    case CASE_STATUS_UNEXPECTED_RETURN:
        log_error_line("UNEXPECTED_RETURN", g_result.current, g_result.index);
        break;
    case CASE_STATUS_TIMEOUT:
        log_error_line("TIMEOUT", g_result.current, g_result.index);
        break;
    case CASE_STATUS_PASS:
    case CASE_STATUS_FAIL:
    case CASE_STATUS_PENDING:
    default:
        break;
    }

    log_result_line(g_result.current, g_result.index, total);
}

static void scheduler_init_runtime(void)
{
    g_trap_baseline.stvec = (uintptr_t)&scheduler_trap_entry;
    g_trap_baseline.sscratch = 0U;
    g_trap_baseline.sie = read_sie() & ~CSR_SIE_STIE;
    g_trap_baseline.sstatus = read_sstatus() & ~CSR_SSTATUS_SIE;
    g_trap_baseline.trap_stack_top = (uintptr_t)__trap_stack_top;
    g_trap_baseline.timeout_ticks = scheduler_timeout_ticks_from_ms((uint64_t)SCHEDULER_TIMEOUT_MS);
    g_trap_baseline.timer_armed = 0U;

    mem_zero(&g_scheduler_trap_frame, sizeof(g_scheduler_trap_frame));
    mem_zero(&g_trap_expected, sizeof(g_trap_expected));
    mem_zero(&g_trap_actual, sizeof(g_trap_actual));
    scheduler_restore_owned_state();
}

void scheduler_main(void)
{
    size_t total = suite_count();
    size_t index;

    uart_init();
    scheduler_init_runtime();
    log_boot_banner();

    if (total == 0U) {
        log_complete();
        for (;;) {
            __asm__ volatile("wfi");
        }
    }

    for (index = 0; index < total; ++index) {
        g_result.index = index;
        g_result.current = &k1_suite_cases[index];
        g_result.status = CASE_STATUS_PENDING;
        g_result.reason = 0;
        g_result.trap_cause = 0U;
        g_result.trap_epc = 0U;
        g_result.trap_tval = 0U;
        g_result.trap_arg0 = 0U;

        log_case_boot(g_result.current, index, total);
        if (scheduler_setjmp(&g_jmpbuf) == 0) {
            run_current_case();
        }
        log_current_result(total);
    }

    log_complete();
    for (;;) {
        __asm__ volatile("wfi");
    }
}
