#include "board.h"
#include <stddef.h>
#include <stdarg.h>

void uart_send_char(char c)
{
    if (c == '\n') uart_send_char('\r');
    while (UART_STATUS & 1u) { }
    UART_TX = (unsigned char)c;
}

static int print_unsigned(uint32_t value, unsigned base, unsigned width, char pad)
{
    char digits[32];
    unsigned n = 0;
    int count = 0;
    do {
        unsigned digit = value % base;
        digits[n++] = (char)(digit < 10 ? '0' + digit : 'a' + digit - 10);
        value /= base;
    } while (value);
    while (width > n) { uart_send_char(pad); --width; ++count; }
    while (n) { uart_send_char(digits[--n]); ++count; }
    return count;
}

/* Formats used by the unmodified official CoreMark report, with software double. */
int ee_printf(const char *fmt, ...)
{
    va_list ap;
    int count = 0;
    va_start(ap, fmt);
    while (*fmt) {
        unsigned width = 0;
        char pad = ' ';
        int is_long = 0;
        char spec;
        if (*fmt != '%') { uart_send_char(*fmt++); ++count; continue; }
        ++fmt;
        if (*fmt == '0') { pad = '0'; ++fmt; }
        while (*fmt >= '0' && *fmt <= '9') width = width * 10u + (unsigned)(*fmt++ - '0');
        if (*fmt == 'l') { is_long = 1; ++fmt; }
        spec = *fmt++;
        if (spec == 's') {
            const char *s = va_arg(ap, const char *);
            while (*s) { uart_send_char(*s++); ++count; }
        } else if (spec == 'c') {
            uart_send_char((char)va_arg(ap, int)); ++count;
        } else if (spec == 'd' || spec == 'i') {
            int32_t value = is_long ? (int32_t)va_arg(ap, long) : va_arg(ap, int);
            uint32_t magnitude = (uint32_t)value;
            if (value < 0) { uart_send_char('-'); ++count; magnitude = 0u - magnitude; }
            count += print_unsigned(magnitude, 10, width, pad);
        } else if (spec == 'u' || spec == 'x') {
            uint32_t value = is_long ? (uint32_t)va_arg(ap, unsigned long) : va_arg(ap, unsigned);
            count += print_unsigned(value, spec == 'x' ? 16 : 10, width, pad);
        } else if (spec == 'f') {
            double value = va_arg(ap, double);
            uint32_t whole, fraction;
            if (value < 0.0) { uart_send_char('-'); ++count; value = -value; }
            whole = (uint32_t)value;
            fraction = (uint32_t)((value - (double)whole) * 1000000.0 + 0.5);
            if (fraction >= 1000000u) { ++whole; fraction -= 1000000u; }
            count += print_unsigned(whole, 10, 0, ' ');
            uart_send_char('.'); ++count;
            count += print_unsigned(fraction, 10, 6, '0');
        } else {
            uart_send_char(spec); ++count;
        }
    }
    va_end(ap);
    return count;
}

void *memset(void *dest, int value, size_t n)
{
    unsigned char *d = dest;
    while (n--) *d++ = (unsigned char)value;
    return dest;
}

void *memcpy(void *dest, const void *src, size_t n)
{
    unsigned char *d = dest;
    const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dest;
}

void board_banner(void)
{
    ee_printf("\nCPU BOARD TEST\nCPU_HZ=%u\n", CPU_HZ);
}

static volatile uint32_t initialized_sentinel = 0x13579bdfu;
static volatile uint32_t zero_sentinel;
static volatile uint32_t test_words[64];

unsigned board_selftest(void)
{
    uint32_t sum = 0;
    unsigned i, errors = 0;
    if (initialized_sentinel != 0x13579bdfu || zero_sentinel != 0) ++errors;
    for (i = 0; i < 64; ++i) test_words[i] = (i * 0x10203u) ^ 0x89abcdefu;
    for (i = 0; i < 64; ++i) sum = (sum << 3 | sum >> 29) ^ test_words[i];
    if (sum != 0x24924939u) ++errors;
    test_words[0] = 0x12345678u;
    ((volatile uint8_t *)test_words)[1] = 0x80u;
    ((volatile uint16_t *)test_words)[1] = 0xffa5u;
    if (test_words[0] != 0xffa58078u) ++errors;
    if (((volatile int8_t *)test_words)[1] != -128) ++errors;
    if (((volatile int16_t *)test_words)[1] != -91) ++errors;
    if (((volatile uint8_t *)test_words)[1] != 128u) ++errors;
    if (((volatile uint16_t *)test_words)[1] != 65445u) ++errors;
    if (errors) ee_printf("SMOKE FAIL errors=%u checksum=0x%08x\n", errors, sum);
    else ee_printf("SMOKE PASS checksum=0x%08x\n", sum);
    return errors;
}
