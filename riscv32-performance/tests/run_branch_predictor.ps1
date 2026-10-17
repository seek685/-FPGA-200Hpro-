$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskModelSim = 'D:\modelsim\modelsim_ase\win32aloem'
$taskBuild = Join-Path $PSScriptRoot 'predictor_sim'
New-Item -ItemType Directory -Force -Path $taskBuild | Out-Null
Push-Location $taskBuild
try {
    if (-not (Test-Path -LiteralPath 'work')) {
        & (Join-Path $taskModelSim 'vlib.exe') work
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    }
    & (Join-Path $taskModelSim 'vlog.exe') -sv -work work (Join-Path $taskRoot 'branch_predictor.sv') (Join-Path $PSScriptRoot 'tb_branch_predictor.sv')
    if ($LASTEXITCODE -ne 0) { throw 'vlog failed' }
    & (Join-Path $taskModelSim 'vsim.exe') -c -onfinish stop -l transcript.log work.tb_branch_predictor -do 'onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0'
    if ($LASTEXITCODE -ne 0) { throw 'branch predictor unit failed' }
    if (-not (Select-String -LiteralPath 'transcript.log' -SimpleMatch 'PASS tb_branch_predictor' -Quiet)) {
        throw 'unit did not reach PASS'
    }
}
finally {
    Pop-Location
}
