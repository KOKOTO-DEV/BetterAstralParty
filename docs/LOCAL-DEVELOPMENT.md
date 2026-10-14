# BetterAstralParty 1.2.1 local modified source (not GA)

## 변경 사항

- **F8 → 일반 설정 → 자동 감사합니다**: ON/OFF 스위치, 기본 ON, BepInEx 설정 자동 저장. OFF는 `AutoThanksUi.Tick()` 호출의 전송만 차단하고 기본 게임 입력은 바꾸지 않습니다.
- **Force-Uninstall.cmd**: 설치 영수증이나 업데이트/Helper 상태가 망가져도 BetterAstralParty 전용 파일·설정·로그·복구 백업을 영구 제거. 게임 파일, 공유 BepInEx 코어, 다른 플러그인은 삭제하지 않습니다. 게임/런처/Helper 종료가 전제이고 전체 목록·확인 문구를 거칩니다. `-KeepLocalData`로 로그·백업을 보존할 수 있습니다.
- **Build-Local.cmd / tools/build-local.ps1**: PowerShell 7 x64 및 로컬 .NET 8.0.425 / .NET 6 참조팩 환경에서 Plugin DLL, Launcher EXE, UpdateHelper EXE를 컴파일하고 해시/Authenticode 상태 매니페스트와 개발 결과 ZIP을 만듭니다.
- **Check-Security.cmd**: 실행 정책, 코드 서명, 다운로드 영역 표시를 변경 없이 조회합니다.

## 강제 제거 (영구 삭제)

기존 안전 제거 `Uninstall.cmd`는 공식 설치 ZIP에서만 동작합니다. 강제 제거는 **별개**입니다. 먼저 `Create-Diagnostics.cmd`로 필요한 로그/복구 백업을 저장하세요. 정상 게임/런처/업데이터를 종료합니다. `-WhatIf`는 읽기 전용 미리 보기입니다.

```powershell
cd 'D:\BetterAstralParty-1.2.1-modified-source'
.\tools\force-uninstall.ps1 -GameRoot 'D:\SteamLibrary\steamapps\common\Astral Party\8vJXnINT' -WhatIf
.\Force-Uninstall.cmd -GameRoot 'D:\SteamLibrary\steamapps\common\Astral Party\8vJXnINT'
```

변경/삭제를 승인하려면 `ERASE BETTERASTRALPARTY`를 정확히 입력해야 합니다. 이후 사용자 데이터(`%LOCALAPPDATA%\BetterAstralParty`)와 그 안의 **복구 백업도 삭제**됩니다. 보존하려면 `-KeepLocalData`를 전달하세요. Steam에 등록된 `Astral Party - Mod` 항목은 기본 보존되며 `-RemoveSteamShortcut`를 추가하면 일치하는 항목만 제거하도록 시도합니다. Steam은 정상 종료되어 있어야 합니다. 이 모드는 파일 ACL을 탈취하거나 백신 탐지를 우회하지 않습니다. 실패 시 어떤 파일이 남았는지 보고합니다.

## PowerShell 7 검출 (R2)

`Build-Local.cmd`는 먼저 `C:\Program Files\PowerShell\7\pwsh.exe`의 64비트 설치본을 검색하고, 없으면 `PATH`의 `pwsh.exe`를 찾습니다. 각 실행 파일은 Windows/64비트/PowerShell 7 이상을 검사합니다. PowerShell 5.1에 들어있는 `powershell.exe`와는 별개이며, PowerShell 7 설치가 실제로 없으면 `winget install --id Microsoft.PowerShell --source winget --exact`를 실행하고 터미널을 새로 열어야 합니다.

확인: `& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -Command '$PSVersionTable.PSVersion; [Environment]::Is64BitProcess'`.

## 빌드 (Windows PowerShell 7 x64)

1. .NET SDK **8.0.425**와 .NET 6 reference pack **6.0.36**을 설치합니다. `dotnet --list-sdks` 확인.
2. 게임 INT를 실행하여 `BepInEx\interop`가 생성된 상태여야 합니다. 원본 BepInEx **6.0.0-be.788** x64를 별도로 풀고 `BepInEx\core` 경로를 지정합니다. 정식 게임·BepInEx 참조 라이브러리는 소스에 포함하지 않습니다.
3. 소스 ZIP을 **로컬 NTFS 폴더**에 압축 해제해 실행합니다. 확인한 파일만 `Unblock-File`로 해제하세요. 회사의 AllSigned 정책을 우회하려 하지 마세요.

