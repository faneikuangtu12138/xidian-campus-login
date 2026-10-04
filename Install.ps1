param([string]$Destination = $PSScriptRoot, [switch]$Background, [switch]$NoLaunch)
$ErrorActionPreference = 'Stop'
$destinationRoot = [IO.Path]::GetFullPath($Destination)
[void][IO.Directory]::CreateDirectory($destinationRoot)
$files = @('DirectNetwork.cs','SrunCrypto.cs','Common.ps1','Monitor.ps1','App.ps1','Launch.ps1','Start.cmd','README.md','Install.ps1','.gitignore','.gitattributes')
if ([IO.Path]::GetFullPath($PSScriptRoot) -ne $destinationRoot) {
    foreach ($name in $files) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $destinationRoot $name) -Force }
    foreach ($directory in @('tests','docs')) {
        if (Test-Path -LiteralPath (Join-Path $PSScriptRoot $directory)) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $directory) -Destination $destinationRoot -Recurse -Force }
    }
}
. (Join-Path $destinationRoot 'Common.ps1')
$legacyData = Join-Path $env:LOCALAPPDATA 'XidianCampusLogin'
if (!(Test-Path -LiteralPath $script:ConfigPath) -and (Test-Path -LiteralPath (Join-Path $legacyData 'settings.json'))) {
    foreach ($name in @('settings.json','activity.log')) {
        $source = Join-Path $legacyData $name
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $script:DataRoot $name) }
    }
}
# Restrict account data to this Windows user, SYSTEM and local administrators.
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true,$false)
$inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl',$inherit,'None','Allow')
    [void]$acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $script:DataRoot -AclObject $acl
$settings = Read-Settings; $settings.version=2; $settings.enabled=$true
Write-JsonAtomic $script:ConfigPath $settings
$shell = New-Object -ComObject WScript.Shell
function Write-AppShortcut([string]$Path) {
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $destinationRoot + '\Launch.ps1"'
    $shortcut.WorkingDirectory = $destinationRoot; $shortcut.WindowStyle=7
    $shortcut.Description = '西电校园网自动登录 · 打开设置'; $shortcut.Save()
}
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) '西电校园网自动登录.lnk'
$menuFolder = Join-Path ([Environment]::GetFolderPath('Programs')) '西电校园网自动登录'
[void][IO.Directory]::CreateDirectory($menuFolder)
$menuShortcut = Join-Path $menuFolder '西电校园网自动登录.lnk'
Write-AppShortcut $desktopShortcut; Write-AppShortcut $menuShortcut
Set-Autostart $true
[pscustomobject]@{installed=$destinationRoot;dataDirectory=$script:DataRoot;desktopShortcut=$desktopShortcut;startMenuShortcut=$menuShortcut;autostart=$true} | ConvertTo-Json
if (!$NoLaunch) { & (Join-Path $destinationRoot 'Launch.ps1') -Background:$Background }
