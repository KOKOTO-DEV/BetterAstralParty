# Read-only assessment. Does not change security settings or unquarantine files.
[CmdletBinding()]
param([string]$Folder=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($Folder)
Write-Host "BetterAstralParty security preflight: $root"
Write-Host 'This tool does NOT disable Defender, SmartScreen, execution policy or antivirus.'
$policy=Get-ExecutionPolicy -List
$policy | Format-Table -AutoSize
$extensions=@('.exe','.dll','.ps1','.cmd')
$items=@(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction Stop | Where-Object {$_.Extension -in $extensions} | Select-Object -First 250)
$rows=foreach($file in $items) {
    $signature=if ($file.Extension -in @('.exe','.dll','.ps1')) {try {(Get-AuthenticodeSignature -LiteralPath $file.FullName).Status.ToString()}catch{'Unknown'}}else{'NotApplicable'}
    $zone=try {$value=Get-Item -LiteralPath $file.FullName -Stream Zone.Identifier -ErrorAction Stop;[bool]$value} catch {$false}
    [pscustomobject]@{File=$file.FullName.Substring($root.Length).TrimStart('\');Signature=$signature;InternetZone=$zone}
}
$rows|Format-Table -AutoSize
Write-Host 'If Explorer/Defender quarantined a file, review Windows Security > Protection history.'
Write-Host 'For false positives, submit the file + SHA256 to Microsoft instead of creating exclusions.'
Write-Host 'Mapped/network drives may be treated as a remote security zone; extract trusted source to a local folder.'
