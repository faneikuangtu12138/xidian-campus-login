param([string]$OutputDirectory = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (!(Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (!(Test-Path -LiteralPath $compiler)) { throw 'Windows .NET Framework compiler is unavailable.' }
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$target = Join-Path $OutputDirectory 'CampusLogin.exe'
$buildRecord = Join-Path $OutputDirectory 'CampusLogin.build.json'
$sourcesHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'BackgroundProcess.cs'))+"`n"+[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'SilentLauncher.cs')))))
if((Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $buildRecord)){
    try {
        $record=Get-Content -LiteralPath $buildRecord -Raw | ConvertFrom-Json
        if($record.sourcesHash -eq $sourcesHash -and $record.imageHash -eq (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash){return}
    }catch{}
}
& $compiler /nologo /target:winexe /optimize+ /platform:anycpu '/reference:System.Windows.Forms.dll' ('/out:'+$target) (Join-Path $PSScriptRoot 'BackgroundProcess.cs') (Join-Path $PSScriptRoot 'SilentLauncher.cs')
if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $target)) { throw 'Silent launcher compilation failed.' }
[IO.File]::WriteAllText($buildRecord,(@{sourcesHash=$sourcesHash;imageHash=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
