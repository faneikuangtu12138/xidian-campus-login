param([switch]$Once, [switch]$Diagnose)
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\MonitorCycle.ps1"
$mutex=[Threading.Mutex]::new($false,(Get-AppMutexName 'Local\XidianCampusLoginWorker'))
$locked=$false
$signals=$null
try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
if (!$locked) { $mutex.Dispose(); exit 0 }
try {
    Add-Type -Path "$PSScriptRoot\DirectNetwork.cs"
    Add-Type -Path "$PSScriptRoot\SrunCrypto.cs"
    $script:PreviousStatus=''
    $state=New-MonitorState
    if (!$Once -and !$Diagnose) {
        $signals=[CampusLogin.ActivitySignals]::new($script:DataRoot,[string[]]@('settings.json','retry.request','stop.request'),$true)
        Write-JsonAtomic (Join-Path $script:DataRoot 'event-subscriptions.json') @{pid=$PID;power=$signals.PowerSubscribed;wifi=$signals.WifiSubscribed;connectivity=$signals.ConnectivitySubscribed;connection=$signals.ConnectionSubscribed;errors=$signals.SubscriptionErrors;updated=[DateTimeOffset]::Now.ToString('o')}
    }
    do {
        if (!$Once -and !$Diagnose -and (Test-Path -LiteralPath (Join-Path $script:DataRoot 'stop.request'))) { break }
        $result=Invoke-MonitorCycle $state -Diagnose:$Diagnose
        $state.lastCompleted=[DateTimeOffset]::Now
        if ($Once -or $Diagnose) { $result | ConvertTo-Json; break }
        $wait=Get-MonitorWaitMilliseconds $state $result
        $reason=$signals.Wait($wait)
        if ($reason -band ([CampusLogin.ActivitySignals]::Network -bor [CampusLogin.ActivitySignals]::Resume)) {
            $deadline=[DateTimeOffset]::Now.AddSeconds(2)
            do { $extra=$signals.Wait(300); $reason=$reason -bor $extra } while($extra -ne 0 -and [DateTimeOffset]::Now -lt $deadline -and !(Test-Path -LiteralPath (Join-Path $script:DataRoot 'stop.request')))
        }
        if ($reason -band [CampusLogin.ActivitySignals]::Resume) {
            Reset-MonitorRetry $state; $state.fingerprint=''
            [void](Save-Status 'RESUMING' '电脑已恢复，正在重新检测校园网认证。' $null)
        }
    } while ($true)
} catch {
    Write-SafeDiagnostic 'worker_start' $_.Exception
    exit 1
} finally { if($signals){$signals.Dispose()}; if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
