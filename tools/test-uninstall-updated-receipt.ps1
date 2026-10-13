param()
$ErrorActionPreference = 'Stop'
# Focused production-AST regression, not package-provenance, native-fence or Steam integration.
# Only inert files in a fresh temporary directory can reach the extracted removal loop.
function Read-Ast([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Invalid script: $Path" }
    return $ast
}
function Part($Ast, [type]$Type, [string]$Start, [string]$Contains = '') {
    $nodes = @($Ast.FindAll({ param($node)
        $node -is $Type -and $node.Extent.Text.StartsWith($Start) -and $node.Extent.Text.Contains($Contains)
    }, $true))
    if ($nodes.Count -ne 1) { throw "Missing or ambiguous production block: $Start" }
    return $nodes[0]
}
function Write-Fixture([string]$Path, [string]$Text) {
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
Add-Type @'
public static class SteamLauncher {
    // Native receipt/channel authentication is a separate test boundary.
    public static void ValidateInstalledReceipt(byte[] bytes) { }
}
'@
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('bap-uninstall-receipt-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($source in @((Join-Path $PSScriptRoot 'uninstall.ps1'))) {
        $ast = Read-Ast $source
        $allowlist = Part $ast ([Management.Automation.Language.AssignmentStatementAst]) '$files = @('
        $receiptRead = Part $ast ([Management.Automation.Language.IfStatementAst]) 'if (Test-Path -LiteralPath $receiptPath'
        $ownership = Part $ast ([Management.Automation.Language.ForEachStatementAst]) 'foreach ($file in $files)'
        $receiptTarget = Part $ast ([Management.Automation.Language.IfStatementAst]) 'if ($receipt -and !$keptReceiptFile)'
        $confirmation = Part $ast ([Management.Automation.Language.IfStatementAst]) 'if (!$PSCmdlet.ShouldProcess('
        $removal = Part $ast ([Management.Automation.Language.ForEachStatementAst]) 'foreach ($entry in $state.Entries)' '$rollbackExpected['
        $hashFunction = Part $ast ([Management.Automation.Language.FunctionDefinitionAst]) 'function Get-UninstallHash('
        $backup = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-InstallTransaction'
        }, $true))
        if ($backup.Count -ne 1 -or $confirmation.Extent.StartOffset -ge $backup[0].Extent.StartOffset -or
            $backup[0].Extent.StartOffset -ge $removal.Extent.StartOffset -or
            $ast.ParamBlock.Attributes.Extent.Text -notmatch 'SupportsShouldProcess=\$true' -or
            $ast.ParamBlock.Attributes.Extent.Text -notmatch "ConfirmImpact='High'") { throw 'Confirmation/backup/removal ordering changed.' }
        if (@($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Assert-BapInstallTransition'
        }, $true)).Count) { throw 'Installation downgrade policy must not gate receipt-owned removal.' }
        $program = @'
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param($GameRoot, $PackageRoot, $FixtureRoot, $Expected, $Probe)
$root = $PackageRoot; $externalBundle = @{Expected=$Expected}
$receiptPath = Join-Path $GameRoot 'BetterAstralParty.install.json'
$receipt = $null; $hashes = @{}; $targets = @(); $plannedHashes = @{}; $keptReceiptFile = $false
function Assert-InstallTarget($Game, $Target) {
    $base = [IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\') + '\'
    $gameBase = [IO.Path]::GetFullPath($Game).TrimEnd('\') + '\'
    if (!$gameBase.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or
        ![IO.Path]::GetFullPath($Target).StartsWith($gameBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture boundary violation.' }
}
function Read-BapInstallFile($Path) { Assert-InstallTarget $GameRoot $Path; return ,([IO.File]::ReadAllBytes($Path)) }
function Read-BapInstallJson([byte[]]$Bytes) { return ([Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json) }
function Get-BapInstallVerifier { return [SteamLauncher].Assembly }
'@
        $program += "`n" + (($hashFunction, $allowlist, $receiptRead, $ownership, $receiptTarget).Extent.Text -join "`n")
        $program += "`n`$Probe.Targets = @(`$targets)`n" + $confirmation.Extent.Text
        $program += @'

$Probe.Confirmed = $true
$state = @{Entries=@($targets | ForEach-Object { @{Target=$_; Hash=$plannedHashes[$_]; Existed=(Test-Path -LiteralPath $_ -PathType Leaf)} })}
$loaderPath = Join-Path $GameRoot 'doorstop_config.ini'; $rollbackExpected = @{}
# Only this boundary is inert: real native deletion is covered by the separate NTFS smoke fixture.
$removalLease = [pscustomobject]@{}
$removalLease | Add-Member ScriptMethod Remove {
    param([string]$Target)
    Assert-InstallTarget $GameRoot $Target
    $entry = @($state.Entries | Where-Object { $_.Target -ceq $Target })
    if ($entry.Count -ne 1) { throw 'Unexpected fixture removal target.' }
    if ($entry[0].Existed) {
        if ((Get-UninstallHash $Target) -cne $entry[0].Hash) { throw 'Fixture file changed before removal.' }
        [IO.File]::Delete($Target)
    } elseif (Test-Path -LiteralPath $Target) { throw 'Fixture missing target appeared.' }
}
$removalLease | Add-Member ScriptMethod WriteLoader { throw 'No loader rewrite is expected in this focused receipt fixture.' }

'@
        $program += "`n" + $removal.Extent.Text
        $fixtureUninstall = [scriptblock]::Create($program)
        # The trusted-package/receipt boundary is covered elsewhere. Here schema-1 receipts
        # contain eight updated owned hashes; every updated byte differs from the old source.
        $files = @(); . ([scriptblock]::Create($allowlist.Extent.Text))
        $product = @($files | Where-Object { $_.Source })
        if ($product.Count -ne 8) { throw 'Review the changed fixed owned inventory.' }
        foreach ($mode in @('updated','modified','injected-shared','legacy')) {
            $case = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
            $game = Join-Path $case 'game'; $package = Join-Path $case 'old-package'
            $expected = @{}; $entries = @()
            foreach ($file in $product) {
                Write-Fixture (Join-Path $package $file.Source) ("baseline source bytes: " + $file.Path)
                $path = Join-Path $game $file.Path
                Write-Fixture $path ("later supported update bytes: " + $file.Path)
                $expected[$file.Path] = Hash (Join-Path $package $file.Source)
                $entries += @{path=$file.Path; sha256=(Hash $path)}
            }
            $dll = Join-Path $game $product[0].Path
            if ($mode -eq 'modified') { Write-Fixture $dll 'User-modified updated DLL; preserve.' }
            $foreign = @('winhttp.dll','BepInEx/core/loader.dll','BepInEx/plugins/OtherMod.dll','BepInEx/plugins/BetterAstralParty/user.keep')
            foreach ($path in $foreign) { Write-Fixture (Join-Path $game $path) 'Unrelated; preserve.' }
            if ($mode -eq 'injected-shared') { $entries[0] = @{path='winhttp.dll'; sha256=(Hash (Join-Path $game 'winhttp.dll'))} }
            $config = Join-Path $game 'BepInEx/config/kr.betterastralparty.mod.cfg'
            Write-Fixture $config 'Owned mod setting.'
            $receiptPath = Join-Path $game 'BetterAstralParty.install.json'
            $receiptFixture=@{schema=1; baseline='1.2.1'; channelState='inert planner boundary substitute'; owner='kr.betterastralparty.mod'; loaderBefore=$false; files=$entries}
            if($mode -eq 'legacy'){$receiptFixture.Remove('baseline');$receiptFixture.Remove('channelState')}
            Write-Fixture $receiptPath ($receiptFixture | ConvertTo-Json -Depth 5)
            $before = @{}; foreach ($file in Get-ChildItem -LiteralPath $game -Recurse -File) { $before[$file.FullName] = Hash $file.FullName }
            $probe = @{Targets=@(); Confirmed=$false}
            if($mode -in @('injected-shared','legacy')){
                foreach($preview in @($false,$true)){
                    $rejected=$false
                    try{$null=& $fixtureUninstall $game $package $scratch $expected $probe -WhatIf:$preview -Confirm:$false}catch{if(!$_.Exception.Message.Contains('Only the new 1.2.1 baseline is supported')){throw};$rejected=$true}
                    if(!$rejected -or $probe.Confirmed){throw 'Unsupported receipt crossed the removal gate.'}
                    foreach($path in $before.Keys){if(!(Test-Path -LiteralPath $path) -or (Hash $path) -cne $before[$path]){throw 'Unsupported receipt rejection changed a fixture.'}}
                }
                continue
            }
            $null = & $fixtureUninstall $game $package $scratch $expected $probe -WhatIf
            if ($probe.Confirmed) { throw 'WhatIf crossed the production confirmation gate.' }
            foreach ($path in $before.Keys) { if (!(Test-Path -LiteralPath $path) -or (Hash $path) -cne $before[$path]) { throw 'WhatIf changed a fixture.' } }
            $remove = @($config)
            if ($mode -ne 'injected-shared') {
                $remove += @($product | ForEach-Object { Join-Path $game $_.Path } | Where-Object { $mode -ne 'modified' -or $_ -ne $dll })
                if ($mode -eq 'updated') { $remove += $receiptPath }
            }
            if ($probe.Targets.Count -ne $remove.Count -or @($probe.Targets | Where-Object { $_ -notin $remove }).Count) { throw "Wrong removal plan: $mode" }
            $null = & $fixtureUninstall $game $package $scratch $expected $probe -Confirm:$false
            if (!$probe.Confirmed) { throw 'Fixture removal did not pass confirmation.' }
            foreach ($path in $before.Keys) {
                if ($path -in $remove) { if (Test-Path -LiteralPath $path) { throw "Updated owned file was not removed: $path" } }
                elseif (!(Test-Path -LiteralPath $path) -or (Hash $path) -cne $before[$path]) { throw "Unknown/modified/shared file was changed: $path" }
            }
        }
    }
    Write-Host 'PASS: current removal blocks accept later supported receipt hashes, preserve modified/shared files, reject legacy/injected receipts before removal, retain confirmation ordering and unchanged WhatIf fixtures. Native authentication is a separate fixture.'
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    if ((Split-Path $resolved -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or (Split-Path $resolved -Leaf) -notlike 'bap-uninstall-receipt-*') { throw 'Unsafe fixture cleanup.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

