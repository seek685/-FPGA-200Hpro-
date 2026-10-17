param(
    [Parameter(Mandatory=$true)][ValidateSet('Pds','Vivado')][string]$Tool,
    [Parameter(Mandatory=$true)][string]$SourceDir,
    [Parameter(Mandatory=$true)][string]$Label
)
$ErrorActionPreference = 'Stop'
if ($Label -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Label must contain letters, numbers, underscore or hyphen.' }
$sourceRoot = (Resolve-Path -LiteralPath $SourceDir).Path
$outputRoot = Join-Path $PSScriptRoot ($Label + '_' + $Tool.ToLowerInvariant())
if (Test-Path -LiteralPath (Join-Path $outputRoot 'source_manifest.json')) {
    throw "This label already has a source snapshot. Choose a new label: $outputRoot"
}
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$rtlRoot = Join-Path $outputRoot 'rtl'
New-Item -ItemType Directory -Path $rtlRoot -Force | Out-Null
$names = @('alu.sv','branch_predictor.sv','branch_unit.sv','control.sv','ex_mem.sv',
           'forwarding.sv','hazard_detection.sv','id_ex.sv','if_id.sv','immgen.sv',
           'mem_wb.sv','myCPU.sv','pc.sv','regfile.sv')
$manifest = foreach ($name in $names) {
    $sourceFile = Join-Path $sourceRoot $name
    $code = [IO.File]::ReadAllText($sourceFile)
    $lowered = @()
    if ($Tool -eq 'Pds') {
        # ADS 2022.2 accepts SystemVerilog logic but not loop-local int declarations.
        $loopMatches = [regex]::Matches($code, '\bfor\s*\(\s*int\s+(\w+)')
        $lowered = @($loopMatches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        if ($lowered.Count -gt 0) {
            $code = [regex]::Replace($code, '\bfor\s*\(\s*int\s+(\w+)', 'for ($1')
            $headerEnd = $code.IndexOf(');')
            if ($headerEnd -lt 0) { throw "Cannot find module header in $sourceFile" }
            $declaration = "`n    integer " + ($lowered -join ', ') + ";`n"
            $code = $code.Insert($headerEnd + 2, $declaration)
        }
    }
    [IO.File]::WriteAllText((Join-Path $rtlRoot $name), $code, [Text.Encoding]::ASCII)
    [pscustomobject]@{file=$name; source_sha256=(Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash; loop_int_lowered=($lowered -join ',')}
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot 'source_manifest.json') -Encoding ascii
if ($Tool -eq 'Pds') {
    @'
create_clock -name cpu_clk -period 6.667 [get_ports cpu_clk]
set_false_path -from [get_ports cpu_rst]
'@ | Set-Content -LiteralPath (Join-Path $outputRoot 'cpu.fdc') -Encoding ascii
    $env:CPU_RTL_DIR = $rtlRoot
    $env:CPU_TIMING_DIR = $outputRoot
    & 'D:\0_FPGA\PDS\PDS_2022.2-SP6.1\bin\pds_shell.exe' -file (Join-Path $PSScriptRoot 'pds_core.tcl') -work_dir $outputRoot -project_name cpu_compare
} else {
    Push-Location $outputRoot
    try {
        & 'D:\vivado\Vivado\2024.2\bin\vivado.bat' -mode batch -nojournal -log vivado.log -source (Join-Path $PSScriptRoot 'vivado_core.tcl') -tclargs $rtlRoot $outputRoot 6.667
    } finally { Pop-Location }
}
if ($LASTEXITCODE -ne 0) { throw "$Tool exited with code $LASTEXITCODE; see $outputRoot" }
if ($Tool -eq 'Pds') {
    $expectedFiles = @('place_route\myCPU_pnr.adf','report_timing\myCPU.rtr')
} else {
    $expectedFiles = @('cpu_routed.dcp','cpu_register_paths.rpt')
}
foreach ($expected in $expectedFiles) {
    $report = Join-Path $outputRoot $expected
    if (!(Test-Path -LiteralPath $report) -or (Get-Item -LiteralPath $report).Length -eq 0) {
        throw "Missing completed output: $report"
    }
}
