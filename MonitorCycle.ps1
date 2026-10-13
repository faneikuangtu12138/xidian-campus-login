function New-MonitorState {
    return @{fingerprint='';failures=0;nextAttempt=[DateTimeOffset]::MinValue;blockedRevision='';revision='';captiveChecks=0;lastCompleted=[DateTimeOffset]::Now;stage='start'}
}
function Reset-MonitorRetry($State) {
    $State.failures=0; $State.nextAttempt=[DateTimeOffset]::MinValue; $State.captiveChecks=0
}
function Get-MonitorWaitMilliseconds($State, $Result, [DateTimeOffset]$Now = [DateTimeOffset]::Now) {
    if ($Result.state -in @('ONLINE','WAITING','PAUSED','NEED_SETTINGS','ACCOUNT_ERROR')) { return -1 }
    if ($Result.state -eq 'NETWORK_ERROR' -and !$Result.ip) { return -1 }
    if ($Result.state -eq 'AUTH_RECHECK') { return 2000 }
    if ($State.nextAttempt -gt $Now) { return [int][Math]::Min(900000,[Math]::Max(1000,($State.nextAttempt-$Now).TotalMilliseconds)) }
    return 30000
}
function Update-MonitorResume($State,[DateTimeOffset]$Now = [DateTimeOffset]::Now) {
    if (($Now-$State.lastCompleted).TotalSeconds -gt 45) {
        Reset-MonitorRetry $State
        $State.fingerprint=''
        [void](Save-Status 'RESUMING' '电脑已恢复，正在重新检测校园网认证。' $null)
        return $true
    }
    return $false
}
function New-DirectNetwork($Adapter) {
    return [CampusLogin.DirectNetwork]::new($Adapter.index,$Adapter.ip,[string[]]$Adapter.dns)
}
function Test-PermanentAccountError($Answer) {
    # Only explicit account failures stop submissions. Unknown/gateway errors
    # must remain retryable rather than locking the app for the rest of the session.
    $names = @([string]$Answer.error,[string]$Answer.error_msg) -join '|'
    return ([string]$Answer.ecode -match '^E(?:2531|2553|2606|2616|2621|6501|6506|6508|6510)(?:\b|:)' -or $names -match '(^|\|)(password_error|username_error|user_not_exist|user_disabled|user_expired|user_must_modify_password|user_balance_not_enough|user_over_online_limit)(\||$)')
}
function Invoke-MonitorCycle($State,[switch]$Diagnose) {
    $net=$null; $adapter=$null
    try {
        $State.stage='settings'
        $settings=Read-Settings
        $retryPath=Join-Path $script:DataRoot 'retry.request'
        if (!$Diagnose -and (Test-Path -LiteralPath $retryPath)) {
            Remove-Item -LiteralPath $retryPath
            Reset-MonitorRetry $State; $State.blockedRevision=''
        }
        $revision=[string]$settings.username+'|'+[string]$settings.protectedPassword
        if ($revision -ne $State.revision) { Reset-MonitorRetry $State; $State.blockedRevision=''; $State.revision=$revision }
        if (!$settings.enabled -and !$Diagnose) { return Save-Status 'PAUSED' '自动登录已暂停。' $null }
        $State.stage='adapter'
        $adapter=Get-CampusAdapter $settings
        if (!$adapter) { $State.fingerprint=''; return Save-Status 'WAITING' '等待连接已配置的校园 Wi-Fi。' $null }
        $current="$($adapter.index)|$($adapter.ip)|$($adapter.gateway)|$($adapter.bssid)|$($adapter.dns -join ',')"
        if ($current -ne $State.fingerprint) { $State.fingerprint=$current; Reset-MonitorRetry $State }
        $net=New-DirectNetwork $adapter
        $State.stage='portal_dns'
        $portalIP=$net.Resolve('w.xidian.edu.cn').ToString()
        $State.stage='online_info'
        $info=Get-PortalJson $net '/cgi-bin/rad_user_info'
        $authenticated=($info.error -eq 'ok' -and $info.online_ip -eq $adapter.ip)
        $State.stage='internet_probe'
        $probe=@{online=$false;redirect='';captive=$false}
        try { $probe=Test-DirectInternet $net } catch { Write-SafeDiagnostic $State.stage $_.Exception }
        if ($probe.online) {
            Reset-MonitorRetry $State
            $message='校园网直连联网检测通过。'
            if (!$settings.protectedPassword) { $message+=' 请设置账号以启用掉线后自动认证。' }
            return Save-Status 'ONLINE' $message $adapter $portalIP
        }
        if ($authenticated -and !$probe.captive) {
            $State.captiveChecks=0
            return Save-Status 'NETWORK_LIMITED' '学校显示已认证，但直连外网检测未通过；正在持续检测网络恢复。' $adapter $portalIP
        }
        if ($authenticated -and $probe.captive) {
            $State.captiveChecks++
            if ($State.captiveChecks -lt 2) { return Save-Status 'AUTH_RECHECK' '检测到认证页跳转，正在核对学校的旧在线状态。' $adapter $portalIP }
        }
        if ($Diagnose) { return Save-Status 'AUTH_REQUIRED' '检测到校园网认证失效或认证页跳转。' $adapter $portalIP }
        if (!$settings.username -or !$settings.protectedPassword) { return Save-Status 'NEED_SETTINGS' '需要在本地设置账号和密码。' $adapter $portalIP }
        if ($State.blockedRevision -eq $revision) { return Save-Status 'ACCOUNT_ERROR' '学校明确拒绝此账号；请检查账号、密码、余额或在线设备限制，保存设置后重试。' $adapter $portalIP }
        if ([DateTimeOffset]::Now -lt $State.nextAttempt) { return Save-Status 'RETRY_WAIT' '认证未成功，正在等待下次重试。' $adapter $portalIP }
        $State.failures++
        $State.nextAttempt=[DateTimeOffset]::Now.AddSeconds([Math]::Min(900,30*[Math]::Pow(2,[Math]::Min($State.failures,5))))
        [void](Save-Status 'CONNECTING' '正在通过校园网卡直连认证。' $adapter $portalIP)
        $State.stage='portal_context'
        $startUrl=Get-SavedPortalRoute $adapter
        if ($probe.redirect) {
            $redirectUri=[Uri]$probe.redirect
            if ($redirectUri.IsAbsoluteUri -and $redirectUri.Host -eq 'w.xidian.edu.cn' -and (Test-ControllerUrl $probe.redirect)) { $startUrl=$probe.redirect; Save-PortalRoute $adapter $startUrl }
        }
        if (!$startUrl) {
            # Some controllers intercept HTTP IP destinations but leave the NCSI
            # hostname accessible or return only a generic notification page.
            $r=$net.Get('http://1.1.1.1/')
            try {
                $body=$r.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $location=if($r.Headers.Location){$r.Headers.Location.ToString()}else{''}
                $candidateUrl=Get-CaptivePortalRedirect $body $location
                if(Test-ControllerUrl $candidateUrl){$startUrl=$candidateUrl}
            } finally { $r.Dispose() }
            if ($startUrl) { Save-PortalRoute $adapter $startUrl }
        }
        if (!$startUrl) { return Save-Status 'PORTAL_REQUIRED' '暂未识别当前区域的学校认证入口，请从浏览器确认入口后重试。' $adapter $portalIP }
        $context=Get-PortalContext $net $startUrl
        if ($context.ip -ne $adapter.ip) { throw '学校识别的 IP 与校园网卡不一致，已取消本次认证。' }
        $State.stage='challenge'
        $challenge=Get-PortalJson $net '/cgi-bin/get_challenge' @{username=$settings.username;ip=$context.ip}
        if ($challenge.error -ne 'ok' -or !$challenge.challenge) { throw '学校未返回有效的认证令牌。' }
        $State.stage='credentials'
        $secure=ConvertTo-SecureString $settings.protectedPassword
        $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $password=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
            $fields=[CampusLogin.SrunCrypto]::Build($settings.username,$password,$context.ip,$context.acid,$challenge.challenge)
        } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer); $password=$null; $secure.Dispose() }
        $State.stage='login_submit'
        try { $answer=Get-PortalJson $net '/cgi-bin/srun_portal' $fields } finally { $fields.Clear(); $fields=$null }
        $safeResult=[ordered]@{updated=[DateTimeOffset]::Now.ToString('o');acid=$context.acid;error='unknown';ecode='unknown';errorName='unknown';successName='unknown'}
        if ([string]$answer.error -match '^(ok|fail|failed|error|[a-z_]+_error)$') { $safeResult.error=[string]$answer.error }
        $codeMatch=[regex]::Match([string]$answer.ecode,'E\d{4}|^\d{1,5}$')
        if ($codeMatch.Success) { $safeResult.ecode=$codeMatch.Value }
        if ([string]$answer.error_msg -match '^[a-z_]+(?:_error)?$') { $safeResult.errorName=[string]$answer.error_msg }
        if ([string]$answer.suc_msg -match '^[a-z_]+(?:_error)?$') { $safeResult.successName=[string]$answer.suc_msg }
        Write-JsonAtomic (Join-Path $script:DataRoot 'last-auth-result.json') $safeResult
        $alreadyOnline=(@([string]$answer.error_msg,[string]$answer.suc_msg) -contains 'ip_already_online_error')
        if ($alreadyOnline -and $probe.captive -and $info.online_ip -eq $adapter.ip -and $info.user_name -eq $settings.username) {
            # Match the school's reAuth behavior, scoped to this account/IP only.
            # A stale session must be removed before a fresh challenge/login.
            $State.stage='reset_own_session'
            [void](Get-PortalJson $net '/cgi-bin/srun_portal' @{action='logout';username=$settings.username;ip=$adapter.ip;ac_id=$context.acid})
            $State.nextAttempt=[DateTimeOffset]::Now.AddSeconds(10)
            return Save-Status 'SESSION_RESET' '正在更新已失效的校园网会话，随后重新认证。' $adapter $portalIP
        }
        $State.stage='login_verify'
        $check=@{online=$false}
        # The controller may acknowledge before its online table/firewall updates.
        # Give accepted requests a short verification window before backing off.
        $verifyCount=if($answer.error -eq 'ok'){4}else{1}
        for ($attempt=0;$attempt -lt $verifyCount;$attempt++) {
            if($attempt){Start-Sleep -Seconds 1}
            $verified=Get-PortalJson $net '/cgi-bin/rad_user_info'
            try { $check=Test-DirectInternet $net } catch { Write-SafeDiagnostic 'verify_probe' $_.Exception }
            if($check.online){break}
        }
        if ($check.online) {
            Reset-MonitorRetry $State
            return Save-Status 'ONLINE' '自动登录成功，直连联网检测通过。' $adapter $portalIP
        }
        if (Test-PermanentAccountError $answer) { $State.blockedRevision=$revision }
        if ($verified.error -eq 'ok' -and $verified.online_ip -eq $adapter.ip) {
            return Save-Status 'NETWORK_LIMITED' '认证接口已接受请求，但直连外网尚未恢复；正在继续检测。' $adapter $portalIP
        }
        return Save-Status 'LOGIN_FAILED' '学校尚未确认登录成功，将按退避间隔重试。' $adapter $portalIP
    } catch {
        Write-SafeDiagnostic $State.stage $_.Exception
        return Save-Status 'NETWORK_ERROR' '校园网直连接口暂不可用，等待网络稳定后再检测。' $adapter
    } finally { if ($net) { $net.Dispose() } }
}
