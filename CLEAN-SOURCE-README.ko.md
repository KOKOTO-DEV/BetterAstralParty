# BetterAstralParty 1.2.1 / PC 3.3.0 전체 소스

이 ZIP은 변경 파일만 담은 패치가 아니라 R6.5 전체 소스에 PC 3.3.0 복구 변경을 반영한 소스입니다.
src, simple-installer, updater, diagnostics, 테스트, 빌드 도구, 라이선스와 제삼자 소스를 포함합니다.
Git 이력, 빌드 결과, 캐시, 게임 파일과 개인 설정은 포함하지 않습니다.

## 빌드

Windows에서 Python 3, .NET SDK 8.0.425 이상 8.0 패치 버전(검증: 8.0.426),
.NET 6 타기팅 팩과 Windows .NET Framework C# 컴파일러가 필요합니다.
해시 검증을 위한 원본 전체 BetterAstralParty 1.2.1 배포본(package-manifest.json 및
.deps/bepinex 포함)과 PC 게임의 재생성된 BepInEx/interop 참조도 필요합니다.
이 외부 입력은 소스 ZIP에 포함되지 않습니다.

소스 폴더에서 Build-PC-3.3.0.cmd를 실행합니다. 자동 탐지가 안 되면 다음처럼 경로를 지정합니다.

```bat
Build-PC-3.3.0.cmd --release "C:\inputs\BetterAstralParty-1.2.1" --game "D:\games\Astral Party\8vJXnINT" --output "C:\output\BAP-PC-3.3.0.zip"
```

출력 ZIP 경로가 이미 있으면 다른 이름을 지정하세요. Build-And-Package.cmd의 기본 호환성
기준은 기존 1.2.1이므로 3.3.0 복구 빌드에는 Build-PC-3.3.0.cmd를 사용하세요.

PC 3.3.0 빌드·설치·실행 및 설정창 표시는 실제 Windows 게임에서 확인했습니다.
전체 전투 기능은 아직 확인하지 않았습니다. 호환성 목록은 검증한 게임/번역 설치에 한정되며
다른 게임 파일이나 다음 업데이트를 자동 허용하지 않습니다.
자세한 내용은 docs/PC-3.3.0-LOCAL.md와 README.md를 참고하세요.
README의 이전 R6.x 검증 기록은 당시의 기록이며 위 내용이 현재 PC 복구 검증 결과입니다.

SOURCE-MANIFEST.json은 이 ZIP의 파일 크기와 SHA256 목록입니다(목록 자신 제외).
오래된 R6-SOURCE-MANIFEST.json은 현재 파일과 맞지 않아 이 새 목록으로 교체했습니다.
설치용 배포 ZIP은 별도이며 이 소스 ZIP을 게임 폴더에 설치하지 않습니다.

## 콘텐츠 업데이트 허용 패치

이 소스는 PC 3.3.0 검토 기준을 유지하면서 콘텐츠만 바뀐 경우 실행을
허용합니다. `data.unity3d`, Addressables 설정/카탈로그는 파일 형식과
카탈로그 쌍의 완전성을 검사한 뒤 해시 차이를 경고로 처리합니다.
실행 파일, 네이티브 DLL, IL2CPP 메타데이터와 BepInEx는 기존 해시를
엄격히 비교합니다. 업데이터의 서명/업데이트 무결성 검사는 변경하지
않았습니다.

실행용 ZIP은 이 소스를 새로 빌드해야 합니다. 자세한 설명:
`docs/RESOURCE-DRIFT-POLICY.md`
