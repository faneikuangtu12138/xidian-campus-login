param([string]$Destination = 'D:\XidianCampusLogin')
$ErrorActionPreference = 'Stop'
$target = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
if ($target -ne 'D:\XidianCampusLogin') { throw 'This repair package only targets D:\XidianCampusLogin.' }
$resultPath = Join-Path $PSScriptRoot 'data\repair-result.json'
[void][IO.Directory]::CreateDirectory((Split-Path $resultPath -Parent))
$taskName = 'XidianCampusLogin-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$originalTaskXml = $null
$backup = $null
$wasStopped = $false
$mutating = $false
$copied = [Collections.Generic.List[string]]::new()
$shortcutBackups = @{}
$stopPath = Join-Path $target 'data\stop.request'
$ownProcesses = @()
$oldDataOverride = $env:XIDIAN_CAMPUS_DATA
$installer = [Threading.Mutex]::new($false,'Local\XidianCampusLoginRepair')
$locked = $false
$repairStage = 'preflight'
function Get-InstalledComponentProcesses {
    foreach ($component in @(@{file='supervisor-state.json';script='Supervisor'},@{file='status.json';script='Monitor'},@{file='ui-state.json';script='App'})) {
        $heartbeatPath = Join-Path $target ('data\'+$component.file)
        if (!(Test-Path -LiteralPath $heartbeatPath)) { continue }
        $heartbeat = Get-Content -LiteralPath $heartbeatPath -Raw | ConvertFrom-Json
        $candidate = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$heartbeat.pid)"
        if (!$candidate) { continue }
        $expected = '-File "'+$target+'\'+$component.script+'.ps1"'
        if ($candidate.ExecutablePath -eq (Join-Path $target 'runtime\pwsh.exe') -and $candidate.SessionId -eq (Get-Process -Id $PID).SessionId -and $candidate.CommandLine.Contains($expected)) { $candidate }
    }
}
function Stop-VerifiedComponents($Candidates) {
    foreach ($previous in $Candidates) {
        $current = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$previous.ProcessId)"
        if ($current -and $current.CreationDate -eq $previous.CreationDate -and $current.ExecutablePath -eq $previous.ExecutablePath -and $current.CommandLine -eq $previous.CommandLine) {
            Stop-Process -Id ([int]$current.ProcessId) -Force -ErrorAction SilentlyContinue
        }
    }
}
try {
    try { $locked = $installer.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'Another repair is running.' }
    if (!(Test-Path -LiteralPath (Join-Path $target 'runtime\pwsh.exe')) -or !(Test-Path -LiteralPath (Join-Path $target 'Common.ps1'))) { throw 'Expected installed application was not found.' }
    # Preflight validates the built GUI image before changing the installation.
    $image = [IO.BinaryReader]::new([IO.File]::OpenRead((Join-Path $PSScriptRoot 'CampusLogin.exe')))
    try { $image.BaseStream.Position=0x3c; $pe=$image.ReadInt32(); $image.BaseStream.Position=$pe+24+68; if($image.ReadUInt16() -ne 2){throw 'Launcher is not a GUI executable.'} } finally { $image.Dispose() }
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'repair-manifest.json') -Raw | ConvertFrom-Json
    foreach ($entry in $manifest) {
        if ($entry.path -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($entry.path) -or $entry.path -match '^(data|runtime|\.git)[\\/]') { throw 'Unexpected repair payload path.' }
        $source = Join-Path $PSScriptRoot $entry.path
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $entry.sha256) { throw ('Payload checksum mismatch: '+$entry.path) }
        $current = Join-Path $target $entry.path
        if (Test-Path -LiteralPath $current) {
            $hash = (Get-FileHash -LiteralPath $current -Algorithm SHA256).Hash
            if ($hash -ne $entry.sha256 -and (!$entry.previousSha256 -or $hash -ne $entry.previousSha256)) { throw ('Installed file was modified after this repair was prepared: '+$entry.path) }
        } elseif ($entry.previousSha256) { throw ('Expected installed file is missing: '+$entry.path) }
    }
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        foreach ($action in $task.Actions) {
            if ($action.Execute -ne (Join-Path $target 'runtime\pwsh.exe') -and $action.Execute -ne (Join-Path $target 'CampusLogin.exe')) { throw 'Unexpected scheduled task command; no changes made.' }
        }
        $originalTaskXml = Export-ScheduledTask -TaskName $taskName
    }
    $backup = Join-Path $target ('development\silent-start-backup-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss'))
    [void][IO.Directory]::CreateDirectory($backup)
    foreach ($entry in $manifest) {
        $original = Join-Path $target $entry.path
        if (Test-Path -LiteralPath $original) {
            $backupFile = Join-Path $backup $entry.path
            [void][IO.Directory]::CreateDirectory((Split-Path $backupFile -Parent))
            Copy-Item -LiteralPath $original -Destination $backupFile
        }
    }
    if ($originalTaskXml) { [IO.File]::WriteAllText((Join-Path $backup 'original-task.xml'),$originalTaskXml) }
    $shortcutPaths = @(
        (Join-Path ([Environment]::GetFolderPath('Startup')) 'XidianCampusLogin.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) '西电校园网自动登录.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Programs')) '西电校园网自动登录\西电校园网自动登录.lnk')
    )
    foreach ($path in $shortcutPaths) {
        $shortcutBackups[$path] = if(Test-Path -LiteralPath $path){[IO.File]::ReadAllBytes($path)}else{$null}
    }
    # Record only verified application PIDs, not every PowerShell process.
    $ownProcesses = @(Get-InstalledComponentProcesses)
    $wasStopped = Test-Path -LiteralPath $stopPath
    $repairStage = 'stop-old-components'
    $mutating = $true
    [IO.File]::WriteAllText($stopPath,'')
    if ($task) { Disable-ScheduledTask -TaskName $taskName | Out-Null; Stop-ScheduledTask -TaskName $taskName }
    Start-Sleep -Seconds 3
    Stop-VerifiedComponents $ownProcesses
    $repairStage = 'replace-program-files'
    foreach ($entry in $manifest) {
        $destinationFile = Join-Path $target $entry.path
        [void][IO.Directory]::CreateDirectory((Split-Path $destinationFile -Parent))
        $copied.Add($entry.path)
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $entry.path) -Destination $destinationFile -Force
    }
    # Run from the installed standalone runtime: no runtime download or recopy.
    $env:XIDIAN_CAMPUS_DATA = Join-Path $target 'data'
    $repairStage = 'install-launcher-and-startup'
    & (Join-Path $target 'Install.ps1') -Destination $target -NoLaunch | Out-Null
    . (Join-Path $target 'Common.ps1')
    $updatedTask = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $repairStage = 'verify-startup-entries'
    if ($updatedTask.State -eq 'Disabled' -or $updatedTask.Actions.Count -ne 1 -or $updatedTask.Actions[0].Execute -ne (Join-Path $target 'CampusLogin.exe') -or $updatedTask.Actions[0].Arguments -ne '--supervise') { throw 'Silent scheduled task verification failed.' }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($path in $shortcutPaths) {
        $shortcut = $shell.CreateShortcut($path)
        if ($shortcut.TargetPath -ne (Join-Path $target 'CampusLogin.exe')) { throw 'Silent shortcut verification failed.' }
    }
    # Fresh heartbeats prevent mistaking a stale process for a completed update.
    $started = [DateTimeOffset]::Now
    $repairStage = 'start-and-verify-components'
    Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $healthy = $false
    for ($attempt=0; $attempt -lt 20; $attempt++) {
        $healthy = $true
        foreach ($name in @('supervisor-state.json','status.json','ui-state.json')) {
            try {
                $state = Get-Content -LiteralPath (Join-Path $target ('data\'+$name)) -Raw | ConvertFrom-Json
                if ([DateTimeOffset]$state.updated -lt $started -or !(Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue)) { $healthy=$false }
            } catch { $healthy=$false }
        }
        if ($healthy) { break }
        Start-Sleep -Seconds 2
    }
    if (!$healthy) { throw 'Updated background components did not become healthy.' }
    if((Get-ScheduledTask -TaskName $taskName).State -ne 'Running'){throw 'Task Scheduler is not supervising the persistent application.'}
    [xml]$verifiedXml=Export-ScheduledTask -TaskName $taskName
    if($verifiedXml.GetElementsByTagName('CalendarTrigger').Count -or $verifiedXml.GetElementsByTagName('Repetition').Count){throw 'Periodic keepalive trigger remains.'}
    [IO.File]::WriteAllText($resultPath,(@{installed=$true;target=$target;backup=$backup;taskVerified=$true;shortcutsVerified=$true;heartbeatsVerified=$true;updated=[DateTimeOffset]::Now.ToString('o')} | ConvertTo-Json))
} catch {
    $failureType = $_.Exception.GetType().Name
    $rollbackComplete = $true
    if ($mutating -and $backup) {
        try {
            [IO.File]::WriteAllText($stopPath,'')
            Start-Sleep -Seconds 3
            Stop-VerifiedComponents @(Get-InstalledComponentProcesses)
            foreach ($name in $copied) {
                $saved = Join-Path $backup $name
                $destinationFile = Join-Path $target $name
                if(Test-Path -LiteralPath $saved){Copy-Item -LiteralPath $saved -Destination $destinationFile -Force}
                elseif(Test-Path -LiteralPath $destinationFile){Remove-Item -LiteralPath $destinationFile -Force}
            }
            foreach ($path in $shortcutBackups.Keys) {
                if($null -ne $shortcutBackups[$path]){[IO.File]::WriteAllBytes($path,$shortcutBackups[$path])}
                elseif(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}
            }
            if($originalTaskXml){Register-ScheduledTask -TaskName $taskName -Xml $originalTaskXml -Force | Out-Null}
            elseif(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
            if (!$wasStopped) {
                Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
                $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $target 'runtime\pwsh.exe'),('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+$target+'\Supervisor.ps1"'))
                $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.WorkingDirectory=$target
                $restore=[Diagnostics.Process]::Start($info); $restore.Dispose()
            }
        } catch { $rollbackComplete=$false }
    }
    [IO.File]::WriteAllText($resultPath,(@{installed=$false;stage=$repairStage;type=$failureType;rollbackComplete=$rollbackComplete;updated=[DateTimeOffset]::Now.ToString('o')} | ConvertTo-Json))
    exit 1
} finally {
    $env:XIDIAN_CAMPUS_DATA=$oldDataOverride
    if($locked){$installer.ReleaseMutex()}; $installer.Dispose()
}
