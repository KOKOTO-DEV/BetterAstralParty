param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
if(!$OutputDirectory){$OutputDirectory=Join-Path $project ('artifacts/frontend-regression-'+[guid]::NewGuid().ToString('N'))}
$scratch=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $scratch){throw 'Fresh fixture output required'}
$null=[IO.Directory]::CreateDirectory($scratch)
$cwd=Join-Path $scratch 'unrelated-working-directory';$null=[IO.Directory]::CreateDirectory($cwd)
$stub=@'
param([string]$GameRoot,[string]$Operation)
$ErrorActionPreference='Stop'
$text=[ordered]@{scriptRoot=$PSScriptRoot;gameRoot=$GameRoot;operation=$Operation;actualInstallerExecuted=$false}|ConvertTo-Json
[IO.File]::WriteAllText($env:BAP_ENTRY_RESULT,$text,[Text.UTF8Encoding]::new($false))
exit ([int]$env:BAP_FIXTURE_EXIT)
'@
$cases=@();$number=0
$labels=@('plain',([string][char]0xAC00+' spaces'), 'brackets [1] (2)','amp&ersand','bang!folder','percent%folder')
foreach($label in $labels){foreach($branch in @('package','development')){foreach($entry in @('Install.cmd','Uninstall.cmd')){foreach($delayed in @('off','on')){
    $statuses=if($label -eq 'plain' -and $delayed -eq 'off'){@(0,7,-1)}else{@(0)}
    foreach($status in $statuses){
        $number++;$root=Join-Path $scratch ('case-'+$number+'/'+$label)
        $null=[IO.Directory]::CreateDirectory((Join-Path $root 'tools'))
        [IO.File]::Copy((Join-Path $project $entry),(Join-Path $root $entry),$false)
        foreach($name in @('install-bootstrap.ps1','uninstall.ps1','development-maintenance.ps1')){[IO.File]::WriteAllText((Join-Path $root ('tools/'+$name)),$stub,[Text.UTF8Encoding]::new($true))}
        if($branch -eq 'package'){[IO.File]::WriteAllText((Join-Path $root 'package-manifest.json'),'{}')}
        $resultPath=Join-Path $root 'inert-result.json';$game=Join-Path $cwd 'selected game [1] (2)'
        $info=[Diagnostics.ProcessStartInfo]::new($env:ComSpec)
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.RedirectStandardInput=$true
        # Caller-expanded bangs cannot be recovered; isolate inherited /v:on from that separate boundary.
        $relative=$label -eq 'bang!folder' -and $delayed -eq 'on'
        $invoke=if($relative){$entry}else{Join-Path $root $entry}
        $info.WorkingDirectory=if($relative){$root}else{$cwd}
        $info.Arguments='/d /s /v:'+$delayed+' /c ""'+$invoke+'" -GameRoot "'+$game+'" <nul"'
        $info.EnvironmentVariables['LOCALAPPDATA']=Join-Path $root 'local-data'
        $info.EnvironmentVariables['TEMP']=Join-Path $root 'temp-data'
        $info.EnvironmentVariables['BAP_ENTRY_RESULT']=$resultPath
        $info.EnvironmentVariables['BAP_FIXTURE_EXIT']=[string]$status
        $info.EnvironmentVariables['BAP_EXIT']='parent-value'
        $process=[Diagnostics.Process]::new();$process.StartInfo=$info
        try {
            if(!$process.Start()){throw 'Inert CMD did not start'}
            $process.StandardInput.Close();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            if(!$process.WaitForExit(20000)){$process.Kill();throw 'Inert CMD timeout'}
            $data=if(Test-Path -LiteralPath $resultPath){Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
            $operation=if($branch -eq 'development'){if($entry -eq 'Install.cmd'){'Install'}else{'Uninstall'}}else{''}
            $passed=$process.ExitCode -eq $status -and $data -and $data.scriptRoot -ceq (Join-Path $root 'tools') -and $data.gameRoot -ceq $game -and [string]$data.operation -ceq $operation -and !$data.actualInstallerExecuted
            $cases+=[ordered]@{case=$number;pathClass=$label;branch=$branch;entry=$entry;delayedExpansion=$delayed;relativeInvocation=$relative;expectedExit=$status;exitCode=$process.ExitCode;passed=[bool]$passed;stdout=$stdout.GetAwaiter().GetResult();stderr=$stderr.GetAwaiter().GetResult()}
        } finally {$process.Dispose()}
    }
}}}}
$record=[ordered]@{schema=1;sourceEntries=@('Install.cmd','Uninstall.cmd')|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $project $_)).Hash}};cases=$cases.Count;passed=@($cases|Where-Object passed).Count;failed=@($cases|Where-Object {!$_.passed}).Count;actualInstallationPerformed=$false;results=$cases}
[IO.File]::WriteAllText((Join-Path $scratch 'result.json'),($record|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
[ordered]@{cases=$record.cases;passed=$record.passed;failed=$record.failed;result=(Join-Path $scratch 'result.json')}|ConvertTo-Json
if($record.failed){throw 'Frontend regression failed; evidence retained'}
