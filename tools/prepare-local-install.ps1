param(
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$UpstreamArchive,
    [Parameter(Mandatory)][ValidatePattern('^[A-F0-9]{64}$')][string]$UpstreamSha256,
    [ValidateSet('LocalInstall','Release')][string]$Scope='LocalInstall'
)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -lt 7){throw 'PowerShell 7 required.'}
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'ga-package-policy.ps1')
Initialize-BapGaPackaging
. (Join-Path $PSScriptRoot 'install-policy.ps1')
. (Join-Path $PSScriptRoot 'install-backup.ps1')
. (Join-Path $PSScriptRoot 'install-helper.ps1')
$files=[BetterAstralParty.Packaging.DevelopmentPackageFiles]::new($project)
$captured=@{};$directories=@{};$bundle=$null
function Relative([string]$Path){
    $full=[IO.Path]::GetFullPath($Path)
    if(!$full.StartsWith($project+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Project-local input/output required.'}
    return $full.Substring($project.Length+1).Replace('\','/')
}
function Capture([string]$Path){
    Assert-BapGaPath $Path
    if(!$captured.ContainsKey($Path)){$files.Capture($Path);$captured[$Path]=$true}
    return ,$files.ReviewBytes($Path)
}
function JsonBytes($Value){return ,[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Value -Depth 10))}
function Parents([string]$Path){
    $parts=$Path.Split('/');$parent=''
    for($i=0;$i -lt $parts.Length-1;$i++){
        $parent=if($parent){$parent+'/'+$parts[$i]}else{$parts[$i]}
        if(!$directories.ContainsKey($parent)){$null=$files.CreateSubdirectory($parent);$directories[$parent]=$true}
    }
}
try{
    $build=Relative $BuildDirectory;$output=Relative $OutputDirectory;$upstream=Relative $UpstreamArchive
    if($build -cnotmatch '^artifacts/.+' -or $output -cnotmatch '^artifacts/automatic-update-development/.+') {throw 'Isolated artifact directories required.'}
    $pointer=Read-BapGaJson (Capture 'artifacts/development-maintenance.json')
    $base=$pointer.packagePath;Assert-BapGaPath $base
    $manifestBytes=Read-BapInstallFile (Join-Path $project ($base+'/package-manifest.json'))
    if((Get-BapGaHash $manifestBytes) -cne $pointer.manifestSha256){throw 'Current approved package pointer changed.'}
    # The pinned container supplies unchanged vendor assets, never old maintenance code or proofs.
    $manifestBytes=Capture ($base+'/package-manifest.json')
    if((Get-BapGaHash $manifestBytes) -cne $pointer.manifestSha256){throw 'Base manifest changed after validation.'}
    $manifest=Read-BapGaJson $manifestBytes
    $record=Read-BapGaJson (Capture ($build+'/build-result.json'))
    $sourceBytes=Capture ($build+'/build-source.json')
    if($record.schema -ne 1 -or $record.configuration -cne 'Release' -or $record.files.Count -ne 3 -or $record.sourceManifestSha256 -cne (Get-BapGaHash $sourceBytes)){throw 'Verified source-bound Release build required.'}
    $sources=Read-BapGaJson ([Text.Encoding]::UTF8.GetBytes('{"files":'+[Text.Encoding]::UTF8.GetString($sourceBytes).TrimStart([char]0xFEFF)+'}'))
    foreach($row in $sources.files){
        $bytes=Capture $row.path
        if($files.SourceHash($row.path) -cne $row.sha256 -or $bytes.Length -ne $row.bytes){throw ('Build source changed: '+$row.path)}
    }
    $replacements=@{'artifacts/BetterAstralParty.dll'='plugin/BetterAstralParty.dll';'artifacts/BetterAstralParty-Launcher.exe'='launcher/BetterAstralParty-Launcher.exe';'helper-bootstrap/BetterAstralParty-UpdateHelper.exe'='helper/BetterAstralParty-UpdateHelper.exe'}
    foreach($row in $record.files){
        $bytes=Capture ($build+'/'+$row.path)
        if($files.SourceHash($build+'/'+$row.path) -cne $row.sha256 -or $bytes.Length -ne $row.bytes){throw 'Build output hash/length mismatch.'}
    }
    $version=(Read-BapInstallMetadata (Capture ($build+'/plugin/BetterAstralParty.dll'))).Version
    $targetVersion=Get-BapInstallVersion $version
    if((Compare-BapInstallVersion $targetVersion (Get-BapInstallVersion '1.2.1-0')) -lt 0){throw 'New 1.2.1 baseline or later required.'}
    if($Scope -eq 'LocalInstall' -and ($version -cnotmatch '\.local\.[1-9][0-9]*(?:\+[^ ]+)?\z' -or (Compare-BapInstallVersion $targetVersion (Get-BapInstallVersion $pointer.version)) -le 0)){throw 'Distinct increasing local prerelease required.'}
    if($Scope -eq 'Release' -and $version -match '\.local\.'){throw 'Local prereleases cannot be remote release inputs.'}
    $archive=Capture $upstream
    if((Get-BapGaHash $archive) -cne $UpstreamSha256){throw 'Upstream loader pin mismatch.'}
    $loaderMemory=[IO.MemoryStream]::new($archive,$false)
    $loaderArchive=[IO.Compression.ZipArchive]::new($loaderMemory,'Read')
    try {
        $configEntries=@($loaderArchive.Entries | Where-Object FullName -CEQ 'doorstop_config.ini')
        if($configEntries.Count -ne 1 -or $configEntries[0].Length -le 0 -or $configEntries[0].Length -gt 65536){throw 'Unique bounded upstream loader configuration required.'}
        $configStream=$configEntries[0].Open();$configBuffer=[IO.MemoryStream]::new()
        try {$configStream.CopyTo($configBuffer);$loaderConfig=$configBuffer.ToArray()} finally {$configBuffer.Dispose();$configStream.Dispose()}
    } finally {$loaderArchive.Dispose();$loaderMemory.Dispose()}
    $null=$files.CreateOutput($output)
    $rows=@()
    foreach($row in $manifest.files){
        $name=$row.path
        if($name.StartsWith('update-proof/') -or $name -in @('helper-bootstrap/helper.descriptor','helper-bootstrap/helper.signature')){continue}
        if($name -ceq '.deps/bepinex/doorstop_config.ini'){$bytes=$loaderConfig}
        elseif($name -eq 'tools/approved-install-bundles.json'){$bytes=JsonBytes ([ordered]@{schema=1;bundles=@()})}
        else{
            $source=if($replacements.ContainsKey($name)){$build+'/'+$replacements[$name]}elseif($name -match '^(tools/|diagnostics/|Install\.cmd$|Uninstall\.cmd$|README\.md$|THIRD-PARTY-NOTICES/(component-matrix\.json|SOURCES\.md)$)' -and (Test-Path -LiteralPath (Join-Path $project $name) -PathType Leaf)){if($name -ieq 'Install.cmd'){'Install.cmd'}elseif($name -ieq 'Uninstall.cmd'){'Uninstall.cmd'}else{$name}}else{$base+'/'+$name}
            $bytes=Capture $source
            if($source -ceq $base+'/'+$name -and ((Get-BapGaHash $bytes) -cne $row.sha256 -or $bytes.Length -ne $row.bytes)){throw 'Base file changed after validation.'}
            if($Scope -eq 'LocalInstall' -and $name -eq 'README.md'){$bytes=[Text.UTF8Encoding]::new($false).GetBytes("Local development installation: $version. Not published to GitHub.`n`n"+[Text.Encoding]::UTF8.GetString($bytes))}
        }
        $destination='files/'+$name;Parents $destination;$files.Write($destination,$bytes)
        $rows+=[ordered]@{path=$name;bytes=$bytes.Length;sha256=(Get-BapGaHash $bytes)}
    }
    # Only proofs from the new protocol-3 generation may be carried forward.
    $priorSources=@($base+'/update-proof/update.descriptor')
    $priorSources+=@(Get-ChildItem -LiteralPath (Join-Path $project ($base+'/update-proof')) -Filter '*.descriptor' -Recurse -File | Where-Object FullName -ne (Join-Path $project ($base+'/update-proof/update.descriptor')) | ForEach-Object {Relative $_.FullName})
    $priorSources+=@(Get-ChildItem -LiteralPath (Join-Path $project 'releases') -Filter 'update.descriptor' -Recurse -File | ForEach-Object {Relative $_.FullName})
    $priorSeen=@{}
    foreach($source in @($priorSources|Sort-Object -Unique)) {
        $descriptor=Capture $source
        $header=[Text.Encoding]::ASCII.GetString($descriptor).Split([char]10)[0]
        if($header -cne 'BetterAstralParty.UpdateDescriptor/v3'){continue}
        $signature=Capture ($source.Substring(0,$source.Length-'.descriptor'.Length)+'.signature')
        $digest=[BetterAstralParty.Packaging.GaPackageContract]::VerifyHistoricalUpdate($descriptor,$signature)
        if($priorSeen.ContainsKey($digest)){continue}
        if($rows.Count+5 -gt 1024){throw 'Historical ownership proofs exceed the complete package inventory limit.'}
        $priorSeen[$digest]=$true
        foreach($item in @(@{suffix='descriptor';bytes=$descriptor},@{suffix='signature';bytes=$signature})) {
            $name='update-proof/prior/'+$digest+'.'+$item.suffix;$destination='files/'+$name
            Parents $destination;$files.Write($destination,$item.bytes)
            $rows+=[ordered]@{path=$name;bytes=$item.bytes.Length;sha256=(Get-BapGaHash $item.bytes)}
        }
    }
    $files.Write('upstream-loader.zip',$archive)
    $spec=[ordered]@{schema=1;version=$version;upstreamArchiveSha256=$UpstreamSha256;productSourceManifestSha256=$record.sourceManifestSha256;basePackageManifestSha256=$pointer.manifestSha256;files=$rows}
    $specBytes=JsonBytes $spec;$files.Write('input-manifest.json',$specBytes)
    $files.Write('build-source.json',$sourceBytes)
    $files.Write('preparation.json',(JsonBytes ([ordered]@{scope=$Scope;version=$version;inputManifestSha256=(Get-BapGaHash $specBytes);buildRecordSha256=$files.SourceHash($build+'/build-result.json');buildSourceManifestSha256=$record.sourceManifestSha256;basePackageManifestSha256=$pointer.manifestSha256;installed=$false;published=$false})))
    $files.Recheck()
    [ordered]@{version=$version;inputDirectory=(Join-Path $project $output);inputManifestSha256=(Get-BapGaHash $specBytes);installed=$false;published=$false}|ConvertTo-Json
}finally{
    if($bundle){foreach($lease in $bundle.Leases){$lease.Dispose()}}
    $files.Dispose()
}
