#requires -Version 7.0
param([string]$Tool=(Join-Path $PSScriptRoot '../artifacts/dotcheck-1.0.0-win-x64/dotcheck.exe'))
$ErrorActionPreference='Stop';$Tool=[IO.Path]::GetFullPath($Tool)
$root=Join-Path ([IO.Path]::GetTempPath()) ('dotcheck публикация '+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $root)
$native=Join-Path $root 'dotcheck.exe';Copy-Item -LiteralPath $Tool -Destination $native
$project=Join-Path $root 'проект с пробелами';[void](New-Item -ItemType Directory $project)
Copy-Item (Join-Path $PSScriptRoot 'NativeSmoke/*.cs*') $project
[IO.File]::WriteAllText((Join-Path $root 'global.json'),'{"sdk":{"version":"10.0.402","rollForward":"disable"}}')
Copy-Item (Join-Path $PSScriptRoot 'fixtures/passed.trx') (Join-Path $root 'отчёт.trx')
$oldPath=$env:PATH;$oldRoot=$env:DOTNET_ROOT
$sdkDirectory=Split-Path (Get-Command dotnet -CommandType Application|Select-Object -First 1).Source
$checks=0
function Invoke-Native([string[]]$Arguments){
    $p=[Diagnostics.Process]::new();$p.StartInfo=[Diagnostics.ProcessStartInfo]::new($native)
    $p.StartInfo.UseShellExecute=$false;$p.StartInfo.WorkingDirectory=$root;$p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
    foreach($a in $Arguments){$p.StartInfo.ArgumentList.Add($a)}
    [void]$p.Start();$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
    try{if(-not $p.WaitForExit(30000)){$p.Kill($true);throw 'Smoke timeout'}
        $r=@{exit=$p.ExitCode;value=($stdout.GetAwaiter().GetResult()|ConvertFrom-Json);stderr=$stderr.GetAwaiter().GetResult()}
        $r|ConvertTo-Json -Depth 15|Set-Content (Join-Path $root ('result-'+[guid]::NewGuid().ToString('N')+'.json'));return $r
    }finally{$p.Dispose()}
}
function Assert([bool]$ok,[string]$name){if(-not $ok){throw "FAIL $name"};$script:checks++}
try{
    $env:PATH=Join-Path $env:WINDIR 'System32';$env:DOTNET_ROOT=Join-Path $root 'absent-runtime'
    $r=Invoke-Native @('-Path','отчёт.trx','-Json');Assert ($r.exit -eq 0) 'self-contained reader without dotnet or pwsh PATH'
    $version=([Diagnostics.FileVersionInfo]::GetVersionInfo($native).FileVersion -split '\.')[0..2] -join '.'
    $r=Invoke-Native @('-Help','-Json');Assert ($r.exit -eq 0 -and $r.value.help[0].StartsWith("dotcheck $version ")) 'Help matches executable version'
    $env:PATH=$sdkDirectory+[IO.Path]::PathSeparator+(Join-Path $env:WINDIR 'System32');$env:DOTNET_ROOT=$sdkDirectory
    $journal=Join-Path $root 'journal.jsonl'
    $r=Invoke-Native @('-Run','-Project',(Join-Path $project 'NativeSmoke.csproj'),'-Filter','FullyQualifiedName~BclArithmetic','-Configuration','Release','-ResultsDirectory','отчёты','-JournalPath',$journal,'-Reason','Unicode SDK selection smoke','-FailOnSkipped','-Json')
    Assert ($r.exit -eq 0 -and $r.value.total -eq 1 -and $r.value.processTreeCompleted -eq $true) 'published real VSTest with spaces Unicode and selected SDK'
    $entries=@(Get-Content -LiteralPath $journal|ForEach-Object { $_|ConvertFrom-Json })
    Assert ($entries.Count -eq 2 -and @($entries|Where-Object { $_.toolVersion -ne $version -or $_.schemaVersion -ne 1 }).Count -eq 0) 'new journal version matches executable and retains schema 1'
    Assert ($r.value.reports[0].StartsWith((Join-Path $root 'отчёты'))) 'relative results directory uses caller cwd'
    $env:PATH=Join-Path $env:WINDIR 'System32';$env:DOTNET_ROOT=Join-Path $root 'absent-runtime'
    $r=Invoke-Native @('-LastRun','-JournalPath',$journal,'-Json');Assert ($r.exit -eq 0 -and $r.value.reportVerification -eq 'checked') 'journal replay needs neither dotnet nor pwsh'
    # Command precedence is observed in an isolated process PATH; registration itself is tested through the fake environment.
    $pwsh=(Get-Process -Id $PID).Path
    $env:PATH=$root
    $resolved=& $pwsh -NoProfile -Command '(Get-Command dotcheck -CommandType Application).Source'
    Assert ($resolved.Trim() -eq $native) 'isolated executable command resolution'
    Set-Content (Join-Path $root 'dotcheck.ps1') '# synthetic foreign command';Set-Content (Join-Path $root 'dotcheck.cmd') '@exit /b 0'
    $resolution=& $pwsh -NoProfile -Command 'Get-Command dotcheck -All | Select-Object -ExpandProperty Source'
    $resolution|Set-Content (Join-Path $root 'precedence.txt')
    Assert (@($resolution).Count -ge 2) 'exe ps1 cmd precedence captured'
    "PASS publishedChecks=$checks evidence=$root"
}finally{$env:PATH=$oldPath;$env:DOTNET_ROOT=$oldRoot}
