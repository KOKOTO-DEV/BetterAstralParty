$ErrorActionPreference='Stop'
function Ast([string]$Name) {
    $tokens=$null; $errors=$null
    $result=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw "Invalid script: $Name"}
    return $result
}
$install=Ast 'install.ps1'
if(@($install.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.Extent.Text.Contains("'set-loader-mode.ps1'")},$true)).Count){throw 'Installation must not toggle the shared loader.'}
$uninstall=Ast 'uninstall.ps1'
$default=$uninstall.ParamBlock.Parameters | Where-Object {$_.Name.VariablePath.UserPath -eq 'RestoreLoader'}
if($default.DefaultValue.Value -cne 'Keep'){throw 'Removal must preserve current shared configuration by default.'}
$blocks=@($uninstall.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith("if (`$RestoreLoader -ne 'Keep'")},$true))
if($blocks.Count -ne 1){throw 'Expected the production explicit-loader-restoration block.'}
$block=[scriptblock]::Create($blocks[0].Extent.Text)
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('bap-shared-loader-'+[guid]::NewGuid().ToString('N'))
try {
    $null=[IO.Directory]::CreateDirectory($scratch)
    $loaderPath=Join-Path $scratch 'doorstop_config.ini'; $targets=@('owned'); $WhatIfPreference=$false
    function Read-Host {throw 'Default removal must not prompt about shared loader settings.'}
    foreach($baseline in @($true,$false,$null)) {
        $receipt=@{loaderBefore=$baseline}
        foreach($current in @('true','false','malformed')) {
            $text="[General]`nenabled=$current`ncustom=keep`n"
            [IO.File]::WriteAllText($loaderPath,$text,[Text.UTF8Encoding]::new($true))
            $before=(Get-FileHash -LiteralPath $loaderPath).Hash
            $RestoreLoader='Keep'; $loaderText=$null; $loaderUpdated=$null
            . $block
            if($null -ne $loaderUpdated -or (Get-FileHash -LiteralPath $loaderPath).Hash -cne $before){throw 'Default removal touched shared configuration.'}
        }
    }
    foreach($choice in @('Enabled','Disabled')) {
        [IO.File]::WriteAllText($loaderPath,"[General]`nenabled=false`ncustom=keep`n")
        $RestoreLoader=$choice; $loaderUpdated=$null
        . $block
        $expected=if($choice -eq 'Enabled'){'true'}else{'false'}
        if($loaderUpdated -cne "[General]`nenabled=$expected`ncustom=keep`n"){throw 'Explicit loader choice lost unrelated configuration.'}
    }
    $RestoreLoader='Recorded'
    foreach($baseline in @($true,$false)) {
        $receipt=@{loaderBefore=$baseline}
        foreach($current in @('true','false')) {
            [IO.File]::WriteAllText($loaderPath,"[General]`nenabled=$current`ncustom=keep`n")
            $loaderUpdated=$null; . $block
            $expected=if($current -eq 'true' -or $baseline){'true'}else{'false'}
            if($loaderUpdated -cne "[General]`nenabled=$expected`ncustom=keep`n"){throw 'Explicit recorded baseline changed policy.'}
        }
    }
    function Read-Host {return '1'}
    $receipt=@{loaderBefore=$null}
    [IO.File]::WriteAllText($loaderPath,"[General]`nenabled=false`ncustom=keep`n")
    $loaderUpdated=$null; . $block
    if($loaderUpdated -cne "[General]`nenabled=true`ncustom=keep`n"){throw 'Unknown recorded baseline must use explicit choice.'}
    $plugin=[IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Plugin.cs'))
    $load=$plugin.IndexOf('public override void Load()',[StringComparison]::Ordinal)
    $gate=$plugin.IndexOf('Environment.GetEnvironmentVariable("BAP_COMPATIBILITY_CHECKED")',$load,[StringComparison]::Ordinal)
    $start=$plugin.IndexOf('MinimalDiagnostics = DiagnosticOwner.Start(',$load,[StringComparison]::Ordinal)
    if($gate -le $load -or $gate -ge $start -or !$plugin.Substring($gate,$start-$gate).Contains('return;')){throw 'Ordinary launch must return before BAP initialization.'}
    Write-Host 'PASS: installation does not toggle existing loader; default uninstall preserves ON/OFF/unknown bytes for all recorded baselines; explicit choices remain; ordinary launch returns before BAP setup.'
    Write-Host 'Scope: production AST/ordering checks, not native runtime or third-party coexistence.'
} finally {
    $resolved=[IO.Path]::GetFullPath($scratch)
    if((Split-Path $resolved -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or (Split-Path $resolved -Leaf) -notlike 'bap-shared-loader-*'){throw 'Unsafe fixture cleanup.'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
