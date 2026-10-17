param(
    [Parameter(Mandatory=$true)][string]$Port,
    [ValidateRange(5,600)][int]$Seconds = 90,
    [string]$LogFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'uart_board_result.txt')
)
$ErrorActionPreference = 'Stop'
$taskSerial = [IO.Ports.SerialPort]::new($Port,115200,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$taskSerial.Handshake = [IO.Ports.Handshake]::None
$taskSerial.DtrEnable = $false
$taskSerial.RtsEnable = $false
$taskText = [Text.StringBuilder]::new()
try {
    $taskSerial.Open()
    Write-Host "Listening on $Port, 115200 8N1. Press and release KEY0 (C22, CPU reset)."
    $taskClock = [Diagnostics.Stopwatch]::StartNew()
    while ($taskClock.Elapsed.TotalSeconds -lt $Seconds) {
        $taskChunk = $taskSerial.ReadExisting()
        if ($taskChunk.Length -gt 0) {
            [void]$taskText.Append($taskChunk)
            Write-Host -NoNewline $taskChunk
            if ($taskText.ToString().Contains('COREMARK DONE')) { break }
        }
        Start-Sleep -Milliseconds 50
    }
} finally {
    if ($taskSerial.IsOpen) { $taskSerial.Close() }
    $taskSerial.Dispose()
    [IO.File]::WriteAllText($LogFile,$taskText.ToString(),[Text.UTF8Encoding]::new($false))
    Write-Host "`nSaved to $LogFile"
}
