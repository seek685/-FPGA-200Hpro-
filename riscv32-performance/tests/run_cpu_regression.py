"""Run pure RTL RV32I architectural differential tests using ModelSim.

Each retired instruction is checked against a scalar RV32I interpreter in the
testbench. The external store stream and final memory are checked separately.
No vendor IP, RISC-V toolchain, or board wrapper is needed.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import random
import re
import subprocess
import sys


def i(op: int, rd: int, f3: int, rs1: int, imm: int) -> int:
    return ((imm & 4095) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def r(rd: int, f3: int, rs1: int, rs2: int, f7: int = 0) -> int:
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33


def store(rs2: int, rs1: int, imm: int = 0, f3: int = 2) -> int:
    return (((imm & 4095) >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 31) << 7) | 0x23


def branch(f3: int, rs1: int, rs2: int, offset: int) -> int:
    n = offset & 8191
    return ((n >> 12) << 31) | (((n >> 5) & 63) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (((n >> 1) & 15) << 8) | (((n >> 11) & 1) << 7) | 0x63


def jal(rd: int, offset: int) -> int:
    n = offset & 0x1FFFFF
    return ((n >> 20) << 31) | (((n >> 1) & 1023) << 21) | (((n >> 11) & 1) << 20) | (((n >> 12) & 255) << 12) | (rd << 7) | 0x6F


def lui(rd: int, upper: int) -> int:
    return (upper << 12) | (rd << 7) | 0x37


def addi(rd: int, rs: int, imm: int) -> int:
    return i(0x13, rd, 0, rs, imm)


def finish(program: list[int]) -> list[int]:
    return program + [lui(31, 0x80200), addi(30, 0, 0x6D), store(30, 31, 0x40), jal(0, 0)]


def programs(seeds: int) -> dict[str, list[int]]:
    alu = [addi(1, 0, -17), addi(2, 0, 5)]
    for a in [0, 1, 2]:
        for b in [0, 1, 2]:
            for f3, f7 in [(0,0),(0,0x20),(1,0),(2,0),(3,0),(4,0),(5,0),(5,0x20),(6,0),(7,0)]:
                alu += [r(3, f3, a, b, f7), r(4, 0, 3, 2)]
    for f3 in [0,2,3,4,6,7]:
        for imm in [-2048,-1,0,1,2047]:
            alu += [i(0x13,3,f3,1,imm),r(4,0,3,1)]
    for sh in [0,1,15,31]:
        alu += [i(0x13,3,1,1,sh),i(0x13,4,5,3,sh),i(0x13,5,5,3,0x400|sh)]
    alu += [addi(0,0,123),r(6,0,0,4),0x12345397,0x0000000F]
    hazards = [lui(20,0x80100)]
    for n in range(64):
        hazards += [addi(1,0,n-31),r(1,0,1,1),r(2,0,1,1),r(3,0,2,1),
                    store(3,20,4*(n%16)),i(0x03,4,2,20,4*(n%16)),r(5,4,4,3),
                    i(0x03,6,2,20,0),store(6,20,4),i(0x03,7,2,20,4),
                    i(0x03,8,2,20,8),r(9,0,8,7),r(10,0,9,9)]
    memory=[lui(20,0x80100),addi(1,0,-128)]
    for n in range(4):
        memory += [store(1,20,n,0),i(0x03,2,0,20,n),i(0x03,3,4,20,n),r(4,0,2,3)]
    for n in [0,2,4,6]:
        memory += [addi(1,0,-1),store(1,20,n,1),i(0x03,2,1,20,n),i(0x03,3,5,20,n)]
    memory += [i(0x03,4,2,20,0),store(4,20,8),i(0x03,5,2,20,8),i(0x03,0,2,20,4)]
    control=[lui(20,0x80100),addi(1,0,1),branch(0,1,1,12),store(1,20,0),addi(7,0,99),addi(2,0,-1),addi(3,0,1)]
    for f3,a,b in [(0,1,1),(1,2,3),(4,2,3),(5,3,2),(6,3,2),(7,2,3)]:
        control += [branch(f3,a,b,12),store(1,20,8),addi(7,0,88),addi(4,4,1)]
    control += [jal(5,12),store(1,20,12),addi(7,0,77),0x00000317,addi(6,6,20),
                i(0x67,7,0,6,1),store(1,20,16),addi(7,0,66),addi(8,0,23),
                addi(9,0,80),addi(9,9,-1),branch(1,9,0,-4),
                i(0x03,11,2,20,0),branch(0,11,0,8),store(1,20,20)]
    # Tight loops measure trained conditional branches and call/return traffic.
    loop=[addi(1,0,200),addi(2,0,0),addi(2,2,3),addi(1,1,-1),branch(1,1,0,-8)]
    calls=[addi(10,0,100),jal(1,16),addi(10,10,-1),branch(1,10,0,-8),jal(0,16),
           addi(2,2,7),i(0x67,0,0,1,0),addi(9,0,99)]
    false_deps=[lui(20,0x80100)]
    for _ in range(100):
        false_deps += [i(0x03,1,2,20,0),addi(2,0,1),i(0x03,3,2,20,4),lui(4,0x183),
                       i(0x03,5,2,20,8),addi(0,5,0)]
    # rs2-only load -> store can bypass; an rs1 address dependency must still wait.
    load_store=[lui(20,0x80100),addi(21,20,128),store(21,20,0),addi(7,0,-85),store(7,20,4),
                i(0x03,1,2,20,4),store(1,20,16),i(0x03,1,2,20,4),store(1,20,21,0),
                i(0x03,1,2,20,4),store(1,20,22,1),i(0x03,1,2,20,0),store(7,1,0),
                i(0x03,1,2,20,0),store(1,1,4),i(0x03,1,2,20,4),addi(1,0,39),store(1,20,24),
                addi(1,0,64),i(0x03,1,2,20,4),store(1,20,28),i(0x03,1,2,20,0),store(1,20,12),
                i(0x03,2,2,20,12),i(0x03,3,2,2,0),i(0x03,0,2,20,0),store(0,20,32)]
    jalr_offsets=[lui(20,0x80100),addi(8,0,10),0x00000317,addi(6,6,17),
                  i(0x67,1,0,6,4),store(8,20,40),addi(8,0,99),addi(9,0,23),
                  0x00000397,addi(7,7,17),i(0x67,5,0,7,-4),addi(10,0,37),
                  jal(0,12),store(8,20,44),addi(8,0,88)]
    # x1 outer call, x5 nested call, both return registers, repeated to train RAS/BTB.
    nested=[addi(10,0,80),jal(1,16),addi(10,10,-1),branch(1,10,0,-8),jal(0,32),
            addi(2,2,3),jal(5,12),i(0x67,0,0,1,0),addi(9,0,99),
            addi(3,3,7),i(0x67,0,0,5,0),addi(9,0,88)]
    # JALR rd=x5/rs1=x1 and reverse are coroutine pop+push hints; control semantics
    # remain ordinary jumps and must survive prediction, including odd source PCs.
    coroutine=[0x00000097,addi(1,1,33),0x00000297,addi(5,5,16),i(0x67,5,0,1,0),
               i(0x67,0,0,1,0),store(0,0,0),addi(9,0,99),
               addi(2,2,3),i(0x67,1,0,5,0),addi(3,3,7),jal(0,4)]
    deep_calls=[lui(2,0x80140),addi(2,2,-16),jal(1,8),0]
    for _ in range(24):
        deep_calls += [addi(2,2,-4),store(1,2,0),jal(1,20),i(0x03,1,2,2,0),
                       addi(2,2,4),i(0x67,0,0,1,0),addi(9,0,99)]
    deep_calls += [addi(3,3,11),i(0x67,0,0,1,0),addi(9,0,88)]
    deep_calls[3]=jal(0,4*(len(deep_calls)-3))
    shared_leaf=[addi(10,0,100),jal(1,28),addi(3,3,1),jal(1,20),addi(4,4,1),
                 addi(10,10,-1),branch(1,10,0,-20),jal(0,16),addi(2,2,7),
                 i(0x67,0,0,1,0),store(0,0,0)]
    warm_reset=[lui(20,0x80100),0x00000317,addi(6,6,36),addi(10,0,80),i(0x67,1,0,6,0),
                addi(10,10,-1),branch(1,10,0,-8),jal(0,36),store(10,20,0),addi(9,0,99),
                addi(2,2,3),i(0x67,0,0,1,0),store(10,20,4),addi(2,2,7),i(0x67,0,0,1,0),store(10,20,8)]
    load_control=[lui(20,0x80100),0x00000317,addi(6,6,52),store(6,20,0),addi(10,0,40),
                  i(0x03,1,2,20,0),i(0x67,1,0,1,0),addi(10,10,-1),branch(1,10,0,-12),
                  i(0x03,2,2,20,4),branch(1,2,0,12),store(2,20,8),addi(9,0,99),jal(0,16),
                  addi(3,3,1),i(0x67,0,0,1,0),store(2,20,12)]
    result={"alu":finish(alu),"hazards":finish(hazards),"subword_memory":finish(memory),
            "control_recovery":finish(control),"branch_loop":finish(loop),"call_return":finish(calls),
            "false_dependencies":finish(false_deps),"branch_same_next_pc":finish([branch(0,0,0,4),addi(1,0,42)]),
            "load_store_bypass":finish(load_store),"jalr_offsets":finish(jalr_offsets),
            "nested_x1_x5":finish(nested),"coroutine_x1_x5":finish(coroutine),"ras_overflow":finish(deep_calls),
            "shared_leaf":finish(shared_leaf),"warm_reset_jalr":finish(warm_reset),"load_to_control":finish(load_control)}
    for seed in range(seeds):
        rng=random.Random(0x325+seed)
        p=[lui(20,0x80100)]+[addi(n,0,n*17-100) for n in range(1,20)]
        for _ in range(1200):
            rd,a,b=rng.randrange(0,20),rng.randrange(0,20),rng.randrange(0,20)
            kind=rng.randrange(8)
            if kind==0:
                size=rng.randrange(3); offset=(rng.randrange(128)>>(size))<<size
                p += [store(a,20,offset,size),i(0x03,rd,rng.choice([size,size+4]) if size<2 else 2,20,offset)]
            elif kind==1:
                p += [branch(rng.choice([0,1,4,5,6,7]),a,b,8),addi(rd,a,rng.randrange(-2048,2048))]
            elif kind==2:
                p += [i(0x13,rd,rng.choice([0,2,3,4,6,7]),a,rng.randrange(-2048,2048))]
            elif kind==3:
                sh=rng.randrange(32); f3=rng.choice([1,5]); imm=sh|(0x400 if f3==5 and rng.randrange(2) else 0)
                p += [i(0x13,rd,f3,a,imm)]
            elif kind==4:
                p += [jal(rd,8),store(a,20,128)]
            else:
                f3=rng.randrange(8); f7=0x20 if f3 in [0,5] and rng.randrange(2) else 0
                p += [r(rd,f3,a,b,f7)]
        result[f"random_{seed:02}"]=finish(p)
    return result


def execute(command: list[str], cwd: Path, logfile: Path) -> str:
    result=subprocess.run(command,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
    logfile.write_text(result.stdout,encoding="utf-8")
    if result.returncode or re.search(r"\*\* (?:Error|Fatal):",result.stdout):
        raise RuntimeError(f"Command failed ({result.returncode}); {logfile}\n{result.stdout[-10000:]}")
    return result.stdout


def compile_c_kernel(here: Path, output: Path, gcc: Path) -> tuple[list[int], int]:
    elf=output/"c_kernel.elf"
    execute([str(gcc),"-march=rv32i","-mabi=ilp32","-O2","-ffreestanding","-fno-builtin",
             "-fno-pic","-msmall-data-limit=0","-nostdlib","-nostartfiles","-Wl,--no-relax",
             "-T",str(here/"c_kernel.ld"),str(here/"c_kernel_start.S"),str(here/"c_kernel.c"),
             "-o",str(elf)],output,output/"c_kernel_compile.log")
    binary=output/"c_kernel.bin"
    objcopy=gcc.with_name(gcc.name.replace("gcc","objcopy"))
    execute([str(objcopy),"-O","binary","--only-section=.text","--only-section=.rodata",str(elf),str(binary)],output,output/"c_kernel_objcopy.log")
    raw=binary.read_bytes(); raw+=bytes((-len(raw))%4)
    words=[int.from_bytes(raw[n:n+4],"little") for n in range(0,len(raw),4)]
    # Host algorithm oracle is independent of the ISA interpreter.
    mask=0xffffffff; state=0x13579bdf; data=[]
    for n in range(64):
        state=(state+n)&mask; state^=(state<<13)&mask; state^=state>>17; state^=(state<<5)&mask
        data.append(state)
    total=0; node=0
    for _ in range(256):
        node=(node+17)&63; x=data[node]
        if x&3==0: total=(total+x)&mask
        elif x&3==1: total^=x
        elif x&3==2: total=(total-x)&mask
        else: total=((total<<1)|(total>>31))&mask
    data.sort(); crc=mask
    for x in data:
        crc^=x
        for _ in range(32): crc=(crc>>1)^(0xedb88320 if crc&1 else 0)
    return words,crc^total^data[0]^data[-1]


def compile_coremark(here: Path, output: Path, gcc: Path) -> tuple[list[int], list[int]]:
    source=here/"coremark"; port=here/"coremark_port"; elf=output/"coremark.elf"
    names=["core_main.c","core_list_join.c","core_matrix.c","core_state.c","core_util.c"]
    execute([str(gcc),"-march=rv32i","-mabi=ilp32","-O2","-ffreestanding","-fno-builtin",
             "-fno-pic","-msmall-data-limit=0","-nostdlib","-nostartfiles","-Wl,--no-relax",
             "-I",str(port),"-I",str(source),"-T",str(port/"link.ld"),
             str(port/"start.S"),str(port/"core_portme.c")]+[str(source/name) for name in names]+
             ["-lgcc","-o",str(elf)],output,output/"coremark_compile.log")
    objcopy=gcc.with_name(gcc.name.replace("gcc","objcopy"))
    result=[]
    for name,sections in [("text",[".text"]),("data",[".rodata",".data"])]:
        binary=output/f"coremark_{name}.bin"
        execute([str(objcopy),"-O","binary"]+["--only-section="+x for x in sections]+[str(elf),str(binary)],output,output/f"coremark_{name}_objcopy.log")
        raw=binary.read_bytes(); raw+=bytes((-len(raw))%4)
        result.append([int.from_bytes(raw[n:n+4],"little") for n in range(0,len(raw),4)])
    return result[0],result[1]


def main() -> int:
    here=Path(__file__).resolve().parent
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core",type=Path,default=here.parent)
    parser.add_argument("--output",type=Path,default=here/"regression_results")
    parser.add_argument("--modelsim",type=Path,default=Path("D:/modelsim/modelsim_ase/win32aloem"))
    parser.add_argument("--seeds",type=int,default=12)
    parser.add_argument("--only",help="comma separated case names")
    parser.add_argument("--c-kernel",action="store_true",help="also compile and execute the real C kernel")
    parser.add_argument("--coremark",action="store_true",help="also execute official CoreMark one-iteration CRC smoke; not a score")
    parser.add_argument("--gcc",type=Path,default=Path("D:/RISCV-none-elf-gcc/xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-gcc.exe"))
    args=parser.parse_args()
    output=args.output.resolve(); output.mkdir(parents=True,exist_ok=True)
    core=args.core.resolve()
    cases=programs(args.seeds)
    expected_seg=None
    if args.c_kernel:
        cases["c_kernel"],expected_seg=compile_c_kernel(here,output,args.gcc)
    coremark_data=[]
    if args.coremark:
        cases["coremark"],coremark_data=compile_coremark(here,output,args.gcc)
    if args.only: cases={name:cases[name] for name in args.only.split(",")}
    execute([str(args.modelsim/"vlib.exe"),"work"],output,output/"vlib.log")
    sources=[core/name for name in ["alu.sv","branch_predictor.sv","branch_unit.sv","control.sv","ex_mem.sv", "forwarding.sv","hazard_detection.sv","id_ex.sv","if_id.sv","immgen.sv","mem_wb.sv","myCPU.sv","pc.sv","regfile.sv"]]
    execute([str(args.modelsim/"vlog.exe"),"-sv","-work","work"]+[str(x) for x in sources]+[str(here/"tb_cpu_regression.sv")],output,output/"compile.log")
    summary={}
    initial_memory=[0x89ABCDEF,0x12345678,0x80000001,0x7FFFFFFF]
    dmem=output/"data.hex"
    dmem.write_text("".join(f"{w:08x}\n" for w in initial_memory+[0]*(65536-len(initial_memory))),encoding="ascii")
    for name,p in cases.items():
        if len(p)>4096: raise ValueError(f"{name}: text size {4*len(p)} exceeds board 16 KiB IROM")
        image=output/f"{name}.hex"
        image.write_text("".join(f"{w&0xffffffff:08x}\n" for w in p+[0x13]*(16384-len(p))),encoding="ascii")
        command=[str(args.modelsim/"vsim.exe"),"-c","work.tb_cpu_regression", "+IMEM="+image.as_posix(),
                 "+DMEM="+dmem.as_posix(),"+TRACE="+(output/f"{name}.trace").as_posix(),
                 "-do","onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0"]
        if name=="c_kernel": command.insert(3,f"+EXPECTED_SEG={expected_seg:08x}")
        if name=="coremark":
            memory=output/"coremark_data.hex"
            memory.write_text("".join(f"{w:08x}\n" for w in coremark_data+[0]*(65536-len(coremark_data))),encoding="ascii")
            command=["+DMEM="+memory.as_posix() if x.startswith("+DMEM=") else x for x in command]
            command.insert(3,"+EXPECTED_SEG=c04e0005")
            command.insert(3,"+MAX_CYCLES=3000000")
        if name=="warm_reset_jalr":
            warm=p.copy(); warm[2]=addi(6,6,48)
            # The old BTB target is now a store. A stale prediction must squash it.
            warm[10]=store(10,20,12)
            warm_image=output/"warm_reset_second.hex"
            warm_image.write_text("".join(f"{w&0xffffffff:08x}\n" for w in warm+[0x13]*(16384-len(warm))),encoding="ascii")
            command.insert(3,"+WARM_RESET=1")
            command.insert(3,"+WARM_IMEM="+warm_image.as_posix())
        log=execute(command,output,output/f"{name}.log")
        found=re.search(r"RESULT PASS ([^\r\n]+)",log)
        if not found: raise RuntimeError(f"No PASS result for {name}")
        metrics={key:int(value) for key,value in re.findall(r"(\w+)=(\d+)",found.group(1))}
        metrics["text_bytes"]=4*len(p)
        region=re.search(r"BENCHMARK_CYCLES (\d+)",log)
        if region: metrics["benchmark_cycles"]=int(region.group(1))
        summary[name]=metrics
        print(name+": "+found.group(1),flush=True)
        (output/"summary.json").write_text(json.dumps(summary,indent=2),encoding="utf-8")
    print(f"PASS: {len(summary)} cases; summary {output/'summary.json'}")
    return 0


if __name__=="__main__":
    sys.exit(main())
