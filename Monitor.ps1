param([switch]$Once, [switch]$Diagnose)
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\MonitorCycle.ps1"
$mutex=[Threading.Mutex]::new($false,'Local\XidianCampusLoginWorker')
$locked=$false
try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
if (!$locked) { $mutex.Dispose(); exit 0 }
try {
    Add-Type -Path "$PSScriptRoot\DirectNetwork.cs"
    Add-Type -Path "$PSScriptRoot\SrunCrypto.cs"
    $script:PreviousStatus=''
    $state=New-MonitorState
    do {
        if (!$Once -and !$Diagnose -and (Test-Path -LiteralPath (Join-Path $script:DataRoot 'stop.request'))) { break }
        [void](Update-MonitorResume $state)
        $result=Invoke-MonitorCycle $state -Diagnose:$Diagnose
        $state.lastCompleted=[DateTimeOffset]::Now
        if ($Once -or $Diagnose) { $result | ConvertTo-Json; break }
        Start-Sleep -Seconds 15
    } while ($true)
} catch {
    Write-SafeDiagnostic 'worker_start' $_.Exception
    exit 1
} finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }