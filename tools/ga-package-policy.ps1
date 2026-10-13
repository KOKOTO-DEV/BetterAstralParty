# Offline packaging policy; never loads the plugin or helper for execution.
function Initialize-BapGaPackaging {
    $project=Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'install-backup.ps1')
    . (Join-Path $PSScriptRoot 'install-policy.ps1')
    if(!('Mono.Cecil.AssemblyDefinition' -as [type])){Add-Type -Path (Join-Path $project '.deps/bepinex/BepInEx/core/Mono.Cecil.dll')}
    if(!('BetterAstralParty.Packaging.GaPackageContract' -as [type])){
        $sources=@((Join-Path $PSScriptRoot 'DevelopmentPackageFiles.cs'),(Join-Path $PSScriptRoot 'GaPackageContract.cs'))
        $sources+=@(Get-ChildItem -LiteralPath (Join-Path $project 'updater') -File -Filter '*.cs'|Where-Object Name -ne 'UpdateHelperProgram.cs'|Sort-Object Name|ForEach-Object FullName)
        $sources+=@(Get-ChildItem -LiteralPath (Join-Path $project 'src/Observability') -File -Filter '*.cs'|Sort-Object Name|ForEach-Object FullName)
        $sources+=Join-Path $project 'diagnostics/MinimalDiagnosticProjection.cs'
        Add-Type -Path $sources
    }
}
function Get-BapGaHash([byte[]]$Bytes){$h=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($h.ComputeHash($Bytes)).Replace('-','')}finally{$h.Dispose()}}
function Read-BapGaJson([byte[]]$Bytes){
    if($Bytes.Length -gt 4MB){throw 'Packaging JSON exceeds bound.'}
    return Read-BapInstallJson $Bytes
}
function Assert-BapGaPath([string]$Name){
    if(!$Name -or [IO.Path]::IsPathRooted($Name) -or $Name -match '\\|[<>:"|?*\x00-\x1F]'){throw 'Unsafe package path.'}
    foreach($p in $Name.Split('/')){if(!$p -or $p -ne $p.Trim() -or $p.EndsWith('.') -or $p -in @('.','..') -or $p -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw 'Package path alias rejected.'}}
}
function Get-BapGaTypes($Types){foreach($t in $Types){$t;if($t.HasNestedTypes){Get-BapGaTypes $t.NestedTypes}}}
function Assert-BapGaImage([byte[]]$Bytes,[string]$Role,[string]$Version){
    $memory=[IO.MemoryStream]::new($Bytes,$false);$a=$null
    try{
        $a=[Mono.Cecil.AssemblyDefinition]::ReadAssembly($memory);$types=@(Get-BapGaTypes $a.MainModule.Types)
        if($Role -eq 'Plugin'){
            $meta=Read-BapInstallMetadata $Bytes
            if($meta.Version -cne $Version -or $meta.Protocol -ne 1){throw 'GA plugin version/protocol mismatch.'}
            foreach($name in @('BetterAstralParty.AutomaticUpdates','BetterAstralParty.MemoryReleaseAuthentication','BetterAstralParty.PrivateUpdateApproval')){
                if(@($types|Where-Object FullName -CEQ $name).Count -ne 1){throw 'GA auth/update integration missing.'}
            }
        }elseif($Role -eq 'Launcher'){
            $meta=Read-BapInstallMetadata $Bytes -Launcher
            if($meta.Protocol -ne 1 -or !$meta.MaintenanceApi -or !$meta.HelperBootstrapApi -or !$meta.RemovedHelperEvidenceApi){throw 'GA launcher protocol/API mismatch.'}
            $resources=@($a.MainModule.Resources|Where-Object {$_.Name.StartsWith('BetterAstralParty.HelperBootstrap.',[StringComparison]::Ordinal)})
            if($resources.Count){throw 'Previous helper bootstrap resources are forbidden in the new baseline.'}
            foreach($resource in $a.MainModule.Resources){
                if($resource -is [Mono.Cecil.EmbeddedResource]){
                    $data=$resource.GetResourceData()
                    if($data.Length -ge 2 -and $data[0] -eq 77 -and $data[1] -eq 90){throw 'Embedded executable resource rejected.'}
                }
            }
        }else{
            if(@($types|Where-Object FullName -CEQ 'BetterAstralParty.Updating.UpdateHelperProgram').Count -ne 1 -or @($types|Where-Object FullName -CEQ 'BetterAstralParty.Updating.UpdateHelperService').Count -ne 1){throw 'GA helper entrypoint/closure missing.'}
        }
        foreach($t in $types){
            if($t.FullName -match 'SettingsTraceProbe|SettingsTracePhase|Fixture|InertProcess|TrialVersionCheck|ReleaseSessionCheck'){throw 'Diagnostic/fixture type rejected.'}
            foreach($m in $t.Methods){
                if(!$m.HasBody){continue}
                foreach($i in $m.Body.Instructions){
                    if($i.OpCode.Name -eq 'ldstr' -and [string]$i.Operand -match 'GS-20261003-B1|settingsProbe|fixture-public-key.bin|INERT_TEST_ONLY|fixture-placeholder-only'){throw 'Diagnostic/fixture marker rejected.'}
                    if($i.Operand -is [Mono.Cecil.MethodReference] -and $i.Operand.Name -match '^(SignData|SignHash|ImportRSAPrivateKey|ImportPkcs8PrivateKey|ExportRSAPrivateKey)$'){throw 'Private signing/key operation entered candidate.'}
                }
            }
        }
        $gate=$null
        if($Role -eq 'Plugin'){
            $m=($types|Where-Object FullName -CEQ 'BetterAstralParty.PrivateUpdateApproval').Methods|Where-Object Name -CEQ 'get_CredentialInputEnabled'
            $il=@($m.Body.Instructions)
            if($il.Count -ne 2 -or $il[1].OpCode.Name -ne 'ret' -or $il[0].OpCode.Name -notin @('ldc.i4.0','ldc.i4.1')){throw 'Unknown credential gate IL.'}
            $gate=$il[0].OpCode.Name -eq 'ldc.i4.1'
        }
        return @{role=$Role;credentialInputCompiled=$gate;diagnosticOrFixtureTypesAndMarkersAbsent=$true;privateSigningCallsAbsent=$true}
    }finally{if($a){$a.Dispose()};$memory.Dispose()}
}
function Get-BapGaIdentity($Rows,[string]$Kind,[string]$Version){
    $null=Get-BapInstallVersion $Version
    [string[]]$names=@($Rows.Keys|Where-Object {$_ -cne 'tools/approved-install-bundles.json'})
    [Array]::Sort($names,[StringComparer]::Ordinal)
    $lines=@('BetterAstralParty.InstallBundle/v1',('version='+$Version),('kind='+$Kind),'protocol=1')
    foreach($n in $names){$lines+=($n+'='+$Rows[$n].sha256)}
    return Get-BapGaHash ([Text.Encoding]::UTF8.GetBytes(($lines -join [char]10)+[char]10))
}


