$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'Common.ps1')
function Assert($Condition, $Message) { if (!$Condition) { throw $Message } }
& (Join-Path $projectRoot 'Build-Launcher.ps1')
$fixture = Join-Path $script:DataRoot 'silent-start-fixture'
[void][IO.Directory]::CreateDirectory($fixture)
$unicodeFolder=Join-Path $fixture '中文路径 with spaces'
[void][IO.Directory]::CreateDirectory($unicodeFolder)
$unicodeLink=Join-Path $unicodeFolder '校园网自动登录.lnk'
$unicodeTarget=Join-Path $unicodeFolder '中文程序.exe'
[IO.File]::WriteAllText($unicodeTarget,'Synthetic shortcut target; never executed')
[CampusLogin.BackgroundProcess]::SaveShortcut($unicodeLink,$unicodeTarget,'--background',$unicodeFolder,'中文快捷方式')
Assert (Test-Path -LiteralPath $unicodeLink) 'Unicode shortcut file was not saved'
Assert ([CampusLogin.BackgroundProcess]::ReadShortcutTarget($unicodeLink) -eq $unicodeTarget) 'Unicode shortcut target did not round-trip'
Assert ([CampusLogin.BackgroundProcess]::ReadShortcutArguments($unicodeLink) -eq '--background') 'Shortcut arguments did not round-trip'
$probeSource = Join-Path $fixture 'ConsoleProbe.cs'
[IO.File]::WriteAllText($probeSource, @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
class ConsoleProbe {
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    static int Main(string[] args) {
        string result = "{\"console\":" + GetConsoleWindow().ToInt64() + "}";
        if (args.Length > 0) File.WriteAllText(args[0], result);
        else {
            Console.OutputEncoding = new UTF8Encoding(false);
            // More than a pipe buffer verifies that stderr is drained concurrently.
            Console.Error.Write(new string('x', 262144));
            Console.Write(result);
        }
        return 0;
    }
}
'@, [Text.UTF8Encoding]::new($false))
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$probe = Join-Path $fixture 'ConsoleProbe.exe'
& $compiler /nologo /target:exe ('/out:'+$probe) $probeSource
Assert ($LASTEXITCODE -eq 0) 'Console probe compilation failed'
$reader = [IO.BinaryReader]::new([IO.File]::OpenRead((Join-Path $projectRoot 'CampusLogin.exe')))
try {
    $reader.BaseStream.Position = 0x3c
    $pe = $reader.ReadInt32()
    $reader.BaseStream.Position = $pe + 24 + 68
    Assert ($reader.ReadUInt16() -eq 2) 'Entry point must use the Windows GUI PE subsystem'
} finally { $reader.Dispose() }
for ($iteration = 0; $iteration -lt 5; $iteration++) {
    $resultPath = Join-Path $fixture ('probe-'+$iteration+'.json')
    $child = Start-BackgroundProcess $probe ('"'+$resultPath+'"')
    try { Assert ($child.WaitForExit(10000) -and $child.ExitCode -eq 0) 'No-console child did not finish' } finally { $child.Dispose() }
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    Assert ($result.console -eq 0) 'Background child allocated a console window'
    $captured = [CampusLogin.BackgroundProcess]::Capture($probe, '', $projectRoot, 10000) | ConvertFrom-Json
    Assert ($captured.console -eq 0) 'Captured native command allocated a console window'
}
$psProbe = Join-Path $fixture 'PowerShellProbe.ps1'
[IO.File]::WriteAllText($psProbe, @'
param([string]$Result)
Add-Type 'using System; using System.Runtime.InteropServices; public static class ConsoleHandle { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'
[IO.File]::WriteAllText($Result, [ConsoleHandle]::GetConsoleWindow().ToInt64().ToString())
'@)
for ($iteration = 0; $iteration -lt 3; $iteration++) {
    $resultPath = Join-Path $fixture ('pwsh-'+$iteration+'.txt')
    $child = Start-BackgroundProcess (Join-Path $PSHOME 'pwsh.exe') ('-NoLogo -NoProfile -STA -File "'+$psProbe+'" -Result "'+$resultPath+'"')
    try { Assert ($child.WaitForExit(15000) -and $child.ExitCode -eq 0) 'Background PowerShell did not finish' } finally { $child.Dispose() }
    Assert ([IO.File]::ReadAllText($resultPath) -eq '0') 'PowerShell allocated a console window'
}
# Repeated task triggers after user exit cannot restart any real worker or clear
# the marker. Isolated data keeps this check away from the installed credentials.
$stop = Join-Path $script:DataRoot 'stop.request'
[IO.File]::WriteAllText($stop, 'explicit-user-exit')
for ($iteration = 0; $iteration -lt 5; $iteration++) {
    $launcher = Start-BackgroundProcess (Join-Path $projectRoot 'CampusLogin.exe') '--supervise'
    try { Assert ($launcher.WaitForExit(10000) -and $launcher.ExitCode -eq 0) 'Repeated GUI recovery trigger failed' } finally { $launcher.Dispose() }
}
Assert ([IO.File]::ReadAllText($stop) -eq 'explicit-user-exit') 'Recovery trigger cleared explicit user exit'
foreach ($path in @('Common.ps1','Supervisor.ps1','App.ps1')) {
    $text = [IO.File]::ReadAllText((Join-Path $projectRoot $path))
    Assert ($text -notmatch '-WindowStyle Hidden') ('Console hiding workaround remains in '+$path)
}
$common = [IO.File]::ReadAllText((Join-Path $projectRoot 'Common.ps1'))
Assert ($common -match "\$arguments = '--supervise'") 'Scheduled task must invoke GUI recovery entry'
Assert ($common -notmatch '\(&.*netsh\.exe') 'Network polling still launches netsh through the shell'
Write-Output 'PASS: Unicode shortcut paths and targets, GUI entry, 13 real PowerShell/native launches without console handles, pipe draining, 5 repeated recovery triggers and explicit exit.'
