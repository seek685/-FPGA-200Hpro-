param([string]$PdsRoot = 'D:\0_FPGA\PDS\PDS_2022.2-SP6.1')
$ErrorActionPreference = 'Stop'
$ipDefinition = Join-Path $PSScriptRoot 'cpu_pll120.idf'
$ipLibrary = Join-Path $PdsRoot 'ip\module_ip\ipm2l_flex_pll\ipm2l_flex_pll_eval\ipm2l_pll'
& (Join-Path $PdsRoot 'bin\ip_generate.exe') -i $ipDefinition -m $ipLibrary -disable-syn
if ($LASTEXITCODE -ne 0) { throw 'Pango PLL generation failed' }
