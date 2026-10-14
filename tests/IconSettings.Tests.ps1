$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'Common.ps1')
function Assert($Condition,$Message){if(!$Condition){throw $Message}}
$fixture=Join-Path $script:DataRoot 'icon-settings-fixture'
[void][IO.Directory]::CreateDirectory($fixture)
$fixtureConfig=Join-Path $fixture 'settings.json'
$original=@{version=2;username='synthetic-icon-test';protectedPassword='synthetic-encrypted-marker';ssids=@('fixture-invalid-ssid');enabled=$false;showTaskbarIcon=$true;showTrayIcon=$true}
[IO.File]::WriteAllText($fixtureConfig,($original|ConvertTo-Json))
$oldOverride=$env:XIDIAN_CAMPUS_DATA
try{
    $env:XIDIAN_CAMPUS_DATA=$fixture
    foreach($phase in @('Hide','Reload','Restore')){
        $output=& (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -STA -File (Join-Path $projectRoot 'App.ps1') -ValidateIconSettings $phase
        Assert ($LASTEXITCODE -eq 0) ('Icon UI test failed: '+$phase)
        $report=$output -join "`n"|ConvertFrom-Json
        $hidden=$phase -ne 'Restore'
        Assert ($report.hideOptionPresent -and $report.hideOptionChecked -eq $hidden -and $report.storedHideTaskbarIcons -eq $hidden) ('Hide option did not persist: '+$phase)
        Assert ($report.showTaskbarIcon -eq !$hidden -and $report.configuredTrayVisible -eq !$hidden -and $report.individualOptionsEnabled -eq !$hidden) ('Icon visibility did not follow checkbox: '+$phase)
        Assert (!$report.windowVisible -and !$report.showTrayIcon) 'Validation exposed a window or tray icon'
        $stored=Get-Content -LiteralPath $fixtureConfig -Raw|ConvertFrom-Json
        Assert ($stored.username -eq $original.username -and $stored.protectedPassword -eq $original.protectedPassword -and !$stored.enabled -and $stored.ssids[0] -eq $original.ssids[0]) 'Icon setting changed account or authentication preferences'
        Assert ($stored.showTaskbarIcon -and $stored.showTrayIcon) 'Hide toggle discarded individual icon preferences'
    }
    Write-Output 'PASS: real WinForms checkbox hides both icons, saves immediately, survives a fresh UI process and restores preferences; account settings preserved. No visible test window or network request.'
}finally{$env:XIDIAN_CAMPUS_DATA=$oldOverride}
