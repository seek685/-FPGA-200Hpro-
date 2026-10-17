param([string]$ModelSim = 'D:\modelsim\modelsim_ase\win32aloem')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskSources = @('alu.sv', 'branch_predictor.sv', 'branch_unit.sv', 'control.sv', 'ex_mem.sv', 'forwarding.sv', 'hazard_detection.sv', 'id_ex.sv', 'if_id.sv', 'immgen.sv', 'mem_wb.sv', 'myCPU.sv', 'pc.sv', 'regfile.sv', 'perip_bridge.sv', 'dram_driver.sv', 'counter.sv', 'display_seg.sv', 'seg7.sv')
$taskVariants = @(
    @{ Name = 'baseline'; Root = (Join-Path $PSScriptRoot 'baseline_rtl') },
    @{ Name = 'final'; Root = $taskRoot }
)
$taskSummary = @()
foreach ($taskVariant in $taskVariants) {
    $taskBuild = Join-Path $PSScriptRoot ('memory_path_' + $taskVariant.Name)
    New-Item -ItemType Directory -Force -Path $taskBuild | Out-Null
    Push-Location $taskBuild
    try {
        if (-not (Test-Path -LiteralPath 'work')) {
            & (Join-Path $ModelSim 'vlib.exe') work 2>&1 | Tee-Object -FilePath vlib.log
            if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
        }
        $taskFiles = @($taskSources | ForEach-Object { Join-Path $taskVariant.Root $_ })
        $taskFiles += Join-Path $PSScriptRoot 'tb_memory_path.sv'
        & (Join-Path $ModelSim 'vlog.exe') -sv -work work @taskFiles 2>&1 | Tee-Object -FilePath compile.log
        if ($LASTEXITCODE -ne 0) { throw ($taskVariant.Name + ' compile failed') }
        & (Join-Path $ModelSim 'vsim.exe') -c -onfinish stop -l transcript.log work.tb_memory_path -do 'onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0' 2>&1 | Tee-Object -FilePath console.log
        if ($LASTEXITCODE -ne 0) { throw ($taskVariant.Name + ' memory path failed') }
        $taskPass = Select-String -LiteralPath transcript.log -SimpleMatch 'PASS tb_memory_path'
        if (-not $taskPass) { throw ($taskVariant.Name + ' did not reach PASS') }
        $taskSummary += $taskVariant.Name + ': ' + $taskPass.Line.TrimStart('#', ' ')
    }
    finally { Pop-Location }
}
$taskSummary | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'memory_path_summary.txt') -Encoding ascii
$taskSummary
