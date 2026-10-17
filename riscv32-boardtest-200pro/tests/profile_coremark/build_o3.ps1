param(
    [ValidateRange(1, 1000000)][int]$Iterations = 1,
    [ValidateRange(1000000, 250000000)][int]$CpuHz = 120000000,
    [string]$ToolchainBin = ''
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$productionFirmwareRoot = Join-Path $projectRoot 'firmware'
$firmwareRoot = Join-Path $PSScriptRoot 'source_o3'
New-Item -ItemType Directory -Path $firmwareRoot,(Join-Path $firmwareRoot 'coremark') -Force | Out-Null
Get-ChildItem -LiteralPath $productionFirmwareRoot -File | Where-Object { $_.Extension -in '.c','.h','.S','.ld' } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $firmwareRoot }
Get-ChildItem -LiteralPath (Join-Path $productionFirmwareRoot 'coremark') -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $firmwareRoot 'coremark') }
$portHeader = Join-Path $firmwareRoot 'core_portme.h'
$headerText = [System.IO.File]::ReadAllText($portHeader).Replace('"-O2 -march=', '"-O3 -march=')
[System.IO.File]::WriteAllText($portHeader, $headerText, [System.Text.UTF8Encoding]::new($false))
if ($ToolchainBin) {
    $gcc = Join-Path $ToolchainBin 'riscv-none-elf-gcc.exe'
} else {
    $gcc = (Get-Command riscv-none-elf-gcc.exe -ErrorAction Stop).Source
    $ToolchainBin = Split-Path -Parent $gcc
}
$objcopy = Join-Path $ToolchainBin 'riscv-none-elf-objcopy.exe'
$size = Join-Path $ToolchainBin 'riscv-none-elf-size.exe'
$objdump = Join-Path $ToolchainBin 'riscv-none-elf-objdump.exe'
$nm = Join-Path $ToolchainBin 'riscv-none-elf-nm.exe'
$common = @('-march=rv32i', '-mabi=ilp32', '-O3', '-mno-relax', '-msmall-data-limit=0',
    '-ffreestanding', '-fno-builtin', '-fno-common', '-ffunction-sections', '-fdata-sections',
    '-nostdlib', '-nostartfiles', '-Wall', '-Wextra', "-DCPU_HZ=$CpuHz",
    "-I$firmwareRoot", "-I$(Join-Path $firmwareRoot 'coremark')",
    "-T$(Join-Path $firmwareRoot 'link.ld')", '-Wl,--gc-sections', '-Wl,--no-relax')

function Build-One([string]$Name, [string[]]$Sources, [string[]]$Defines) {
    $outputDir = Join-Path $PSScriptRoot $Name
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    $elf = Join-Path $outputDir 'firmware.elf'
    $bin = Join-Path $outputDir 'firmware.bin'
    $map = Join-Path $outputDir 'firmware.map'
    $argsList = $common + $Defines + $Sources + @('-lgcc', "-Wl,-Map=$map", '-o', $elf)
    & $gcc @argsList 2>&1 | Tee-Object -FilePath (Join-Path $outputDir 'build.log')
    if ($LASTEXITCODE -ne 0) { throw "$Name GCC failed (O3 experiment; 32 KiB ROM limit is intentionally unchanged)" }
    & $objcopy -O binary $elf $bin
    if ($LASTEXITCODE -ne 0) { throw "$Name objcopy failed" }
    $imageBytes = [System.IO.File]::ReadAllBytes($bin)
    if ($imageBytes.Length -gt 32768) { throw "ROM overflow: $($imageBytes.Length) bytes" }
    $romBytes = New-Object byte[] 32768
    [Array]::Copy($imageBytes, $romBytes, $imageBytes.Length)
    $words = for ($offset = 0; $offset -lt 32768; $offset += 4) {
        [BitConverter]::ToUInt32($romBytes, $offset).ToString('x8')
    }
    [System.IO.File]::WriteAllLines((Join-Path $outputDir 'rom.hex'), $words, [System.Text.Encoding]::ASCII)
    $sizeReport = & $size -A $elf
    $sizeReport | Set-Content (Join-Path $outputDir 'size.txt') -Encoding ascii
    & $objdump -d $elf | Set-Content (Join-Path $outputDir 'disassembly.txt') -Encoding ascii
    & $nm -n $elf | Set-Content (Join-Path $outputDir 'symbols.txt') -Encoding ascii
    [ordered]@{
        program = $Name
        cpu_hz = $CpuHz
        iterations = $(if ($Name.StartsWith('build_coremark')) { $Iterations } else { 0 })
        rom_address = '0x80000000'
        rom_capacity_bytes = 32768
        rom_bytes = $imageBytes.Length
        ram_address = '0x80100000'
        ram_capacity_bytes = 65536
        compiler = ((& $gcc --version | Select-Object -First 1) -join '')
        flags = ($common + $Defines) -join ' '
        elf_sha256 = (Get-FileHash -Algorithm SHA256 $elf).Hash
        rom_hex_sha256 = (Get-FileHash -Algorithm SHA256 (Join-Path $outputDir 'rom.hex')).Hash
    } | ConvertTo-Json | Set-Content (Join-Path $outputDir 'build_info.json') -Encoding utf8
    Write-Host "$Name ready: $outputDir ($($imageBytes.Length) / 32768 ROM bytes)"
    $sizeReport | Write-Host
}

$startup = Join-Path $firmwareRoot 'start.S'
$board = Join-Path $firmwareRoot 'board.c'
# Independent O3 experiment: no production smoke or coremark files are changed.
$coreSources = @('core_list_join.c', 'core_main.c', 'core_matrix.c', 'core_state.c', 'core_util.c') |
    ForEach-Object { Join-Path (Join-Path $firmwareRoot 'coremark') $_ }
Build-One "build_coremark_o3_i${Iterations}_hz$CpuHz" (@($startup, $board, (Join-Path $firmwareRoot 'core_portme.c')) + $coreSources) @("-DITERATIONS=$Iterations")
