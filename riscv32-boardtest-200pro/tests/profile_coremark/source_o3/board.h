#ifndef BOARD_H
#define BOARD_H
#include <stdint.h>
#ifndef CPU_HZ
#define CPU_HZ 120000000u
#endif
#define MMIO32(a) (*(volatile uint32_t *)(a))
#define TIMER_COUNT MMIO32(0x80200050u)
#define TIMER_OVERFLOW MMIO32(0x80200054u)
#define TIMER_CONTROL MMIO32(0x80200070u)
#define UART_TX MMIO32(0x80200100u)
#define UART_STATUS MMIO32(0x80200104u)
void uart_send_char(char c);
int ee_printf(const char *fmt, ...);
void board_banner(void);
unsigned board_selftest(void);
#endif
