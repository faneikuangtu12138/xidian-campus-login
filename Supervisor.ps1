param([switch]$OpenSettings)
. "$PSScriptRoot\Common.ps1"
$mutex = [Threading.Mutex]::new($false,'Local\XidianCampusLoginSupervisor')
$locked = $false
try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
if (!$locked) { $mutex.Dispose(); exit 0 }
$runtime = Join-Path $PSHOME 'pwsh.exe'
$stopPath = Join-Path $script:DataRoot 'stop.request'
$components = @{
    Monitor = @{ mutex='Local\XidianCampusLoginWorker'; heartbeat='status.json'; timeout=150; process=$null; started=[DateTimeOffset]::MinValue }
    App = @{ mutex='Local\XidianCampusLoginApp'; heartbeat='ui-state.json'; timeout=40; process=$null; started=[DateTimeOffset]::MinValue }
}
function Write-SupervisorLog([string]$Event) {
    $path = Join-Path $script:DataRoot 'supervisor.log'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 524288) { [IO.File]::WriteAllText($path,'') }
    [IO.File]::AppendAllText($path,([DateTimeOffset]::Now.ToString('o')+' '+$Event+"`r`n"))
}
function Get-ComponentProcess($Component,[string]$Name) {
    $path = Join-Path $script:DataRoot $Component.heartbeat
    try {
        if (!(Test-Path -LiteralPath $path)) { return $null }
        $heartbeat = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $candidate = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$heartbeat.pid)" -ErrorAction Stop
        $expected = '-File "' + $PSScriptRoot + '\' + $Name + '.ps1"'
        if ($candidate.Name -eq 'pwsh.exe' -and $candidate.SessionId -eq (Get-Process -Id $PID).SessionId -and $candidate.CommandLine.Contains($expected)) {
            return Get-Process -Id $candidate.ProcessId -ErrorAction Stop
        }
    } catch { }
    return $null
}
$lastTick = [DateTimeOffset]::Now
$lastHeartbeat = [DateTimeOffset]::MinValue
try {
    Write-SupervisorLog 'SUPERVISOR_STARTED'
    while (!(Test-Path -LiteralPath $stopPath)) {
        $now = [DateTimeOffset]::Now
        if (($now-$lastTick).TotalSeconds -gt 45) {
            # Sleep freezes timers; let workers reset before treating old heartbeats as hangs.
            foreach ($component in $components.Values) { $component.started = $now }
            Write-SupervisorLog 'RESUME_DETECTED'
        }
        $lastTick = $now
        foreach ($name in @('Monitor','App')) {
            $component = $components[$name]
            $probe = [Threading.Mutex]::new($false,$component.mutex)
            $free = $false
            try {
                try { $free = $probe.WaitOne(0) } catch [Threading.AbandonedMutexException] { $free = $true }
                if ($free) {
                    $probe.ReleaseMutex()
                    if (($now-$component.started).TotalSeconds -lt 10) { continue }
                    $args = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSScriptRoot + '\' + $name + '.ps1"'
                    if ($name -eq 'App' -and !$OpenSettings) { $args += ' -Background' }
                    $component.process = Start-Process -FilePath $runtime -ArgumentList $args -WindowStyle Hidden -PassThru
                    $component.started = $now
                    Write-SupervisorLog ($name.ToUpperInvariant()+'_STARTED pid='+$component.process.Id)
                    if ($name -eq 'App') { $OpenSettings = $false }
                } elseif (($now-$component.started).TotalSeconds -gt $component.timeout) {
                    $path = Join-Path $script:DataRoot $component.heartbeat
                    $age = 999
                    try { $heartbeat = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json; $age = ($now-[DateTimeOffset]::Parse($heartbeat.updated)).TotalSeconds } catch { }
                    if ($age -gt $component.timeout) {
                        $owned = Get-ComponentProcess $component $name
                        if ($owned) { Stop-Process -Id $owned.Id -Force; Write-SupervisorLog ($name.ToUpperInvariant()+'_HUNG_RESTART'); $component.started = [DateTimeOffset]::MinValue }
                    }
                }
            } finally { $probe.Dispose() }
        }
        if (($now-$lastHeartbeat).TotalSeconds -ge 5) {
            Write-JsonAtomic (Join-Path $script:DataRoot 'supervisor-state.json') @{pid=$PID;updated=$now.ToString('o')}
            $lastHeartbeat = $now
        }
        Start-Sleep -Seconds 2
    }
    Write-SupervisorLog 'USER_STOPPED'
    $ui = Get-ComponentProcess $components.App 'App'
    if ($ui) { Stop-Process -Id $ui.Id -Force }
} catch {
    Write-SupervisorLog ('SUPERVISOR_FAILED type='+$_.Exception.GetType().Name)
    exit 1
} finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
