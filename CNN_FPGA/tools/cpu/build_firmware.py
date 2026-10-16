#!/usr/bin/env python3
"""Build RV32I CTC firmware reproducibly; only explicit --write updates the ROM."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "firmware/lpr_ctc"
ROM = ROOT / "rtl_pds/cpu/lpr_ctc.mem"


def build(out, prefix="riscv64-unknown-elf-"):
    out.mkdir(parents=True, exist_ok=True)
    gcc, objcopy, objdump = [shutil.which(prefix + x) for x in ("gcc", "objcopy", "objdump")]
    if not all((gcc, objcopy, objdump)):
        raise SystemExit(f"Missing {prefix}gcc/objcopy/objdump")
    elf = out / "lpr_ctc.elf"
    command = [gcc, "-march=rv32i", "-mabi=ilp32", "-Os", "-ffreestanding",
               "-fno-builtin", "-fno-pic", "-msmall-data-limit=0", "-mno-relax",
               "-nostdlib", "-nostartfiles", "-Wl,--no-relax,--build-id=none",
               "-T", str(SOURCE / "link.ld"), str(SOURCE / "start.S"),
               str(SOURCE / "main.c"), "-o", str(elf)]
    subprocess.run(command, check=True, capture_output=True)
    binary = out / "lpr_ctc.bin"
    subprocess.run([objcopy, "-O", "binary", "--only-section=.text", str(elf), str(binary)], check=True)
    code = binary.read_bytes()
    if len(code) > 4096 or len(code) % 4:
        raise RuntimeError("RV32I code must fit 1024 aligned instruction words")
    words = [int.from_bytes(code[i:i + 4], "little") for i in range(0, len(code), 4)]
    words += [0x00000013] * (1024 - len(words))
    memory = "".join(f"{w:08x}\n" for w in words)
    (out / "lpr_ctc.mem").write_text(memory)
    (out / "lpr_ctc.dis").write_text(subprocess.check_output([objdump, "-d", str(elf)], text=True))
    report = {"compiler": subprocess.check_output([gcc, "--version"], text=True).splitlines()[0],
              "isa": "rv32i", "code_bytes": len(code), "rom_bytes": 4096,
              "rom_sha256": hashlib.sha256(memory.encode()).hexdigest(),
              "source_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in sorted(SOURCE.iterdir()) if p.suffix in (".c", ".S", ".ld")}}
    (out / "firmware.json").write_text(json.dumps(report, indent=2) + "\n")
    return memory, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path)
    parser.add_argument("--prefix", default="riscv64-unknown-elf-")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    out = args.build_dir or Path(tempfile.mkdtemp(prefix="lpr-cpu-fw-"))
    memory, report = build(out, args.prefix)
    if args.write:
        ROM.write_text(memory)
        (SOURCE / "firmware.json").write_text(json.dumps(report, indent=2) + "\n")
    elif ROM.read_text() != memory:
        raise SystemExit("ROM differs from freshly built firmware (compiler version may differ)")
    print(json.dumps(report, indent=2))
    print(f"Firmware verified. Build: {out}")


if __name__ == "__main__":
    main()
