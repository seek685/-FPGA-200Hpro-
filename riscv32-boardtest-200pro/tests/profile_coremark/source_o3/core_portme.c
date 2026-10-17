#include "coremark.h"
#include "board.h"
#ifndef ITERATIONS
#define ITERATIONS 3000
#endif

volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;

void start_time(void) { TIMER_CONTROL = 1; }
void stop_time(void) { TIMER_CONTROL = 0; }
CORE_TICKS get_time(void) { return (TIMER_OVERFLOW & 1u) ? 0u : TIMER_COUNT; }
secs_ret time_in_secs(CORE_TICKS ticks) { return (double)ticks / (double)CPU_HZ; }

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    board_banner();
    if (board_selftest()) {
        ee_printf("HALTED: SELFTEST FAILED\n");
        for (;;) { }
    }
    ee_printf("COREMARK ITERATIONS=%u\nTIMER_MAX_SECONDS=%f\n", (unsigned)ITERATIONS,
              4294967295.0 / (double)CPU_HZ);
    ee_printf("Please wait; UART is outside the timed region.\n");
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    CORE_TICKS ticks = get_time();
    if (TIMER_OVERFLOW & 1u) {
        ee_printf("TIMER OVERFLOW: INVALID RESULT\n");
    } else {
        ee_printf("CPU cycles       : %u\n", ticks);
        if (ticks && time_in_secs(ticks) >= 10.0)
            ee_printf("CoreMark/MHz     : %f\n", (double)ITERATIONS * 1000000.0 / (double)ticks);
        else
            ee_printf("CoreMark/MHz not reported: duration below 10 seconds.\n");
    }
    ee_printf("COREMARK DONE\n");
    p->portable_id = 0;
}
