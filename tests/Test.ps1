param([switch]$SkipUi)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$oldDataOverride = $env:XIDIAN_CAMPUS_DATA
$testData = Join-Path ([IO.Path]::GetTempPath()) ('XidianCampusLoginTest-' + [Guid]::NewGuid().ToString('N'))
$env:XIDIAN_CAMPUS_DATA = $testData
function Assert([bool]$Condition,[string]$Message) { if (!$Condition) { throw $Message } }
try {
    $scripts = @(Get-ChildItem -LiteralPath $projectRoot -Filter *.ps1 -File) + @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1 -File)
    foreach ($file in $scripts) {
        $tokens=$null; $errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        Assert (!$errors.Count) ('PowerShell parse failed: ' + $file.Name)
    }
    # Legacy command-line bootstrap must still parse under Windows PowerShell 5.1.
    $bootstrap=Join-Path $projectRoot 'Launch.ps1'
    Assert (!([IO.File]::ReadAllBytes($bootstrap) | Where-Object { $_ -gt 127 })) 'Bootstrap must remain ASCII for Windows PowerShell 5.1'
    $resolvedRuntime = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File $bootstrap -CheckRuntime
    Assert ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath ([string]$resolvedRuntime))) 'Windows PowerShell 5.1 startup entry failed'
    . (Join-Path $projectRoot 'Common.ps1')
    & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'SilentStart.Tests.ps1')
    Assert ($LASTEXITCODE -eq 0) 'Silent startup regression tests failed'
    & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'EventMode.Tests.ps1')
    Assert ($LASTEXITCODE -eq 0) 'Event mode regression tests failed'
    & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'Repair.Tests.ps1')
    Assert ($LASTEXITCODE -eq 0) 'Repair installation regression tests failed'
    Add-Type -Path (Join-Path $projectRoot 'DirectNetwork.cs')
    Add-Type -Path (Join-Path $projectRoot 'SrunCrypto.cs')
    $vectors=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'protocol-vectors.json') -Raw | ConvertFrom-Json
    foreach ($vector in $vectors) {
        $vectorInput=$vector.input
        $result=[CampusLogin.SrunCrypto]::Build($vectorInput.username,$vectorInput.password,$vectorInput.ip,$vectorInput.acid,$vectorInput.token)
        foreach ($field in @('info','password','chksum')) { Assert ($result[$field] -ceq $vector.actual.$field) ('SRun protocol mismatch: ' + $field) }
    }
    $parsed=Convert-PortalJson 'campus({"error":"ok","online_ip":"192.0.2.100"});'
    Assert ($parsed.error -eq 'ok') 'JSONP parser failed'
    $redirect=Get-CaptivePortalRedirect '<html><script>window.location="http://w.xidian.edu.cn/srun_portal_pc?ac_id=8&amp;theme=pro";</script></html>'
    Assert ($redirect -eq 'http://w.xidian.edu.cn/srun_portal_pc?ac_id=8&theme=pro') 'HTTP 200 captive page lost the real controller ID'
    $redirect=Get-CaptivePortalRedirect 'location="http:\/\/w.xidian.edu.cn\/srun_portal_pc?ac_id=8"'
    Assert ($redirect -match 'ac_id=8') 'Escaped JavaScript captive URL was not parsed'
    $redirect=Get-CaptivePortalRedirect 'location="http://w.xidian.edu.cn?ac_id=8"'
    Assert ($redirect -match 'ac_id=8') 'Captive URL without a slash lost its controller ID'
    $redirect=Get-CaptivePortalRedirect '<html><body><form name="CMCCWLANFORM" method="post" action="https://w.xidian.edu.cn/index_8.html"></form><script>CMCCWLANFORM.submit();</script></body></html>'
    Assert ($redirect -eq 'https://w.xidian.edu.cn/index_8.html') 'School HTTP 200 auto-submit form lost controller 8'
    Assert (!(Get-CaptivePortalRedirect '' 'https://w.xidian.edu.cn.evil.example/')) 'Lookalike captive host accepted'
    $routeAdapter=[pscustomobject]@{ssid='stu-xdwlan';gateway='192.0.2.1';ip='192.0.2.100';bssid='00:11:22:33:44:55'}
    Save-PortalRoute $routeAdapter 'https://w.xidian.edu.cn/srun_portal_success?ac_id=8&theme=pro'
    Assert ((Get-SavedPortalRoute $routeAdapter) -eq 'https://w.xidian.edu.cn/srun_portal_pc?ac_id=8') 'Verified controller route was not saved'
    Save-PortalRoute $routeAdapter 'https://w.xidian.edu.cn/index_9.html'
    Assert ((Get-SavedPortalRoute $routeAdapter) -eq 'https://w.xidian.edu.cn/srun_portal_pc?ac_id=9') 'Controller index page was not persisted'
    $routeAdapter.bssid='00:11:22:33:44:66'
    Assert ([bool](Get-SavedPortalRoute $routeAdapter)) 'Roaming within the same IP network discarded the verified controller'
    $routeAdapter.ip='192.0.2.200'
    Assert (!(Get-SavedPortalRoute $routeAdapter)) 'IP change reused an unverified controller route'
    $fakeNet=[pscustomobject]@{}
    $fakeNet | Add-Member ScriptMethod Get {
        param($url)
        $script:FixtureUrl=$url
        $r=[Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
        $r.Content=[Net.Http.StringContent]::new('campus({"error":"ok"});')
        return $r
    }
    [void](Get-PortalJson $fakeNet '/cgi-bin/get_challenge' @{username='student-test';ip='192.0.2.100'})
    Assert ($script:FixtureUrl -match '[?&]_=\d{13}(?:&|$)' -and $script:FixtureUrl -notmatch '[?&]_=(&|$)') 'JSONP cache-busting timestamp was empty'
    foreach ($url in @('https://example.com/phishing','https://w.xidian.edu.cn:444/','https://user@w.xidian.edu.cn/')) {
        $blocked=$false
        try { Get-PortalContext $null $url } catch { $blocked=$_.Exception.Message -eq '认证跳转地址不在学校白名单中。' }
        Assert $blocked 'Untrusted portal redirect was not rejected'
    }
    Write-JsonAtomic $script:ConfigPath @{version=1;username='student-test';protectedPassword='';ssids=@('stu-xdwlan');enabled=$true}
    $migrated=Read-Settings
    Assert ($migrated.showTaskbarIcon -and $migrated.showTrayIcon) 'Legacy settings migration failed'
    $migrated.showTaskbarIcon=$false; $migrated.showTrayIcon=$false
    Write-JsonAtomic $script:ConfigPath $migrated
    $reloaded=Read-Settings
    Assert (!$reloaded.showTaskbarIcon -and !$reloaded.showTrayIcon) 'Icon preferences were not persisted'
    $secure=ConvertTo-SecureString 'synthetic-password-only' -AsPlainText -Force
    try { $protected=ConvertFrom-SecureString $secure } finally { $secure.Dispose() }
    $decoded=ConvertTo-SecureString $protected
    $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($decoded)
    try { Assert ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) -ceq 'synthetic-password-only') 'Windows password encryption failed' } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer); $decoded.Dispose() }
    & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'Monitor.Tests.ps1')
    Assert ($LASTEXITCODE -eq 0) 'Monitor recovery regression tests failed'
    if (!$SkipUi) {
        foreach ($scale in @(0.5,0.625,0.75,1.0)) {
            $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -STA -File (Join-Path $projectRoot 'App.ps1') -ValidateUi -UiScale $scale
            Assert ($LASTEXITCODE -eq 0) 'UI validation process failed'
            $report=$output -join "`n" | ConvertFrom-Json
            Assert ($report.passwordMasked -and $report.buttonsFit -and $report.footerVisible -and $report.taskbarOptionPresent -and $report.trayOptionPresent) ('UI layout validation failed at scale ' + $scale)
        }
    }
    Write-Output ('PASS: Windows PowerShell 5.1 bootstrap, protocol vectors, redirect guards, settings migration, icon persistence, password encryption' + $(if(!$SkipUi){', UI layout sizes'}else{''}) + '. No campus login was submitted.')
} finally {
    $env:XIDIAN_CAMPUS_DATA=$oldDataOverride
    $resolved=[IO.Path]::GetFullPath($testData)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (!$resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'XidianCampusLoginTest-*') { throw 'Refusing to remove unexpected test path' }
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
