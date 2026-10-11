param(
    [ValidateSet('Menu','Collect','Open')][string]$Action = 'Menu',
    [string]$GameRoot = '',
    [ValidateSet('ko','en')][string]$Language = 'ko',
    [switch]$NoOpen
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Say([string]$Ko, [string]$En) { if ($Language -eq 'ko') { Write-Host $Ko } else { Write-Host $En } }
function Resolve-DiagnosticsGameRoot([string]$Selected, [string]$Deployment) {
    # Fixed adjacent INT probes only; the collector still validates and pins the selected root.
    $candidates = if ($Selected) { @($Selected, (Join-Path $Selected '8vJXnINT')) }
        else { @($Deployment, (Join-Path $Deployment '8vJXnINT'), (Split-Path -Parent $Deployment), (Join-Path (Split-Path -Parent $Deployment) '8vJXnINT')) }
    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath (Join-Path $candidate 'AstralParty_INT.exe') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $candidate 'AstralParty_INT_Data') -PathType Container)) { return $candidate }
    }
    if ($Selected) {
        if ((Split-Path -Leaf $Selected) -ne '8vJXnINT' -and (Test-Path -LiteralPath (Join-Path $Selected '8vJXnINT') -PathType Container)) { return Join-Path $Selected '8vJXnINT' }
        return $Selected
    }
    foreach ($candidate in $candidates) {
        if ((Split-Path -Leaf $candidate) -eq '8vJXnINT' -and (Test-Path -LiteralPath $candidate -PathType Container)) { return $candidate }
    }
    return ''
}
try {
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'diagnostics/DiagnosticBundle.cs'
    if (!(Test-Path -LiteralPath $source -PathType Leaf)) { throw 'BAP-DIAGNOSTICS-TOOL-MISSING' }
    $projection = Join-Path (Split-Path -Parent $PSScriptRoot) 'diagnostics/MinimalDiagnosticProjection.cs'
    if (!(Test-Path -LiteralPath $projection -PathType Leaf)) { throw 'BAP-DIAGNOSTICS-PROJECTION-MISSING' }
    if (!('BetterAstralParty.Diagnostics.DiagnosticBundle' -as [type])) {
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            Add-Type -Path @($source,$projection) -ReferencedAssemblies 'System.dll','System.Core.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll'
        } else { Add-Type -Path @($source,$projection) }
    }
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $profile = [Environment]::GetFolderPath('UserProfile')
    $temp = [IO.Path]::GetTempPath()
    $primaryHub = Join-Path $local 'BetterAstralParty/Diagnostics'
    $fallbackHub = Join-Path $temp 'BetterAstralParty/Diagnostics'
    if ($Action -eq 'Menu') {
        Say '1: 진단 ZIP 만들기  2: 진단 폴더 열기  Enter: 종료' '1: Create diagnostics ZIP  2: Open diagnostics folder  Enter: Exit'
        $choice = Read-Host
        if ($choice -eq '1') { $Action = 'Collect' } elseif ($choice -eq '2') { $Action = 'Open' } else { exit 0 }
    }
    if ($Action -eq 'Open') {
        $lease = [BetterAstralParty.Diagnostics.DiagnosticBundle]::AcquireHub($primaryHub, $fallbackHub)
        try {
            $hub = $lease.Path
            Say "진단 폴더: $hub" "Diagnostics folder: $hub"
            Say 'Create-Diagnostics.cmd로 ZIP을 만든 뒤 ZIP 안의 로그를 볼 수 있습니다.' 'Create a ZIP with Create-Diagnostics.cmd, then open its logs.'
            if (!$NoOpen) { $lease.Open([Action[string]]{ param($folder) Start-Process -FilePath $folder }) }
        } finally { $lease.Dispose() }
        exit 0
    }
    if (!$GameRoot) {
        # Probe only adjacent deployment roots; no registry, account, Steam profile or recursive search.
        $deployment = Split-Path -Parent $PSScriptRoot
        $GameRoot = Resolve-DiagnosticsGameRoot '' $deployment
        if (!$GameRoot) {
            Say 'Steam의 설치 폴더 경로를 붙여 넣으세요. 비워 두면 설치·런처·Unity 로그만 수집합니다.' 'Paste the INT installation folder from Steam. Leave blank for install/launcher/Unity logs only.'
            $GameRoot = Read-Host
        }
    }
    if ($GameRoot) { $GameRoot = Resolve-DiagnosticsGameRoot $GameRoot (Split-Path -Parent $PSScriptRoot) }
    Say '최근 설치·초기 실행·런처·호환성 오류 본문과 게임 진단 요약을 ZIP에 포함합니다. 토큰·개인 경로는 가리며 카드·손패·채팅·덤프·전체 설정은 제외합니다.' 'Including recent install/bootstrap/launcher/compatibility error text and game diagnostic summaries. Tokens and private paths are redacted; card/hand/chat payload, dumps and full settings are excluded.'
    Say '카탈로그는 파일명·크기·SHA-256 목록만 포함하며 원본 내용은 제외합니다.' 'Catalogs contribute filenames, sizes and SHA-256 only, never their contents.'
    Say '게임 파일이 일부 없어도 고정 모드 파일·복구·백업 표식의 존재와 해시를 기록합니다. 복구 기록 원문·인증 저장소는 제외합니다.' 'Fixed mod files and recovery/backup marker presence and hashes are collected even when game files are missing. Raw recovery records and credential stores are excluded.'
    $bundle = [BetterAstralParty.Diagnostics.DiagnosticBundle]::Collect($GameRoot,
        (Join-Path $local 'BetterAstralParty/Logs'), (Join-Path $temp 'BetterAstralParty'),
        (Join-Path $profile 'AppData/LocalLow/feimo/AstralParty_INT'), $primaryHub, $fallbackHub,
        $PSVersionTable.PSVersion.ToString())
    Say "ZIP 생성됨: $($bundle.ArchivePath)" "ZIP created: $($bundle.ArchivePath)"
    Say "포함 로그 $($bundle.Included)개, 제외·누락 항목 $($bundle.Omitted)개. summary.json에서 이유를 확인하세요." "Included $($bundle.Included) logs, omitted/missing $($bundle.Omitted) items. See summary.json for reasons."
    Say '카탈로그 목록과 해시 제한·누락 사유는 catalog-inventory.json에서 확인하세요.' 'See catalog-inventory.json for catalog metadata and hash limits or omission reasons.'
    Say '모드 파일·복구 표식의 관측 목록은 recovery-inventory.json에서 확인하세요. 설치 정상 또는 안전 복구 판정은 아닙니다.' 'See recovery-inventory.json for mod file and recovery marker observations; it does not verify installation or authorize recovery.'
    Say '개인정보가 남을 수 있습니다. ZIP 내용을 확인한 뒤 개발자에게 직접 첨부하세요.' 'Unrecognised personal data may remain. Review the ZIP, then attach it to the developer yourself.'
    if (!$NoOpen) {
        try { $bundle.OpenFolder([Action[string]]{ param($folder) Start-Process -FilePath $folder }) }
        catch { Say 'ZIP은 생성됐지만 폴더를 열지 못했습니다. 위 경로로 직접 열어 주세요.' 'The ZIP was created, but the folder could not open. Use the path above.' }
    }
    exit 0
} catch {
    # Exception messages/paths may themselves contain private information. Print fixed codes only.
    Say 'BAP-DIAGNOSTICS-FAILED: 진단 도구 또는 쓰기 권한을 확인하고 다시 실행하세요. 기존 로그는 보존됩니다.' 'BAP-DIAGNOSTICS-FAILED: Check the diagnostics tool and write permissions, then retry. Existing logs are preserved.'
    exit 1
}
