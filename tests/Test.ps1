param([switch]$SkipUi)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$oldDataOverride = $env:XIDIAN_CAMPUS_DATA
$testData = Join-Path ([IO.Path]::GetTempPath()) ('XidianCampusLoginTest-' + [Guid]::NewGuid().ToString('N'))
$env:XIDIAN_CAMPUS_DATA = $testData
function Assert([bool]$Condition,[string]$Message) { if (!$Condition) { throw $Message } }
try {
    foreach ($file in Get-ChildItem -LiteralPath $projectRoot -Filter *.ps1 -Recurse) {
        $tokens=$null; $errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        Assert (!$errors.Count) ('PowerShell parse failed: ' + $file.Name)
    }
    . (Join-Path $projectRoot 'Common.ps1')
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
    if (!$SkipUi) {
        foreach ($scale in @(0.5,0.625,0.75,1.0)) {
            $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -STA -File (Join-Path $projectRoot 'App.ps1') -ValidateUi -UiScale $scale
            Assert ($LASTEXITCODE -eq 0) 'UI validation process failed'
            $report=$output -join "`n" | ConvertFrom-Json
            Assert ($report.passwordMasked -and $report.buttonsFit -and $report.footerVisible -and $report.taskbarOptionPresent -and $report.trayOptionPresent) ('UI layout validation failed at scale ' + $scale)
        }
    }
    Write-Output ('PASS: protocol vectors, redirect guards, settings migration, icon persistence, password encryption' + $(if(!$SkipUi){', UI layout sizes'}else{''}) + '. No campus login was submitted.')
} finally {
    $env:XIDIAN_CAMPUS_DATA=$oldDataOverride
    $resolved=[IO.Path]::GetFullPath($testData)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (!$resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'XidianCampusLoginTest-*') { throw 'Refusing to remove unexpected test path' }
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
