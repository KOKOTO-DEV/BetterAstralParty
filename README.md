# BetterAstralParty

https://github.com/TSM701/BetterAstralParty의 포크버전 입니다.
이 포크는 원본에서 있던 불편한점을 개선하는데 목적을 둡니다.


원본에서 변화된 점은 다음과 같습니다.

1. Install.cmd로 실행하면 자동으로 바탕화면에 바로가기 파일이 생성됩니다.
2. 설치 과정중에 윈도우 바이러스 탐지에 걸리지 않도록 설치 과정 자체를 변경했습니다.
3. 동봉된 Force-Uninstall.cmd 파일을 실행하면 버전 관계없이 BetterAstralParty 강제 삭제가 가능합니다.
4. 자동으로 반응하는 '감사합니다' 팝업을 끌 수 있습니다.

아래는 원본 소개문구 입니다.

----------------------------------------------------------------------------------------------------------------------------------------


[한국어](#한국어) · [English](#english)

## 한국어

> 수정 소스: 자동 감사합니다 ON/OFF 및 독립된 강제 제거 도구를 추가했습니다. 정식 설치·Steam 등록·업데이트는 원본 1.2.1 설치 파이프라인만 사용합니다. 배포 패키지 생성을 위해서는 기존 서명·승인 절차가 필요합니다.

Astral Party 국제판 INT(Global)의 PvE 정보 표시와 판단을 돕는 한국어·영어 지원 편의성 모드입니다.

[최신 안정판 다운로드](https://github.com/TSM701/BetterAstralParty/releases/latest)

### 주요 기능

- 공개 정보를 사용하는 PvE 전투 추천과 카드 평가
- KO·생존 최소 조건, 전투 확률과 최종 피해 표시
- 플레이어·몬스터 필드 인디케이터와 공개 버프·반격 표시
- 카드·칩 핑 상세 팝업과 손패 정렬 옵션
- 게임 기본 감사합니다 추천을 추천마다 한 번 자동 전송 (ON/OFF 선택 가능)
- 인게임 모드 설정, 캐릭터 이름 옵션, 창 비활성화 시 음소거
- PvE 매칭 성사 또는 직접 만든 PvE 방의 게임 시작 시 창 포커스
- PvE 필드 휠 확대·축소와 턴 전환에도 유지되는 자유 시점, 자유 시점 카메라 종료 버튼
- 별도의 Astral Party - Mod Steam 항목

PvP 방·경기가 감지되면 전투 추천·카드 정렬·추가 정보 표시·비활성 창 음소거 등 모드 편의 기능이 일시 중지됩니다. PvP에서 나오면 저장된 설정대로 다시 작동하며, 업데이트와 진단 처리는 PvP에서도 계속됩니다.

### 지원 환경

- Windows x64, Steam, 설치된 INT(Global) 클라이언트가 필요합니다. CN 클라이언트는 지원하지 않습니다.
- 한국어 패치는 별도로 설치하세요. 기존에 설치한 패치는 유지합니다.

### 설치와 실행

BetterAstralParty 1.2.0 이하 버전을 사용 중이라면, 게임과 모드 실행기를 종료하고 사용하던 패키지의 `Uninstall.cmd`로 먼저 제거하세요. 제거가 정상 완료되면 아래 순서로 1.2.1을 새로 설치하세요. 구버전에서 자동 업데이트하거나 새 패키지로 덮어쓰는 설치는 지원하지 않습니다. 제거 오류가 나면 임의로 파일을 삭제하지 말고 오류 로그와 함께 제보하세요. 처음 설치하는 사용자는 바로 아래 순서대로 진행하면 됩니다.

1. GitHub Releases에서 `BetterAstralParty-1.2.1.zip` 안정판 전체 설치 ZIP을 받으세요. 소스 ZIP은 설치용이 아닙니다.
2. Steam 클라이언트의 라이브러리에서 Astral Party를 열고 INT(Global) 순정 게임을 먼저 한 번 실행하세요. Astral Party - Mod가 아닌 게임 자체를 실행해 업데이트와 데이터 다운로드를 마친 뒤 정상 종료하세요.
3. 쓰기 가능한 별도 폴더에 ZIP 전체를 압축 해제하고, 동봉된 파일과 폴더를 함께 유지하세요. 게임 폴더 위에 직접 덮어쓰거나 ZIP 내부에서 실행하지 마세요.
4. Steam에 로그인한 상태에서 압축을 푼 폴더의 `Install.cmd`를 실행하세요. PowerShell에서는 `.\Install.cmd`를 실행합니다. 경로를 묻는 경우 Steam의 설치된 파일 → 찾아보기로 확인한 `Astral Party` 폴더 또는 `8vJXnINT` 하위 폴더를 선택하세요.
5. Steam 라이브러리의 Astral Party - Mod로 실행하세요. 첫 실행은 로더 초기화와 파일 다운로드로 시간이 걸리며 인터넷 연결이 필요할 수 있습니다.

Steam 항목 등록·수정 때문에 종료 안내가 나오면 Steam을 정상 종료한 뒤 `r`로 재확인할 수 있습니다. `y`를 입력하면 표시된 Steam 게임·앱과 Steam이 강제 종료될 수 있으므로 진행 상황을 저장하고 동기화를 마치세요. 빈 입력이나 거절은 취소합니다. 강제로 종료한 경우 작업 후 Steam만 다시 실행합니다. 실행 경로를 확인할 수 없는 프로세스는 강제 종료하지 않습니다.

BetterAstralParty 없이 실행하려면 Steam 클라이언트에서 Astral Party를 실행해 INT(Global)를 선택하거나 게임 폴더의 `AstralParty-Vanilla.cmd`를 실행하세요. Astral Party - Mod에서는 BetterAstralParty를 함께 불러옵니다. 두 실행 방법은 BetterAstralParty 적용 여부만 구분하며 다른 BepInEx 모드는 그대로 유지합니다. 새 공용 로더는 ON으로 설치됩니다. 전환 전 게임을 종료하고, Steam의 Astral Party 실행 옵션은 변경하지 마세요.

### 설정

로비의 모드 설정 버튼 또는 F8로 열고 모드 기능·일반 설정 탭에서 조절하세요. 변경 사항은 자동 저장됩니다. 아래는 1.2.1을 처음 설치했을 때의 기본값이며, 이후 업데이트 시 기존 저장값은 유지합니다. 전투 추천은 모드 전체를 끄는 스위치가 아닙니다.

#### 모드 기능 탭

- 전투 추천: 기본 ON이며 개별 OFF가 가능합니다. 공개 정보를 바탕으로 공격·놓아주기, 방어·회피, 카드 사용을 추천하고 실제 전투의 최종 피해를 표시합니다. OFF는 추천과 최종 피해를 함께 숨깁니다. 선택을 자동 입력하지 않으며, KO 최소 조건·전투 정보·슈슈 쉴드는 별도 설정입니다.

- 호버 수치: 기본 ON입니다. 전투 추천에 마우스를 올리면 피해와 전투불능 확률을 표시합니다. OFF는 수치만 숨기고 추천 아이콘은 유지합니다. 전투 추천이 OFF이면 이 옵션만 켜도 추천 수치는 나오지 않습니다.

- KO 최소 조건 표시: 기본 ON이며 전투 추천·호버 수치와 독립적으로 끌 수 있습니다. 공격·다른 사람 전투에서는 KO 조건, 내가 방어자이면 생존 조건을 표시합니다. 카드 호버 조건도 포함하며 가장 유리한 결과를 기준으로 합니다. 최종 피해 표시를 켜는 옵션은 아닙니다.

- 카드·칩 핑 팝업: 기본 ON입니다. 게임의 카드·칩 핑 말풍선을 클릭하면 원본 이미지와 설명을 추가 팝업으로 엽니다. OFF는 추가 팝업만 끄며, 게임 기본 핑 말풍선과 일반 카드 호버는 유지합니다.

- 손패 기능별 정렬: 기본·클릭 펼치기·호버 펼치기 중 선택하며, 처음에는 게임 원래 배치인 기본을 사용합니다. 내가 참가한 PvE 필드의 손패를 기능별로 묶고, 클릭은 가로로, 호버는 세로로 펼칩니다. 전투 화면과 관전자 손패에는 적용하지 않습니다. 펼치는 방식과 제출 영역이 함께 바뀌며, 접힌 카드의 반투명도는 별도 조절할 수 없습니다.

- 전투 정보 표시: 기본 ON입니다. 전투 HP 아래 공개 손패 장수·효과와 플레이어·몬스터의 반격 상태를 표시합니다. 효과 아이콘 호버로 설명을 봅니다. OFF는 추가 전투 정보·반격 표시와 그 애니메이션·소리를 함께 끕니다. 슈슈 쉴드와 필드 인디케이터는 별도 설정입니다.

- 슈슈 쉴드 표시: 기본 ON입니다. 전투 캐릭터에 활성 쉴드를 표시하고, 쉴드가 있는 내가 방어자이면 방어 버튼과 방어 카드를 잠급니다. 표시와 입력 잠금은 하나의 설정에 묶여 있어 따로 선택할 수 없으며, OFF로 둘 다 해제합니다. 회피를 자동 입력하지는 않습니다. 전투 추천이 ON이면 쉴드를 반영한 계산·회피 추천은 유지합니다.

- 플레이어 필드 인디케이터: 기본 ON입니다. 필드에 플레이어 이름·HP·공개 효과와 플레이어·몬스터의 추가 반격 아이콘을 표시합니다. 효과 아이콘을 짧게 클릭하면 게임 기본 설명을 엽니다. OFF는 추가 플레이어 인디케이터와 추가 필드 반격 아이콘을 함께 끄며, 게임 원래 몬스터 인디케이터·효과 설명은 유지합니다.

- 필드 휠 줌: 기본 ON입니다. PvE 필드에서 휠 줌과 자유 시점 이동을 사용하며, 배율과 자유 시점은 턴이 바뀌어도 유지합니다. OFF는 휠 줌·추가 자유 시점·종료 버튼·줌에 따른 인디케이터 흐림과 숨김을 함께 해제하고 원래 시점을 복원합니다.

- 캐릭터 이름: 본명·이명 중 선택하며 기본은 본명입니다. 캐릭터 선택·목록에서 게임에 등록된 이름을 사용합니다. 이명은 게임 원래 표기이며, 계정 닉네임·캐릭터 소개·역할 표시는 바꾸지 않습니다.

기존 설정에 새 항목이 없을 때 KO 최소 조건 표시는 이전 전투 추천과 호버 수치가 모두 켜져 있었는지, 슈슈 쉴드 표시는 이전 전투 정보 표시 상태를 최초값으로 이어받습니다.

#### 일반 설정 탭

- 언어: 자동·한국어·English 중 선택하며 기본은 자동입니다. 모드의 메뉴·설명을 번역하고, 자동은 게임 메뉴 언어를 따릅니다. 게임 자체 언어·원본 설명·플레이어 이름은 바꾸지 않습니다.

- 창 비활성화 시 음소거: 기본 ON이며 개별 OFF가 가능합니다. 다른 창으로 전환하면 게임 소리를 끄고 복귀하면 복원합니다. 저장된 볼륨은 바꾸지 않으며 PvP에서는 적용하지 않습니다.

- 입력 대기 알림: 작업표시줄·Windows 알림·OFF 중 선택하며 기본은 작업표시줄입니다. 비활성 창에서 내 PvE 입력을 기다릴 때 알립니다. 두 방식 모두 모드가 소리를 재생하지 않으며, Windows 알림은 OS 알림 설정을 따릅니다.

- 매칭 성사 시 창 포커스: 기본 ON이며 개별 OFF가 가능합니다. PvE 매칭 성사 또는 공개·비밀번호 로비 방장이 시작해 캐릭터 선택에 진입할 때 한 번 창을 앞으로 올립니다. 잠깐 최상위로 올린 뒤 원상복원하며, Windows가 전환을 거절하면 작업표시줄을 깜빡입니다. 영구 항상 위는 아닙니다.

- 표시 크기: 기본 100%이며 75~150% 사이에서 5%씩 조절합니다. 모드 추천·전투 상태 패널만 조절하며, 게임 전체 UI나 다른 기능의 ON·OFF에는 영향을 주지 않습니다.

- 배경 불투명도: 기본 100%이며 0~100% 사이에서 5%씩 조절합니다. 모드 전투 패널의 바탕만 바꾸고, 0%에서도 글자·아이콘·테두리는 유지합니다. 필드 인디케이터의 줌 반투명도와는 별개입니다.

- 자동 감사합니다: 기본 ON이며 F8 → 일반 설정에서 개별 OFF가 가능합니다. 게임 기본 PvE 감사합니다 빠른 응답이 나올 때만 자동 확인하며, OFF여도 직접 클릭할 수 있습니다. PvP·관전·리플레이에서는 동작하지 않습니다.

- 충돌 진단 로그: 기본 OFF이며 개별 ON·OFF가 가능합니다. 오류·성능·공개 전투 계산의 상세 진단을 기록합니다. OFF여도 기본 오류 로그와 진단 ZIP 생성은 유지합니다.

- 업데이트 채널: 일반 사용자는 기본값인 안정판을 사용하세요. 선택한 채널의 저장소만 확인하고, 채널을 바꾸면 결과를 갱신하며 다운로드 페이지도 해당 저장소를 엽니다. 채널 선택만으로 파일을 교체하지는 않습니다.

- 자동 다운로드·종료 후 적용: 기본은 각각 ON이며 두 옵션을 따로 끌 수 있습니다. 새 버전을 내려받고 검증한 뒤, 적용 대기 상태에서 게임·모드 실행기가 종료되면 적용합니다. 저장된 OFF와 업데이트 실패 후 OFF로 저장된 값은 유지합니다. 자동 다운로드 OFF는 업데이트 확인까지 끄는 옵션이 아닙니다.

진단 폴더 열기·진단 ZIP 만들기, 업데이트 확인·다운로드 페이지·업데이트 받기·취소는 실행 버튼이며 ON·OFF 설정이 아닙니다. 새 버전의 변경 사항은 업데이트 알림 팝업에 표시합니다.

#### 그 밖의 자동 동작

- 반격 표시 소리는 소리만 끄는 옵션이 없습니다. 모드가 추가한 전투·인카운트 반격 아이콘에 게임 원본 애니메이션과 효과음을 사용합니다. 모드 기능 → 전투 정보 표시를 OFF로 하면 해당 표시·소리를 함께 끕니다. 게임 원래 효과음 전체를 끄는 설정은 아닙니다.

- 카드 대상 선택의 확인·취소 버튼은 개별 OFF 옵션이 없습니다. 카드가 버튼을 가리지 않도록 그리기·클릭 우선순위를 올리며, 원래 위치·크기·클릭 동작은 유지합니다. 손패 기본·클릭·호버 모두에 적용합니다.

- 캐릭터 역할·준비 화면 설명은 개별 OFF 옵션이 없습니다. 역할은 게임 내부 분류를 사용하고, 준비 화면의 캐릭터 초상화 호버에 공개 스킬·재사용 대기시간·잠재력 설명을 표시합니다. 캐릭터 이름 설정과 독립적입니다.

- 줌에 따른 인디케이터 흐림·숨김은 필드 휠 줌과 함께 적용합니다. 기본 거리보다 축소하면 플레이어·몬스터 필드 인디케이터가 반투명해지고, 더 멀리 축소하면 숨겨지며, 다시 확대하면 표시합니다. 별도 반투명도·숨김 기준 설정은 없습니다.

필드 휠 줌은 위로 확대·아래로 축소합니다. 첫 유효 휠 입력부터 자유 시점이 되며, WASD·왼쪽 마우스 드래그는 게임 원래 카메라 조작 설정과 감도를 따릅니다. 턴 바의 핀 오른쪽 자유 시점 카메라 종료 버튼으로 기본 배율·캐릭터 추적으로 복귀하세요. 버튼은 상점·대상 선택 등 상위 창 뒤에 배치됩니다.

상점·카드·대상 선택 창 자체는 필드 줌을 막지 않습니다. 다만 전투 화면·설정창·실제 목록 스크롤·텍스트 입력·카드 드래그 중·터치 입력·포커스 상실 상태는 제외합니다. 확대·축소 한계는 지도 범위와 카메라의 안전 범위로 계산하며 고정 배율을 선택하는 설정은 없습니다.

손패 정렬의 클릭 펼치기는 카드 위쪽, 호버 펼치기는 오른쪽의 강조된 제출 영역으로 드래그하세요. 호버 방식의 안내 화살표도 오른쪽을 가리킵니다.

스크린샷과 오버레이는 본인의 Steam 단축키를 사용하세요.

### 업데이트

- 자동·수동 업데이트는 1.2.1 이상을 설치한 상태에서 지원합니다. 1.2.0 이하 버전은 사용하던 패키지로 먼저 제거한 뒤 1.2.1 전체 패키지로 새로 설치하세요. 새 패키지의 설치·제거 도구는 구버전 전환을 지원하지 않습니다.
- 안정판은 로그인 없이 확인합니다. 업데이트 채널을 바꾸면 해당 채널의 결과를 갱신하며, 다운로드 페이지는 선택한 채널의 GitHub 릴리스 목록을 엽니다.
- 자동 업데이트: 1.2.1 이상 설치 후 모드 설정에서 자동 다운로드와 종료 후 적용을 켜세요. 적용 대기가 완료되면 게임과 모드 실행기를 정상 종료하고, 적용 후 직접 다시 실행하세요. 선택한 채널의 저장소만 확인합니다.
- 채널 전환: 선택한 저장소의 지원되는 최신 릴리스를 확인합니다. 설치된 버전보다 낮거나 같은 버전이어도 다른 채널로 전환할 수 있으며, 전환 안내에서 직접 승인해야 적용을 준비합니다. 같은 채널의 일반 업데이트는 버전 역행을 허용하지 않습니다.
- 수동 업데이트: 1.2.1 이상 설치 이후에는 게임과 모드 실행기를 종료한 뒤 상위 버전 전체 패키지의 `Install.cmd`를 실행하세요. 기존 설정은 유지하며, 버전 역행과 같은 버전의 다른 파일 덮어쓰기는 차단합니다.
- Mod 실행 시 공용 로더가 OFF라면 안내창 없이 ON으로 전환하며, 다른 모드 파일과 나머지 로더 설정은 보존합니다. 변경 전 원본은 `BepInEx/config/BetterAstralParty.loader-before-*.bak`에 보관됩니다.
- 이전에 받은 패키지의 설치·제거 도구는 자동 업데이트로 바뀌지 않으므로 최신 전체 패키지를 사용하세요.

### 제거

1.2.1 이상 설치의 제거에는 최신 전체 패키지의 `Uninstall.cmd`를 사용하세요. 게임과 모드 실행기를 종료한 뒤 제거 목록을 확인하세요. 모드 파일과 설정은 `%LOCALAPPDATA%/BetterAstralParty/Backups/v3`에 백업한 뒤 제거합니다. 1.2.0 이하 버전은 사용하던 패키지의 제거기를 사용해야 합니다.

공용 BepInEx 파일과 현재 로더 설정, 다른 모드, 한국어 패치와 원래 Steam 항목은 유지합니다. 다른 모드를 BetterAstralParty 설치 이후에 추가한 경우에도 해당 모드와 로더 설정을 그대로 둡니다.

완전 제거 후에는 전체 패키지의 `Install.cmd`로 재설치할 수 있습니다. 복구 안내가 나오면 로그와 백업을 보관하고 표시된 절차를 따르세요.

### 문제 해결과 제보

- Steam 항목이 안 보이면 Steam을 재시작하고 라이브러리 필터와 로그인 계정을 확인하세요. 항목 복구에는 `Install.cmd`를 사용하세요.
- 설치·실행 오류는 `Open-Logs.cmd`로 로그를 확인하세요. 호환성 검사 오류가 나면 오류 문구를 함께 제보하세요.
- 계산 문제는 모드 설정에서 진단을 켠 뒤 재현하세요.
- 진단 ZIP은 패키지의 `Create-Diagnostics.cmd` 또는 게임의 F8 → 일반 설정 → 진단 ZIP 만들기로 생성하세요. 기본 저장 위치는 `%LOCALAPPDATA%/BetterAstralParty/Diagnostics`입니다.
- 최근 설치·초기 실행·런처·호환성 오류의 상세 본문도 포함합니다. 토큰·개인 경로를 가리며, 용량 제한이나 누락 사유는 ZIP의 `summary.json`에 기록합니다.
- Steam 관련 설치·제거 오류는 실패 당시의 프로세스 확인 결과와 단계도 수집합니다. 확인하지 못한 정보는 미확인으로 남깁니다.
- 게임·모드 파일이 일부 없는 경우에도 고정 모드 파일·복구 및 백업 표식의 존재·크기·해시를 `recovery-inventory.json`에 기록합니다. 복구 기록 원문과 인증 저장소는 포함하지 않습니다.

모드 버전, 재현 순서, 스크린샷과 관련 로그 또는 진단 ZIP을 함께 전달하세요. 공유 전 개인정보와 사용자 지정 경로를 확인하세요.

### 소스와 라이선스

BetterAstralParty 자체 코드는 MIT 라이선스로 제공합니다. 외부 구성 요소의 고지와 대응 소스 안내는 `THIRD-PARTY-NOTICES/`에서 확인하세요. 소스 빌드 방법은 공개 소스 묶음의 `docs/BUILD.md`에 있습니다.

## English

This is a fork of BetterAstralParty. https://github.com/TSM701/BetterAstralParty
The purpose of this fork is to improve some of the inconveniences found in the original version.

Changes from the Original Version
1. Running Install.cmd automatically creates a desktop shortcut.
2. The installation process has been modified to prevent Windows Defender from flagging it as a potential threat.
3. The included Force-Uninstall.cmd allows you to forcibly uninstall BetterAstralParty, regardless of the installed version.
4. Added an option to disable the automatic "Thank You" pop-up.

Below is the original description of BetterAstralParty.

---------------------------------------------------------------------------------------------------------------------------------------

A Korean/English quality-of-life mod for Astral Party INT(Global), focused on PvE information and decision support.

[Download the latest stable release](https://github.com/TSM701/BetterAstralParty/releases/latest)

### Features

- PvE combat recommendations and card evaluation using public information
- Minimum KO/survival conditions, combat probabilities and observed final damage
- Player/monster field indicators with public buffs and counterattack markers
- Detail popups for card and chip pings, and hand-layout options
- Automatically send each native Thanks quick-chat recommendation once (toggle in General settings)
- In-game settings, character-name options and mute on focus loss
- Focus the game when a PvE match is found or a manually created PvE room starts
- PvE field wheel zoom and free view across turns, with an Exit Free Camera button
- A separate Astral Party - Mod Steam entry

When a PvP room or match is detected, mod conveniences such as combat recommendations, hand layouts, additional information displays and focus muting pause. They resume with your saved settings after leaving PvP; updates and diagnostics continue even during PvP.

### Requirements

- Windows x64, Steam and an installed INT(Global) client. The CN client is not supported.
- Install a Korean patch separately if needed. An existing patch is preserved.

### Install and play

If you use BetterAstralParty 1.2.0 or earlier, close the game and mod launcher and uninstall using your previous package's `Uninstall.cmd` first. After removal completes successfully, install 1.2.1 fresh using the steps below. Automatic updates and in-place installation from older versions are not supported. If removal fails, report the error log instead of deleting files manually. First-time users can follow the steps below directly.

1. Download the complete stable `BetterAstralParty-1.2.1.zip` installation package from GitHub Releases. Source ZIPs are not installation packages.
2. In the Steam client, first launch Astral Party INT(Global) itself from your library, not Astral Party - Mod. Wait for game/data updates to finish, then exit normally.
3. Extract the entire ZIP to a separate writable folder and keep all bundled files and folders together. Do not overwrite the game folder directly or run inside the ZIP.
4. While signed in to Steam, run `Install.cmd` from the extracted folder. In PowerShell, run `.\Install.cmd`. If prompted, select the `Astral Party` folder or its `8vJXnINT` child, as shown by Steam's Installed Files → Browse.
5. Launch Astral Party - Mod from your Steam library. First-time loader initialization and file downloads may take time and require internet access.

If Steam entry registration or repair prompts you to close processes, you can close Steam normally and enter `r` to recheck. Entering `y` may force-close the listed Steam games/apps and Steam, so save progress and finish syncing first. A blank response or refusal cancels. After a forced shutdown, only Steam restarts. Processes with unverified executable paths are never force-closed.

To play without BetterAstralParty, launch Astral Party through the Steam client and select INT(Global), or run `AstralParty-Vanilla.cmd` in the game folder. Astral Party - Mod also loads BetterAstralParty. These launch methods select BetterAstralParty only; other BepInEx mods remain available in both. A newly installed shared loader defaults to ON. Close the game before switching and leave Astral Party's Steam launch options unchanged.

### Settings

Open Mod Settings in the lobby using its button or F8, then select Mod Features or General. Changes are saved automatically. Defaults below apply to a first installation of 1.2.1; later updates preserve saved values. Battle Advice is not a master switch for the whole mod.

#### Mod Features tab

- Battle Advice: ON by default and can be disabled independently. Uses public information to recommend Attack/Let Go, Defend/Dodge and cards, and displays observed final combat damage. OFF hides advice and final damage together. It does not automatically select actions; KO Conditions, Battle Info and Shushu Shield are separate settings.

- Hover Details: ON by default. Hover over combat advice to see damage and KO probabilities. OFF hides numeric details, not recommendation icons. Enabling this alone does not show advice values when Battle Advice is OFF.

- KO Conditions: ON by default and can be disabled independently of Battle Advice and Hover Details. Shows KO conditions when attacking or viewing another player's combat, survival conditions when you defend, and card-hover conditions. Uses best-case outcomes; it does not enable final damage display.

- Card / Chip Pings: ON by default. Click a native card/chip ping bubble to open an added popup with its original image and description. OFF disables only the added popup; native ping bubbles and normal card hover remain.

- Grouped Hand: choose Native, Click or Hover; the default is the game's Native layout. Groups your hand by function in the PvE field; Click expands horizontally and Hover vertically. Excludes combat screens and spectators' hands. Expansion and submission areas change together; folded-card translucency has no separate setting.

- Battle Info: ON by default. Shows public hand counts/effects and player/monster counterattack status below combat HP. Hover effect icons for details. OFF disables added battle information, counter indicators and their animation/sound together. Shushu Shield and field indicators are separate settings.

- Shushu Shield: ON by default. Shows active shields on combat characters and locks Defend and defense cards when you are the shielded defender. Visuals and input locks share one setting and cannot be selected separately; OFF disables both. It does not automatically select Dodge. With Battle Advice ON, shield-aware calculations and Dodge advice remain.

- Player Field Indicator: ON by default. Shows field player names, HP, public effects and added player/monster counter icons. A short click on an effect opens its native description. OFF removes added player indicators and added field counter icons together; native monster indicators and effect descriptions remain.

- Field Wheel Zoom: ON by default. Enables PvE field wheel zoom and free-view movement; zoom and free view persist across turns. OFF disables wheel zoom, added free view, its exit button and zoom-dependent indicator fading/hiding together, restoring the original view.

- Character Names: choose Name or Title; the default is Name. Uses names registered by the game in selection screens and lists. Title restores native labels; player nicknames, character descriptions and role labels are unchanged.

When an existing configuration lacks the new entries, KO Conditions initially inherits whether both Battle Advice and Hover Details were enabled; Shushu Shield inherits the previous Battle Info state.

#### General tab

- Language: choose Auto, 한국어 or English; the default is Auto. Translates mod menus/help, with Auto following the game menu language. Leaves the game's language, original descriptions and player names unchanged.

- Mute When Unfocused: ON by default and can be disabled independently. Mutes game audio on focus loss and restores it on return. Saved volume is unchanged; not applied in PvP.

- Input Alert: choose Taskbar, Windows or OFF; the default is Taskbar. Alerts while the unfocused game awaits your PvE input. Neither mode plays a mod notification sound; Windows alerts follow OS notification settings.

- Focus on Match Found: ON by default and can be disabled independently. Brings the game forward once on a PvE match, or when a public/password lobby host starts character selection. Briefly raises the window to topmost, then restores its state; flashes the taskbar if Windows refuses. Not permanently always-on-top.

- UI Scale: defaults to 100%, adjustable from 75–150% in 5% steps. Scales only mod advice and battle-status panels; does not scale the entire game UI or change feature toggles.

- Opacity: defaults to 100%, adjustable from 0–100% in 5% steps. Changes only the background fill of mod battle panels; text, icons and borders remain visible even at 0%. Separate from zoom-dependent field-indicator translucency.

- Automatic Thanks: ON by default and can be disabled under F8 → General settings. Confirms the native PvE Thanks quick-chat recommendation once per suggestion. OFF disables only automated confirmation; native manual input is unaffected.

- Diagnostic Log: OFF by default and can be enabled or disabled independently. Records detailed errors, performance and public combat calculations. Basic error logs and diagnostics ZIP creation remain available when OFF.

- Update Channel: general users should keep the default, Stable. Checks only the selected channel's repository. Switching refreshes its result and Download Page opens that repository. Selecting a channel does not replace files.

- Auto Download / Apply After Exit: both default to ON and can be disabled separately. Downloads and verifies a new version, then applies a queued update after the game and mod launcher close. Saved OFF values and OFF values persisted after update failure remain. Auto Download OFF does not disable update checks.

Open Diagnostics Folder, Create Diagnostics ZIP, Check Updates, Download Page, Get Update and Cancel Update are action buttons, not ON/OFF settings. Release notes appear in the update notification popup.

#### Automatic behavior without individual settings

- Counter-indicator sound has no sound-only option. Added combat/encounter counter icons use the game's native animation and sound. Turn OFF Mod Features → Battle Info to remove these added indicators and their sound together. This does not silence all native game effects.

- Card-target Confirm/Cancel buttons have no individual OFF option. Their draw and click priority is raised so cards do not cover them; original position, size and click handlers remain. Applies to Native, Click and Hover hand layouts.

- Character roles and preparation details have no individual OFF option. Roles use the game's internal classification; hovering a preparation-screen portrait shows public skill, cooldown and potential descriptions. Independent of Character Names.

- Zoom-dependent indicator fading/hiding is coupled to Field Wheel Zoom. Player/monster field indicators fade beyond the default distance, hide farther out and reappear when zoomed back in. There is no separate opacity or hiding-threshold setting.

Scroll up to zoom in and down to zoom out. The first accepted wheel input starts free view; WASD and left-mouse drag follow native camera-control settings and sensitivity. Select Exit Free Camera to the right of the turn-bar pin to restore default zoom and character tracking. The button stays behind higher-level windows such as shops and target selection.

Shop, card and target-selection windows do not themselves block field zoom. Combat screens, settings, actual list scrolling, text entry, card dragging, touch input and focus loss are excluded. Zoom limits are calculated from map bounds and the camera's safe range; there is no fixed zoom-percentage selector.

With Click hand layout, drag cards into the submission area above the cards. With Hover, use the highlighted area on the right; its guide arrow also points right.

Use your own Steam screenshot and overlay hotkeys.

### Updates

- Automatic and manual updates are supported after installing 1.2.1 or newer. Uninstall 1.2.0 or earlier with your previous package before installing the complete 1.2.1 package fresh. The new installation/removal tools do not support migration from older installations.
- Stable checks do not require login. Switching channels refreshes that channel's result; Download Page opens its GitHub releases listing.
- Automatic updates: after installing 1.2.1 or newer, enable Auto Download and Apply After Exit in mod settings. Once the update is queued, close the game and mod launcher normally, then restart the game yourself after it finishes. Only the selected channel's repository is checked.
- Channel switching: checks the latest supported release in the selected repository. A different channel can have a lower or equal version; approve the transition notice to prepare it. Ordinary updates within the same channel still reject downgrades.
- Manual updates: after installing 1.2.1 or newer, close the game and mod launcher, then run `Install.cmd` from a newer complete package. Saved settings are preserved; downgrades and replacing a version with different files at the same version remain blocked.
- A Mod launch enables the shared loader without a prompt if it is OFF, preserving other mods' files and all remaining loader settings. The original configuration is retained at `BepInEx/config/BetterAstralParty.loader-before-*.bak`.
- Automatic updates do not replace installation/removal tools in previously downloaded packages; use the latest complete package for maintenance.

### Uninstall

Use `Uninstall.cmd` from the latest complete package to remove a 1.2.1 or newer installation. Close the game and mod launcher and review the removal list. Mod files and settings are backed up under `%LOCALAPPDATA%/BetterAstralParty/Backups/v3` before removal. Versions 1.2.0 or earlier must use their previous package's uninstaller.

Shared BepInEx files and current loader settings, other mods, Korean patches and the original Steam entry are preserved. Mods added after BetterAstralParty installation and their loader settings are also left unchanged.

After complete removal, run `Install.cmd` from a complete package to reinstall. If recovery is required, keep logs and backups and follow the displayed procedure.

### Troubleshooting and reports

- Missing Steam entry: restart Steam and check library filters and the signed-in account. Use `Install.cmd` to repair the entry.
- Installation or launch errors: open logs with `Open-Logs.cmd`. Include the error message when reporting a compatibility-check failure.
- Calculation issues: enable diagnostics in mod settings, then reproduce the issue.
- Create a diagnostics ZIP using the package's `Create-Diagnostics.cmd` or F8 → General → Create Diagnostics ZIP in game. The default output folder is `%LOCALAPPDATA%/BetterAstralParty/Diagnostics`.
- Recent installation, bootstrap, launcher and compatibility errors include detailed text with tokens and private paths redacted. Size limits and missing evidence are listed in the ZIP's `summary.json`.
- Steam-related installation and removal errors include the process observations and stage recorded at failure time. Unavailable information remains unknown.
- Even when game or mod files are missing, `recovery-inventory.json` lists the presence, size and hashes of fixed mod files and recovery/backup markers. Raw recovery records and credential stores are excluded.

Include the mod version, reproduction steps, screenshots and relevant logs or diagnostics ZIP. Review personal information and custom paths before sharing.

### Source and licenses

BetterAstralParty-owned code is provided under the MIT license. See `THIRD-PARTY-NOTICES/` for third-party notices and corresponding-source information. Build instructions are in `docs/BUILD.md` in the public source archive.

## Modified source R3 — local install ZIP generation

The previous `Build-Local.cmd` stops at DLL/EXE compilation. Use **`Package-Local.cmd`** afterward to produce an actually installable **unsigned local-development** ZIP by combining the locally compiled plugin and the original 1.2.1 release's SHA-256-verified loader/compatibility files. The resulting ZIP contains `Install-Local.cmd`, `Launch-Local.cmd` and `Uninstall-Local.cmd` but cannot be installed over an official BetterAstralParty instance. The official signed launcher/helper and update trust remain untouched and are not impersonated. See `docs/LOCAL-DEVELOPMENT.md` and bundled `LOCAL-INSTALL-README.md` for the two-step process, prerequisites and limitations. It disables BetterAstralParty automatic download/apply in the separate local install only.

**One run:** `Build-And-Package.cmd`. **Already compiled:** `Package-Local.cmd`. Both create only an unsigned LOCAL development install ZIP; the original signed GA `Install.cmd` must not be used with these artifacts.


### 수정 소스 통합 빌드

이 저장소는 원본 1.2.1의 `Install.cmd`, `Uninstall.cmd`, `tools/find-game.ps1`,
Steam 바로가기 등록 및 전체 설치 영수증·복구·서명 검증을 유지합니다.
별도 `LocalDev` 설치기를 사용하지 않습니다.

`Build-And-Package.cmd`는 컴파일과 원본 GA 패키징을 연결하는 도구입니다.
기본 실행 결과는 **미승인 검토용 candidate**이며 설치 가능한 ZIP이 아닙니다.
정식 설치 ZIP을 생성하려면 해당 바이너리에 대한 유효한 Helper/업데이트
서명과 외부 빌드 승인 기록을 기존 `package-ga.ps1`에 전달해야 합니다.
공식 업데이트 서명을 모방하거나 승인 목록을 임의 생성하지 않습니다.
세부 절차: `docs/INTEGRATED-RELEASE.md`.

`Force-Uninstall.cmd`는 별도 확인이 필요한 파괴적 제거 도구로,
사용자 설정·로그·복구 백업까지 삭제할 수 있습니다. 일반 제거는 `Uninstall.cmd`를 사용하세요.

---

## R6 — simplified offline one-click install package (antivirus false-positive reduction)

**Recommended for personal unsigned development builds:** use
`Build-And-Package.cmd` to compile only the plugin and generate an extractable,
installable ZIP in a single operation, or `OneClick-Package.cmd` to reuse an
existing compiled `export` DLL. The ZIP contains a small, readable .NET
Framework installer rather than the original installer PowerShell chain,
launcher and update helper. This avoids **some** patterns that can lead to
false alarms, but does not promise antivirus acceptance.

The generated ZIP contains `Install.cmd`, `Uninstall.cmd`, compiled
`BetterAstralParty.Setup.exe`, and verified BepInEx/mod files. `Install.cmd`
auto-detects Steam's INT game directory, requires a user confirmation, installs
only non-conflicting files and disables the local auto-updater. It creates
`Launch-BAP.cmd` for manual game launch; the installed setup executable performs the original compatibility review before activating the plugin. It refuses to mix with an existing
official BetterAstralParty install or recovery markers. Optional publisher
Authenticode signing is supported for the installer EXE if you already own
an accepted certificate. This does **not** create official BetterAstralParty
release signing/approval or bypass its signing checks.

Full details: `docs/SIMPLE-ONECLICK.md`. The previous integrated official
pipeline remains available for review as `Original-Release-Review.cmd`.
The earlier R5 manifests/records are historical; `R6-SOURCE-MANIFEST.json`
indexes this revised source bundle.


### R6.3 local launch fix

R6.2 started the game but omitted the mod compatibility-approved launch signal,
leaving the F8 menu disabled. R6.3 uses the existing .NET setup executable as
a verified launcher so that compatibility checks precede plugin activation.
See `docs/SIMPLE-ONECLICK.md`. Existing local installations require the
local uninstall/reinstall sequence for the new payload ownership manifest.
