param(
    [Parameter(Mandatory)][string]$InputDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[A-F0-9]{64}$')][string]$InputManifestSha256,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('Release','LocalInstall')][string]$Scope='Release',
    [string]$ApprovalRecord,
    [ValidatePattern('^[A-F0-9]{64}$')][string]$ApprovalSha256
)
$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
if($PSVersionTable.PSVersion.Major -lt 7 -or ![Environment]::Is64BitProcess){throw 'PowerShell 7 x64 required.'}
. (Join-Path $PSScriptRoot 'ga-package-policy.ps1')
Initialize-BapGaPackaging
# Keep JSON/metadata functions in this caller scope as well.
. (Join-Path $PSScriptRoot 'install-backup.ps1')
. (Join-Path $PSScriptRoot 'install-policy.ps1')
$project=Split-Path -Parent $PSScriptRoot
$boundary=[IO.Path]::GetFullPath((Join-Path $project 'artifacts/automatic-update-development')).TrimEnd('\')
$prefix=$boundary+'\'
$input=[IO.Path]::GetFullPath($InputDirectory).TrimEnd('\');$output=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
foreach($p in @($input,$output)){if(!$p.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Private isolated artifact boundary required.'}}
if($input -eq $output -or $input.StartsWith($output+'\',[StringComparison]::OrdinalIgnoreCase) -or $output.StartsWith($input+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Input/output overlap rejected.'}
if(Test-Path -LiteralPath $output){throw 'Existing output retained; fresh output required.'}
$relative={param($p) $p.Substring($prefix.Length).Replace('\','/')}
$files=[BetterAstralParty.Packaging.DevelopmentPackageFiles]::new($boundary)
$rows=@{};$captured=@{};$directories=@{};$kind=if($Scope -eq 'LocalInstall'){'local-development-whole-candidate'}else{'private-ga-whole-candidate'}
try{
    $manifestRelative=&$relative (Join-Path $input 'input-manifest.json')
    $files.Capture($manifestRelative)
    if($files.SourceHash($manifestRelative) -cne $InputManifestSha256){throw 'Input manifest hash mismatch.'}
    $spec=Read-BapGaJson ($files.ReviewBytes($manifestRelative))
    if(($spec.schema -isnot [int] -and $spec.schema -isnot [long]) -or $spec.schema -ne 1 -or $spec.version -isnot [string] -or $spec.files -isnot [array] -or ($spec.files.Count -lt 25 -or $spec.files.Count -gt 1024)){throw 'Invalid GA input inventory.'}
    $version=(Get-BapInstallVersion $spec.version).Text
    if((Compare-BapInstallVersion (Get-BapInstallVersion $version) (Get-BapInstallVersion '1.2.1-0')) -lt 0){throw 'Whole maintenance packages require the new 1.2.1 baseline or later.'}
    $expandedInputs=[long]0
    foreach($f in $spec.files){
        if($f.path -isnot [string] -or $f.sha256 -isnot [string] -or $f.sha256 -cnotmatch '\A[A-F0-9]{64}\z' -or ($f.bytes -isnot [int] -and $f.bytes -isnot [long]) -or $f.bytes -le 0){throw 'Invalid GA input entry.'}
        $expandedInputs+=$f.bytes;if($f.bytes -gt 64MB -or $expandedInputs -gt 256MB){throw 'GA input expansion limit exceeded.'}
        Assert-BapGaPath $f.path
        if($f.path.StartsWith('assets/steam/',[StringComparison]::OrdinalIgnoreCase)){throw 'Steam artwork is excluded from this distribution.'}
        if($captured.ContainsKey($f.path)){throw 'Duplicate GA input path.'}
        $rel=&$relative (Join-Path (Join-Path $input 'files') $f.path)
        $files.Capture($rel);$bytes=$files.ReviewBytes($rel)
        if($files.SourceHash($rel) -cne $f.sha256 -or $bytes.Length -ne $f.bytes){throw ('Pinned GA input mismatch: '+$f.path)}
        if(([IO.Path]::GetExtension($f.path) -eq '.cs' -and $f.path -cnotin @('diagnostics/DiagnosticBundle.cs','diagnostics/MinimalDiagnosticProjection.cs')) -or [IO.Path]::GetExtension($f.path) -in @('.pdb','.log','.bak','.dmp','.ttf','.otf','.cfg') -or [IO.Path]::GetFileName($f.path) -like 'test-*' -or [IO.Path]::GetFileName($f.path) -in @('AGENTS.md','development-maintenance.ps1')){throw 'Private/developer input rejected.'}
        if($f.path.EndsWith('.ps1')){$tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseInput([Text.UTF8Encoding]::new($false,$true).GetString($bytes).TrimStart([char]0xFEFF),[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Invalid packaged PowerShell script.'}}
        $captured[$f.path]=@{relative=$rel;bytes=$bytes;sha256=$f.sha256}
    }
    $actual=@(Get-ChildItem -LiteralPath (Join-Path $input 'files') -Recurse -Force -File)
    if($actual.Count -ne $captured.Count){throw 'Unlisted GA input file.'}
    $required=@('install.cmd','Uninstall.cmd','Open-Logs.cmd','Create-Diagnostics.cmd','tools/diagnostics.ps1','diagnostics/DiagnosticBundle.cs','diagnostics/MinimalDiagnosticProjection.cs','README.md','artifacts/BetterAstralParty.dll','artifacts/BetterAstralParty-Launcher.exe','artifacts/BetterAstralParty.compatibility.json','helper-bootstrap/BetterAstralParty-UpdateHelper.exe','tools/install-policy.ps1','tools/install-helper.ps1','tools/install-reinstall.ps1','tools/approved-install-bundles.json','tools/install.ps1','tools/install-bootstrap.ps1','tools/install-backup.ps1','tools/install-log.ps1','tools/find-game.ps1','tools/steam-session.ps1','tools/set-loader-mode.ps1','tools/uninstall.ps1','tools/BetterAstralParty-Mod.cmd','tools/AstralParty-Vanilla.cmd','tools/check-compatibility.ps1','tools/steam-shortcut.ps1','tools/BetterAstralParty-Steam.ps1','.deps/bepinex/BepInEx/core/Mono.Cecil.dll','.deps/bepinex/doorstop_config.ini','.deps/bepinex/winhttp.dll')
    foreach($n in $required){if(!$captured.ContainsKey($n)){throw ('Missing required GA input: '+$n)}}
    foreach($n in @('BepInEx-LICENSE.txt','Doorstop-LICENSE.txt','dotnet-LICENSE.txt','dotnet-THIRD-PARTY-NOTICES.txt','SOURCES.md')){if(!$captured.ContainsKey('THIRD-PARTY-NOTICES/'+$n)){throw 'Missing third-party notice.'}}
    if($captured['.deps/bepinex/BepInEx/core/Mono.Cecil.dll'].sha256 -cne '769A59793D4B8885BBBFBC5AEE8F57A0D4E34D275C56C60C03994309B87F67E9'){throw 'Metadata reader hash mismatch.'}
    $catalog=Read-BapGaJson $captured['tools/approved-install-bundles.json'].bytes
    if(($catalog.schema -isnot [int] -and $catalog.schema -isnot [long]) -or $catalog.schema -ne 1 -or $catalog.bundles -isnot [array] -or $catalog.bundles.Count){throw 'Candidate input catalog must remain empty; use external exact approval.'}
    if($captured.ContainsKey('package-manifest.json') -or $captured.ContainsKey('helper-bootstrap/helper.descriptor')){throw 'Derived manifest/descriptor cannot be supplied as input.'}
    $historyNames=@($captured.Keys|Where-Object {$_.StartsWith('update-proof/prior/',[StringComparison]::Ordinal)})
    foreach($name in $historyNames) {
        if($name -cnotmatch '\Aupdate-proof/prior/([A-F0-9]{64})\.(descriptor|signature)\z'){throw 'Invalid historical proof path.'}
        if($Matches[2] -ceq 'signature'){if(!$captured.ContainsKey($name.Replace('.signature','.descriptor'))){throw 'Historical descriptor missing.'};continue}
        $digest=$Matches[1];$signature=$name.Replace('.descriptor','.signature')
        if(!$captured.ContainsKey($signature) -or [BetterAstralParty.Packaging.GaPackageContract]::VerifyHistoricalUpdate($captured[$name].bytes,$captured[$signature].bytes) -cne $digest){throw 'Historical ownership proof mismatch.'}
    }
    $metadata=@(
        (Assert-BapGaImage $captured['artifacts/BetterAstralParty.dll'].bytes 'Plugin' $version),
        (Assert-BapGaImage $captured['artifacts/BetterAstralParty-Launcher.exe'].bytes 'Launcher' $version),
        (Assert-BapGaImage $captured['helper-bootstrap/BetterAstralParty-UpdateHelper.exe'].bytes 'Helper' $version)
    )
    # Keep the upstream loader ON; launch selection gates BAP, never other mods.
    $loaderRel=&$relative (Join-Path $input 'upstream-loader.zip');$files.Capture($loaderRel)
    if($spec.upstreamArchiveSha256 -isnot [string] -or $files.SourceHash($loaderRel) -cne $spec.upstreamArchiveSha256){throw 'Clean loader archive hash mismatch.'}
    $memory=[IO.MemoryStream]::new($files.ReviewBytes($loaderRel),$false);$archive=[IO.Compression.ZipArchive]::new($memory,'Read');$seen=@{};$expanded=[long]0
    try{
        foreach($e in $archive.Entries){
            $name=$e.FullName.Replace('\','/')
            if($name -cnotmatch '^(winhttp\.dll|doorstop_config\.ini|\.doorstop_version|changelog\.txt|BepInEx/core/[^/]+\.(dll|config)|dotnet/[^/]+\.(dll|json)|dotnet/\.version)$'){continue}
            Assert-BapGaPath $name
            $key='.deps/bepinex/'+$name
            if($seen.ContainsKey($key) -or !$captured.ContainsKey($key) -or $e.Length -le 0 -or $e.Length -gt 64MB){throw 'Invalid clean loader closure.'}
            $expanded+=$e.Length;if($expanded -gt 128MB){throw 'Loader expansion limit exceeded.'}
            $stream=$e.Open();$m=[IO.MemoryStream]::new()
            try{$stream.CopyTo($m);$bytes=$m.ToArray()}finally{$m.Dispose();$stream.Dispose()}
            if((Get-BapGaHash $bytes) -cne $captured[$key].sha256){throw ('Clean loader byte mismatch: '+$name)}
            $seen[$key]=$true
        }
        if(@($captured.Keys|Where-Object {$_.StartsWith('.deps/bepinex/')}).Count -ne $seen.Count){throw 'Unlisted loader input rejected.'}
    }finally{$archive.Dispose();$memory.Dispose()}
    $licenseClosure=Assert-BapGaLicenseClosure $captured $seen $spec.upstreamArchiveSha256
    $compatibility=Read-BapGaJson $captured['artifacts/BetterAstralParty.compatibility.json'].bytes
    foreach($e in $compatibility.files){
        if($e.root -ceq 'game' -and ($e.path -ceq 'winhttp.dll' -or $e.path -cmatch '^BepInEx/core/[^/]+\.dll$')){
            $key='.deps/bepinex/'+$e.path
            if(!$captured.ContainsKey($key) -or $captured[$key].sha256 -cne $e.sha256.ToUpperInvariant()){throw 'Compatibility/clean loader hash mismatch.'}
        }
    }
    foreach($n in $captured.Keys){$rows[$n]=[ordered]@{path=$n;sha256=$captured[$n].sha256;bytes=$captured[$n].bytes.Length}}
    $helperDescriptor=[BetterAstralParty.Packaging.GaPackageContract]::PrepareHelper($version,$captured['helper-bootstrap/BetterAstralParty-UpdateHelper.exe'].bytes)
    $rows['helper-bootstrap/helper.descriptor']=[ordered]@{path='helper-bootstrap/helper.descriptor';sha256=(Get-BapGaHash $helperDescriptor);bytes=$helperDescriptor.Length}
    $signed=$captured.ContainsKey('helper-bootstrap/helper.signature')
    if($signed){$null=[BetterAstralParty.Packaging.GaPackageContract]::VerifyHelper($version,$helperDescriptor,$captured['helper-bootstrap/helper.signature'].bytes,$captured['helper-bootstrap/BetterAstralParty-UpdateHelper.exe'].bytes)}
    $pluginContract=Read-BapInstallMetadata $captured['artifacts/BetterAstralParty.dll'].bytes
    $launcherContract=Read-BapInstallMetadata $captured['artifacts/BetterAstralParty-Launcher.exe'].bytes -Launcher
    $owned=[BetterAstralParty.Packaging.GaPackageContract]::OwnedPaths()
    $map=@{'BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll'='artifacts/BetterAstralParty.dll';'BetterAstralParty-Launcher.exe'='artifacts/BetterAstralParty-Launcher.exe';'BetterAstralParty.compatibility.json'='artifacts/BetterAstralParty.compatibility.json'}
    $previewPayload=[byte[][]]::new($owned.Length)
    for($i=0;$i -lt $owned.Length;$i++){$n=$owned[$i];$source=if($map.ContainsKey($n)){$map[$n]}else{'tools/'+$n};$previewPayload[$i]=$captured[$source].bytes}
    $previewZip=[BetterAstralParty.Packaging.GaPackageContract]::PreviewUpdateZip($previewPayload)
    $previewHash=Get-BapGaHash $previewZip
    $hasDescriptor=$captured.ContainsKey('update-proof/update.descriptor');$hasSignature=$captured.ContainsKey('update-proof/update.signature')
    if($hasDescriptor -ne $hasSignature){throw 'Both update proof descriptor and signature required.'}
    $proofVerified=$false;$proofHash=$null
    if($hasDescriptor){
        $localProof=[Text.Encoding]::ASCII.GetString($captured['update-proof/update.descriptor'].bytes).StartsWith("BetterAstralParty.LocalInstallDescriptor/v1`n",[StringComparison]::Ordinal)
        if($localProof -ne ($Scope -eq 'LocalInstall')){throw 'Local installation proofs and remote release proofs must remain separate.'}
        $proofHash=[BetterAstralParty.Packaging.GaPackageContract]::VerifyWholeUpdate($version,$captured['update-proof/update.descriptor'].bytes,$captured['update-proof/update.signature'].bytes,$previewZip)
        $proofVerified=$true
    }
    $build=Get-BapGaIdentity $rows $kind $version
    [string[]]$names=@($rows.Keys);[Array]::Sort($names,[StringComparer]::Ordinal)
    $reviewInventory=[ordered]@{schema=1;version=$version;kind=$kind;protocol=1;buildIdentity=$build;files=@($names|Where-Object {$_ -cne 'tools/approved-install-bundles.json'}|ForEach-Object {$rows[$_]})}
    $reviewBytes=[Text.UTF8Encoding]::new($false).GetBytes(($reviewInventory|ConvertTo-Json -Depth 8));$reviewHash=Get-BapGaHash $reviewBytes
    $approved=$false;$approval=$null
    if($ApprovalRecord -or $ApprovalSha256){
        Assert-BapWholeUpdateProtocol $pluginContract $launcherContract
        if($pluginContract.UpdateProtocol -ceq '3' -and !$proofVerified){throw 'Verified signed owned8 update proof required before whole approval.'}
        if(!$ApprovalRecord -or !$ApprovalSha256 -or !$signed){throw 'Signed helper and exact external approval required.'}
        $approvalPath=[IO.Path]::GetFullPath($ApprovalRecord)
        if(!$approvalPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Approval record must be in the private review boundary.'}
        $approvalRelative=&$relative $approvalPath;$files.Capture($approvalRelative)
        if($files.SourceHash($approvalRelative) -cne $ApprovalSha256){throw 'Approval record hash mismatch.'}
        $approval=Read-BapGaJson ($files.ReviewBytes($approvalRelative))
        foreach($name in @('purpose','status','version','kind','buildIdentity','reviewInventorySha256','reviewReference')){
            if($approval.$name -isnot [string]){throw 'External approval scalar type mismatch.'}
        }
        if(($approval.schema -isnot [int] -and $approval.schema -isnot [long]) -or $approval.schema -ne 1 -or $approval.purpose -cne 'approve-ga-whole-bundle' -or $approval.status -cne 'approved' -or $approval.version -cne $version -or $approval.kind -cne $kind -or ($approval.protocol -isnot [int] -and $approval.protocol -isnot [long]) -or $approval.protocol -ne 1 -or $approval.buildIdentity -cne $build -or $approval.reviewInventorySha256 -cne $reviewHash -or $approval.reviewReference -isnot [string] -or !$approval.reviewReference){throw 'External approval binding mismatch.'}
        $approved=$true
    }
    $catalogBytes=[Text.UTF8Encoding]::new($false).GetBytes((([ordered]@{schema=1;bundles=@(if($approved){[ordered]@{buildIdentity=$build;version=$version;kind=$kind;protocol=1}})})|ConvertTo-Json -Depth 5))
    $rows['tools/approved-install-bundles.json']=[ordered]@{path='tools/approved-install-bundles.json';sha256=(Get-BapGaHash $catalogBytes);bytes=$catalogBytes.Length}
    if((Get-BapGaIdentity $rows $kind $version) -cne $build){throw 'Catalog changed content identity.'}
    $outputId=$files.CreateOutput((&$relative $output));$null=$files.CreateSubdirectory('payload');$null=$files.CreateSubdirectory('update-payload')
    function Ensure-BapGaDirectory([string]$Path){
        $parts=$Path.Split('/');$current=''
        for($i=0;$i -lt $parts.Length-1;$i++){
            $current=if($current){$current+'/'+$parts[$i]}else{$parts[$i]}
            if($current -in @('payload','update-payload')){continue}
            if(!$directories.ContainsKey($current)){$null=$files.CreateSubdirectory($current);$directories[$current]=$true}
        }
    }
    foreach($n in $captured.Keys){
        if($n -ceq 'tools/approved-install-bundles.json'){continue}
        Ensure-BapGaDirectory ('payload/'+$n);$files.CopySource($captured[$n].relative,('payload/'+$n))
    }
    Ensure-BapGaDirectory 'payload/tools/approved-install-bundles.json';$files.Write('payload/tools/approved-install-bundles.json',$catalogBytes)
    $files.Write('payload/helper-bootstrap/helper.descriptor',$helperDescriptor)
    [string[]]$names=@($rows.Keys);[Array]::Sort($names,[StringComparer]::Ordinal)
    $manifest=[ordered]@{schema=1;version=$version;kind=$kind;buildIdentity=$build;files=@($names|ForEach-Object {$rows[$_]})}
    $manifestBytes=[Text.UTF8Encoding]::new($false).GetBytes(($manifest|ConvertTo-Json -Depth 8))
    $files.Write('payload/package-manifest.json',$manifestBytes)
    $owned=[BetterAstralParty.Packaging.GaPackageContract]::OwnedPaths()
    $map=@{'BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll'='artifacts/BetterAstralParty.dll';'BetterAstralParty-Launcher.exe'='artifacts/BetterAstralParty-Launcher.exe';'BetterAstralParty.compatibility.json'='artifacts/BetterAstralParty.compatibility.json'}
    $updateInventory=@()
    foreach($n in $owned){
        $source=if($map.ContainsKey($n)){$map[$n]}else{'tools/'+$n}
        Ensure-BapGaDirectory ('update-payload/'+$n);$files.CopySource($captured[$source].relative,('update-payload/'+$n))
        $updateInventory+=[ordered]@{path=$n;sha256=$captured[$source].sha256;bytes=$captured[$source].bytes.Length}
    }
    $wholeName='BetterAstralParty-'+$version+$(if($approved){''}else{'-unsigned-candidate'})+'.zip'
    $updateName='BetterAstralParty-'+$version+'-update.zip'
    $wholeHash=$files.Archive($wholeName,'payload',$true);$updateHash=$files.Archive($updateName,'update-payload',$true)
    if($updateHash -cne $previewHash){throw 'Deterministic update ZIP differs from verified preview.'}
    foreach($v in @(@($wholeName,$wholeHash),@($updateName,$updateHash))){$files.Write(($v[0]+'.sha256'),[Text.Encoding]::ASCII.GetBytes($v[1]+'  '+$v[0]+[char]10))}
    $files.Write('review-inventory.json',$reviewBytes)
    $proposal=[ordered]@{schema=1;purpose='approve-ga-whole-bundle';status='pending';version=$version;kind=$kind;protocol=1;buildIdentity=$build;reviewInventorySha256=$reviewHash;candidateManifestSha256=(Get-BapGaHash $manifestBytes);helperSigned=$signed;exactApprovalReady=$signed -and ($pluginContract.UpdateProtocol -cne '3' -or $proofVerified);updateProofVerified=$proofVerified;reviewReference=$null}
    $files.Write('catalog-proposal.json',[Text.UTF8Encoding]::new($false).GetBytes(($proposal|ConvertTo-Json -Depth 6)))
    $state=[ordered]@{schema=1;version=$version;kind=$kind;sourceInputManifestSha256=$InputManifestSha256;buildIdentity=$build;catalogRegistered=$approved;licenseClosure=$licenseClosure;installableRelease=$approved -and $signed -and ($pluginContract.UpdateProtocol -cne '3' -or $proofVerified);updateProofVerified=$proofVerified;updateProofDescriptorSha256=$proofHash;helperSignatureVerified=$signed;helperDescriptorSha256=(Get-BapGaHash $helperDescriptor);helperImageSha256=$captured['helper-bootstrap/BetterAstralParty-UpdateHelper.exe'].sha256;publicKeyIds=@([BetterAstralParty.Packaging.GaPackageContract]::PublicKeyIds());operationalTrustConfigured=([BetterAstralParty.Packaging.GaPackageContract]::PublicKeyIds().Count -gt 0);runtimeAuthenticationConnected=$null;runtimeHelperInstalled=$false;privateCredentialInputCompiled=$metadata[0].credentialInputCompiled;credentialsAccessed=$false;operationalPrivateKeyAccessed=$false;updateDescriptorReady=$proofVerified;updateReleaseAndAssetIds=$null;updateInventory=$updateInventory;wholeZip=$wholeName;wholeZipSha256=$wholeHash;updateZipSha256=$updateHash;cleanLoaderSourceSha256=$spec.upstreamArchiveSha256;inputPinned=$true;outputRootIdentity=$outputId;metadata=$metadata}
    $files.Write('candidate-state.json',[Text.UTF8Encoding]::new($false).GetBytes(($state|ConvertTo-Json -Depth 8)))
    $files.Recheck()
    Write-Output ($state|ConvertTo-Json -Depth 8)
}finally{$files.Dispose()}

