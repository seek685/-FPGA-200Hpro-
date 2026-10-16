#!/usr/bin/env python3
"""Generate deterministic RV32I dependency/branch/subword checks, no CSR/M/cache."""
from pathlib import Path
import random
import subprocess


def build(out):
    out.mkdir(parents=True, exist_ok=True)
    lines = ['.section .text', '.globl _start', '.option norvc', '.option norelax',
             '_start:', 'li t4, 0x80100000', 'li t5, 0x40001000']
    number = 0

    def check(body, expected, reg='t2'):
        nonlocal number
        number += 1
        lines.extend([f'li t6, {number * 2 + 1}', *body,
                      f'li t3, 0x{expected & 0xffffffff:08x}', f'bne {reg}, t3, fail'])

    check(['li t0, 7', 'addi t1, t0, -9', 'add t2, t1, t0'], 5)
    check(['li t0, -1', 'addi zero, t0, 1', 'add t2, zero, zero'], 0)
    # Back-to-back loads/stores, every byte lane, sign extension, load-use.
    check(['li t0, 0x80ff7f01', 'sw t0, 0(t4)', 'lw t1, 0(t4)', 'addi t2, t1, 1'], 0x80ff7f02)
    for i, value in enumerate((1, 127, 255, 128)):
        check([f'lbu t2, {i}(t4)'], value)
        check([f'lb t2, {i}(t4)'], value if value < 128 else value - 256)
    check(['lh t2, 2(t4)'], -32513)
    check(['lhu t2, 2(t4)'], 0x80ff)
    check(['li t0, 0x11223344', 'sw t0, 4(t4)', 'li t1, 0xaa', 'sb t1, 5(t4)', 'lw t2, 4(t4)'], 0x1122aa44)
    check(['li t1, 0x89ab', 'sh t1, 6(t4)', 'lw t2, 4(t4)'], 0x89abaa44)
    check(['lw t0, 4(t4)', 'sw t0, 8(t4)', 'lw t2, 8(t4)'], 0x89abaa44)
    check(['li t0, 32', 'sw t0, 12(t4)', 'lw t1, 12(t4)', 'sw t1, 16(t4)',
           'lw t0, 16(t4)', 'add t2, t0, t1'], 64)
    # AUIPC PC-relative address, ID JAL, EX JALR low-bit masking and return bypass.
    check(['auipc t0, 0', 'auipc t1, 0', 'sub t2, t1, t0'], 4)
    check(['li t2, 0', 'jal ra, jump_target', 'j fail', 'jump_target:',
           'addi t2, t2, 1', 'la t0, indirect_target', 'ori t0, t0, 1',
           'jalr ra, 0(t0)', 'j fail', 'indirect_target:', 'addi t2, t2, 2'], 3)
    # A wrong-path store would immediately fail the test via the host address.
    lines += ['li t0, 128', 'li t1, 0', 'predict_loop:', 'addi t1, t1, 1',
              'blt t1, t0, predict_loop', 'beq t1, t0, no_wrong_store',
              'sw t6, 0(t5)', 'no_wrong_store:']
    check(['addi t2, t1, 0'], 128)
    for op, a, b, taken in [('beq',1,1,True),('beq',1,2,False),('bne',1,2,True),('bne',1,1,False),
                            ('blt',-1,1,True),('blt',1,-1,False),('bge',1,-1,True),('bge',-1,1,False),
                            ('bltu',1,-1,True),('bltu',-1,1,False),('bgeu',-1,1,True),('bgeu',1,-1,False)]:
        tag = f'branch_{number}'
        check([f'li t0, {a}', f'li t1, {b}', 'sw t0, 24(t4)', 'lw t0, 24(t4)',
               'li t2, 0', f'{op} t0, t1, {tag}', f'j {tag}_end', f'{tag}:',
               'li t2, 1', f'{tag}_end:'], int(taken))

    rng = random.Random(200)
    signed = lambda x: x if x < 0x80000000 else x - 0x100000000
    for _ in range(24):
        a, b = rng.getrandbits(32), rng.getrandbits(32)
        expected = {'add':a+b, 'sub':a-b, 'xor':a^b, 'or':a|b, 'and':a&b,
                    'slt':int(signed(a)<signed(b)), 'sltu':int(a<b),
                    'sll':a<<(b&31), 'srl':a>>(b&31), 'sra':signed(a)>>(b&31)}
        for op, value in expected.items():
            check([f'li t0, 0x{a:08x}', f'li t1, 0x{b:08x}', f'{op} t2, t0, t1'], value)
        imm = rng.randrange(-2048, 2048)
        for op, value in [('addi', a+imm), ('xori', a^(imm&0xffffffff)),
                          ('ori', a|(imm&0xffffffff)), ('andi', a&(imm&0xffffffff)),
                          ('slti', int(signed(a)<imm)), ('sltiu', int(a<(imm&0xffffffff)))]:
            check([f'li t0, 0x{a:08x}', f'{op} t2, t0, {imm}'], value)
        shift = rng.randrange(32)
        for op, value in [('slli',a<<shift), ('srli',a>>shift), ('srai',signed(a)>>shift)]:
            check([f'li t0, 0x{a:08x}', f'{op} t2, t0, {shift}'], value)
    # Load->branch with no intervening instruction, and taken branch over a store.
    lines += ['li t0, 17', 'sw t0, 32(t4)', 'lw t1, 32(t4)',
              'bne t1, t0, fail', 'li t0, 64', 'memory_loop:',
              'lw t1, 32(t4)', 'addi t1, t1, 1', 'sw t1, 32(t4)',
              'addi t0, t0, -1', 'bne t0, zero, memory_loop']
    check(['lw t2, 32(t4)'], 81)
    lines += ['li t0, 1', 'sw t0, 0(t5)', 'halt:', 'j halt', 'fail:', 'sw t6, 0(t5)', 'j halt']
    source = out / 'selftest.S'
    source.write_text('\n'.join(lines)+'\n')
    elf, binary = out/'selftest.elf', out/'selftest.bin'
    subprocess.run(['riscv64-unknown-elf-gcc', '-march=rv32i', '-mabi=ilp32', '-nostdlib',
                    '-nostartfiles', '-Wl,-Ttext=0x80000000,--no-relax,--build-id=none',
                    str(source), '-o', str(elf)], check=True, capture_output=True)
    subprocess.run(['riscv64-unknown-elf-objcopy', '-O', 'binary', '--only-section=.text',
                    str(elf), str(binary)], check=True)
    code = binary.read_bytes()
    words = [int.from_bytes(code[i:i+4], 'little') for i in range(0, len(code), 4)]
    if len(words)>16384: raise RuntimeError('selftest exceeds test ROM')
    (out/'selftest.mem').write_text(''.join(f'{w:08x}\n' for w in words+[0x13]*(16384-len(words))))
    return number
