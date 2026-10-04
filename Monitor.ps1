param([switch]$Once, [switch]$Diagnose)
. "$PSScriptRoot\Common.ps1"
Add-Type -Path "$PSScriptRoot\DirectNetwork.cs"
Add-Type -Path "$PSScriptRoot\SrunCrypto.cs"
$mutex = [Threading.Mutex]::new($false,'Local\XidianCampusLoginWorker')
$locked = $false
try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
if (!$locked) { $mutex.Dispose(); exit 0 }
$script:PreviousStatus = ''
$fingerprint = ''; $failures = 0; $nextAttempt = [DateTimeOffset]::MinValue; $blockedPassword = ''; $lastRevision = ''
try {
    do {
        if (!$Once -and !$Diagnose -and (Test-Path -LiteralPath (Join-Path $script:DataRoot 'stop.request'))) { break }
        $net = $null; $adapter = $null
        try {
            $settings = Read-Settings
            $retryPath = Join-Path $script:DataRoot 'retry.request'
            if (!$Diagnose -and (Test-Path -LiteralPath $retryPath)) {
                Remove-Item -LiteralPath $retryPath
                $blockedPassword = ''; $failures = 0; $nextAttempt = [DateTimeOffset]::MinValue
            }
            $revision = [string]$settings.username + '|' + [string]$settings.protectedPassword
            if ($revision -ne $lastRevision) { $blockedPassword = ''; $failures = 0; $nextAttempt = [DateTimeOffset]::MinValue; $lastRevision = $revision }
            if (!$settings.enabled -and !$Diagnose) { $result = Save-Status 'PAUSED' '自动登录已暂停。' $null }
            else {
                $adapter = Get-CampusAdapter $settings
                if (!$adapter) { $result = Save-Status 'WAITING' '等待连接已配置的校园 Wi-Fi。' $null }
                else {
                    $current = "$($adapter.index)|$($adapter.ip)|$($adapter.gateway)|$($adapter.bssid)|$($adapter.dns -join ',')"
                    if ($current -ne $fingerprint) { $fingerprint = $current; $failures = 0; $nextAttempt = [DateTimeOffset]::MinValue }
                    $net = [CampusLogin.DirectNetwork]::new($adapter.index,$adapter.ip,[string[]]$adapter.dns)
                    $portalIP = $net.Resolve('w.xidian.edu.cn').ToString()
                    $info = Get-PortalJson $net '/cgi-bin/rad_user_info'
                    $authenticated = ($info.error -eq 'ok' -and $info.online_ip -eq $adapter.ip)
                    $probe = @{ online = $false; redirect = '' }
                    if ($authenticated -or $Diagnose) { try { $probe = Test-DirectInternet $net } catch { } }
                    if ($authenticated) {
                        $failures = 0
                        $message = if ($probe.online) { '校园网已登录，直连联网检测通过。' } else { '校园网已登录，外网检测暂未通过；等待网络恢复。' }
                        if (!$settings.protectedPassword) { $message += ' 请设置账号以启用掉线后自动认证。' }
                        $result = Save-Status 'ONLINE' $message $adapter $portalIP
                    } elseif ($Diagnose) { $result = Save-Status 'AUTH_REQUIRED' '学校认证服务器确认当前 IP 尚未登录。' $adapter $portalIP }
                    elseif (!$settings.username -or !$settings.protectedPassword) { $result = Save-Status 'NEED_SETTINGS' '需要在本地设置账号和密码。' $adapter $portalIP }
                    elseif ($blockedPassword -eq $revision) { $result = Save-Status 'ACCOUNT_ERROR' '认证被学校拒绝；请检查账号、密码、余额或在线设备限制，保存设置后重试。' $adapter $portalIP }
                    elseif ([DateTimeOffset]::Now -lt $nextAttempt) { $result = Save-Status 'RETRY_WAIT' '认证未成功，正在等待下次重试。' $adapter $portalIP }
                    else {
                        $failures++
                        $nextAttempt = [DateTimeOffset]::Now.AddSeconds([Math]::Min(900,30 * [Math]::Pow(2,[Math]::Min($failures,5))))
                        [void](Save-Status 'CONNECTING' '正在通过校园网卡直连认证。' $adapter $portalIP)
                        if (!$probe.redirect) { try { $probe = Test-DirectInternet $net } catch { } }
                        $startUrl = 'https://w.xidian.edu.cn/'
                        if ($probe.redirect) {
                            $redirectUri = [Uri]$probe.redirect
                            if ($redirectUri.IsAbsoluteUri -and $redirectUri.Host -eq 'w.xidian.edu.cn') { $startUrl = $probe.redirect }
                        }
                        $context = Get-PortalContext $net $startUrl
                        if ($context.ip -ne $adapter.ip) { throw '学校识别的 IP 与校园网卡不一致，已取消本次认证。' }
                        $challenge = Get-PortalJson $net '/cgi-bin/get_challenge' @{ username = $settings.username; ip = $context.ip }
                        if ($challenge.error -ne 'ok' -or !$challenge.challenge) { throw '学校未返回有效的认证令牌。' }
                        $secure = ConvertTo-SecureString $settings.protectedPassword
                        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
                        try {
                            $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
                            $fields = [CampusLogin.SrunCrypto]::Build($settings.username,$password,$context.ip,$context.acid,$challenge.challenge)
                        } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer); $password = $null; $secure.Dispose() }
                        try { $answer = Get-PortalJson $net '/cgi-bin/srun_portal' $fields } finally { $fields.Clear(); $fields = $null }
                        # Never equate an HTTP 200 or a login response with actual connectivity.
                        $verified = Get-PortalJson $net '/cgi-bin/rad_user_info'
                        if ($verified.error -eq 'ok' -and $verified.online_ip -eq $adapter.ip) {
                            $failures = 0
                            $check = @{ online = $false }
                            try { $check = Test-DirectInternet $net } catch { }
                            $result = Save-Status 'ONLINE' $(if ($check.online) { '自动登录成功，直连联网检测通过。' } else { '认证成功，等待外网恢复。' }) $adapter $portalIP
                        } else {
                            $code = [string]$answer.ecode
                            $errorName = [string]$answer.error_msg
                            $transient = $errorName -match 'no_response|not_online|timeout|busy|ip_already_online'
                            if (!$transient -and (($code -and $code -ne 'E0000') -or ($answer.error -and $answer.error -ne 'ok'))) { $blockedPassword = $revision }
                            $result = Save-Status 'LOGIN_FAILED' '学校尚未确认登录成功，将按退避间隔重试；账号错误会暂停重试。' $adapter $portalIP
                        }
                    }
                }
            }
        } catch {
            # Exception messages can contain authentication URLs. Do not store raw exceptions.
            $result = Save-Status 'NETWORK_ERROR' '校园网直连接口暂不可用，等待网络稳定后再检测。' $adapter
        } finally { if ($net) { $net.Dispose() } }
        if ($Once -or $Diagnose) { $result | ConvertTo-Json; break }
        Start-Sleep -Seconds 15
    } while ($true)
} finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
