# Key-free validation; Execute permits one bounded local signing run per version, never a retry.
[CmdletBinding()]
param(
    [ValidateSet('SelfCheck','Validate','Execute')][string]$Mode='Validate',
    [string]$PolicyPath,
    [ValidatePattern('^[A-F0-9]{64}$')][string]$PolicySha256,
    [ValidatePattern('^[A-F0-9]{64}$')][string]$ReviewSha256
)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 7 -or ![Environment]::Is64BitProcess){throw 'PowerShell 7 x64 required.'}
if($Mode -ne 'SelfCheck' -and (!$PolicySha256 -or !$PolicyPath)){throw 'Exact reviewed policy SHA-256 required.'}
if($Mode -eq 'Execute' -and !$ReviewSha256){throw 'Exact independent signing review SHA-256 required.'}
$project=Split-Path $PSScriptRoot -Parent
if($Mode -ne 'SelfCheck'){
    if($PolicyPath -cnotmatch '\Aartifacts/automatic-update-development/[A-Za-z0-9/_-]+/signing-policy\.json\z' -or $PolicyPath.Split('/') -contains '..'){throw 'Local signing policy path required.'}
    $stage=$PolicyPath.Substring(0,$PolicyPath.LastIndexOf('/'))
}
$leases=[Collections.Generic.List[IO.FileStream]]::new()
function Read-Locked([string]$Relative,[string]$Hash){
    if($Relative.Contains('\') -or $Relative.Contains(':') -or $Relative.Split('/') -contains '..'){throw 'Unsafe tool path.'}
    $stream=[IO.FileStream]::new((Join-Path $project $Relative),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $leases.Add($stream)
    if($stream.Length -le 0 -or $stream.Length -gt 67108864){throw 'Reviewed file size bound.'}
    $bytes=[byte[]]::new([int]$stream.Length);$position=0
    while($position -lt $bytes.Length){$count=$stream.Read($bytes,$position,$bytes.Length-$position);if(!$count){throw 'Incomplete reviewed input.'};$position+=$count}
    if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $Hash){throw ('Reviewed file changed: '+$Relative)}
    return ,$bytes
}
try{
    $names=@('tools/DevelopmentPackageFiles.cs','tools/GaPackageContract.cs','diagnostics/MinimalDiagnosticProjection.cs')
    $names+=@(Get-ChildItem -LiteralPath (Join-Path $project 'updater') -Filter '*.cs' -File|Where-Object Name -ne 'UpdateHelperProgram.cs'|ForEach-Object {'updater/'+$_.Name})
    $names+=@(Get-ChildItem -LiteralPath (Join-Path $project 'src/Observability') -Filter '*.cs' -File|ForEach-Object {'src/Observability/'+$_.Name})
    $names+='tools/SignLocalInstall.cs'
    if($Mode -eq 'SelfCheck'){
        $rows=@($names|ForEach-Object {[pscustomobject]@{path=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $project $_) -Algorithm SHA256).Hash}})
    }else{
        $policy=[Text.Encoding]::UTF8.GetString((Read-Locked ($stage+'/signing-policy.json') $PolicySha256))|ConvertFrom-Json
        $rows=@($policy.compiledFiles)
        if($rows.Count -ne $names.Count -or (@($rows.path|Sort-Object -Unique).Count -ne $names.Count) -or (Compare-Object ($names|Sort-Object) ($rows.path|Sort-Object))){throw 'Unexpected compiled file scope.'}
        if(@($policy.toolFiles).Count -ne 2 -or (Compare-Object (@('tools/SignLocalInstall.cs','tools/sign-local-install.ps1')|Sort-Object) ($policy.toolFiles.path|Sort-Object))){throw 'Unexpected tool scope.'}
        foreach($row in $policy.toolFiles){Read-Locked $row.path $row.sha256|Out-Null}
        if($ReviewSha256){Read-Locked ($stage+'/signing-review.json') $ReviewSha256|Out-Null}
    }
    $compile=@()
    foreach($row in $rows){Read-Locked $row.path $row.sha256|Out-Null;$compile+=Join-Path $project $row.path}
    if('BetterAstralParty.GaSigning.SignLocalInstall' -as [type] -or 'BetterAstralParty.Updating.WindowsFileFence' -as [type]){throw 'Preloaded signing types; use a fresh PowerShell process.'}
    Add-Type -Path $compile
    foreach($lease in $leases){$lease.Dispose()};$leases.Clear()
    switch($Mode){
        'SelfCheck' {[BetterAstralParty.GaSigning.SignLocalInstall]::SelfCheck()}
        'Validate' {[BetterAstralParty.GaSigning.SignLocalInstall]::Validate($project,$PolicyPath,$PolicySha256,$(if($ReviewSha256){$ReviewSha256}else{$null}))}
        'Execute' {[BetterAstralParty.GaSigning.SignLocalInstall]::Execute($project,$PolicyPath,$PolicySha256,$ReviewSha256)}
    }
}finally{foreach($lease in $leases){$lease.Dispose()}}
