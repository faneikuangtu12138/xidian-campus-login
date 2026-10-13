# Isolated regression scenarios. All network operations are mocked; no live login.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'Common.ps1')
. (Join-Path $projectRoot 'MonitorCycle.ps1')
Add-Type -Path (Join-Path $projectRoot 'SrunCrypto.cs')
function Assert($Condition,$Message) { if (!$Condition) { throw $Message } }
$secure=ConvertTo-SecureString 'fixture-password' -AsPlainText -Force
try { $cipher=ConvertFrom-SecureString $secure } finally { $secure.Dispose() }
Write-JsonAtomic $script:ConfigPath @{ssids=@('stu-xdwlan');username='student-test';protectedPassword=$cipher;enabled=$true}
$script:FixtureAdapter=[pscustomobject]@{index=18;ip='192.0.2.100';gateway='192.0.2.1';bssid='00:11:22:33:44:55';dns=@('192.0.2.53');ssid='stu-xdwlan';alias='WLAN'}
function Get-CampusAdapter($Settings) { return $script:FixtureAdapter }
function New-DirectNetwork($Adapter) {
    $fake=[pscustomobject]@{}
    $fake | Add-Member ScriptMethod Resolve { param($hostName) return [Net.IPAddress]::Parse('192.0.2.53') }
    $fake | Add-Member ScriptMethod Dispose { }
    return $fake
}
$script:Authenticated=$false; $script:Internet=$false; $script:Captive=$true; $script:SubmitCount=0; $script:LogoutCount=0
$script:LoginSucceeds=$true; $script:LoginAnswer=@{error='ok';ecode='E0000'}; $script:BadContext=$false
function Test-DirectInternet($Net) { return @{online=$script:Internet;captive=$script:Captive;redirect=if($script:Captive){'http://w.xidian.edu.cn/srun_portal_pc?ac_id=1'}else{''}} }
function Get-PortalContext($Net,$StartUrl) { return @{acid='1';ip=if($script:BadContext){'192.0.2.200'}else{$script:FixtureAdapter.ip}} }
function Get-PortalJson($Net,$Path,$Fields=@{}) {
    switch ($Path) {
        '/cgi-bin/rad_user_info' { return @{error=if($script:Authenticated){'ok'}else{'not_online'};online_ip=$script:FixtureAdapter.ip;user_name='student-test'} }
        '/cgi-bin/get_challenge' { return @{error='ok';challenge='synthetic-challenge'} }
        '/cgi-bin/srun_portal' {
            if($Fields.action -eq 'logout'){$script:LogoutCount++;$script:Authenticated=$false;return @{error='ok'}}
            Assert ($Fields.action -eq 'login' -and $Fields.username -eq 'student-test') 'Login did not use fixture credentials'
            $script:SubmitCount++
            if ($script:LoginSucceeds) { $script:Authenticated=$true; $script:Internet=$true; $script:Captive=$false }
            return $script:LoginAnswer
        }
        default { throw 'Unexpected fixture endpoint' }
    }
}
# A normal offline transition must submit and verify the actual login result.
$state=New-MonitorState
$result=Invoke-MonitorCycle $state
Assert ($result.state -eq 'ONLINE' -and $script:SubmitCount -eq 1) 'Offline-to-online authentication failed'
[void](Invoke-MonitorCycle $state)
Assert ($script:SubmitCount -eq 1) 'Healthy connection submitted duplicate login'
# The same adapter/IP after a two-hour sleep must clear a 15-minute retry delay.
$script:Authenticated=$false; $script:Internet=$false; $script:Captive=$true
$state.failures=5; $state.nextAttempt=[DateTimeOffset]::Now.AddMinutes(15); $state.lastCompleted=[DateTimeOffset]::Now.AddHours(-2)
Assert (Update-MonitorResume $state) 'Sleep gap was not detected'
$result=Invoke-MonitorCycle $state
Assert ($result.state -eq 'ONLINE' -and $script:SubmitCount -eq 2) 'Resume retained the old retry delay'
# A stale school online flag and an explicit captive redirect are not ONLINE.
$script:Authenticated=$true; $script:Internet=$false; $script:Captive=$true
$result=Invoke-MonitorCycle $state
Assert ($result.state -eq 'AUTH_RECHECK') 'Stale online flag was accepted as internet connectivity'
$result=Invoke-MonitorCycle $state
Assert ($result.state -eq 'ONLINE' -and $script:SubmitCount -eq 3) 'Confirmed captive redirect did not recover'
# A failed probe without a captive redirect can be an upstream outage: no login storm.
$script:Authenticated=$true; $script:Internet=$false; $script:Captive=$false
$result=Invoke-MonitorCycle $state
Assert ($result.state -eq 'NETWORK_LIMITED' -and $script:SubmitCount -eq 3) 'Upstream outage triggered a login storm'
# Only an explicit already-online response plus a captive portal and matching
# current account permits replacing the stale session.
$state=New-MonitorState; $script:Authenticated=$true; $script:Captive=$true; $script:LoginSucceeds=$false
$script:LoginAnswer=@{error='ok';suc_msg='ip_already_online_error'}
[void](Invoke-MonitorCycle $state); $result=Invoke-MonitorCycle $state
Assert ($result.state -eq 'SESSION_RESET' -and $script:LogoutCount -eq 1 -and !$script:Authenticated) 'Stale own session was not renewed'
$state.nextAttempt=[DateTimeOffset]::MinValue; $script:LoginSucceeds=$true; $script:LoginAnswer=@{error='ok';suc_msg='login_ok'}
$result=Invoke-MonitorCycle $state
Assert ($result.state -eq 'ONLINE') 'Fresh authentication after session reset failed'
# A gateway failure must remain retryable, while an explicit account refusal stops.
$script:Authenticated=$false; $script:Internet=$false; $script:Captive=$true; $script:LoginSucceeds=$false
$script:LoginAnswer=@{error='gateway_error';ecode='E9999'}
$state=New-MonitorState; [void](Invoke-MonitorCycle $state)
Assert (!$state.blockedRevision) 'Unknown gateway failure permanently blocked the account'
Assert ($state.nextAttempt -gt [DateTimeOffset]::Now) 'Failed login has no retry backoff'
$state.nextAttempt=[DateTimeOffset]::MinValue; $script:LoginAnswer=@{error='password_error'}
[void](Invoke-MonitorCycle $state); $count=$script:SubmitCount
$result=Invoke-MonitorCycle $state
Assert ($result.state -eq 'ACCOUNT_ERROR' -and $script:SubmitCount -eq $count) 'Explicit account refusal was not blocked'
# An address mismatch must cancel before sending credentials and log no raw URL.
$state=New-MonitorState; $script:BadContext=$true
$result=Invoke-MonitorCycle $state
Assert ($result.state -eq 'NETWORK_ERROR' -and $script:SubmitCount -eq $count) 'Address mismatch submitted credentials'
Write-SafeDiagnostic 'fixture' ([InvalidOperationException]::new('secret https://w.xidian.edu.cn/?username=student-test&password=fixture-password'))
$log=Get-Content -LiteralPath (Join-Path $script:DataRoot 'diagnostic.log') -Raw
Assert ($log -notmatch 'student-test|fixture-password|https://') 'Diagnostic log leaked credential data'
Write-Output 'PASS: offline reauthentication, two-hour resume, stale online state, upstream outage, retry classification, address guard, safe diagnostics.'