function Assert-BapGaLicenseClosure($Captured,$LoaderSeen,[string]$UpstreamHash) {
    foreach($name in @('LICENSE','THIRD-PARTY-NOTICES/component-matrix.json','THIRD-PARTY-NOTICES/SOURCES.md')){
        if(!$Captured.ContainsKey($name)){throw ('Missing license closure input: '+$name)}
    }
    $license=[Text.UTF8Encoding]::new($false,$true).GetString($Captured['LICENSE'].bytes)
    if(!$license.Contains('Copyright (c) 2026 TSM701') -or !$license.Contains('Permission is hereby granted, free of charge')){throw 'BetterAstralParty MIT license/copyright missing.'}
    $matrix=Read-BapGaJson $Captured['THIRD-PARTY-NOTICES/component-matrix.json'].bytes
    if(($matrix.schema -isnot [int] -and $matrix.schema -isnot [long]) -or $matrix.schema -ne 1 -or $matrix.upstreamArchiveSha256 -cne $UpstreamHash -or $matrix.components -isnot [array] -or $matrix.files -isnot [array] -or $matrix.components.Count -lt 3 -or $matrix.components.Count -gt 64 -or $matrix.files.Count -ne $LoaderSeen.Count){throw 'Invalid license matrix closure.'}
    $components=@{};$notices=@{};$sources=@{}
    foreach($c in $matrix.components){
        if($c.component -isnot [string] -or $c.component -cnotmatch '\A[A-Za-z0-9.-]{1,64}\z' -or $components.ContainsKey($c.component) -or $c.version -isnot [string] -or !$c.version -or $c.license -isnot [string] -or !$c.license -or $c.sourceUrl -isnot [string] -or !$c.sourceUrl.StartsWith('https://github.com/',[StringComparison]::Ordinal) -or $c.notices -isnot [array] -or !$c.notices.Count){throw 'Invalid component license row.'}
        $components[$c.component]=$true
        foreach($notice in $c.notices){
            if($notice.path -isnot [string] -or !$notice.path.StartsWith('THIRD-PARTY-NOTICES/',[StringComparison]::Ordinal) -or $notice.sha256 -isnot [string] -or $notice.sha256 -cnotmatch '\A[A-F0-9]{64}\z'){throw 'Invalid component notice reference.'}
            Assert-BapGaPath $notice.path
            if(!$Captured.ContainsKey($notice.path) -or $Captured[$notice.path].sha256 -cne $notice.sha256){throw 'Component notice missing or changed.'}
            $notices[$notice.path]=$true
        }
        if($c.license.StartsWith('LGPL',[StringComparison]::Ordinal)){
            $src=$c.correspondingSource
            if($src.path -isnot [string] -or !$src.path.StartsWith('THIRD-PARTY-SOURCE/',[StringComparison]::Ordinal) -or !$src.path.EndsWith('.zip',[StringComparison]::Ordinal) -or $src.sha256 -isnot [string] -or $src.sha256 -cnotmatch '\A[A-F0-9]{64}\z' -or $src.sourceRevision -isnot [string] -or $src.sourceRevision -cnotmatch '\A[a-f0-9]{40}\z' -or $src.sourceCodeUnmodified -isnot [bool] -or !$src.sourceCodeUnmodified){throw 'LGPL corresponding source absent or invalid.'}
            Assert-BapGaPath $src.path
            if(!$Captured.ContainsKey($src.path) -or $Captured[$src.path].sha256 -cne $src.sha256 -or $sources.ContainsKey($src.path)){throw 'LGPL source hash/closure mismatch.'}
            $sources[$src.path]=$true
            $memory=[IO.MemoryStream]::new($Captured[$src.path].bytes,$false);$z=[IO.Compression.ZipArchive]::new($memory,'Read');$names=@{};$expanded=[long]0;$code=$false;$licenseText=$false
            try{
                if(!$z.Entries.Count -or $z.Entries.Count -gt 8192){throw 'Source archive entry bound exceeded.'}
                foreach($e in $z.Entries){
                    $n=$e.FullName.Replace('\','/')
                    if($n.EndsWith('/')){continue}
                    Assert-BapGaPath $n
                    if($names.ContainsKey($n) -or $e.Length -gt 16MB){throw 'Source archive alias or entry bound exceeded.'}
                    $names[$n]=$true;$expanded+=$e.Length
                    if($expanded -gt 64MB){throw 'Source archive expansion bound exceeded.'}
                    if([IO.Path]::GetExtension($n).ToLowerInvariant() -in @('.dll','.exe','.so','.dylib','.lib','.a','.pdb','.ttf','.otf')){throw 'Vendor/development binary in corresponding source rejected.'}
                    if([IO.Path]::GetExtension($n).ToLowerInvariant() -in @('.cs','.c','.cpp','.h')){$code=$true}
                    if([IO.Path]::GetFileName($n) -cmatch '^(LICENSE|LICENSE\.txt|COPYING|COPYING\.txt)$'){$licenseText=$true}
                }
                if(!$code -or !$licenseText){throw 'Corresponding source lacks source or license text.'}
            }finally{$z.Dispose();$memory.Dispose()}
        }
    }
    $seen=@{}
    foreach($row in $matrix.files){
        if($row.path -isnot [string] -or !$LoaderSeen.ContainsKey($row.path) -or $seen.ContainsKey($row.path) -or $row.component -isnot [string] -or !$components.ContainsKey($row.component) -or $row.sha256 -isnot [string] -or $row.sha256 -cnotmatch '\A[A-F0-9]{64}\z' -or ($row.bytes -isnot [int] -and $row.bytes -isnot [long]) -or $row.bytes -le 0 -or $Captured[$row.path].sha256 -cne $row.sha256 -or $Captured[$row.path].bytes.Length -ne $row.bytes){throw 'Packaged loader/license matrix mismatch.'}
        $seen[$row.path]=$true
    }
    foreach($name in $Captured.Keys){
        if($name.StartsWith('THIRD-PARTY-SOURCE/',[StringComparison]::Ordinal) -and !$sources.ContainsKey($name)){throw 'Unlisted corresponding source archive.'}
        if($name.StartsWith('THIRD-PARTY-NOTICES/',[StringComparison]::Ordinal) -and $name -cnotin @('THIRD-PARTY-NOTICES/component-matrix.json','THIRD-PARTY-NOTICES/SOURCES.md') -and !$notices.ContainsKey($name)){throw 'Unlisted third-party notice file.'}
    }
    return @{matrixSha256=$Captured['THIRD-PARTY-NOTICES/component-matrix.json'].sha256;loaderFiles=$seen.Count;components=$components.Count;correspondingSourceArchives=$sources.Count;vendorBinarySourceEntriesAbsent=$true;independentReviewPending=$true}
}
