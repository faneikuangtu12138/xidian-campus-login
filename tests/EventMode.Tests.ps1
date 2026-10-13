$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'Common.ps1')
. (Join-Path $projectRoot 'MonitorCycle.ps1')
function Assert($Condition,$Message){if(!$Condition){throw $Message}}
$state=New-MonitorState
foreach($name in @('ONLINE','WAITING','PAUSED','NEED_SETTINGS','ACCOUNT_ERROR')){
    Assert ((Get-MonitorWaitMilliseconds $state @{state=$name}) -eq -1) ('Idle state has a timer: '+$name)
}
$state.nextAttempt=[DateTimeOffset]::Now.AddSeconds(60)
Assert ((Get-MonitorWaitMilliseconds $state @{state='LOGIN_FAILED';ip='192.0.2.100'}) -gt 50000) 'Authentication retry ignored backoff'
Assert ((Get-MonitorWaitMilliseconds $state @{state='NETWORK_ERROR';ip=''}) -eq -1) 'No-campus error kept polling'
$common=[IO.File]::ReadAllText((Join-Path $projectRoot 'Common.ps1'))
Assert ($common -notmatch '<CalendarTrigger>|<Repetition>') 'Periodic keepalive trigger remains'
Assert ([IO.File]::ReadAllText((Join-Path $projectRoot 'Monitor.ps1')) -notmatch 'Start-Sleep -Seconds 15') 'Fixed network polling remains'
Assert ([IO.File]::ReadAllText((Join-Path $projectRoot 'App.ps1')) -notmatch 'Windows.Forms.Timer|Add_Tick') 'UI polling remains'
$signals=[CampusLogin.ActivitySignals]::new($script:DataRoot,[string[]]@('retry.request'),$false)
try{
    Assert ($signals.Wait(250) -eq 0) 'Event wait woke without an event'
    [IO.File]::WriteAllText((Join-Path $script:DataRoot 'retry.request'),'')
    Assert (($signals.Wait(3000) -band [CampusLogin.ActivitySignals]::Request) -ne 0) 'File request did not wake the event wait'
}finally{$signals.Dispose()}
Remove-Item -LiteralPath (Join-Path $script:DataRoot 'retry.request') -ErrorAction SilentlyContinue
$fixtureRoot=Join-Path $script:DataRoot 'event-mode-app'
[void][IO.Directory]::CreateDirectory($fixtureRoot)
foreach($file in @('CampusLogin.exe','BackgroundProcess.cs','ActivitySignals.cs','Common.ps1','Monitor.ps1','MonitorCycle.ps1','Supervisor.ps1','App.ps1','DirectNetwork.cs','SrunCrypto.cs')){
    Copy-Item -LiteralPath (Join-Path $projectRoot $file) -Destination $fixtureRoot
}
$fixture=Join-Path $fixtureRoot 'fixture-data'
[void][IO.Directory]::CreateDirectory($fixture)
$oldOverride=$env:XIDIAN_CAMPUS_DATA
$env:XIDIAN_CAMPUS_DATA=$fixture
# Only the network operation is substituted; the real monitor wait loop,
# supervisor, GUI launcher and WinForms request dispatch all run unchanged.
[IO.File]::AppendAllText((Join-Path $fixtureRoot 'MonitorCycle.ps1'),@'

function Invoke-MonitorCycle($State,[switch]$Diagnose) {
    $retry=Join-Path $script:DataRoot 'retry.request'
    if(Test-Path -LiteralPath $retry){Remove-Item -LiteralPath $retry}
    return Save-Status 'ONLINE' 'Synthetic online fixture; no network request.' ([pscustomobject]@{ssid='fixture-invalid-ssid';alias='fixture';ip='192.0.2.100'})
}
'@)
[IO.File]::WriteAllText((Join-Path $fixture 'settings.json'),'{"enabled":false,"username":"","protectedPassword":"","ssids":["fixture-invalid-ssid"],"showTrayIcon":false,"showTaskbarIcon":false}')
$started=[DateTimeOffset]::Now
$launch=$null;$tracked=@()
function Get-FixtureState([string]$Name){Get-Content -LiteralPath (Join-Path $fixture $Name) -Raw | ConvertFrom-Json}
try{
    $launch=Start-BackgroundProcess (Join-Path $fixtureRoot 'CampusLogin.exe') '--background'
    Assert ($launch.WaitForExit(15000) -and $launch.ExitCode -eq 0) 'Isolated background launch failed'
    $ready=$false
    for($attempt=0;$attempt -lt 30;$attempt++){
        try{
            $worker=Get-FixtureState 'status.json';$ui=Get-FixtureState 'ui-state.json';$supervisor=Get-FixtureState 'supervisor-state.json'
            if($worker.state -eq 'ONLINE' -and !$ui.visible){$ready=$true;break}
        }catch{}
        Start-Sleep -Milliseconds 500
    }
    Assert $ready 'Real background components did not initialize'
    $tracked=@([int]$worker.pid,[int]$ui.pid,[int]$supervisor.pid)
    # Let startup callbacks settle, then measure past the old 15-second interval.
    Start-Sleep -Seconds 2
    $files=@('status.json','ui-state.json','supervisor-state.json','supervisor.log')
    $before=@{};foreach($name in $files){$before[$name]=(Get-FileHash -LiteralPath (Join-Path $fixture $name)).Hash}
    $cpuBefore=@{};foreach($processId in $tracked){$cpuBefore[$processId]=(Get-Process -Id $processId).CPU}
    Start-Sleep -Seconds 20
    foreach($name in $files){Assert ((Get-FileHash -LiteralPath (Join-Path $fixture $name)).Hash -eq $before[$name]) ('Idle component kept writing '+$name)}
    $cpu=0.0;foreach($processId in $tracked){$cpu+=(Get-Process -Id $processId).CPU-$cpuBefore[$processId]}
    $initialPid=[int](Get-FixtureState 'status.json').pid
    Stop-Process -Id $initialPid -Force
    $recovered=$false
    for($attempt=0;$attempt -lt 20;$attempt++){
        Start-Sleep -Milliseconds 500
        $worker=Get-FixtureState 'status.json'
        if([int]$worker.pid -ne $initialPid -and $worker.state -eq 'ONLINE'){$tracked+=[int]$worker.pid;$recovered=$true;break}
    }
    Assert $recovered 'Child-exit event did not restore the worker'
    $lastUpdate=(Get-FixtureState 'status.json').updated
    [IO.File]::WriteAllText((Join-Path $fixture 'retry.request'),'')
    $requestHandled=$false
    for($attempt=0;$attempt -lt 20;$attempt++){
        Start-Sleep -Milliseconds 100
        if((Get-FixtureState 'status.json').updated -ne $lastUpdate){$requestHandled=$true;break}
    }
    Assert $requestHandled 'Manual request did not wake idle worker'
    Write-Output ('PASS: no periodic task/network/UI timers, real 20-second idle without file writes, child-exit recovery, request wake; combined idle CPU='+[Math]::Round($cpu,4)+' seconds. No network request or campus login.')
}finally{
    [IO.File]::WriteAllText((Join-Path $fixture 'stop.request'),'')
    Start-Sleep -Milliseconds 1000
    foreach($name in @('status.json','ui-state.json','supervisor-state.json')){try{$tracked+=[int](Get-FixtureState $name).pid}catch{}}
    foreach($processId in @($tracked | Select-Object -Unique)){if($processId -ne $PID){Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue}}
    if($launch){$launch.Dispose()}
    $env:XIDIAN_CAMPUS_DATA=$oldOverride
}
