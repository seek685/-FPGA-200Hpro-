#!/usr/bin/env python3
"""CPU/APB/CTC regressions. Behavioral CNN tensors are not image recognition tests."""
import argparse
import importlib.util
import json
import shutil
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
RTL=ROOT/'rtl_pds'
CPU=RTL/'cpu'


def load(name, path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(name, sources, build, defines=()):
    target=build/name
    target.mkdir(parents=True,exist_ok=True)
    cmd=['verilator','--binary','--timing','--assert','-Wno-fatal','-j','2',
         '--top-module',name.replace('_original',''),'--Mdir',str(target),'-o','simulation',
         *defines, *map(str,sources)]
    (target/'command.json').write_text(json.dumps(cmd,indent=2))
    print(f'Building {name} ...',flush=True)
    with (target/'build.log').open('w') as log:
        result=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,cwd=build)
    if result.returncode:
        print((target/'build.log').read_text()[-12000:])
        raise SystemExit(f'Build failed: {target}')
    result=subprocess.run([str(target/'simulation')],cwd=build,capture_output=True,text=True,timeout=120)
    (target/'run.log').write_text(result.stdout+result.stderr)
    print(result.stdout+result.stderr,end='',flush=True)
    if result.returncode: raise SystemExit(f'Simulation failed: {target}')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir',type=Path)
    parser.add_argument('--original-dir',type=Path)
    parser.add_argument('--test',choices=['core','soc','post','mailbox','bus'])
    args=parser.parse_args()
    build=(args.build_dir or Path(tempfile.mkdtemp(prefix='lwc-cpu-tests-'))).resolve()
    build.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(RTL/'data_process/mem_data/chars_16x16.mem',build/'chars_16x16.mem')
    fw=load('cpu_fw',ROOT/'tools/cpu/build_firmware.py')
    memory,report=fw.build(build)
    if memory!=(CPU/'lpr_ctc.mem').read_text(): raise SystemExit('Firmware ROM differs from source build')
    print(f'PASS firmware: {report["code_bytes"]} code bytes, RV32I',flush=True)
    core=sorted((CPU/'core').glob('*.sv'))
    bus=[CPU/'lwc_cpu_apb.sv']
    if args.test in (None,'core'):
        checks=load('cpu_selftest',ROOT/'tools/cpu/build_selftest.py').build(build)
        print(f'CPU selftest: {checks} generated checks',flush=True)
        tb=ROOT/'tests/cpu/tb_cpu_core.sv'
        if args.original_dir:
            original=json.loads((CPU/'cpu_import.json').read_text())['source_sha256']
            run('tb_cpu_core_original',[tb,*[args.original_dir/f for f in original]],build,['-DORIGINAL_CPU'])
        run('tb_cpu_core',[tb,*core,*bus],build)
    tests={
        'soc':('tb_lpr_cpu_soc',[*core,*bus,CPU/'lpr_cpu_mailbox.sv',CPU/'lpr_cpu_soc.sv']),
        'post':('tb_lpr_cpu_post',[*core,*bus,CPU/'lpr_cpu_mailbox.sv',CPU/'lpr_cpu_soc.sv',
                                RTL/'data_process/lprnet_post_process.sv',RTL/'data_process/lprnet_spatial_sum.sv',
                                RTL/'data_process/extrema_finder.sv',RTL/'data_process/sdp_ram.sv',
                                RTL/'overlay/char_overlay.sv',RTL/'my_fifo.sv']),
        'mailbox':('tb_lpr_cpu_mailbox',[CPU/'lpr_cpu_mailbox.sv']),
        'bus':('tb_cpu_apb',[CPU/'lwc_cpu_apb.sv'])}
    for key,(name,sources) in tests.items():
        if args.test in (None,key):
            run(name,[ROOT/f'tests/cpu/{name}.sv',*sources],build)
    print(f'All selected CPU tests passed. Logs: {build}',flush=True)


if __name__=='__main__': main()
