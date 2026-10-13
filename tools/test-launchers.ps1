param([string]$GameRoot = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '8vJXnINT'))
$ErrorActionPreference = 'Stop'
$config = Join-Path $GameRoot 'doorstop_config.ini'
$before = (Get-FileHash -LiteralPath $config).Hash
$logging = Get-Content -LiteralPath (Join-Path $GameRoot 'BepInEx/config/BepInEx.cfg') -Raw
$consoleSection = [regex]::Match($logging, '(?ms)^\[Logging.Console\]\s*\r?\n(.*?)(?=^\[|\z)').Groups[1].Value
$diskSection = [regex]::Match($logging, '(?ms)^\[Logging.Disk\]\s*\r?\n(.*?)(?=^\[|\z)').Groups[1].Value
if ($consoleSection -notmatch '(?m)^Enabled\s*=\s*false\s*$' -or $diskSection -notmatch '(?m)^Enabled\s*=\s*true\s*$') {
    throw '실행 시 로그 콘솔 포커스 방지/파일 로그 유지 설정 누락'
}
if ((Get-Content -LiteralPath $config -Raw) -notmatch '(?m)^enabled\s*=\s*(true|false)\s*$') {
    throw 'Shared loader setting is unavailable.'
}
foreach ($name in 'BetterAstralParty-Mod.cmd', 'AstralParty-Vanilla.cmd', 'BetterAstralParty-Steam.ps1', 'steam-shortcut.ps1') {
    $source = Join-Path $PSScriptRoot $name
    $installed = Join-Path $GameRoot $name
    if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $installed).Hash) {
        throw "설치된 실행기 불일치: $name"
    }
    $text = Get-Content -LiteralPath $source -Raw
    if ($name -like '*.cmd' -and $text -match '(?i)WriteAllText|Set-Content|enabled=true') {
        throw "전역 설정 변경 또는 중복 실행 보호 누락: $name"
    }
}
$mod = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'BetterAstralParty-Mod.cmd') -Raw
$entry = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'SteamLauncher.cs') -Raw
$shortcut = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'steam-shortcut.ps1') -Raw
if (!$mod.Contains('-Mode Launch') -or !$mod.Contains('setlocal') -or $mod.Contains('-applaunch') -or
    !$entry.Contains('--doorstop-enabled true --bap-compatibility-checked') -or
    !$entry.Contains('Process.GetProcessesByName(name)') -or
    !$shortcut.Contains('steam://rungameid/$gameId') -or
    !$entry.Contains('new[] { "SteamAppId", "SteamGameId", "SteamOverlayGameId" }') -or
    !$entry.Contains('start.EnvironmentVariables[name] = "2622000"')) {
    throw 'Steam 경유·일회성 모드 실행 옵션 누락 또는 EXE 직접 실행 회귀'
}
try {
    & (Join-Path $PSScriptRoot 'set-loader-mode.ps1') -Mode Mod -GameRoot $GameRoot
    throw '전역 Mod 활성화가 허용됨'
} catch {
    if ($_.Exception.Message -notlike '*BAP 적용 여부는 실행 항목*') { throw }
}
& (Join-Path $PSScriptRoot 'set-loader-mode.ps1') -Mode Vanilla -GameRoot $GameRoot
if ($before -ne (Get-FileHash -LiteralPath $config).Hash) { throw '검증 중 기본 설정이 변경됨' }
Write-Host 'BAP 실행 항목 구분 · 설치본 일치 · 다른 모드/현재 로더 비변경 검증 통과'
& (Join-Path $PSScriptRoot 'test-steam-shortcut.ps1')
