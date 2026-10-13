# Exercise the actual repair script against isolated files and mocked OS tasks.
# No installed application, real startup directory, or real task is modified.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'Common.ps1')
function Assert($Condition,$Message){if(!$Condition){throw $Message}}
function Get-ScheduledTask { param($TaskName,$ErrorAction) return $global:RepairFixture.task }
function Export-ScheduledTask { param($TaskName) '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Triggers><LogonTrigger/><EventTrigger/></Triggers></Task>' }
function Disable-ScheduledTask { param($TaskName) $global:RepairFixture.task.State='Disabled' }
function Stop-ScheduledTask { param($TaskName) }
function Register-ScheduledTask { param($TaskName,$Xml,[switch]$Force) $global:RepairFixture.task=$global:RepairFixture.originalTask }
function Get-CimInstance { param($ClassName,$Filter,$ErrorAction) return $null }
function Start-Sleep { param($Seconds,$Milliseconds) }
function Start-ScheduledTask {
    param($TaskName,$ErrorAction)
    if($global:RepairFixture.failRestart){throw 'Synthetic task-start failure'}
    $global:RepairFixture.task.State='Running'
    foreach($name in @('supervisor-state.json','status.json','ui-state.json')){
        [IO.File]::WriteAllText((Join-Path $global:RepairFixture.target ('data\'+$name)),(@{pid=$PID;updated=[DateTimeOffset]::Now.ToString('o')}|ConvertTo-Json))
    }
}
$oldOverride=$env:XIDIAN_CAMPUS_DATA
try {
    foreach($scenario in @('success','checksum','rollback')) {
        $root=Join-Path $script:DataRoot ('repair-fixture-'+$scenario)
        $payload=Join-Path $root 'payload';$target=Join-Path $root 'installation'
        foreach($directory in @($payload,$target,(Join-Path $target 'runtime'),(Join-Path $target 'data'),(Join-Path $root 'startup'),(Join-Path $root 'desktop'),(Join-Path $root 'programs'))){[void][IO.Directory]::CreateDirectory($directory)}
        [IO.File]::WriteAllText((Join-Path $target 'Common.ps1'),'# original installation')
        [IO.File]::WriteAllText((Join-Path $target 'runtime\pwsh.exe'),'synthetic-runtime-marker; never executed')
        [IO.File]::WriteAllText((Join-Path $target 'data\stop.request'),'')
        [IO.File]::WriteAllText((Join-Path $target 'data\settings.json'),'{"enabled":false,"username":"synthetic-only"}')
        $settingsHash=(Get-FileHash -LiteralPath (Join-Path $target 'data\settings.json')).Hash
        foreach($name in @('Common.ps1','BackgroundProcess.cs','ActivitySignals.cs','CampusLogin.exe')){Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $payload}
        $global:RepairFixture=@{target=$target;failRestart=($scenario -eq 'rollback');startup=(Join-Path $root 'startup');desktop=(Join-Path $root 'desktop');programs=(Join-Path $root 'programs')}
        $originalTask=[pscustomobject]@{State='Ready';Actions=@([pscustomobject]@{Execute=(Join-Path $target 'runtime\pwsh.exe');Arguments='old-supervisor'})}
        $global:RepairFixture.originalTask=$originalTask
        $global:RepairFixture.task=$originalTask
        $fakeInstall=@'
param($Destination,[switch]$NoLaunch)
$global:RepairFixture.task=[pscustomobject]@{State='Ready';Actions=@([pscustomobject]@{Execute=(Join-Path $Destination 'CampusLogin.exe');Arguments='--supervise'})}
$paths=@((Join-Path $global:RepairFixture.startup 'XidianCampusLogin.lnk'),(Join-Path $global:RepairFixture.desktop '西电校园网自动登录.lnk'),(Join-Path $global:RepairFixture.programs '西电校园网自动登录\西电校园网自动登录.lnk'))
foreach($path in $paths){[void][IO.Directory]::CreateDirectory((Split-Path $path -Parent));[CampusLogin.BackgroundProcess]::SaveShortcut($path,(Join-Path $Destination 'CampusLogin.exe'),'',$Destination,'Synthetic shortcut')}
'@
        [IO.File]::WriteAllText((Join-Path $payload 'Install.ps1'),$fakeInstall,[Text.UTF8Encoding]::new($false))
        $manifest=foreach($name in @('Common.ps1','BackgroundProcess.cs','ActivitySignals.cs','CampusLogin.exe','Install.ps1')){
            $oldFile=Join-Path $target $name
            @{path=$name;sha256=(Get-FileHash -LiteralPath (Join-Path $payload $name)).Hash;previousSha256=$(if(Test-Path -LiteralPath $oldFile){(Get-FileHash -LiteralPath $oldFile).Hash}else{$null})}
        }
        [IO.File]::WriteAllText((Join-Path $payload 'repair-manifest.json'),($manifest|ConvertTo-Json))
        # Only the test copy redirects the fixed installation path and shortcuts.
        $apply=[IO.File]::ReadAllText((Join-Path $projectRoot 'Apply-Fix.ps1')).Replace("'D:\XidianCampusLogin'",("'"+$target+"'"))
        $apply=$apply.Replace('    $failureType = $_.Exception.GetType().Name','    $failureType = $_.Exception.GetType().Name; Write-Output ("Synthetic repair error: "+$_.Exception.Message+" at "+$_.InvocationInfo.ScriptLineNumber)')
        foreach($pair in @(@('Startup',$global:RepairFixture.startup),@('Desktop',$global:RepairFixture.desktop),@('Programs',$global:RepairFixture.programs))){$apply=$apply.Replace(("[Environment]::GetFolderPath('"+$pair[0]+"')"),("'"+$pair[1]+"'"))}
        [IO.File]::WriteAllText((Join-Path $payload 'Apply-Fix.ps1'),$apply,[Text.UTF8Encoding]::new($false))
        if($scenario -eq 'checksum'){[IO.File]::AppendAllText((Join-Path $payload 'Common.ps1'),"`n# modified payload")}
        $env:XIDIAN_CAMPUS_DATA=Join-Path $target 'data'
        $global:LASTEXITCODE=0
        & (Join-Path $payload 'Apply-Fix.ps1') -Destination $target
        $result=Get-Content -LiteralPath (Join-Path $payload 'data\repair-result.json') -Raw|ConvertFrom-Json
        Assert ((Get-FileHash -LiteralPath (Join-Path $target 'data\settings.json')).Hash -eq $settingsHash) 'Repair changed existing settings'
        if($scenario -eq 'success'){
            Assert ($result.installed -and $result.taskVerified -and $result.shortcutsVerified -and $result.heartbeatsVerified) 'Repair did not complete verification'
            Assert ($global:RepairFixture.task.State -eq 'Running') 'Persistent scheduler ownership was lost'
        }else{
            Assert (!$result.installed -and $result.rollbackComplete) ('Failure rollback did not complete: '+$scenario)
            Assert ([IO.File]::ReadAllText((Join-Path $target 'Common.ps1')) -eq '# original installation') 'Failed repair changed original files'
            Assert ($global:RepairFixture.task.Actions[0].Execute -eq (Join-Path $target 'runtime\pwsh.exe')) 'Failed repair changed original task'
        }
        $env:XIDIAN_CAMPUS_DATA=$oldOverride
    }
    Write-Output 'PASS: isolated repair success, payload tampering rejection, task-start failure rollback, preserved settings. No real task or startup entry was changed.'
}finally{$env:XIDIAN_CAMPUS_DATA=$oldOverride;Remove-Variable -Name RepairFixture -Scope Global -ErrorAction SilentlyContinue}
