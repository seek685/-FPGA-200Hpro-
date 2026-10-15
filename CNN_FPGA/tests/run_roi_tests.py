#!/usr/bin/env python3
"""Run the portable ROI classifier tests; this does not invoke PDS."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl_pds/roi_cnn"
TESTS = {
    "tb_roi_capture_28": ["roi_capture_28.sv"],
    "tb_roi_label_overlay": ["roi_label_overlay.sv"],
    "tb_roi_cnn_core": ["roi_cnn_core.sv"],
    "tb_roi_cnn_video": ["roi_capture_28.sv", "roi_cnn_core.sv", "roi_label_overlay.sv"],
}


def check_pds_files(pds_text, pds_dir):
    # Check the file-entry form used by the original PDS-generated project.
    # This is a targeted metadata check, not a replacement for the PDS parser.
    entries = re.findall(
        r'\(_file\s+"([^"]+)"(?:\s*\+\s*"[^"]*")?\s*((?:\([^()]*\)\s*)*)\)',
        pds_text)
    if not entries or len(entries) != len(re.findall(r'\(_file\s', pds_text)):
        raise RuntimeError("Unrecognized PDS file-entry structure")
    for path, metadata in entries:
        if not re.fullmatch(
                r'\(_format\s+\w+\)\s*'
                r'\(_timespec\s+"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"\)\s*', metadata):
            raise RuntimeError(f"PDS file entry needs _format followed by _timespec: {path}")
    for path in re.findall(r'\(_(?:file|ip_source_item)\s+"([^"]+)"', pds_text):
        if not (pds_dir / path).is_file():
            raise RuntimeError(f"Missing PDS input: {path}")


def check_model_files():
    hashes = json.loads((ROOT / "models/roi_fruit/artifact_sha256.json").read_text())
    for relative, expected in hashes.items():
        path = ROOT / relative
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"Model/fixture checksum mismatch: {relative}")
    report = json.loads((ROOT / "models/roi_fruit/model_report.json").read_text())
    header = (RTL / "roi_cnn_model.vh").read_text()
    for i, expected in enumerate(report["shifts"], 1):
        found = re.search(rf"`define ROI_CNN_SHIFT{i}\s+(\d+)", header)
        if not found or int(found.group(1)) != expected:
            raise RuntimeError("Model/RTL shift mismatch")
    lengths = {"conv1_w": (216, 2), "conv1_b": (8, 8), "conv2_w": (1152, 2),
               "conv2_b": (16, 8), "fc1_w": (12800, 2), "fc1_b": (32, 8),
               "fc2_w": (128, 2), "fc2_b": (4, 8)}
    for name, (count, digits) in lengths.items():
        path = ROOT / "rtl_pds/data_process/mem_data/roi_cnn" / (name + ".mem")
        words = path.read_text().split()
        if len(words) != count or not all(re.fullmatch(rf"[0-9a-f]{{{digits}}}", w) for w in words):
            raise RuntimeError(f"Invalid ROM {path}")
    pds = ROOT / "prj_pds/hdmi_loop.pds"
    check_pds_files(pds.read_text(), pds.parent)
    print("PASS model/fixture SHA256, model shifts, ROM lengths, PDS file metadata/input paths", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test", action="append", choices=sorted(TESTS))
    parser.add_argument("--build-dir", type=Path)
    parser.add_argument("--check-only", action="store_true",
                        help="Check artifacts and PDS file entries without running RTL simulations")
    args = parser.parse_args()
    check_model_files()
    if args.check_only:
        return
    executable = shutil.which("verilator")
    if not executable:
        raise SystemExit("Verilator is required; these tests do not use PDS.")
    build = args.build_dir or Path(tempfile.mkdtemp(prefix="fpga-roi-tests-"))
    build = build.resolve()
    for test in args.test or TESTS:
        target = build / test
        target.mkdir(parents=True, exist_ok=True)
        command = [executable, "--binary", "--timing", "--assert", "-Wall", "-j", "2",
                   # Testbench clocks/reference counters deliberately use
                   # blocking assignments and observe the asynchronous reset.
                   "-Wno-BLKSEQ", "-Wno-UNUSEDSIGNAL", "-Wno-SYNCASYNCNET",
                   "--top-module", test, "--Mdir", str(target), "-o", "simulation",
                   str(ROOT / "tests" / (test + ".sv"))] + [str(RTL / src) for src in TESTS[test]]
        with (target / "build.log").open("w") as log:
            subprocess.run(command, cwd=RTL, stdout=log, stderr=subprocess.STDOUT, check=True)
        result = subprocess.run([str(target / "simulation")], cwd=RTL, capture_output=True, text=True, timeout=180)
        (target / "run.log").write_text(result.stdout + result.stderr)
        print(result.stdout, end="", flush=True)
        result.check_returncode()
    print("Build logs:", build)


if __name__ == "__main__":
    main()
