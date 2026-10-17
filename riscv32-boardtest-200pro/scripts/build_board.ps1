param(
    [Parameter(Mandatory=$true)][string]$FirmwareDir,
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Label = 'coremark_120mhz'
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskFirmware = (Resolve-Path -LiteralPath $FirmwareDir).Path
$taskInfo = Get-Content -Raw -LiteralPath (Join-Path $taskFirmware 'build_info.json') | ConvertFrom-Json
if ($taskInfo.cpu_hz -ne 120000000) { throw 'The board PLL is 120 MHz. Rebuild firmware with -CpuHz 120000000.' }
$taskBuild = Join-Path (Join-Path $taskRoot 'build') $Label
if (Test-Path -LiteralPath $taskBuild) { throw "Build already exists; choose a new -Label: $taskBuild" }
$taskFiles = @(Get-ChildItem -LiteralPath (Join-Path $taskRoot 'rtl') -Filter '*.sv' -File -Recurse)
if ($taskFiles.Count -lt 20) { throw 'Board RTL is incomplete.' }
$taskPll = Join-Path $taskRoot 'ipcore\cpu_pll120\cpu_pll120.v'
if (!(Test-Path -LiteralPath $taskPll)) { throw 'Missing generated PLL wrapper.' }
New-Item -ItemType Directory -Path $taskBuild -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $taskRoot 'rtl') -Destination (Join-Path $taskBuild 'rtl') -Recurse
Copy-Item -LiteralPath $taskPll -Destination (Join-Path $taskBuild 'rtl\cpu_pll120.v')
Copy-Item -LiteralPath (Join-Path $taskRoot 'constraints\board_200pro.fdc') -Destination (Join-Path $taskBuild 'board_200pro.fdc')
Copy-Item -LiteralPath (Join-Path $taskFirmware 'rom.hex') -Destination (Join-Path $taskBuild 'firmware.hex')
Copy-Item -LiteralPath (Join-Path $taskFirmware 'build_info.json') -Destination (Join-Path $taskBuild 'firmware_build_info.json')
$taskManifest = @(Get-ChildItem -LiteralPath (Join-Path $taskBuild 'rtl') -File -Recurse | ForEach-Object {
    [pscustomobject]@{file=$_.FullName.Substring($taskBuild.Length+1); sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
})
$taskManifest += [pscustomobject]@{file='firmware.hex'; sha256=(Get-FileHash -LiteralPath (Join-Path $taskBuild 'firmware.hex') -Algorithm SHA256).Hash}
$taskManifest += [pscustomobject]@{file='board_200pro.fdc'; sha256=(Get-FileHash -LiteralPath (Join-Path $taskBuild 'board_200pro.fdc') -Algorithm SHA256).Hash}
$taskManifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskBuild 'source_manifest.json') -Encoding ascii
$env:BOARD_RTL_DIR = Join-Path $taskBuild 'rtl'
$env:BOARD_BUILD_DIR = $taskBuild
Push-Location $taskBuild
try {
    Write-Host "Building board test in $taskBuild; detailed output: console.log"
    & 'D:\0_FPGA\PDS\PDS_2022.2-SP6.1\bin\pds_shell.exe' -file (Join-Path $PSScriptRoot 'build_board.tcl') -work_dir $taskBuild -project_name cpu_boardtest 2>&1 | Out-File -LiteralPath (Join-Path $taskBuild 'console.log') -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw "PDS failed, exit=$LASTEXITCODE; see $taskBuild" }
} finally { Pop-Location }
$taskReport = Join-Path $taskBuild 'report_timing\board_top.rtr'
$taskBit = Join-Path $taskBuild 'generate_bitstream\board_top.sbit'
if (!(Test-Path -LiteralPath $taskReport) -or !(Test-Path -LiteralPath $taskBit)) { throw 'PDS did not produce the routed timing report and bitstream.' }
if (!(Select-String -LiteralPath $taskReport -SimpleMatch 'Design Summary : All Constraints Met.' -Quiet)) {
    throw "Timing did not meet constraints. Do not use this build for a scored run: $taskReport"
}
Get-Item -LiteralPath $taskBit | Select-Object FullName,Length,LastWriteTime
