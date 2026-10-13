param(
    [Parameter(Mandatory)][string]$StageDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[A-F0-9]{64}$')][string]$InputManifestSha256,
    [Parameter(Mandatory)][ValidatePattern('^[A-F0-9]{64}$')][string]$PolicySha256,
    [Parameter(Mandatory)][ValidatePattern('^[A-F0-9]{64}$')][string]$ReviewSha256
)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -lt 7){throw 'PowerShell 7 required.'}
$project=Split-Path -Parent $PSScriptRoot
$boundary=[IO.Path]::GetFullPath((Join-Path $project 'artifacts/automatic-update-development')).TrimEnd('\')
$stageFull=[IO.Path]::GetFullPath($StageDirectory).TrimEnd('\')
if(!$stageFull.StartsWith($boundary+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Local artifact stage required.'}
$stage=$stageFull.Substring($boundary.Length+1).Replace('\','/');$base=$stage+'/inputs';$output=$stage+'/signed-inputs'
. (Join-Path $PSScriptRoot 'ga-package-policy.ps1');Initialize-BapGaPackaging
. (Join-Path $PSScriptRoot 'install-policy.ps1')
$files=[BetterAstralParty.Packaging.DevelopmentPackageFiles]::new($boundary)
function ReadPinned([string]$Path,[string]$Hash){
    $files.Capture($Path)
    if($files.SourceHash($Path) -cne $Hash){throw ('Changed input: '+$Path)}
    return ,$files.ReviewBytes($Path)
}
try{
    $spec=Read-BapGaJson (ReadPinned ($base+'/input-manifest.json') $InputManifestSha256)
    $policy=Read-BapGaJson (ReadPinned ($stage+'/signing-policy.json') $PolicySha256)
    $review=Read-BapGaJson (ReadPinned ($stage+'/signing-review.json') $ReviewSha256)
    if($policy.purpose -cne 'sign-local-install-once' -or $policy.version -cne $spec.version -or $policy.output -cne 'artifacts/automatic-update-development/'+$stage+'/signatures' -or $review.policySha256 -cne $PolicySha256 -or $review.purpose -cne 'approve-local-install-signing' -or $review.status -cne 'approved'){throw 'Exact local signing review required.'}
    $files.Capture($stage+'/signatures/signing-evidence.json');$evidence=Read-BapGaJson ($files.ReviewBytes($stage+'/signatures/signing-evidence.json'))
    if($evidence.signingComplete -ne $true -or $evidence.nativeSignCalls -ne 2 -or $evidence.policySha256 -cne $PolicySha256 -or $evidence.reviewSha256 -cne $ReviewSha256 -or $evidence.helperDescriptorSha256 -cne $policy.helperDescriptorSha256 -or $evidence.updateDescriptorSha256 -cne $policy.updateDescriptorSha256){throw 'Completed bounded signing evidence required.'}
    $rows=@{}
    foreach($row in $spec.files){
        Assert-BapGaPath $row.path
        if($rows.ContainsKey($row.path)){throw 'Duplicate input.'}
        $path=$base+'/files/'+$row.path;$bytes=ReadPinned $path $row.sha256
        if($bytes.Length -ne $row.bytes){throw 'Input length mismatch.'}
        $rows[$row.path]=[ordered]@{path=$row.path;bytes=$row.bytes;sha256=$row.sha256;source=$path}
    }
    if(@(Get-ChildItem -LiteralPath (Join-Path $boundary ($base+'/files')) -Recurse -Force -File).Count -ne $rows.Count){throw 'Unlisted input.'}
    $signed=@(
        @{path='helper-bootstrap/helper.signature';source=$stage+'/signatures/helper.signature';sha256=$evidence.helperSignatureSha256},
        @{path='update-proof/update.descriptor';source=$stage+'/signing-inputs/update.descriptor.unsigned';sha256=$policy.updateDescriptorSha256},
        @{path='update-proof/update.signature';source=$stage+'/signatures/update.signature';sha256=$evidence.updateSignatureSha256}
    )
    foreach($row in $signed){
        if($rows.ContainsKey($row.path)){throw 'Signature/proof already included.'}
        $bytes=ReadPinned $row.source $row.sha256
        $rows[$row.path]=[ordered]@{path=$row.path;bytes=$bytes.Length;sha256=$row.sha256;source=$row.source}
    }
    $helperImage=$files.ReviewBytes($rows['helper-bootstrap/BetterAstralParty-UpdateHelper.exe'].source)
    if((Get-BapGaHash $helperImage) -cne $policy.helperImageSha256){throw 'Helper image changed.'}
    $helperDescriptor=[BetterAstralParty.Packaging.GaPackageContract]::PrepareHelper($spec.version,$helperImage)
    if((Get-BapGaHash $helperDescriptor) -cne $policy.helperDescriptorSha256){throw 'Helper descriptor changed.'}
    $null=[BetterAstralParty.Packaging.GaPackageContract]::VerifyHelper($spec.version,$helperDescriptor,$files.ReviewBytes($signed[0].source),$helperImage)
    $zip=ReadPinned ($stage+'/signing-inputs/payload.zip') $policy.zipSha256
    $proofHash=[BetterAstralParty.Packaging.GaPackageContract]::VerifyWholeUpdate($spec.version,$files.ReviewBytes($signed[1].source),$files.ReviewBytes($signed[2].source),$zip)
    $upstream=$base+'/upstream-loader.zip';$null=ReadPinned $upstream $spec.upstreamArchiveSha256
    [string[]]$names=@($rows.Keys);[Array]::Sort($names,[StringComparer]::Ordinal)
    $manifest=[ordered]@{schema=1;version=$spec.version;upstreamArchiveSha256=$spec.upstreamArchiveSha256;baseInputManifestSha256=$InputManifestSha256;productSourceManifestSha256=$spec.productSourceManifestSha256;signedInputReviewSha256=$ReviewSha256;files=@($names|ForEach-Object{[ordered]@{path=$_;bytes=$rows[$_].bytes;sha256=$rows[$_].sha256}})}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($manifest|ConvertTo-Json -Depth 8))
    $null=$files.CreateOutput($output);$null=$files.CreateSubdirectory('files');$directories=@{}
    foreach($name in $names){
        $parts=$name.Split('/');$current='files'
        for($i=0;$i -lt $parts.Length-1;$i++){$current+='/'+$parts[$i];if(!$directories.ContainsKey($current)){$null=$files.CreateSubdirectory($current);$directories[$current]=$true}}
        $files.CopySource($rows[$name].source,'files/'+$name)
    }
    $files.CopySource($upstream,'upstream-loader.zip');$files.Write('input-manifest.json',$bytes);$files.Recheck()
    [ordered]@{inputDirectory=(Join-Path $boundary $output);inputManifestSha256=(Get-BapGaHash $bytes);files=$rows.Count;helperVerified=$true;updateDescriptorSha256=$proofHash;signingCalls=0;catalogApproved=$false}|ConvertTo-Json
}finally{$files.Dispose()}
