param([string[]]$Labels = @('baseline_pnr','final_rev3','final_rev4'))
$ErrorActionPreference = 'Stop'
function Read-Performance([string]$Report) {
    $data = [IO.File]::ReadAllText($Report)
    $perf = [regex]::Match($data, '(?m)^\s*cpu_clk\s+([\d.]+) MHz\s+([\d.]+) MHz\s+([\d.]+)\s+([\d.]+)\s+(-?[\d.]+)')
    if (!$perf.Success) { throw "No performance summary in $Report" }
    $path = [regex]::Match($data, '(?s)Startpoint\s*:\s*([^\r\n]+)\r?\nEndpoint\s*:\s*([^\r\n]+).*?Data arrival time\s+([\d.]+).*?Logic Levels:\s*(\d+).*?Logic:\s*([\d.]+)ns.*?Route:\s*([\d.]+)ns')
    if (!$path.Success) { throw "No internal path in $Report" }
    $holdSlow = [regex]::Match($data, '(?s)Hold Summary\(Slow Corner\):(.*?)(?:={10})')
    $holdSlowValue = [regex]::Match($holdSlow.Groups[1].Value, 'cpu_clk\s+cpu_clk\s+(-?[\d.]+)')
    $holdFast = [regex]::Match($data, '(?s)Hold Summary\(Fast Corner\):(.*?)(?:={10})')
    $holdFastValue = [regex]::Match($holdFast.Groups[1].Value, 'cpu_clk\s+cpu_clk\s+(-?[\d.]+)')
    return [ordered]@{
        requested_period_ns = [double]$perf.Groups[3].Value
        estimated_period_ns = [double]$perf.Groups[4].Value
        setup_wns_ns = [double]$perf.Groups[5].Value
        slow_hold_whs_ns = $(if ($holdSlowValue.Success) {[double]$holdSlowValue.Groups[1].Value} else {$null})
        fast_hold_whs_ns = $(if ($holdFastValue.Success) {[double]$holdFastValue.Groups[1].Value} else {$null})
        first_path_start = $path.Groups[1].Value.Trim()
        first_path_end = $path.Groups[2].Value.Trim()
        first_path_logic_levels = [int]$path.Groups[4].Value
        first_path_logic_delay_ns = [double]$path.Groups[5].Value
        first_path_route_delay_ns = [double]$path.Groups[6].Value
    }
}
$results = foreach ($label in $Labels) {
    $root = Join-Path $PSScriptRoot ($label + '_pds')
    $synthesis = Join-Path $root 'synthesize\myCPU.snr'
    $synData = [IO.File]::ReadAllText($synthesis)
    $route = Join-Path $root 'report_timing\myCPU.rtr'
    $placement = [IO.File]::ReadAllText((Join-Path $root 'place_route\myCPU.prr'))
    $physical = [regex]::Match($placement, '(?m)^\| myCPU\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)')
    [ordered]@{
        label = $label
        device = 'PG2L200H-6 FBB676'
        tool = 'PDS 2022.2-SP6.1 ADS'
        synthesis_lut = [int]([regex]::Match($synData, 'Total LUTs:\s*(\d+)').Groups[1].Value)
        synthesis_ff = [int]([regex]::Match($synData, 'Total Registers:\s*(\d+)').Groups[1].Value)
        routed_lut = [int]$physical.Groups[1].Value
        routed_ff = [int]$physical.Groups[2].Value
        routed_lutram = [int]$physical.Groups[3].Value
        synthesis = Read-Performance $synthesis
        routed = Read-Performance $route
        source_manifest = (Join-Path $root 'source_manifest.json')
        routed_report = $route
    }
}
[ordered]@{
    limitations = @(
        'Independent CPU with normal I/O insertion and automatically placed pads; no memory or NPU logic.',
        'Only the 6.667 ns CPU clock is constrained; data input/output delays are not specified.',
        'The reported paths are internal sequential paths. Results are not 200Pro board timing signoff or measured Fmax.',
        'Each version uses one default place-and-route run; no multiple-seed search was performed.',
        'routed_lut is the total LUT count from the PDS module resource table and already includes routed_lutram. routed_ff is the same table FF count.',
        'Original RTL is frozen by SHA256. ADS-only copies lower for(int ...) variables into equivalent module integers.'
    )
    results = @($results)
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'pds_comparison.json') -Encoding utf8
