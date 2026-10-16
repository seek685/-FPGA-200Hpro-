#!/usr/bin/env python3
"""Check actual top/DDR reset wiring with explicit nonfunctional IP/inference stubs."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl_pds"
STUBS = {
    "top_yolo": "rtl_pds/top_yolo.sv",
    "lprnet_top": "rtl_pds/top_lprnet.sv",
    "layer_data_adapter": "rtl_pds/layer_data_adapter.sv",
    "my_fifo": "rtl_pds/my_fifo.sv",
    "box_overlay_sync": "rtl_pds/overlay/box_overlay_sync.sv",
    "crop_buffer_manager": "rtl_pds/overlay/crop_buffer_manager.sv",
    "char_overlay": "rtl_pds/overlay/char_overlay.sv",
    "ms72xx_ctl": "rtl_pds/drive_hdmi/ms72xx_ctl.v",
    "PLL": "prj_pds/ipcore/PLL/PLL.v",
    "ms72": "prj_pds/ipcore/ms72/ms72.v",
    "ddr3_test": "prj_pds/ipcore/ddr3_test/ddr3_test.v",
}
STUB_DRIVES = {
    "PLL": "assign clkout2 = tb_hdmi_reset.pe_clk;",
    "ms72": "assign clkout0 = tb_hdmi_reset.cfg_clk; assign lock = tb_hdmi_reset.cfg_locked;",
    "ms72xx_ctl": "assign init_over = tb_hdmi_reset.cfg_init;",
    "ddr3_test": "assign core_clk = tb_hdmi_reset.ddr_clk;",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path)
    args = parser.parse_args()
    if not shutil.which("verilator"):
        parser.error("Verilator is required")
    build = (args.build_dir or Path(tempfile.mkdtemp(prefix="fpga-reset-test-"))).resolve()
    build.mkdir(parents=True, exist_ok=True)
    bodies = ["// Interfaces only: these stubs do not implement IP or inference.\n"]
    for name, source in STUBS.items():
        text = (ROOT / source).read_text()
        match = re.search(r"(?ms)^module\s+" + re.escape(name) + r"\b.*?^\s*\);", text)
        if not match:
            raise SystemExit(f"Cannot extract {name} interface from {source}")
        bodies.append(match.group(0) + "\n" + STUB_DRIVES.get(name, "") + "\nendmodule\n")
    bodies.append('module GTP_INBUFGDS #(parameter IOSTANDARD="DEFAULT", '
                  'parameter TERM_DIFF="ON") (output wire O, input wire I, input wire IB); endmodule\n')
    stub_file = build / "reset_test_stubs.sv"
    stub_file.write_text("\n".join(bodies))
    sources = [RTL / "hdmi_loop.sv", RTL / "reset_release_sync.sv",
               *sorted((RTL / "ddr").glob("*.sv")), *sorted((RTL / "ddr").glob("*.v"))]
    (build / "scope.json").write_text(json.dumps({
        "real_rtl": [str(p.relative_to(ROOT)) for p in sources],
        "interface_stubs": STUBS,
        "primitive_stub": "GTP_INBUFGDS",
        "test_clock_and_status_drives": STUB_DRIVES,
        "limits": "Reset/control integration only; no DDR protocol, PLL behavior or inference validation.",
    }, indent=2))
    command = ["verilator", "--binary", "--timing", "--assert", "-Wno-fatal", "-j", "2",
               "--top-module", "tb_hdmi_reset", "--Mdir", str(build / "obj"), "-o", "simulation",
               f"-I{RTL}", str(ROOT / "tests/tb_hdmi_reset.sv"),
               *[str(p) for p in sources], str(stub_file)]
    (build / "command.json").write_text(json.dumps(command, indent=2))
    log = build / "build.log"
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        print(log.read_text()[-16000:])
        raise SystemExit(f"Build failed: {log}")
    result = subprocess.run([str(build / "obj/simulation")], cwd=ROOT,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (build / "run.log").write_text(result.stdout)
    print(result.stdout, end="")
    if result.returncode:
        raise SystemExit(f"Simulation failed: {build}")
    print(f"Reset integration passed. Scope and logs: {build}")


if __name__ == "__main__":
    main()
