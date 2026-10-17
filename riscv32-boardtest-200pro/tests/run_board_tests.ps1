param(
    [ValidateSet('All','Mmio','Uart','Reset','Smoke','CoreMarkSmoke')][string]$Test = 'All',
    [string]$ModelSim = 'D:\modelsim\modelsim_ase\win32aloem'
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskTests = if ($Test -eq 'All') { @('Mmio','Uart','Reset','Smoke','CoreMarkSmoke') } else { @($Test) }
$taskSources = @(Get-ChildItem -LiteralPath (Join-Path $taskRoot 'rtl\core') -Filter '*.sv' -File | Sort-Object Name | ForEach-Object FullName)
$taskSources += @('board_dram.sv','board_irom.sv','uart_tx.sv','board_mmio.sv','cpu_soc.sv','board_top.sv') | ForEach-Object { Join-Path $taskRoot ('rtl\' + $_) }
$taskSources += @('serial_uart_monitor.sv','tb_board_mmio.sv','tb_uart_nominal.sv','tb_board_reset.sv','tb_cpu_soc.sv') | ForEach-Object { Join-Path $PSScriptRoot $_ }
$taskSummary = @()
foreach ($taskTest in $taskTests) {
    $taskBuild = Join-Path $PSScriptRoot ('sim_' + $taskTest.ToLower())
    New-Item -ItemType Directory -Force -Path $taskBuild | Out-Null
    $taskHashes = @($taskSources | ForEach-Object { [ordered]@{ path=$_; sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLower() } })
    if ($taskTest -in @('Reset','Smoke','CoreMarkSmoke')) {
        $taskHexDir = if ($taskTest -in @('Reset','Smoke')) { 'build_smoke_hz120000000' } else { 'build_coremark_i1_hz120000000' }
        $taskHex = Join-Path $taskRoot ('firmware\' + $taskHexDir + '\rom.hex')
        Copy-Item -LiteralPath $taskHex -Destination (Join-Path $taskBuild 'firmware.hex') -Force
        $taskHashes += [ordered]@{ path=$taskHex; sha256=(Get-FileHash -LiteralPath $taskHex -Algorithm SHA256).Hash.ToLower() }
    }
    $taskHashes | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $taskBuild 'inputs_sha256.json') -Encoding ascii
    Push-Location $taskBuild
    try {
        & (Join-Path $ModelSim 'vlib.exe') work 2>&1 | Tee-Object -FilePath vlib.log
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
        & (Join-Path $ModelSim 'vlog.exe') -sv -work work @taskSources 2>&1 | Tee-Object -FilePath compile.log
        if ($LASTEXITCODE -ne 0) { throw 'vlog failed' }
        $taskTop = switch ($taskTest) { 'Mmio' {'work.tb_board_mmio'} 'Uart' {'work.tb_uart_nominal'} 'Reset' {'work.tb_board_reset'} default {'work.tb_cpu_soc'} }
        $taskMode = if ($taskTest -eq 'CoreMarkSmoke') { '+COREMARK=1' } else { '+COREMARK=0' }
        & (Join-Path $ModelSim 'vsim.exe') -c -onfinish stop -l transcript.log $taskTop $taskMode -do 'onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0' 2>&1 | Tee-Object -FilePath console.log
        if ($LASTEXITCODE -ne 0) { throw ($taskTest + ' simulation failed') }
        $taskPass = Select-String -LiteralPath transcript.log -Pattern '^# PASS '
        if (-not $taskPass) { throw ($taskTest + ' missing PASS') }
        $taskCapturePath = Join-Path $taskBuild 'uart_capture.txt'
        $taskCapture = if (Test-Path -LiteralPath $taskCapturePath) { [IO.File]::ReadAllText($taskCapturePath) } else { '' }
        if ($taskTest -eq 'Smoke' -and $taskCapture -notmatch 'UART PASS') { throw 'Smoke missing UART PASS' }
        if ($taskTest -eq 'CoreMarkSmoke') {
            foreach ($taskPair in @(@('seedcrc','e9f5'),@('crclist','e714'),@('crcmatrix','1fd7'),@('crcstate','8e3a'),@('crcfinal','e714'))) {
                if ($taskCapture -notmatch ($taskPair[0] + '\s*:\s*0x' + $taskPair[1])) { throw ('CoreMark CRC mismatch: ' + $taskPair[0]) }
            }
            $taskExpectedError = 'ERROR! Must execute for at least 10 secs for a valid result!'
            if (-not $taskCapture.Contains($taskExpectedError)) { throw 'Expected one-iteration duration rejection missing' }
            if ($taskCapture.Replace($taskExpectedError,'') -match 'ERROR[!:]') { throw 'Unexpected CoreMark runtime error' }
        }
        $taskByteCount = if (Test-Path -LiteralPath $taskCapturePath) { (Get-Item -LiteralPath $taskCapturePath).Length } else { 0 }
        $taskSummary += [ordered]@{test=$taskTest; result='PASS'; detail=$taskPass.Line.TrimStart('#',' '); uart_bytes=$taskByteCount; capture=$taskCapture }
    } finally { Pop-Location }
}
$taskSummary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'board_test_summary.json') -Encoding ascii
$taskSummary | ForEach-Object { $_.detail }
