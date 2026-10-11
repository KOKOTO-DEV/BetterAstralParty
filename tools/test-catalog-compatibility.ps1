[CmdletBinding()]
param([string]$DotnetRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$artifactRoot=Join-Path $projectRoot 'artifacts'
$buildRoot=Join-Path $artifactRoot ('cat-build-'+[Guid]::NewGuid().ToString('N').Substring(0,12))
$scratch=Join-Path $artifactRoot ('cat-'+[Guid]::NewGuid().ToString('N').Substring(0,12))
foreach($path in @($buildRoot,$scratch)){
    if((Split-Path -Parent $path) -cne $artifactRoot -or (Test-Path -LiteralPath $path)){throw 'Fresh short direct artifact outputs required.'}
}
$savedTelemetry=$env:DOTNET_CLI_TELEMETRY_OPTOUT
$leases=[Collections.Generic.List[IDisposable]]::new();$pins=[ordered]@{}
function Pin([string]$Relative){
    $path=Join-Path $projectRoot $Relative;$file=[IO.File]::Open($path,'Open','Read','Read');$leases.Add($file)
    $pins[$Relative]=(Get-FileHash -InputStream $file -Algorithm SHA256).Hash;$file.Position=0
}
try{
    $env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
    foreach($relative in @('focus-tests/catalog-compatibility/CatalogCompatibilityFixture.csproj','focus-tests/catalog-compatibility/Program.cs','focus-tests/catalog-compatibility/Compare-PowerShell.ps1','tools/test-catalog-compatibility.ps1','tools/check-compatibility.ps1','src/CatalogGuard.cs','NuGet.Config')){Pin $relative}
    foreach($folder in @('updater','src/Observability')){
        foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $projectRoot $folder) -File -Filter '*.cs'|Where-Object {$_.Name -ne 'UpdateHelperProgram.cs'}|Sort-Object Name)){
            Pin ($file.FullName.Substring($projectRoot.Length+1).Replace('\','/'))
        }
    }
    if(!$DotnetRoot){$DotnetRoot=Join-Path $projectRoot '.dotnet'}
    $dotnet=Join-Path $DotnetRoot 'dotnet.exe';$project=Join-Path $projectRoot 'focus-tests/catalog-compatibility/CatalogCompatibilityFixture.csproj'
    $common=@("-p:BaseIntermediateOutputPath=$buildRoot/obj/","-p:MSBuildProjectExtensionsPath=$buildRoot/obj/",'-p:UseSharedCompilation=false','-p:NuGetAudit=false')
    & $dotnet restore $project --configfile (Join-Path $projectRoot 'NuGet.Config') @common
    if($LASTEXITCODE -ne 0){throw 'Catalog fixture restore failed.'}
    & $dotnet build $project --no-restore -c Release -o (Join-Path $buildRoot 'bin') @common
    if($LASTEXITCODE -ne 0){throw 'Catalog fixture build failed.'}
    & $dotnet (Join-Path $buildRoot 'bin/CatalogCompatibilityFixture.dll') $scratch $artifactRoot
    if($LASTEXITCODE -ne 0){throw 'Catalog native/runtime fixture failed; scratch evidence preserved.'}
    $comparison=Join-Path $projectRoot 'focus-tests/catalog-compatibility/Compare-PowerShell.ps1'
    $currentResult=Join-Path $scratch 'powershell-current.json'
    & $comparison -ProjectRoot $projectRoot -Scratch $scratch -SourceSha256 $pins['tools/check-compatibility.ps1'] -ResultPath $currentResult
    $legacy=Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell/v1.0/powershell.exe'
    if(!(Test-Path -LiteralPath $legacy -PathType Leaf)){throw 'Windows PowerShell 5.1 required for parity check.'}
    $legacyResult=Join-Path $scratch 'powershell-5.1.json'
    & $legacy -NoLogo -NoProfile -File $comparison -ProjectRoot $projectRoot -Scratch $scratch -SourceSha256 $pins['tools/check-compatibility.ps1'] -ResultPath $legacyResult
    if($LASTEXITCODE -ne 0){throw 'Windows PowerShell catalog parity failed.'}
    foreach($relative in @($pins.Keys)){
        if((Get-FileHash -LiteralPath (Join-Path $projectRoot $relative) -Algorithm SHA256).Hash -cne $pins[$relative]){throw ('Source changed during fixture: '+$relative)}
    }
    $native=Get-Content -LiteralPath (Join-Path $scratch 'native-results.json') -Raw|ConvertFrom-Json
    $current=Get-Content -LiteralPath $currentResult -Raw|ConvertFrom-Json
    $legacyProof=Get-Content -LiteralPath $legacyResult -Raw|ConvertFrom-Json
    $result=Join-Path $buildRoot 'verification.json'
    @{Passed=$true;Scratch=$scratch;Native=$native;PowerShellCurrent=$current;PowerShell51=$legacyProof;Sources=$pins;ActualGameCacheInstallerSteamOrKeysUsed=$false}|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $result -Encoding UTF8
    Write-Host ('Catalog compatibility combined PASS. Evidence: '+$result)
}finally{
    foreach($lease in $leases){$lease.Dispose()}
    $env:DOTNET_CLI_TELEMETRY_OPTOUT=$savedTelemetry
}
