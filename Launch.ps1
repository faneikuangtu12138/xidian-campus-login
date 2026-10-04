param([switch]$Background)
$ErrorActionPreference = 'Stop'
# Resolve PowerShell 7 each time instead of embedding a versioned Codex runtime path.
$candidates = @(
    (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
    (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe')
)
$found = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($found) { $candidates = @($found.Source) + $candidates }
$runtime = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (!$runtime) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show('需要 PowerShell 7。当前电脑的 Codex 自带该运行环境；若已卸载 Codex，请安装 PowerShell 7 后重试。','校园网自动登录')
    exit 1
}
$arguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSScriptRoot + '\App.ps1"'
if ($Background) { $arguments += ' -Background' }
Start-Process -FilePath $runtime -ArgumentList $arguments -WindowStyle Hidden
