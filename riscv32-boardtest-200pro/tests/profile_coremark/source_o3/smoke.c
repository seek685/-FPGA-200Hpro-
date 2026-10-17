#include "board.h"
int main(void)
{
    board_banner();
    if (board_selftest()) {
        ee_printf("HALTED: SELFTEST FAILED\n");
        return 1;
    }
    ee_printf("UART PASS\nSMOKE DONE\n");
    return 0;
}
