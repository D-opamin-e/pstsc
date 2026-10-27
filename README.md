# Pstsc

**원격 Windows PC의 프로그램을 맥 앱처럼 쓰는 macOS용 RemoteApp 클라이언트**

Parallels Desktop의 Coherence 모드처럼, 다른 곳에 있는 Windows PC의 프로그램을 하나씩 불러와 맥에서 독립된 창으로 띄웁니다. 프로그램마다 Dock 아이콘이 생기고, Windows 11 모양의 시작 메뉴와 Spotlight·Launchpad 실행을 지원합니다. Windows를 맥 안에 설치하는 대신, 이미 있는 Windows PC에 원격 데스크톱(RDP)으로 접속하는 방식입니다.

> 개인 프로젝트이며 Microsoft, Parallels와 관련이 없습니다.

## 주요 기능

**창과 화면**
- 원격 프로그램의 창 하나가 맥 창 하나로 뜹니다(RDP RemoteApp). 원격 바탕화면은 보이지 않습니다.
- 창을 드래그하면 맥에서 바로 움직이고, 놓았을 때만 원격에 위치를 알립니다.
- 듀얼 모니터를 지원합니다. 맥의 모니터 배치를 원격에 그대로 알려서 모니터 사이로 창을 옮길 수 있습니다.
- 데스크톱 모드에서는 원격 바탕화면 전체를 창 하나로 보여줍니다. 앱 창 모드와 언제든 전환할 수 있습니다.

