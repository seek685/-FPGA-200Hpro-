"""Require identical architectural traces, then compare cycle counts."""
import argparse
import hashlib
import json
from pathlib import Path


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline",type=Path,nargs="+",required=True)
    parser.add_argument("--optimized",type=Path,required=True)
    parser.add_argument("--output",type=Path,default=Path(__file__).parent/"comparison.json")
    args=parser.parse_args()
    baseline={}; traces={}
    for folder in args.baseline:
        for name,metrics in json.loads((folder/"summary.json").read_text()).items():
            baseline[name]=metrics; traces[name]=folder/(name+".trace")
    optimized=json.loads((args.optimized/"summary.json").read_text())
    if baseline.keys()!=optimized.keys():
        raise SystemExit(f"Case mismatch baseline-only={baseline.keys()-optimized.keys()} optimized-only={optimized.keys()-baseline.keys()}")
    comparison={}
    for name,before in baseline.items():
        after=optimized[name]
        left=hashlib.sha256(traces[name].read_bytes()).hexdigest()
        right=hashlib.sha256((args.optimized/(name+".trace")).read_bytes()).hexdigest()
        if left!=right: raise SystemExit("Architectural trace differs: "+name)
        entry={"before_cycles":before["cycles"],"after_cycles":after["cycles"],
               "cycles_reduced_percent":round(100*(1-after["cycles"]/before["cycles"]),2),
               "speedup":round(before["cycles"]/after["cycles"],4),"retired":after["retired"],
               "identical_architectural_trace":True,"trace_sha256":left,
               "before_stalls":before["stalls"],"after_stalls":after["stalls"]}
        if "benchmark_cycles" in before:
            entry["before_benchmark_cycles"]=before["benchmark_cycles"]
            entry["after_benchmark_cycles"]=after["benchmark_cycles"]
        if "text_bytes" in after: entry["text_bytes"]=after["text_bytes"]
        comparison[name]=entry
        print(f"{name}: {before['cycles']} -> {after['cycles']} cycles ({entry['cycles_reduced_percent']:+.2f}% fewer)")
    args.output.write_text(json.dumps(comparison,indent=2),encoding="utf-8")
    print(f"PASS: {len(comparison)} identical architectural traces; {sum(x['retired'] for x in comparison.values())} instructions")


if __name__=="__main__": main()
