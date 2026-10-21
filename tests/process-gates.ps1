#requires -Version 7.0
param([string]$Tool=(Join-Path $PSScriptRoot '../src/dotcheck/bin/Release/net10.0/dotcheck.exe'),[string]$Simulator=(Join-Path $PSScriptRoot 'Simulator/bin/Release/net10.0/dotnet.exe'))
$ErrorActionPreference='Stop'
$Tool=[IO.Path]::GetFullPath($Tool);$Simulator=[IO.Path]::GetFullPath($Simulator)
$root=Join-Path ([IO.Path]::GetTempPath()) ('dotcheck-process-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $root)
$oldPath=$env:PATH;$oldCase=$env:DOTCHECK_SIM_CASE;$oldPid=$env:DOTCHECK_SIM_PIDFILE
$checks=0
function Assert([bool]$ok,[string]$name){if(-not $ok){throw "FAIL $name"};$script:checks++}
function Start-Runner([string[]]$Arguments){
    $p=[Diagnostics.Process]::new();$p.StartInfo=[Diagnostics.ProcessStartInfo]::new($Tool)
    $p.StartInfo.UseShellExecute=$false;$p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
    foreach($a in $Arguments){$p.StartInfo.ArgumentList.Add($a)}
    [void]$p.Start();return @{process=$p;out=$p.StandardOutput.ReadToEndAsync();err=$p.StandardError.ReadToEndAsync()}
}
function Complete($r){
    try{if(-not $r.process.WaitForExit(15000)){$r.process.Kill($true);throw 'gate timeout'}
        $text=$r.out.GetAwaiter().GetResult();$errorText=$r.err.GetAwaiter().GetResult()
        return @{exit=$r.process.ExitCode;value=($text|ConvertFrom-Json);text=$text;stderr=$errorText}
    }finally{$r.process.Dispose()}
}
function Run([string[]]$Arguments){Complete (Start-Runner $Arguments)}
function Wait-File([string]$file){$sw=[Diagnostics.Stopwatch]::StartNew();while(-not(Test-Path $file) -and $sw.ElapsedMilliseconds -lt 5000){Start-Sleep -Milliseconds 10};if(-not(Test-Path $file)){throw 'PID file missing'}}
function Assert-Gone([int[]]$ids,[string]$name){
    $sw=[Diagnostics.Stopwatch]::StartNew();do{$alive=@($ids|Where-Object{Get-Process -Id $_ -ErrorAction SilentlyContinue});if(-not $alive){break};Start-Sleep -Milliseconds 20}while($sw.ElapsedMilliseconds -lt 5000)
    Assert ($alive.Count -eq 0) $name
}
try{
    $env:PATH=(Split-Path $Simulator)+[IO.Path]::PathSeparator+$oldPath
    $base=@('-Project',(Join-Path $PSScriptRoot 'Simulator/Simulator.csproj'),'-Json')
    foreach($case in @('early','delayed','parentkill','pipes')){
        $env:DOTCHECK_SIM_CASE=$case;$env:DOTCHECK_SIM_PIDFILE=Join-Path $root "$case.pid"
        $r=Start-Runner (@('-Build')+$base)
        $ids=@()
        try{
            Wait-File $env:DOTCHECK_SIM_PIDFILE;Wait-File ($env:DOTCHECK_SIM_PIDFILE+'.leaf')
            $ids=@((Get-Content $env:DOTCHECK_SIM_PIDFILE).Split(',')|ForEach-Object{[int]$_})+@([int](Get-Content ($env:DOTCHECK_SIM_PIDFILE+'.leaf')))
            foreach($childId in $ids){$p=Get-Process -Id $childId -ErrorAction SilentlyContinue;if($p -and $p.Path -ne $Simulator){throw 'Foreign PID refused'}}
            if($case -in @('early','delayed')){
                $r.process.Kill();[void]$r.process.WaitForExit(5000)
                Assert-Gone $ids "kill runner only: $case"
            }else{
                if($case -eq 'parentkill'){Stop-Process -Id $ids[0]}
                $result=Complete $r;$r=$null
                Assert ($result.value.processTreeCompleted -eq $true) "confirmed job completion: $case"
                if($case -eq 'parentkill'){Assert ($result.exit -ne 0) 'native parent death cannot pass'}
                Assert-Gone $ids "kill native parent / inherited pipes: $case"
            }
        }finally{
            if($r){if(-not $r.process.HasExited){$r.process.Kill($true);[void]$r.process.WaitForExit(5000)};$r.process.Dispose()}
            foreach($childId in $ids){$p=Get-Process -Id $childId -ErrorAction SilentlyContinue;if($p -and $p.Path -eq $Simulator){$p.Kill();[void]$p.WaitForExit(5000)}}
        }
    }
    foreach($case in @(@('flood',125),@('longline',0),@('signed',-7),@('warning',1),@('compilerzero',1))){
        $env:DOTCHECK_SIM_CASE=$case[0];$result=Run (@('-Build')+$base+@('-MaxLogMiB','1','-MaxWarningDiagnostics','0'))
        Assert ($result.exit -eq $case[1] -and $result.value.processTreeCompleted -eq $true) "bounded capture / native exit: $($case[0])"
        Assert ($result.text.Length -lt 6000 -and $result.text -notmatch 'synthetic-private') "bounded safe JSON: $($case[0])"
    }
    $env:DOTCHECK_SIM_CASE='diagnosticflood'
    $result=Run (@('-Build')+$base)
    Assert ($result.exit -eq 125 -and $result.value.condition -eq 'diagnostic_limit' -and $result.value.processTreeCompleted -eq $true) 'distinct diagnostic memory limit fails closed'
    Assert ($result.text.Length -lt 6000) 'diagnostic flood output stays bounded'

    $env:DOTCHECK_SIM_CASE='early';$env:DOTCHECK_SIM_PIDFILE=Join-Path $root 'lock-alias.pid'
    $owner=Start-Runner (@('-Build')+$base+@('-LockRoot',$root))
    try{
        Wait-File $env:DOTCHECK_SIM_PIDFILE;Wait-File ($env:DOTCHECK_SIM_PIDFILE+'.leaf')
        $env:DOTCHECK_SIM_CASE='quick'
        $result=Run (@('-Build')+$base+@('-LockRoot',($root+[IO.Path]::DirectorySeparatorChar)))
        Assert ($result.exit -eq 2 -and $result.value.condition -eq 'build_outputs_busy') 'trailing directory separator cannot bypass the worktree lock'
    }finally{
        if(-not $owner.process.HasExited){$owner.process.Kill();[void]$owner.process.WaitForExit(5000)}
        $owner.process.Dispose()
        $ownedIds=@((Get-Content $env:DOTCHECK_SIM_PIDFILE).Split(',')|ForEach-Object{[int]$_})+@([int](Get-Content ($env:DOTCHECK_SIM_PIDFILE+'.leaf')))
        Assert-Gone $ownedIds 'lock alias test leaves no owned descendants'
    }
    foreach($case in @(@('missing',2),@('stale',2),@('invalid',2),@('trxpass',0),@('nonzero',7),@('skip',1))){
        $env:DOTCHECK_SIM_CASE=$case[0]
        $result=Run (@('-Run')+$base+@('-ResultsDirectory',(Join-Path $root $case[0]),'-FailOnSkipped','-Mode','Warnings'))
        Assert ($result.exit -eq $case[1]) "report health independent of diagnostic selection: $($case[0])"
    }
    $env:DOTCHECK_SIM_CASE='argv';$env:DOTCHECK_SIM_PIDFILE=Join-Path $root 'argv'
    $literal='value with spaces Юникод $(literal) & ;'
    $result=Run (@('-Build')+$base+@('-DotnetArgs','--synthetic', $literal))
    $received=Get-Content ($env:DOTCHECK_SIM_PIDFILE+'.args') -Raw|ConvertFrom-Json
    Assert ($result.exit -eq 0 -and $received[-1] -ceq $literal) 'ArgumentList literal forwarding'
    foreach($arg in @('--logger=foreign','--filter=foreign','-p:Configuration=Release','-p:VSTestTestCaseFilter=foreign','-p:Foo=1;Configuration=Release','@foreign.rsp')){
        $result=Run (@('-Build')+$base+@('-DotnetArgs',$arg));Assert ($result.exit -eq 2 -and $result.value.error -eq 'managed_argument_override') "managed ownership $arg"
    }
    'PASS processChecks='+$checks+' evidence='+$root
}finally{$env:PATH=$oldPath;$env:DOTCHECK_SIM_CASE=$oldCase;$env:DOTCHECK_SIM_PIDFILE=$oldPid}
