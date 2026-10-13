param([switch]$Background, [switch]$CheckRuntime)
# ASCII-only bootstrap: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
$ErrorActionPreference = 'Stop'
$dataRoot = if ($env:XIDIAN_CAMPUS_DATA) { $env:XIDIAN_CAMPUS_DATA } else { Join-Path $PSScriptRoot 'data' }
try {
    [void][IO.Directory]::CreateDirectory($dataRoot)
    $candidates = @(
        (Join-Path $PSScriptRoot 'runtime\pwsh.exe'),
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe')
    )
    $found = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($found) { $candidates += $found.Source }
    $runtime = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (!$runtime) { throw 'PowerShell 7.4 or later is required.' }
    if ($CheckRuntime) { Write-Output $runtime; exit 0 }
    $stopPath = Join-Path $dataRoot 'stop.request'
    if (Test-Path -LiteralPath $stopPath) { Remove-Item -LiteralPath $stopPath }
    if (!$Background) { [IO.File]::WriteAllText((Join-Path $dataRoot 'open.request'),'') }
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSScriptRoot + '\Supervisor.ps1"'
    if (!$Background) { $arguments += ' -OpenSettings' }
    $process = Start-Process -FilePath $runtime -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if ($process.WaitForExit(1500) -and $process.ExitCode -ne 0) { throw 'Background supervisor exited during startup.' }
} catch {
    [IO.File]::AppendAllText((Join-Path $dataRoot 'startup.log'),([DateTimeOffset]::Now.ToString('o') + ' STARTUP_FAILED ' + $_.Exception.GetType().Name + "`r`n"))
    if (!$Background) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show('Campus login could not start. Check data\startup.log and data\supervisor.log.','Campus Login')
    }
    exit 1
}
