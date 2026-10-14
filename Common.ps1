$ErrorActionPreference = 'Stop'
$script:ProgramRoot = $PSScriptRoot
$script:DataRoot = if ($env:XIDIAN_CAMPUS_DATA) { [IO.Path]::GetFullPath($env:XIDIAN_CAMPUS_DATA) } else { Join-Path $PSScriptRoot 'data' }
$script:ConfigPath = Join-Path $script:DataRoot 'settings.json'
$script:StatusPath = Join-Path $script:DataRoot 'status.json'
$script:LogPath = Join-Path $script:DataRoot 'activity.log'
[void][IO.Directory]::CreateDirectory($script:DataRoot)
if (!('CampusLogin.BackgroundProcess' -as [type])) { Add-Type -Path (Join-Path $script:ProgramRoot 'BackgroundProcess.cs') }
if (!('CampusLogin.ActivitySignals' -as [type])) { Add-Type -Path (Join-Path $script:ProgramRoot 'ActivitySignals.cs') }
function Start-BackgroundProcess([string]$FilePath, [string]$Arguments) {
    return [CampusLogin.BackgroundProcess]::Start($FilePath, $Arguments, $script:ProgramRoot)
}
function Get-AppMutexName([string]$Name) {
    return [CampusLogin.BackgroundProcess]::MutexName($Name,$script:ProgramRoot,$script:DataRoot)
}
function Write-JsonAtomic($Path, $Value) {
    $temp = $Path + '.' + $PID + '.tmp'
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp, $Path, $true)
}
function Read-Settings {
    $defaults = [ordered]@{ ssids = @('stu-xdwlan'); username = ''; protectedPassword = ''; enabled = $true; hideTaskbarIcons = $false; showTaskbarIcon = $true; showTrayIcon = $true; version = 3 }
    if (Test-Path -LiteralPath $script:ConfigPath) {
        $stored = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
        foreach ($property in $stored.PSObject.Properties) { $defaults[$property.Name] = $property.Value }
    }
    return [pscustomobject]$defaults
}
function Save-IconPreferences([bool]$HideTaskbarIcons, [bool]$ShowTaskbarIcon, [bool]$ShowTrayIcon) {
    $fresh = Read-Settings
    $fresh.version = 3
    $fresh.hideTaskbarIcons = $HideTaskbarIcons
    $fresh.showTaskbarIcon = $ShowTaskbarIcon
    $fresh.showTrayIcon = $ShowTrayIcon
    Write-JsonAtomic $script:ConfigPath $fresh
}
function Set-Autostart([bool]$Enabled) {
    $startupPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'XidianCampusLogin.lnk'
    $taskName = 'XidianCampusLogin-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($Enabled) {
        $launcher = Join-Path $script:ProgramRoot 'CampusLogin.exe'
        if (!(Test-Path -LiteralPath $launcher)) { throw 'Silent launcher is missing. Run Build-Launcher.ps1 or Install.ps1 first.' }
        [CampusLogin.BackgroundProcess]::SaveShortcut($startupPath,$launcher,'--background',$script:ProgramRoot,'西电校园网自动登录（后台启动）')
        # OS triggers only; there is no calendar/repetition trigger. Task Scheduler
        # restarts a failed supervisor without launching an idle keepalive process.
        $escape = { param($text) [Security.SecurityElement]::Escape([string]$text) }
        $sid = & $escape ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $command = & $escape $launcher
        $arguments = '--supervise'
        $directory = & $escape $script:ProgramRoot
        $subscription = & $escape '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[(Provider[@Name="Microsoft-Windows-Power-Troubleshooter"] and EventID=1) or (Provider[@Name="Microsoft-Windows-Kernel-Power"] and EventID=107)]]</Select></Query></QueryList>'
        $xml = @"
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled><UserId>$sid</UserId></LogonTrigger>
    <EventTrigger><Enabled>true</Enabled><Subscription>$subscription</Subscription></EventTrigger>
  </Triggers>
  <Principals><Principal id="CurrentUser"><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><AllowHardTerminate>true</AllowHardTerminate><AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>true</Hidden><WakeToRun>false</WakeToRun><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure></Settings>
  <Actions Context="CurrentUser"><Exec><Command>$command</Command><Arguments>$arguments</Arguments><WorkingDirectory>$directory</WorkingDirectory></Exec></Actions>
</Task>
"@
        try {
            [void](Register-ScheduledTask -TaskName $taskName -Xml $xml -Force -ErrorAction Stop)
            Write-JsonAtomic (Join-Path $script:DataRoot 'autostart-state.json') @{mode='ScheduledTaskAndStartup';task=$taskName;updated=[DateTimeOffset]::Now.ToString('o')}
        } catch {
            # Non-admin machines may forbid registering tasks. The fixed startup
            # entry still starts the supervisor; expose the reduced recovery mode.
            Write-JsonAtomic (Join-Path $script:DataRoot 'autostart-state.json') @{mode='StartupOnly';error=$_.Exception.GetType().Name;updated=[DateTimeOffset]::Now.ToString('o')}
            [IO.File]::AppendAllText((Join-Path $script:DataRoot 'startup.log'),([DateTimeOffset]::Now.ToString('o')+' TASK_REGISTRATION_FAILED type='+$_.Exception.GetType().Name+"`r`n"))
        }
    } else {
        if (Test-Path -LiteralPath $startupPath) { Remove-Item -LiteralPath $startupPath }
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop }
    }
}
function Get-CampusAdapter($Settings) {
    # The SSID comparison prevents submitting credentials on hotel/home Wi-Fi.
    $wlan = [CampusLogin.BackgroundProcess]::Capture("$env:SystemRoot\System32\netsh.exe", 'wlan show interfaces', $script:ProgramRoot, 8000)
    $ssidMatch = [regex]::Match($wlan, '(?m)^\s*SSID\s*:\s*(.+?)\s*$')
    $ssid = if ($ssidMatch.Success) { $ssidMatch.Groups[1].Value.Trim() } else { '' }
    $guidMatch = [regex]::Match($wlan, '(?im)^\s*GUID\s*:\s*([a-f0-9-]+)\s*$')
    $bssidMatch = [regex]::Match($wlan, '(?im)^\s*(?:AP )?BSSID\s*:\s*(.+?)\s*$')
    foreach ($adapter in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')) {
        # NLA may rename a profile after roaming; prefer the actual WLAN SSID and GUID.
        if (!$ssid -or $ssid -notin @($Settings.ssids) -or !$guidMatch.Success) { continue }
        if ([Guid]$adapter.InterfaceGuid -ne [Guid]$guidMatch.Groups[1].Value) { continue }
        $config = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex
        $address = $config.IPv4Address | Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
        $dns = @($config.DNSServer.ServerAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
        if (!$address -or !$config.IPv4DefaultGateway -or !$dns.Count) { continue }
        return [pscustomobject]@{ index = [int]$adapter.ifIndex; alias = $adapter.Name; ip = $address.IPAddress; dns = $dns; gateway = $config.IPv4DefaultGateway.NextHop; ssid = $ssid; bssid = $bssidMatch.Groups[1].Value.Trim() }
    }
    return $null
}
function Convert-PortalJson([string]$Text) {
    $clean = $Text.Trim()
    if ($clean.StartsWith('campus(') -and $clean -match '^campus\((.*)\)\s*;?\s*$') { $clean = $Matches[1] }
    return $clean | ConvertFrom-Json
}
function Get-PortalJson($Net, [string]$Path, $Fields = @{}) {
    $pairs = @('callback=campus', ('_=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()))
    foreach ($key in $Fields.Keys) { $pairs += [Uri]::EscapeDataString([string]$key) + '=' + [Uri]::EscapeDataString([string]$Fields[$key]) }
    $response = $Net.Get('https://w.xidian.edu.cn' + $Path + '?' + ($pairs -join '&'))
    try {
        if (!$response.IsSuccessStatusCode) { throw '校园网接口返回异常状态。' }
        return Convert-PortalJson $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } finally { $response.Dispose() }
}
function Get-PortalContext($Net, [string]$StartUrl = 'https://w.xidian.edu.cn/') {
    $uri = [Uri]$StartUrl
    for ($step = 0; $step -lt 6; $step++) {
        if ($uri.Host -ne 'w.xidian.edu.cn' -or $uri.Port -notin @(80,443) -or $uri.UserInfo) { throw '认证跳转地址不在学校白名单中。' }
        if ($uri.Scheme -eq 'http') { $uri = [Uri]('https://w.xidian.edu.cn' + $uri.PathAndQuery) }
        $r = $Net.Get($uri.AbsoluteUri)
        try {
            if ([int]$r.StatusCode -in @(301,302,303,307,308) -and $r.Headers.Location) { $uri = [Uri]::new($uri,$r.Headers.Location); continue }
            if (!$r.IsSuccessStatusCode) { throw '无法读取校园网认证页面。' }
            $html = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $acid = [regex]::Match($html, '\bacid\s*:\s*["''](\d+)["'']')
            $ip = [regex]::Match($html, '\bip\s*:\s*["''](\d+\.\d+\.\d+\.\d+)["'']')
            if ($acid.Success -and $ip.Success) { return @{ acid = $acid.Groups[1].Value; ip = $ip.Groups[1].Value } }
            $refresh = [regex]::Match($html, '(?i)content=["''][^"'']*url=([^"'']+)')
            if ($refresh.Success) { $uri = [Uri]::new($uri,[Net.WebUtility]::HtmlDecode($refresh.Groups[1].Value)); continue }
            throw '认证页格式已变化，请检查学校认证页面。'
        } finally { $r.Dispose() }
    }
    throw '校园网认证跳转次数过多。'
}
function Get-CaptivePortalRedirect([string]$Body,[string]$Location = '') {
    $headerUrl=''
    if ($Location) {
        $uri=$null
        if ([Uri]::TryCreate($Location,[UriKind]::Absolute,[ref]$uri) -and $uri.Host -eq 'w.xidian.edu.cn' -and $uri.Port -in @(80,443) -and !$uri.UserInfo) { $headerUrl=$uri.AbsoluteUri; if(Test-ControllerUrl $headerUrl){return $headerUrl} }
    }
    $text=[Net.WebUtility]::HtmlDecode($Body).Replace('\/','/')
    try { $text=[Uri]::UnescapeDataString($text) } catch { }
    $matches=[regex]::Matches($text,'(?i)https?://w\.xidian\.edu\.cn(?::(?:80|443))?(?=[/?#\s"''<>]|$)[^\s"''<>\\]*')
    foreach($match in $matches){$candidate=$match.Value.TrimEnd(')', ';');if(Test-ControllerUrl $candidate){return $candidate}}
    if($headerUrl){return $headerUrl}
    if($matches.Count){return $matches[0].Value.TrimEnd(')', ';')}
    return ''
}
function Test-ControllerUrl([string]$Url) {
    return $Url -match '(?:[?&]ac_id=\d+(?:&|$)|/index_\d+\.html(?:[?]|$))'
}
function Get-AdapterRouteKey($Adapter) {
    # Neighboring Wi-Fi APs may roam without changing the assigned IP/controller.
    # A fresh captive redirect always takes precedence; a changed IP/gateway
    # invalidates this fallback instead of copying it to a different region.
    $identity=$Adapter.ssid+'|'+$Adapter.gateway+'|'+$Adapter.ip
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity)))
}
function Save-PortalRoute($Adapter,[string]$Url) {
    $uri=[Uri]$Url
    if ($uri.Host -ne 'w.xidian.edu.cn' -or $uri.Port -notin @(80,443) -or $uri.UserInfo) { return }
    $match=[regex]::Match($uri.Query,'(?:^|[?&])ac_id=(\d+)(?:&|$)')
    if (!$match.Success) { $match=[regex]::Match($uri.AbsolutePath,'^/index_(\d+)\.html$') }
    if (!$match.Success) { return }
    $path=Join-Path $script:DataRoot 'portal-route.json'
    # Strip everything except the controller ID; do not persist redirect tokens.
    Write-JsonAtomic $path @{key=(Get-AdapterRouteKey $Adapter);url=('https://w.xidian.edu.cn/srun_portal_pc?ac_id='+$match.Groups[1].Value);updated=[DateTimeOffset]::Now.ToString('o')}
}
function Get-SavedPortalRoute($Adapter) {
    try {
        $route=Get-Content -LiteralPath (Join-Path $script:DataRoot 'portal-route.json') -Raw | ConvertFrom-Json
        if ($route.key -eq (Get-AdapterRouteKey $Adapter)) { return [string]$route.url }
    } catch { }
    return ''
}
function Test-DirectInternet($Net) {
    $r = $Net.Get('http://www.msftconnecttest.com/connecttest.txt')
    try {
        $body = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult().Trim()
        $location = if ($r.Headers.Location) { $r.Headers.Location.ToString() } else { '' }
        $redirect = Get-CaptivePortalRedirect $body $location
        $captive = ([bool]$redirect -or $body -match '(?i)(?:https?://)?w\.xidian\.edu\.cn(?:/|["''])')
        return @{ online = ([int]$r.StatusCode -eq 200 -and $body -eq 'Microsoft Connect Test'); redirect = $redirect; captive = $captive }
    } finally { $r.Dispose() }
}
function Write-SafeDiagnostic([string]$Stage, $Exception) {
    # Never log exception messages, response bodies, usernames or request URLs.
    $types = @(); $socketCode = ''
    for ($inner = $Exception; $inner -and $types.Count -lt 6; $inner = $inner.InnerException) {
        $types += $inner.GetType().Name
        if ($inner -is [Net.Sockets.SocketException]) { $socketCode = [string]$inner.SocketErrorCode }
    }
    $path = Join-Path $script:DataRoot 'diagnostic.log'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 524288) { [IO.File]::WriteAllText($path,'') }
    [IO.File]::AppendAllText($path,([DateTimeOffset]::Now.ToString('o')+' stage='+$Stage+' types='+($types -join '>')+' socket='+$socketCode+"`r`n"))
}
function Save-Status([string]$State, [string]$Message, $Adapter, [string]$PortalIP = '') {
    $status = [ordered]@{ state = $State; message = $Message; updated = [DateTimeOffset]::Now.ToString('o'); pid = $PID; ssid = ''; adapter = ''; ip = ''; portalIP = $PortalIP }
    if ($Adapter) { $status.ssid = $Adapter.ssid; $status.adapter = $Adapter.alias; $status.ip = $Adapter.ip }
    Write-JsonAtomic $script:StatusPath $status
    if ($script:PreviousStatus -ne ($State + '|' + $Message)) {
        if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -gt 524288) { [IO.File]::WriteAllText($script:LogPath,'') }
        [IO.File]::AppendAllText($script:LogPath, ([DateTimeOffset]::Now.ToString('o') + ' ' + $State + ' ' + $Message + "`r`n"))
        $script:PreviousStatus = $State + '|' + $Message
    }
    return [pscustomobject]$status
}