**Dock과 실행**
- Pstsc Dock 아이콘을 누르면 Windows 11 모양의 시작 메뉴가 열립니다. 검색, 고정 앱, 전체 앱(#, A–Z, ㄱ–ㅎ), 최근 앱, 전원 메뉴가 있습니다.
- 실행 중인 원격 프로그램마다 그 이름과 아이콘으로 Dock 아이콘이 생깁니다. 클릭하면 창이 앞으로 오고, 우클릭하면 창 목록, 종료를 누르면 원격 프로그램이 닫힙니다.
- 원격 시작 메뉴의 앱이 `~/Applications/Pstsc 앱/`에 등록되어 Spotlight와 Launchpad에서 바로 실행할 수 있습니다. Pstsc가 꺼져 있으면 먼저 켜서 연결한 뒤 실행합니다.

**연결**
- 비밀번호를 맥 키체인에 저장해서, Pstsc를 켜면 바로 연결합니다. 맥 로그인 시 자동 실행도 설정할 수 있습니다.
- 네트워크가 끊기거나 맥이 잠자기에서 깨어나면 자동으로 다시 연결합니다.
- 원격 프로그램을 모두 트레이로 숨겨도 원격 세션이 로그아웃되지 않습니다. 그래서 트레이의 카카오톡 같은 앱도 계속 실행됩니다.

**그 밖에**
- 원격 소리가 맥에서 재생됩니다.
- 맥 홈 폴더가 원격 탐색기에 `Mac` 드라이브로 보여서 파일을 주고받을 수 있습니다.
- 원격 트레이 아이콘의 말풍선 알림을 맥 알림 센터에 띄웁니다.
- 키보드: 왼쪽 ⌘는 Ctrl로 보내서 ⌘C·⌘V가 그대로 동작하고, 오른쪽 ⌘는 한/영 전환입니다.
- 메뉴의 "원격 PC 리소스 사용량"으로 이 연결이 원격 PC에서 쓰는 CPU와 메모리를 측정할 수 있습니다.

## 요구 사항

| 구분 | 내용 |
|---|---|
| 맥 | macOS 14 이상 (Apple Silicon에서 개발·테스트) |
| 개발 도구 | Xcode (Swift 6 툴체인), [Homebrew](https://brew.sh) |
| 라이브러리 | FreeRDP 3.32 이상 (`brew install freerdp`) |
| 원격 PC | 원격 데스크톱을 켤 수 있는 Windows 10/11 **Pro** 이상 또는 Windows Server. Home 버전은 RDP 호스트가 될 수 없습니다. |

## 원격 PC 준비

1. **설정 → 시스템 → 원격 데스크톱**을 켭니다.
2. [`remote/enable-remoteapp.reg`](remote/enable-remoteapp.reg)를 원격 PC에서 실행합니다(관리자 권한 필요). RemoteApp으로 등록되지 않은 프로그램도 실행할 수 있게 하는 설정입니다.
3. (권장) [`remote/single-session.reg`](remote/single-session.reg)도 실행합니다. 같은 계정으로 다시 접속하면 항상 기존 세션 하나에 붙게 하는 설정입니다.
4. 원격 PC를 다시 시작합니다.
5. 외부에서 접속하려면 공유기에서 RDP 포트(기본 3389)를 원격 PC로 열어 줘야 합니다. 보안을 생각하면 VPN이나 Tailscale 같은 방식을 권장합니다.

## 빌드와 설치

```bash
brew install freerdp
git clone <이 저장소 주소> Pstsc
cd Pstsc
scripts/build-app.sh
```

`scripts/build-app.sh`는 릴리스 빌드를 한 뒤 아이콘이 들어 있는 `Pstsc.app`을 만들어 `/Applications`에 설치합니다. Dock에는 이 앱을 고정하세요.

개발 중에는 이렇게 바로 실행할 수 있습니다. Dock용 보조 실행 파일도 함께 빌드해야 해서 `swift build`를 먼저 합니다.

```bash
swift build && swift run PstscAgent
```

## 사용법

1. Pstsc를 실행하고 원격 PC 주소, 사용자 이름, 비밀번호를 입력합니다. Microsoft 계정이면 사용자에 `MicrosoftAccount\메일주소`를 넣고, PIN이 아닌 계정 비밀번호를 씁니다.
2. 연결되면 Dock의 Pstsc 아이콘을 눌러 시작 메뉴에서 프로그램을 실행합니다.
3. 원격 바탕화면 전체가 필요하면 시작 메뉴의 전원 버튼 → **Windows 데스크톱 보기**를 고릅니다.

| 동작 | 방법 |
|---|---|
| 프로그램 실행 | Dock의 Pstsc 아이콘 → 시작 메뉴, 또는 Spotlight에서 앱 이름 검색 |
| 앱 고정/해제 | 시작 메뉴에서 앱 우클릭 |
| 원격 창 목록 | 메뉴바 **창** 메뉴, 또는 Dock 아이콘 우클릭 |
| 한/영 전환 | 오른쪽 ⌘ |
| 파일 주고받기 | 원격 탐색기의 `Mac` 드라이브 (`\\tsclient\Mac`) |
| 연결 끊기·원격 PC 재시작 | 시작 메뉴의 전원 버튼 |

## 동작 방식

```
[원격 Windows PC]
   ├─ RemoteApp 세션: 프로그램 창마다 화면을 따로 전송 (RDP 그래픽 파이프라인)
   └─ Pstsc 도우미 PowerShell (창 없이 실행)
        시작 메뉴 목록·아이콘 내보내기, 세션 유지용 1×1 창
        │
        │  RDP 연결 1개 (FreeRDP)          공유 폴더 \\tsclient\pstsc
        ▼
[Pstsc.app — 맥]
   ├─ 원격 창 하나 = 테두리 없는 맥 창 하나, 마우스·키보드 전달
   ├─ Windows 11 모양 시작 메뉴, 연결·재연결·모드 전환
   └─ 프로그램별 작은 대리 앱 (Dock 아이콘, Launchpad·Spotlight 실행용)
```

- RDP 연결과 RemoteApp 처리에는 [FreeRDP](https://www.freerdp.com) 라이브러리를 씁니다. C로 얇게 감싼 층([`Sources/PstscRDP`](Sources/PstscRDP))을 Swift/AppKit 앱이 사용합니다.
- 프로그램별 Dock 아이콘은 프로그램마다 작은 .app을 만들어 실행하는 방식입니다. 창 자체는 Pstsc 본체가 그립니다.

### 원격 PC에서 Pstsc가 하는 일

투명하게 밝혀 둡니다. 모두 Pstsc로 접속한 세션 안에서만 일어납니다.

- 연결할 때 공유 폴더의 `helper.ps1`을 창 없이 실행합니다(`conhost --headless powershell`).
  - `Get-StartApps`로 시작 메뉴 목록을 내보냅니다.
  - 앱 아이콘(96px)을 내보냅니다. 이미 받은 아이콘은 건너뜁니다.
  - 세션 유지용 1×1 창을 하나 띄워 둡니다. 보이는 앱 창이 없으면 Windows가 RemoteApp 세션을 로그아웃하기 때문입니다.
  - 같은 세션에 이전 연결의 Pstsc 도우미가 남아 있으면 종료하고 대신합니다.
- 상시 메모리 사용량은 약 25MB입니다(PowerShell 약 10MB와 conhost).
- "원격 PC 리소스 사용량" 메뉴를 고르면 고정된 측정 스크립트(`resources.ps1`)를 한 번 실행합니다.

## 맥에 저장되는 것

| 항목 | 위치 |
|---|---|
| 비밀번호 | 키체인, 서비스 이름 `com.pstsc.agent` |
| 주소·사용자·설정 | `defaults read com.pstsc.agent` |
| 공유 폴더, 앱 목록, 아이콘 | `~/Library/Application Support/Pstsc/` |
| 프로그램별 Dock 대리 앱 | `~/Library/Application Support/Pstsc/Apps/` |
| Launchpad·Spotlight 실행용 앱 | `~/Applications/Pstsc 앱/` |
| 로그 | `~/Library/Logs/Pstsc/agent.log` (실행할 때마다 새로 씀) |

## 보안 참고

- 서버 인증서는 처음 접속할 때 신뢰하고 저장합니다(TOFU). 이후 인증서가 바뀌면 연결을 거부합니다.
- 홈 폴더 공유를 켜 두면 원격 PC에서 맥 홈 폴더에 접근할 수 있습니다. 필요 없으면 메뉴에서 끄세요.
- 빌드된 앱은 개발자 인증서가 아닌 ad-hoc 서명입니다. 다른 맥에 복사해서 쓰면 Gatekeeper 경고가 뜰 수 있습니다.

## 알려진 제한

- **진짜 Windows 시작 메뉴, 검색, 알림 센터는 RemoteApp으로 전달되지 않습니다.** 그래서 맥에서 비슷하게 생긴 시작 메뉴를 직접 그립니다. 데스크톱 모드에서는 진짜 시작 메뉴가 열립니다.
- Windows 11 토스트 알림은 전달되지 않습니다. 트레이 아이콘의 말풍선 알림만 맥 알림이 됩니다.
- 원격 트레이 아이콘을 직접 누를 수는 없습니다. 트레이로 숨은 앱은 시작 메뉴나 Spotlight에서 다시 실행하면 열립니다.
- 원격 창을 직접 클릭하면 Dock과 ⌘Tab에서는 해당 프로그램이 아니라 Pstsc가 활성 앱으로 표시됩니다.
- Windows 11 창의 크기 조절 손잡이는 눈에 보이는 테두리 바깥에 있어서 잡히지 않을 수 있습니다.
- 클립보드 공유, 원격 마우스 커서 모양, Retina 해상도는 아직 지원하지 않습니다. 화면은 맥 1포인트당 1픽셀로 받습니다.
- 모니터를 연결하거나 뺀 경우 다시 연결해야 반영됩니다.

## 문제 해결

- **연결이 계속 끊기고 다시 붙는다**: 다른 기기(예: Windows App)가 같은 계정으로 접속해 있으면 세션을 서로 빼앗습니다. 한쪽만 쓰세요.
- **"already running"이 나오고 바로 종료된다**: Pstsc가 이미 실행 중입니다. Pstsc는 한 번에 하나만 실행됩니다.
- **프로그램이 실행되지 않는다**: 원격 PC에 `enable-remoteapp.reg`를 적용했는지 확인하세요.
- **그 밖의 문제**: `~/Library/Logs/Pstsc/agent.log`를 확인하세요. 개인정보가 남지 않도록 연결 상태와 오류만 기록합니다. 창 제목, 실행한 앱, 원격 PC 주소, 계정은 남기지 않습니다. FreeRDP 자체 로그는 원격 PC 이름과 계정을 포함하므로 기본으로 꺼져 있습니다. 디버깅할 때만 `WLOG_LEVEL=INFO swift run PstscAgent`처럼 켜고, 그 로그는 공개된 곳에 올리지 마세요.

## 프로젝트 구조

| 경로 | 내용 |
|---|---|
| `Sources/PstscRDP/` | FreeRDP를 감싸는 C 코드: 연결 스레드, RemoteApp 창 정보, 창별 화면, 입력, 아이콘, 알림 |
| `Sources/PstscAgent/` | 맥 앱 본체 (Swift/AppKit) |
| `Sources/PstscDockProxy/` | 프로그램별 Dock 아이콘 겸 Launchpad 실행용 보조 앱 |
| `scripts/build-app.sh` | `Pstsc.app` 빌드·설치 |
| `scripts/test-remoteapp.sh` | xfreerdp로 RemoteApp 동작만 따로 확인하는 스크립트 |
| `remote/` | 원격 PC에 적용하는 레지스트리 파일, 테스트용 `.rdp` |
| `PLAN.md`, `PROGRESS.md` | 설계와 개발 기록 |

## 라이선스

[MIT License](LICENSE)

## 크레딧

- [FreeRDP](https://github.com/FreeRDP/FreeRDP) (Apache License 2.0): RDP 프로토콜 구현
