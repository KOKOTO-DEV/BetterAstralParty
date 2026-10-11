$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'install-log.ps1')
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('bap-install-log-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$savedLocal = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $scratch
$passed = $false
try {
    try { throw "Fixture failure at $env:USERPROFILE" } catch { $failure = $_ }
    $log = Write-InstallFailure $failure 'Compatibility validation' $scratch 'D:\Game'
    $text = Get-Content -LiteralPath $log -Raw
    if (!$text.Contains('Stage: Compatibility validation') -or !$text.Contains('Fixture failure') -or
        !$text.Contains('%USERPROFILE%') -or $text.Contains($env:USERPROFILE)) { throw 'Log fields/redaction failed' }
    if (!$text.Contains(('HResult: ' + ('0x{0:X8}' -f $failure.Exception.HResult))) -or
        !$text.Contains('Exception: ') -or !$text.Contains($failure.Exception.GetType().FullName) -or
        !$text.EndsWith([Environment]::NewLine)) { throw 'Detailed exception or HRESULT missing' }
    $again = Write-InstallFailure $failure 'Discovery' $scratch ''
    if ($again -eq $log -or !(Test-Path -LiteralPath $log)) { throw 'Failure logs must not overwrite each other' }
    $blocked = Join-Path $scratch 'not-a-directory'
    [IO.File]::WriteAllText($blocked, 'fixture')
    $env:LOCALAPPDATA = $blocked
    $fallback = Write-InstallFailure $failure 'Backup' $blocked ''
    $env:LOCALAPPDATA = $scratch
    $expected = Join-Path ([IO.Path]::GetTempPath()) 'BetterAstralParty'
    if ((Split-Path $fallback -Parent) -ne $expected) { throw 'Unwritable package fallback failed' }
    Remove-Item -LiteralPath $fallback
    # Exercise the production catch, with an isolated registry failure before any writes.
    $installer = Get-Content (Join-Path $PSScriptRoot 'install.ps1') -Raw
    $installer = $installer.Replace('$root = Split-Path -Parent $PSScriptRoot', ('$root = ''' + $scratch.Replace("'", "''") + ''''))
    $installer = $installer.Replace('$PSScriptRoot', ("'" + $PSScriptRoot.Replace("'", "''") + "'"))
    function Get-ItemProperty { throw 'Fixture registry inaccessible' }
    try { & ([scriptblock]::Create($installer)); throw 'Installer swallowed failure' }
    catch { if ($_.Exception.Message -notlike '*Fixture registry inaccessible*') { throw } }
    $logs = @(Get-ChildItem (Join-Path $scratch 'BetterAstralParty/Logs') -File)
    if ($logs.Count -ne 3 -or !($logs | Where-Object { (Get-Content $_.FullName -Raw).Contains('Stage: Steam registration lookup') })) {
        throw 'Early installation error was not logged'
    }
    Write-Output 'PASS: installation failure logging, original error, unique files, profile masking and unwritable-folder fallback.'
    $passed = $true
} finally {
    $env:LOCALAPPDATA = $savedLocal
    $resolved = [IO.Path]::GetFullPath($scratch)
    if ((Split-Path $resolved -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or
        (Split-Path $resolved -Leaf) -notlike 'bap-install-log-*') { throw 'Unsafe fixture cleanup' }
    if ($passed) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    else { Write-Warning ('Failed logging fixture preserved: ' + $resolved) }
}
