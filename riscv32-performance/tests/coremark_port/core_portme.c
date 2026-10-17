/* Simulation-only port. One iteration validates official CRCs; no CoreMark score is reported. */
#include "coremark.h"
#include <stdarg.h>

volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = 1;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;
static unsigned checks, errors;

static int contains(const char *text, const char *match)
{
    for (; *text; ++text) {
        const char *a = text, *b = match;
        while (*b && *a == *b) { ++a; ++b; }
        if (!*b) return 1;
    }
    return 0;
}

void start_time(void) { *(volatile ee_u32 *)0x80200070u = 1; }
void stop_time(void) { *(volatile ee_u32 *)0x80200070u = 0; }
CORE_TICKS get_time(void) { return 1; }
secs_ret time_in_secs(CORE_TICKS ticks) { (void)ticks; return 0; }

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc; (void)argv;
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    p->portable_id = 0;
    *(volatile ee_u32 *)0x80200020u = 0xc04e0000u | checks | (errors << 8);
}

int ee_printf(const char *format, ...)
{
    va_list args;
    unsigned expected = 0, value;
    int crc = 1, context = 1;
    if (contains(format, "seedcrc")) { expected = 0xe9f5; context = 0; }
    else if (contains(format, "crclist")) expected = 0xe714;
    else if (contains(format, "crcmatrix")) expected = 0x1fd7;
    else if (contains(format, "crcstate")) expected = 0x8e3a;
    else if (contains(format, "crcfinal")) expected = 0xe714;
    else crc = 0;
    if (crc) {
        va_start(args, format);
        if (context) (void)va_arg(args, int);
        value = va_arg(args, unsigned);
        va_end(args);
        *(volatile ee_u32 *)(0x80200080u + checks * 4) = value;
        if (value != expected) ++errors;
        ++checks;
    }
    /* The official >=10 s error is expected in this deliberately short CRC test. */
    if (contains(format, "ERROR!") && !contains(format, "Must execute")) ++errors;
    return 0;
}
