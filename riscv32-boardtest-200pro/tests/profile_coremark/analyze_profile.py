import bisect
import csv
import json
import pathlib
import re
import sys

directory = pathlib.Path(sys.argv[1])
counters = json.loads((directory / 'counters.json').read_text())
symbols = {}
for line in (directory / 'symbols.txt').read_text().splitlines():
    match = re.fullmatch(r'([0-9a-fA-F]+)\s+[Tt]\s+(\S+)', line.strip())
    if match:
        address = int(match[1], 16)
        symbols.setdefault(address, []).append(match[2])
addresses = sorted(symbols)
function_counts = {}
hotspots = []
with (directory / 'pc_counts.csv').open(newline='') as stream:
    for item in csv.DictReader(stream):
        pc = int(item['pc'], 16)
        position = bisect.bisect_right(addresses, pc) - 1
        address = addresses[position]
        name = '/'.join(symbols[address])
        entry = function_counts.setdefault(name, dict(address=f'{address:08x}', retired=0,
            cycles_by_last_retired_pc=0, branch_mispredict=0, jalr_redirect=0, load_use_stall=0, entry_retired=0))
        record = {key: int(value) for key, value in item.items() if key != 'pc'}
        for key, value in record.items():
            entry[key] += value
        if pc == address:
            entry['entry_retired'] += record['retired']
        hotspots.append(dict(pc=item['pc'], function=name, **record))
counters['cpi'] = counters['cycles'] / counters['retired']
counters['ipc'] = counters['retired'] / counters['cycles']
counters['cycles_per_iteration'] = counters['cycles']
counters['estimated_coremark_per_mhz_single_iteration'] = 1_000_000 / counters['cycles']
counters['conditional_prediction_accuracy'] = 1 - counters['branch_mispredicts'] / counters['ex_conditional_branches']
counters['jalr_prediction_accuracy'] = 1 - counters['jalr_redirects'] / counters['ex_jalr']
counters['stall_cycle_fraction'] = counters['load_use_stalls'] / counters['cycles']
counters['wb_bubble_fraction'] = counters['wb_bubbles'] / counters['cycles']
functions = []
for name, entry in function_counts.items():
    functions.append(dict(function=name, **entry,
        retired_fraction=entry['retired']/counters['retired'],
        attributed_cycle_fraction=entry['cycles_by_last_retired_pc']/counters['cycles']))
functions.sort(key=lambda row: row['cycles_by_last_retired_pc'], reverse=True)
hotspots.sort(key=lambda row: row['cycles_by_last_retired_pc'], reverse=True)
notes = [
    'Window equals hardware timer: excludes start-store edge, includes stop-store edge.',
    'Retired counts WB-valid each clock, including stores and branches. At most a few boundary pipeline instructions straddle the software timed region.',
    'EX branch/JALR events and load-use stalls are sampled in the same window; these are overlapping event categories, not additive measured execution times.',
    'cycles_by_last_retired_pc assigns every WB bubble to the last retired PC. Useful leaf-function time attribution; not instruction latency or exclusive pipeline occupancy.',
    'One iteration retains the official below-10-second rejection, so normalized numbers are estimates, not formal scores.',
    'Same production v2 RTL, one-iteration firmware, accelerated UART outside the timed region.'
]
result = dict(counters=counters, functions=functions, hottest_pcs=hotspots[:40], notes=notes)
(directory / 'profile_summary.json').write_text(json.dumps(result, indent=2) + '\n')
lines = [f"cycles={counters['cycles']} retired={counters['retired']} CPI={counters['cpi']:.6f} IPC={counters['ipc']:.6f}",
    f"WB bubbles={counters['wb_bubbles']} ({100*counters['wb_bubble_fraction']:.3f}%), load-use stalls={counters['load_use_stalls']} ({100*counters['stall_cycle_fraction']:.3f}%)",
    f"conditional branches={counters['ex_conditional_branches']} mispredict={counters['branch_mispredicts']} accuracy={100*counters['conditional_prediction_accuracy']:.3f}%",
    f"JALR={counters['ex_jalr']} redirect={counters['jalr_redirects']} accuracy={100*counters['jalr_prediction_accuracy']:.3f}%",
    f"effective ID JAL corrections={counters['effective_id_jal_corrections']}, raw={counters['raw_id_jal_corrections']}, stall/flush overlap={counters['stall_flush_overlap']}",
    'Function: retired | cycles by last retired PC | conditional mispredicts | retired fraction | attributed cycle fraction']
for entry in functions[:20]:
    lines.append(f"{entry['function']}: {entry['retired']} | {entry['cycles_by_last_retired_pc']} | {entry['branch_mispredict']} | {100*entry['retired_fraction']:.3f}% | {100*entry['attributed_cycle_fraction']:.3f}%")
lines += notes
(directory / 'profile_summary.txt').write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))