```powershell
pwsh -NoProfile -File .\tools\build-local.ps1 `
  -GameRoot 'D:\SteamLibrary\steamapps\common\Astral Party\8vJXnINT' `
  -BepInExRoot 'D:\BepInEx-IL2CPP-788' `
  -DotnetRoot 'C:\Program Files\dotnet' `
  -OutputDirectory 'D:\BAP-1.2.1-LocalBuild'
```

유효한 코드 서명 인증서가 이미 Windows 사용자 인증서 저장소에 있다면, 명령에 `-SigningCertificateThumbprint '인증서SHA1지문' -TimestampServer '타임스탬프서버URL'`를 추가해 **컴파일한 세 이미지에 정식 Authenticode 서명을 선택적으로 적용**할 수 있습니다. 인증서가 없다면 서명 없이 컴파일하며, 자체 서명 인증서만으로 백신 평판이 해결되지는 않습니다. 인증서/개인 키를 ZIP에 넣지 마세요.

완료 시 `D:\BAP-1.2.1-LocalBuild\plugin\BetterAstralParty.dll`, `launcher\BetterAstralParty-Launcher.exe`, `helper\BetterAstralParty-UpdateHelper.exe` 및 `D:\BAP-1.2.1-LocalBuild.zip`가 생성됩니다. ZIP은 **로컬 컴파일 결과물**이며 `Install.cmd`를 넣지 않습니다. 공식 1.2.1은 매니페스트·설치 승인·Helper 서명·업데이트 서명을 검증하므로, DLL만 교체하거나 임의 승인 기록을 만들면 설치/업데이트가 실패할 수 있습니다. 전체 배포 ZIP은 소유자가 관리하는 공식 서명 키와 원본 loader, 빌드 증명/서명 절차가 추가로 필요합니다. 임의로 우회하지 않습니다.

## 백신 및 권한 문제

`Check-Security.cmd`를 실행해 서명·인터넷 영역 표시·실행 정책을 **읽기 전용**으로 확인합니다. 설치 패키지를 `Z:` 매핑 드라이브 대신 신뢰 가능한 `D:` 로컬 폴더에 풀면 원격 영역으로 인식되는 경우를 줄일 수 있습니다. 출처를 검증한 *해당* 파일에 대해서만 `Unblock-File`을 사용하세요. `0x80131515`는 인터넷/원격 영역으로 판단된 .NET 어셈블리 로드 차단과 관련될 수 있습니다. 

Defender/SmartScreen 탐지 제거는 보장할 수 없습니다. 배포용 실행 파일에 신뢰 가능한 퍼블리셔의 Authenticode 서명 및 타임스탬프를 사용하고 Microsoft의 false-positive 제출 경로로 SHA-256, 탐지명, 재현 파일을 제공해야 합니다. 이 패치는 실시간 보호 끄기, 백신 예외 지정, 실행 정책 영구 완화를 하지 않습니다.

## 검증 범위

이 소스에는 공식 서명 비밀 키와 게임 바이너리가 없습니다. Linux 분석 환경에서는 실제 Windows 컴파일/인게임/Defender 테스트를 수행할 수 없습니다. 로컬 설치 이전에 컴파일, 복구 가능성, 제거 대상 미리 보기, 정상 재실행 등을 확인해야 합니다. 원본 `SOURCE-MANIFEST.json`과 `BUILD-RECORD.json`은 **공식 1.2.1 원본의 역사적 기록**으로 남기고, 변경 파일 검증은 별도 `LOCAL-MODIFIED-SOURCE-MANIFEST.json`으로 제공합니다.


## Original-installer integration

The separate R3/R4 LocalDev installer has been removed. For signed original-installer packaging, follow `docs/INTEGRATED-RELEASE.md`; without authorized signatures and external approval only an unsigned review candidate can be generated, not an installable ZIP.
