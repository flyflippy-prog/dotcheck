#requires -Version 7.0
param([string]$Tool = (Join-Path $PSScriptRoot '../src/dotcheck/bin/Release/net10.0/dotcheck.exe'))
$ErrorActionPreference='Stop'
$Tool=[IO.Path]::GetFullPath($Tool)
$baseline=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../reference/powershell/dotcheck.ps1'))
$goldens=[Collections.Generic.List[object]]::new()
function Invoke-Captured([string]$File,[string[]]$Arguments) {
    $p=[Diagnostics.Process]::new(); $p.StartInfo=[Diagnostics.ProcessStartInfo]::new($File)
    $p.StartInfo.UseShellExecute=$false;$p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
    foreach($a in $Arguments){$p.StartInfo.ArgumentList.Add($a)}
    [void]$p.Start();$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
    if(-not $p.WaitForExit(15000)){$p.Kill($true);throw 'bounded invocation timeout'}
    $r=@{exit=$p.ExitCode;json=$stdout.GetAwaiter().GetResult();stderr=$stderr.GetAwaiter().GetResult()};$p.Dispose();return $r
}
$checks=0
foreach($file in Get-ChildItem (Join-Path $PSScriptRoot fixtures) -Filter *.trx | Sort-Object Name){
    foreach($mode in @('Summary','Failed','Skipped','Slow','Detail','RunErrors')){
        $a=@('-Path',$file.FullName,'-Mode',$mode,'-Json');if($mode -eq 'Detail'){$a+=@('-Test','Synthetic','-StackLines','1')}
        $old=Invoke-Captured (Get-Command pwsh).Source (@('-NoProfile','-File',$baseline)+$a)
        $new=Invoke-Captured $Tool $a
        $left=[Text.Json.Nodes.JsonNode]::Parse($old.json);$right=[Text.Json.Nodes.JsonNode]::Parse($new.json)
        if($old.exit -ne $new.exit -or -not [Text.Json.Nodes.JsonNode]::DeepEquals($left,$right)){throw "Differential mismatch: $($file.Name) $mode`nlegacy=$($old.json)`nnative=$($new.json)"}
        $goldens.Add(@{fixture=$file.Name;mode=$mode;exit=$old.exit;payload=($old.json|ConvertFrom-Json -AsHashtable)});$checks++
    }
}
$goldenPath=Join-Path $PSScriptRoot 'fixtures/golden.json'
if(Test-Path $goldenPath){
    $existing=[Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($goldenPath))
    $actual=[Text.Json.Nodes.JsonNode]::Parse(($goldens|ConvertTo-Json -Depth 20))
    if(-not [Text.Json.Nodes.JsonNode]::DeepEquals($existing,$actual)){throw 'Captured golden drift'}
}else{$goldens|ConvertTo-Json -Depth 20|Set-Content $goldenPath}
$multi=Join-Path ([IO.Path]::GetTempPath()) ('dotcheck-differential-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory $multi)
Copy-Item (Join-Path $PSScriptRoot 'fixtures/failed.trx') (Join-Path $multi 'z.trx')
Copy-Item (Join-Path $PSScriptRoot 'fixtures/failed.trx') (Join-Path $multi 'é.trx')
$a=@('-Path',$multi,'-Mode','Detail','-Test','Synthetic','-Json')
$old=Invoke-Captured (Get-Command pwsh).Source (@('-NoProfile','-File',$baseline)+$a);$new=Invoke-Captured $Tool $a
if($old.exit -ne $new.exit -or -not [Text.Json.Nodes.JsonNode]::DeepEquals([Text.Json.Nodes.JsonNode]::Parse($old.json),[Text.Json.Nodes.JsonNode]::Parse($new.json))){throw 'Culture-sensitive report ordering mismatch'};$checks++
"PASS differentialChecks=$checks golden=$goldenPath multiReportEvidence=$multi"
