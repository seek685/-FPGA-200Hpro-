# Compatible with Windows PowerShell 5.1. Run after PDS finishes Report Timing.
# Copies the actual build and RTL; never changes the original project or Git.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectDir,
    [string]$OutputDir = ""
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path -LiteralPath $ProjectDir).Path
foreach ($required in @("prj_pds/hdmi_loop.pds", "rtl_pds/hdmi_loop.sv")) {
    if (-not (Test-Path -LiteralPath (Join-Path $projectPath $required) -PathType Leaf)) {
        throw "ProjectDir must be the CNN_FPGA directory: missing $required"
    }
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = [Environment]::GetFolderPath("Desktop")
    if ([string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir = [IO.Path]::GetTempPath() }
}
$null = New-Item -ItemType Directory -Force -Path $OutputDir
$outputPath = (Resolve-Path -LiteralPath $OutputDir).Path
$bundleName = "FPGA_PDS_debug_" + (Get-Date -Format "yyyyMMdd_HHmmss") + "_" +
    [Guid]::NewGuid().ToString("N").Substring(0, 8)
$stagePath = Join-Path ([IO.Path]::GetTempPath()) $bundleName
$snapshotPath = Join-Path $stagePath "CNN_FPGA"
$zipPath = Join-Path $outputPath ($bundleName + ".zip")
$null = New-Item -ItemType Directory -Path $snapshotPath
try {
    @(
        "Collected: $([DateTimeOffset]::Now.ToString('o'))"
        "Project directory: $projectPath"
        "PowerShell version: $($PSVersionTable.PSVersion)"
        "Contains complete prj_pds and rtl_pds snapshots, including existing build outputs."
        "This script does not run PDS or prove that reports are current."
        "Do not rebuild or edit the project while collecting."
    ) | Set-Content -LiteralPath (Join-Path $stagePath "collection_info.txt") -Encoding UTF8
    if (Get-Command git -ErrorAction SilentlyContinue) {
        try {
            $gitHead = & git -C $projectPath rev-parse HEAD 2>&1
            if ($LASTEXITCODE -eq 0) {
                $gitHead | Set-Content -LiteralPath (Join-Path $stagePath "git_head.txt") -Encoding UTF8
                & git -C $projectPath status --short --branch |
                    Set-Content -LiteralPath (Join-Path $stagePath "git_status.txt") -Encoding UTF8
                & git -C $projectPath diff --no-ext-diff HEAD -- . |
                    Set-Content -LiteralPath (Join-Path $stagePath "git_diff.txt") -Encoding UTF8
            } else { throw "No Git history found in this project copy." }
        } catch {
            $_.Exception.Message | Set-Content -LiteralPath (Join-Path $stagePath "git_unavailable.txt") -Encoding UTF8
        }
    }
    foreach ($directory in @("prj_pds", "rtl_pds")) {
        Write-Host "Copying $directory ..."
        Copy-Item -LiteralPath (Join-Path $projectPath $directory) -Destination $snapshotPath -Recurse -Force
    }
    Get-ChildItem -LiteralPath $snapshotPath -File -Recurse -Force | ForEach-Object {
        [PSCustomObject]@{
            Path = $_.FullName.Substring($stagePath.Length + 1)
            Bytes = $_.Length
            LastWriteTimeUtc = $_.LastWriteTimeUtc.ToString("o")
        }
    } | Export-Csv -LiteralPath (Join-Path $stagePath "files.csv") -NoTypeInformation -Encoding UTF8
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Write-Host "Creating archive; large build databases may take several minutes ..."
    [IO.Compression.ZipFile]::CreateFromDirectory($stagePath, $zipPath)
    Write-Host "Created: $zipPath"
    Write-Host "Bytes: $((Get-Item -LiteralPath $zipPath).Length)"
    Write-Host "SHA256: $((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash)"
} finally {
    # Delete only this invocation's unique temporary copy, never the source.
    if (Test-Path -LiteralPath $stagePath) { Remove-Item -LiteralPath $stagePath -Recurse -Force }
}
