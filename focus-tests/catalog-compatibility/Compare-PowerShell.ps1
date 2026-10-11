[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][string]$Scratch,
    [Parameter(Mandatory)][string]$SourceSha256,
    [Parameter(Mandatory)][string]$ResultPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$source=Join-Path $ProjectRoot 'tools/check-compatibility.ps1'
if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -cne $SourceSha256){throw 'Pinned PowerShell compatibility source changed.'}
$artifactRoot=Join-Path $ProjectRoot 'artifacts'
$Scratch=[IO.Path]::GetFullPath($Scratch);$ResultPath=[IO.Path]::GetFullPath($ResultPath)
if((Split-Path -Parent $Scratch) -cne $artifactRoot -or (Split-Path -Parent $ResultPath) -cne $Scratch -or (Test-Path -LiteralPath $ResultPath)){throw 'Result must be a new file inside the selected isolated scratch.'}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Compatibility source syntax error.'}
foreach($name in @('Test-BapCatalogInventory','Get-CompatibilityReport')){
    $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
    if($nodes.Count -ne 1){throw ('Missing/ambiguous production function: '+$name)}
    # Import only the two exact function definitions, never the script's launch/exit/log-writing statements.
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}
$checks=0;$document=Get-Content -LiteralPath (Join-Path $Scratch 'policy-cases.json') -Raw|ConvertFrom-Json
$cases=@($document)
foreach($case in $cases){
    $actual=Test-BapCatalogInventory ([string[]]@($case.Expected)) ([string[]]@($case.Actual))
    if($actual -isnot [bool] -or $actual -ne $case.Allowed -or $actual -ne $case.CsResult){throw ('C#/PowerShell policy mismatch: '+$case.Name)}
    $checks++
}
$reports=@()
$expected=@{
    'native-exact'=$true;'native-older'=$true;'native-unknown'=$false;'native-newer'=$false;'native-alias'=$false;'native-uppercase'=$false;
    'native-malformed'=$false;'native-missing'=$false;'native-limit'=$false;
    'native-no-settings-exact'=$true;'native-no-settings-older'=$false;'native-legacy-exact'=$true;'native-legacy-extra'=$false;
    'native-race-catalog_3.3.0'=$false;'native-race-catalog_2.0.0'=$true
}
foreach($folder in @(Get-ChildItem -LiteralPath $Scratch -Directory|Where-Object {$_.Name.StartsWith('native-',[StringComparison]::Ordinal)})){
    $allowed=if($folder.Name.StartsWith('native-digest-',[StringComparison]::Ordinal)){$false}else{
        if(!$expected.ContainsKey($folder.Name)){throw ('Unexpected scratch fixture: '+$folder.Name)};$expected[$folder.Name]
    }
    $GameRoot=$folder.FullName;$CacheRoot=Join-Path $GameRoot 'fixture-cache';$Manifest=Join-Path $GameRoot 'baseline.json';$LoaderRoot=$null
    $report=Get-CompatibilityReport
    if($report.Allowed -ne $allowed){throw ('Production report mismatch: '+$folder.Name+'; '+($report.Issues -join '; '))}
    $reports+=@{Name=$folder.Name;Allowed=$report.Allowed;Issues=@($report.Issues)};$checks++
}
if($reports.Count -ne 19){throw 'Every native compatibility fixture must have a PowerShell report check.'}
@{Passed=$true;PowerShell=$PSVersionTable.PSVersion.ToString();PolicyCases=$cases.Count;ReportCases=$reports.Count;Checks=$checks;SourceSha256=$SourceSha256;AstFunctionsOnly=$true;Reports=$reports}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ResultPath -Encoding UTF8
Write-Host ('Catalog PowerShell '+$PSVersionTable.PSVersion+': '+$checks+' checks PASS; production AST only.')
