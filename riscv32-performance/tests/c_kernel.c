#include <stdint.h>

static volatile uint32_t data[64];
static volatile uint32_t links[64];

__attribute__((noinline)) static uint32_t mix(uint32_t x)
{
    x ^= x << 13;
    x ^= x >> 17;
    return x ^ (x << 5);
}

__attribute__((noinline)) static uint32_t crc_word(uint32_t crc, uint32_t word)
{
    crc ^= word;
    for (unsigned bit = 0; bit < 32; ++bit)
        crc = (crc >> 1) ^ ((0u - (crc & 1u)) & 0xedb88320u);
    return crc;
}

int main(void)
{
    uint32_t state = 0x13579bdfu;
    for (unsigned i = 0; i < 64; ++i) {
        state = mix(state + i);
        data[i] = state;
        links[i] = (i + 17u) & 63u;
    }
    uint32_t sum = 0;
    unsigned node = 0;
    for (unsigned i = 0; i < 256; ++i) {
        node = links[node];
        uint32_t x = data[node];
        if ((x & 3u) == 0) sum += x;
        else if ((x & 3u) == 1) sum ^= x;
        else if ((x & 3u) == 2) sum -= x;
        else sum = (sum << 1) | (sum >> 31);
    }
    for (unsigned i = 1; i < 64; ++i) {
        uint32_t key = data[i];
        unsigned j = i;
        while (j && data[j - 1] > key) {
            data[j] = data[j - 1];
            --j;
        }
        data[j] = key;
    }
    uint32_t crc = 0xffffffffu;
    for (unsigned i = 0; i < 64; ++i)
        crc = crc_word(crc, data[i]);
    return (int)(crc ^ sum ^ data[0] ^ data[63]);
}
