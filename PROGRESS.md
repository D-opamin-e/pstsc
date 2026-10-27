# 개발 기록

설계 개요는 [PLAN.md](PLAN.md), 사용법은 [README.md](README.md)를 참고하세요. 이 문서는 구현 단계와 개발하면서 알게 된 기술적인 사실을 정리합니다.

## 단계별 진행

| 단계 | 내용 | 상태 |
|---|---|---|
| 1 | 원격 PC RemoteApp 허용, 기존 클라이언트로 동작 확인 | 완료 |
| 2 | FreeRDP + Swift로 원격 창 하나를 맥 창 하나로 표시, 입력 전달 | 완료 |
| 3 | 원격 시작 메뉴 목록·아이콘, Windows 11 모양 시작 메뉴, 데스크톱 모드 | 완료 |
| 4 (간이) | 프로그램별 Dock 아이콘 (대리 앱 방식) | 완료 |
| 5 | 듀얼 모니터, 소리, 자동 로그인, 자동 재연결, 파일 공유, 알림, Launchpad/Spotlight | 완료 |
| 4 (완전) | 프로그램별 앱이 직접 창을 그림 (IOSurface + XPC) | 예정 |

## 개발하면서 알게 된 것

**그래픽**
- Windows 11은 그래픽 파이프라인(GFX) 없이 RemoteApp으로 접속하면 로그인 직후 연결을 끊습니다. GFX는 반드시 켜야 합니다.
- FreeRDP 3.32의 명령줄 옵션 `-gfx`는 GFX를 끄지 않고 오히려 켭니다. `FreeRDP_SupportGraphicsPipeline` 설정값으로 직접 제어합니다.
- GFX에서는 원격 창마다 별도의 surface로 화면이 옵니다(`UpdateWindowFromSurface`). surface를 받지 않은 창(작업 표시줄, Program Manager 등)은 표시하면 안 됩니다. 공용 화면 버퍼에는 오래된 로그인 화면이 남아 있기 때문입니다.

**RemoteApp(RAIL) 프로토콜**
- 원격이 시작 절차를 마치기 전(MonitoredDesktop의 ARC_COMPLETED → `client_rail_server_start_cmd`)에는 창 활성화 같은 RAIL 메시지를 보내지 않습니다.
- 메뉴·툴팁 판별: `WS_POPUP`이면서 `WS_CAPTION`이 없더라도, `WS_SYSMENU`/`WS_THICKFRAME`/`WS_MINIMIZEBOX`가 있거나 `WS_EX_APPWINDOW`이면 앱 창입니다. 제목줄을 직접 그리는 앱이 여기에 해당합니다.
- 창 이동은 원격의 로컬 이동 신호(`ServerLocalMoveSize`)를 받으면 맥에서 직접 처리하고, 끝나면 버튼 뗌과 `ClientWindowMove`로 최종 위치를 보고합니다.
- 창이 어느 프로그램 것인지는 `ClientGetAppIdRequest`로 묻습니다. `GET_APPID_RESPONSE_EX_SUPPORTED`를 알리면 실행 파일 경로까지 받을 수 있습니다.
- 진짜 Windows 시작 메뉴, 검색, 알림 센터는 RemoteApp으로 전달되지 않습니다. Windows 키를 보내도 창 정보가 오지 않습니다.
- 트레이로 숨는 앱은 X를 누르면 창이 숨김(`showState = 0`)으로 바뀝니다. 서버가 숨긴 창을 클라이언트가 다시 띄우면 앱과 충돌합니다.

**세션**
- 보이는 RemoteApp 창이 하나도 없으면 Windows가 세션을 로그아웃합니다(`ERRINFO_LOGOFF_BY_USER`). 이때 트레이에서 돌던 앱도 함께 종료됩니다. 숨은 프로세스는 열린 앱으로 치지 않으므로, 1×1 크기의 거의 투명한 창을 띄워 세션을 유지합니다.
- 같은 계정으로 두 클라이언트가 접속하면 서로 세션을 빼앗습니다(`ERRINFO_RPC_INITIATED_DISCONNECT`). 그래서 Pstsc는 한 번에 하나만 실행되게 막습니다.
- RemoteApp 세션과 전체 데스크톱 세션은 Windows가 별도 세션으로 만들 수 있습니다. `fSingleSessionPerUser`(`remote/single-session.reg`)로 줄일 수 있습니다.

**다중 모니터**
- 모니터 배치는 주 모니터를 (0,0)으로 두고 보냅니다. 창 좌표는 주 모니터 기준이고, 마우스 입력 좌표는 가상 데스크톱의 왼쪽 위 기준이라 보정이 필요합니다.

**원격 도우미(PowerShell)**
- `-WindowStyle Hidden`만으로는 PowerShell 창이 잠깐 보였다가 최소화된 채 남습니다. `conhost.exe --headless`로 실행하면 창이 생기지 않습니다.
- 스크립트가 길면 RemoteApp 명령줄 길이 제한에 걸립니다. 공유 폴더에 스크립트 파일을 두고, 명령줄에는 그 파일을 실행하는 짧은 부트스트랩만 넘깁니다.
- 앱 아이콘은 `IShellItemImageFactory`로 `shell:AppsFolder\<AppID>`에서 뽑습니다. 일반 프로그램과 스토어 앱 모두 됩니다.
- 한국어 Windows는 성능 카운터 이름이 현지화되어 있어서, 리소스 측정에는 WMI 클래스를 씁니다.
- 아이콘 추출용 코드를 불러온 PowerShell은 메모리를 많이 씁니다. 작업 후 GC와 `SetProcessWorkingSetSize(-1, -1)`로 반납하면 상시 사용량이 약 10MB로 줄어듭니다.

**맥**
- AppKit은 ⌘를 누른 상태의 keyUp 이벤트를 창에 전달하지 않습니다. `NSApplication.sendEvent`에서 직접 넘겨줘야 원격에서 키가 눌린 채로 남지 않습니다.
- 테두리 없는 창은 기본적으로 키보드 포커스를 받지 못하므로 `canBecomeKey`를 재정의합니다.
- 프로세스 하나에는 Dock 아이콘이 하나만 생깁니다. 프로그램별 Dock 아이콘은 프로그램마다 작은 .app을 만들어 실행하는 방식으로 구현했습니다.

## 다음에 할 일

- 클립보드 공유
- 원격 마우스 커서 모양 반영
- Retina 해상도(원격 배율 200%로 받기)
- 화면 갱신 최적화: 바뀐 부분만 GPU로 올리기
- 프로그램별 앱이 직접 창을 그리는 완전한 Dock 통합
- 원격 트레이 아이콘을 맥 메뉴바에 표시

## 참고

- FreeRDP 3.32.2 소스: `git clone --depth 1 --branch 3.32.2 https://github.com/FreeRDP/FreeRDP.git`
  - RemoteApp: `client/X11/xf_rail.c`, `client/X11/xf_gfx.c`, `libfreerdp/gdi/gfx.c`
  - 맥 키 처리: `client/Mac/MRDPView.m`
