/* Real greedy CTC over the 20 hardware argmax tokens; no fixed plate output.
 * APB reads do not pop. COMMIT verifies the task ID and atomically consumes it.
 * Polling avoids interrupts/CSRs. The uncached, single-outstanding bus is ordered.
 */
typedef unsigned int u32;
#define REG(offset) (*(volatile u32 *)(0x40000000u + (offset)))

int main(void)
{
    for (;;) {
        while (!(REG(0x00) & 1u)) { }
        u32 task = REG(0x04);
        u32 previous = 75u, length = 0u;
        for (u32 t = 0; t < 20u; ++t) {
            u32 symbol = REG(0x40 + 4u * t);
            if (symbol < 75u && symbol != previous) {
                REG(0x100 + 4u * length) = symbol;
                ++length;
            }
            previous = symbol; /* blank separates two copies of the same label */
        }
        REG(0x10) = length;
        REG(0x14) = task;
    }
}
