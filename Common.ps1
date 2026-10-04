$ErrorActionPreference = 'Stop'
$script:ProgramRoot = $PSScriptRoot
$script:DataRoot = if ($env:XIDIAN_CAMPUS_DATA) { [IO.Path]::GetFullPath($env:XIDIAN_CAMPUS_DATA) } else { Join-Path $PSScriptRoot 'data' }
$script:ConfigPath = Join-Path $script:DataRoot 'settings.json'
$script:StatusPath = Join-Path $script:DataRoot 'status.json'
$script:LogPath = Join-Path $script:DataRoot 'activity.log'
[void][IO.Directory]::CreateDirectory($script:DataRoot)
function Write-JsonAtomic($Path, $Value) {
    $temp = $Path + '.' + $PID + '.tmp'
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp, $Path, $true)
}
function Read-Settings {
    $defaults = [ordered]@{ ssids = @('stu-xdwlan'); username = ''; protectedPassword = ''; enabled = $true; showTaskbarIcon = $true; showTrayIcon = $true; version = 2 }
    if (Test-Path -LiteralPath $script:ConfigPath) {
        $stored = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
        foreach ($property in $stored.PSObject.Properties) { $defaults[$property.Name] = $property.Value }
    }
    return [pscustomobject]$defaults
}
function Set-Autostart([bool]$Enabled) {
    $startupPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'XidianCampusLogin.lnk'
    if ($Enabled) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($startupPath)
        $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $shortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script:ProgramRoot + '\Launch.ps1" -Background'
        $shortcut.WorkingDirectory = $script:ProgramRoot
        $shortcut.WindowStyle = 7
        $shortcut.Description = '西电校园网自动登录（后台启动）'
        $shortcut.Save()
    } elseif (Test-Path -LiteralPath $startupPath) { Remove-Item -LiteralPath $startupPath }
}
function Get-CampusAdapter($Settings) {
    # The SSID comparison prevents submitting credentials on hotel/home Wi-Fi.
    $wlan = (& "$env:SystemRoot\System32\netsh.exe" wlan show interfaces 2>$null) -join "`n"
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
    $pairs = @('callback=campus', '_=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
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
function Test-DirectInternet($Net) {
    $r = $Net.Get('http://www.msftconnecttest.com/connecttest.txt')
    try {
        $body = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult().Trim()
        return @{ online = ([int]$r.StatusCode -eq 200 -and $body -eq 'Microsoft Connect Test'); redirect = if ($r.Headers.Location) { $r.Headers.Location.ToString() } else { '' } }
    } finally { $r.Dispose() }
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
