param([switch]$OpenSettings)
. "$PSScriptRoot\Common.ps1"
$mutex = [Threading.Mutex]::new($false,(Get-AppMutexName 'Local\XidianCampusLoginSupervisor'))
$locked = $false; $signals = $null
try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
if (!$locked) { $mutex.Dispose(); exit 0 }
$runtime = Join-Path $PSHOME 'pwsh.exe'
$stopPath = Join-Path $script:DataRoot 'stop.request'
$components = @{
    Monitor = @{ mutex='Local\XidianCampusLoginWorker'; state='status.json'; process=$null; started=[DateTimeOffset]::MinValue }
    App = @{ mutex='Local\XidianCampusLoginApp'; state='ui-state.json'; process=$null; started=[DateTimeOffset]::MinValue }
}
function Write-SupervisorLog([string]$Event) {
    $path=Join-Path $script:DataRoot 'supervisor.log'
    if((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 524288){[IO.File]::WriteAllText($path,'')}
    [IO.File]::AppendAllText($path,([DateTimeOffset]::Now.ToString('o')+' '+$Event+"`r`n"))
}
function Get-ComponentProcess($Component,[string]$Name) {
    try {
        $status=Get-Content -LiteralPath (Join-Path $script:DataRoot $Component.state) -Raw | ConvertFrom-Json
        $candidate=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$status.pid)" -ErrorAction Stop
        $expected='-File "'+$PSScriptRoot+'\'+$Name+'.ps1"'
        if($candidate.ExecutablePath -eq $runtime -and $candidate.SessionId -eq (Get-Process -Id $PID).SessionId -and $candidate.CommandLine.Contains($expected)){
            return Get-Process -Id $candidate.ProcessId -ErrorAction Stop
        }
    } catch { }
    return $null
}
try {
    $signals=[CampusLogin.ActivitySignals]::new($script:DataRoot,[string[]]@('stop.request'),$false)
    Write-SupervisorLog 'SUPERVISOR_STARTED_EVENT_MODE'
    Write-JsonAtomic (Join-Path $script:DataRoot 'supervisor-state.json') @{pid=$PID;mode='EventDriven';updated=[DateTimeOffset]::Now.ToString('o')}
    while(!(Test-Path -LiteralPath $stopPath)) {
        foreach($name in @('Monitor','App')) {
            $component=$components[$name]
            if($component.process -and !$component.process.HasExited){continue}
            if($component.process -and ([DateTimeOffset]::Now-$component.started).TotalSeconds -lt 10){throw 'Component failed during startup.'}
            if($component.process){$component.process.Dispose();$component.process=$null}
            $probe=[Threading.Mutex]::new($false,(Get-AppMutexName $component.mutex));$free=$false
            try {
                try{$free=$probe.WaitOne(0)}catch [Threading.AbandonedMutexException]{$free=$true}
                if($free){
                    $probe.ReleaseMutex()
                    $arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "'+$PSScriptRoot+'\'+$name+'.ps1"'
                    if($name -eq 'App' -and !$OpenSettings){$arguments+=' -Background'}
                    $component.process=Start-BackgroundProcess $runtime $arguments
                    $component.started=[DateTimeOffset]::Now
                    Write-SupervisorLog ($name.ToUpperInvariant()+'_STARTED pid='+$component.process.Id)
                    if($name -eq 'App'){$OpenSettings=$false}
                }else{
                    $component.process=Get-ComponentProcess $component $name
                    if(!$component.process){throw 'Cannot safely adopt the existing component.'}
                }
                $signals.Watch($component.process)
            }finally{$probe.Dispose()}
        }
        [void]$signals.Wait(-1)
    }
    Write-SupervisorLog 'USER_STOPPED'
    foreach($component in $components.Values){
        if($component.process -and !$component.process.HasExited){$component.process.Kill()}
    }
}catch{
    Write-SupervisorLog ('SUPERVISOR_FAILED type='+$_.Exception.GetType().Name)
    exit 1
}finally{
    if($signals){$signals.Dispose()}
    foreach($component in $components.Values){if($component.process){$component.process.Dispose()}}
    if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()
}
