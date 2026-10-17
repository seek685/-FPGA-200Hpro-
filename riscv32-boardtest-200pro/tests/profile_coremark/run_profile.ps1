param(
    [string]$Label = 'o2_i1',
    [string]$HexFile = 'D:\0-contest\riscv32-boardtest-200pro\firmware\build_coremark_i1_hz120000000\rom.hex',
    [string]$SymbolsFile = 'D:\0-contest\riscv32-boardtest-200pro\firmware\build_coremark_i1_hz120000000\symbols.txt',
    [string]$SourceRoot = 'D:\0-contest\riscv32-boardtest-200pro\build\coremark120_board_v2\rtl',
    [string]$ModelSim = 'D:\modelsim\modelsim_ase\win32aloem'
)
$ErrorActionPreference = 'Stop'
if ($Label -notmatch '^[a-zA-Z0-9_]+$') { throw 'Label must contain only letters/numbers/underscore' }
$taskBuild = Join-Path $PSScriptRoot $Label
New-Item -ItemType Directory -Force -Path $taskBuild | Out-Null
Copy-Item -LiteralPath $HexFile -Destination (Join-Path $taskBuild 'firmware.hex')
Copy-Item -LiteralPath $SymbolsFile -Destination (Join-Path $taskBuild 'symbols.txt')
$taskSources = @(Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'core') -Filter '*.sv' -File | Sort-Object Name | ForEach-Object FullName)
$taskSources += @('board_dram.sv','board_irom.sv','uart_tx.sv','board_mmio.sv','cpu_soc.sv') | ForEach-Object { Join-Path $SourceRoot $_ }
$taskSources += Join-Path (Split-Path -Parent $PSScriptRoot) 'serial_uart_monitor.sv'
$taskSources += Join-Path $PSScriptRoot 'tb_profile.sv'
$taskInputs = @($taskSources) + @($HexFile,$SymbolsFile)
$taskInputs | ForEach-Object { [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLower()} } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $taskBuild 'inputs_sha256.json') -Encoding ascii
Push-Location $taskBuild
try {
    if (-not (Test-Path -LiteralPath work)) {
        & (Join-Path $ModelSim 'vlib.exe') work 2>&1 | Tee-Object -FilePath vlib.log
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    }
    & (Join-Path $ModelSim 'vlog.exe') -sv -work work @taskSources 2>&1 | Tee-Object -FilePath compile.log
    if ($LASTEXITCODE -ne 0) { throw 'vlog failed' }
    & (Join-Path $ModelSim 'vsim.exe') -c -onfinish stop -l transcript.log work.tb_profile -do 'run -all; quit -code 0' 2>&1 | Tee-Object -FilePath console.log
    if ($LASTEXITCODE -ne 0) { throw 'vsim failed' }
    if (-not (Select-String -LiteralPath transcript.log -SimpleMatch 'PASS tb_profile')) { throw 'Profile missing PASS' }
    $taskCapture = [IO.File]::ReadAllText((Join-Path $taskBuild 'uart_capture.txt'))
    foreach ($taskPair in @(@('seedcrc','e9f5'),@('crclist','e714'),@('crcmatrix','1fd7'),@('crcstate','8e3a'),@('crcfinal','e714'))) {
        if ($taskCapture -notmatch ($taskPair[0] + '\s*:\s*0x' + $taskPair[1])) { throw ('CRC mismatch: ' + $taskPair[0]) }
    }
    $taskExpectedError = 'ERROR! Must execute for at least 10 secs for a valid result!'
    if (-not $taskCapture.Contains($taskExpectedError) -or $taskCapture.Replace($taskExpectedError,'') -match 'ERROR[!:]') { throw 'Unexpected runtime error or absent short-run rejection' }
} finally { Pop-Location }
& 'C:\Users\111\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' (Join-Path $PSScriptRoot 'analyze_profile.py') $taskBuild
if ($LASTEXITCODE -ne 0) { throw 'Profile analysis failed' }
