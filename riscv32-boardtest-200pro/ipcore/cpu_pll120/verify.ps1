param(
    [string]$PdsRoot = 'D:\0_FPGA\PDS\PDS_2022.2-SP6.1',
    [string]$ModelSimRoot = 'D:\modelsim\modelsim_ase\win32aloem'
)
$ErrorActionPreference = 'Stop'
$pllBuild = Join-Path $PSScriptRoot 'sim'
New-Item -ItemType Directory -Path $pllBuild -Force | Out-Null
Push-Location $pllBuild
try {
    if (-not (Test-Path -LiteralPath 'work')) {
        & (Join-Path $ModelSimRoot 'vlib.exe') work
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    }
    $pllModel = Join-Path $PdsRoot 'arch\vendor\pango\verilog\simulation\GTP_GPLL.v'
    & (Join-Path $ModelSimRoot 'vlog.exe') -sv -work work $pllModel (Join-Path $PSScriptRoot 'cpu_pll120.v') (Join-Path $PSScriptRoot 'tb_cpu_pll120_check.sv')
    if ($LASTEXITCODE -ne 0) { throw 'PLL compile failed' }
    & (Join-Path $ModelSimRoot 'vsim.exe') -c -t 1fs -onfinish stop -l transcript.log work.tb_cpu_pll120_check -do 'onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0'
    if ($LASTEXITCODE -ne 0) { throw 'PLL verification failed' }
    if (-not (Select-String -LiteralPath 'transcript.log' -SimpleMatch 'PASS cpu_pll120:' -Quiet)) { throw 'PLL did not reach PASS' }
}
finally { Pop-Location }
