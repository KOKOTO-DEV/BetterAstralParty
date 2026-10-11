param(
    [Parameter(Mandatory)]
    [ValidateSet('Mod','Vanilla')]
    [string]$Mode,
    [string]$GameRoot = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '8vJXnINT')
)

$ErrorActionPreference = 'Stop'
if ($Mode -eq 'Mod') {
    throw 'BAP 적용 여부는 실행 항목에서 선택합니다. 게임 폴더의 BetterAstralParty-Mod.cmd로 실행하세요.'
}
Write-Host 'BAP 없이 실행하려면 원래 Steam 항목을 선택하세요. 공용 로더와 다른 모드는 변경하지 않습니다. / Use the original Steam entry without BAP; shared loader and other mods are unchanged.'
