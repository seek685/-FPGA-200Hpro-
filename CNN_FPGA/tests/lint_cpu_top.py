#!/usr/bin/env python3
"""Top wiring lint with real CPU/postprocessing/overlay/DDR control, explicit CNN/IP stubs."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
RTL=ROOT/'rtl_pds'
STUBS={
    'layer':'rtl_pds/data_process/layer.sv',
    'lprnet_layer_direct':'rtl_pds/data_process/layer.sv',
    'ms72xx_ctl':'rtl_pds/drive_hdmi/ms72xx_ctl.v',
    'PLL':'prj_pds/ipcore/PLL/PLL.v',
    'ms72':'prj_pds/ipcore/ms72/ms72.v',
    'ddr3_test':'prj_pds/ipcore/ddr3_test/ddr3_test.v',
}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir',type=Path)
    args=parser.parse_args()
    build=(args.build_dir or Path(tempfile.mkdtemp(prefix='lwc-cpu-top-lint-'))).resolve()
    build.mkdir(parents=True,exist_ok=True)
    stubs=[]
    for name,path in STUBS.items():
        source=(ROOT/path).read_text()
        match=re.search(r'(?ms)^module\s+'+name+r'\b.*?^\s*\);',source)
        if not match: raise RuntimeError(f'Cannot extract {name}')
        stubs.append(match.group(0)+'\nendmodule\n')
    stubs.append('module GTP_INBUFGDS #(parameter IOSTANDARD="DEFAULT", parameter TERM_DIFF="ON") '
                 '(output wire O, input wire I, input wire IB); endmodule\n')
    stub_file=build/'interfaces_only.sv'
    stub_file.write_text('\n'.join(stubs))
    names=['hdmi_loop.sv','reset_release_sync.sv','my_fifo.sv','layer_data_adapter.sv',
           'top_yolo.sv','top_lprnet.sv','overlay/box_overlay_sync.sv',
           'overlay/crop_buffer_manager.sv','overlay/char_overlay.sv',
           'data_process/post_cv3_conv2d.sv','data_process/activation_lut.sv','data_process/extrema_finder.sv',
           'data_process/lprnet_post_process.sv','data_process/lprnet_spatial_sum.sv','data_process/sdp_ram.sv']
    sources=[*[RTL/n for n in names],*sorted((RTL/'cpu').rglob('*.sv')),
             *sorted((RTL/'ddr').glob('*.sv')),*sorted((RTL/'ddr').glob('*.v')),
             *sorted((RTL/'roi_cnn').glob('*.sv'))]
    scope={'real_rtl':[str(p.relative_to(ROOT)) for p in sources],
           'interface_stubs':STUBS,'primitive_stub':'GTP_INBUFGDS',
           'limits':'Wiring lint only, no CNN convolution/DDR PHY behavior, synthesis, timing or board verification.'}
    (build/'scope.json').write_text(json.dumps(scope,indent=2)+'\n')
    for cpu,roi in ((1,0),(0,0),(0,1)):
        name=f'cpu{cpu}_roi{roi}'
        command=['verilator','--lint-only','--timing','-Wno-fatal','--top-module','hdmi_loop',
                 f'-I{RTL}',f'-GCPU_CTC_ENABLE={cpu}',f'-GROI_CNN_ENABLE={roi}',
                 *map(str,sources),str(stub_file)]
        result=subprocess.run(command,cwd=build,capture_output=True,text=True)
        log=result.stdout+result.stderr
        (build/f'{name}.log').write_text(log)
        (build/f'{name}.command.json').write_text(json.dumps(command,indent=2))
        if result.returncode:
            print(log[-16000:]);raise SystemExit(f'Top lint failed: {name}')
        print(f'PASS top wiring lint: CPU_CTC_ENABLE={cpu}, ROI_CNN_ENABLE={roi}; CNN/IP interfaces are stubbed')
    print(f'Scope/logs: {build}')


if __name__=='__main__':main()
