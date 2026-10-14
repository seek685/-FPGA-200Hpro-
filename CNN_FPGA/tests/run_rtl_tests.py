#!/usr/bin/env python3
"""Run portable RTL regressions; no Pango IP, model training, or board required."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl_pds"
TESTS = {
    "tb_lprnet_post_process": ["data_process/lprnet_post_process.sv", "data_process/lprnet_spatial_sum.sv",
                               "data_process/extrema_finder.sv", "data_process/sdp_ram.sv"],
    "tb_char_overlay": ["overlay/char_overlay.sv", "my_fifo.sv"],
    "tb_box_crop": ["overlay/box_overlay_sync.sv", "my_fifo.sv"],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path)
    parser.add_argument("--test", choices=TESTS)
    args = parser.parse_args()
    if not shutil.which("verilator"):
        parser.error("Verilator with --binary/--timing support is required")
    build = (args.build_dir or Path(tempfile.mkdtemp(prefix="fpga-rtl-tests-"))).resolve()
    build.mkdir(parents=True, exist_ok=True)
    names = [args.test] if args.test else TESTS
    for name in names:
        log = build / f"{name}.build.log"
        command = ["verilator", "--binary", "--timing", "--assert", "-Wno-fatal", "-j", "2",
                   "--top-module", name, "--Mdir", str(build / name), "-o", "simulation",
                   str(ROOT / "tests" / f"{name}.sv"), *[str(RTL / p) for p in TESTS[name]]]
        print(f"Building {name} ...", flush=True)
        with log.open("w") as stream:
            result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            print(log.read_text()[-16000:])
            raise SystemExit(f"Build failed: {log}")
        result = subprocess.run([str(build / name / "simulation")], cwd=ROOT,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (build / f"{name}.run.log").write_text(result.stdout)
        print(result.stdout, end="", flush=True)
        if result.returncode:
            raise SystemExit(f"Simulation failed: {name}; logs: {build}")
    print(f"All selected regressions passed. Logs: {build}")


if __name__ == "__main__":
    main()
