# Pstsc — 원격 Windows 앱을 맥 앱처럼 쓰는 RDP 클라이언트

목표: 원격 Windows 11 Pro PC의 프로그램을 하나씩 불러와서, Parallels Coherence처럼
**프로그램마다 독립된 맥 창 + 자기 아이콘의 Dock 항목**으로 쓰는 것.

## 핵심 원리

- **RemoteApp (RAIL, MS-RDPERP)**: RDP가 바탕화면 대신 개별 창 단위로 화면과 창 정보를 보내주는 기능.
  원격의 창 하나 = RAIL 창 ID(실제로는 HWND) 하나.
- **창 → 프로그램 매칭**: RAIL의 `Get AppID Extended Response`(MS-RDPERP 2.2.2.8.1)가
  창마다 프로세스 ID와 실행 파일 경로를 알려준다. 이걸로 창을 프로그램별로 묶는다.
- **Dock 아이콘 분리**: 맥은 프로세스 하나에 Dock 아이콘 하나. 그래서 프로그램마다
  작은 껍데기 앱(stub .app)을 만들고, 각 껍데기 앱이 자기 프로그램의 창만 그린다.
  (Parallels도 `~/Applications (Parallels)`에 같은 방식으로 껍데기 앱을 만든다.)
- **RDP 연결은 하나만**: Windows Pro는 세션을 하나만 허용하므로, 연결은 메인 에이전트가
  하나만 유지하고 화면과 입력을 껍데기 앱들에 나눠준다.

## 구조

```
[원격 Windows 11 Pro]  RemoteApp 허용 (remote/enable-remoteapp.reg)
        │  RDP 연결 1개 (RAIL 채널)
[PstscAgent]  메뉴바 앱 · libfreerdp3 기반
   - 연결/재연결, RAIL 창 목록 관리, 창→프로그램 매칭
   - 창 화면을 IOSurface로 공유, 입력/창 이동 이벤트를 원격으로 전달
        │  XPC (또는 Unix socket)
[Notepad.app] [Excel.app] [ERP.app] ...  ~/Applications/Pstsc Apps/
   - 프로그램별 껍데기 앱. 원격 exe 아이콘을 앱 아이콘으로 사용
   - 실행 → 에이전트에 "이 프로그램 실행" 요청
   - 자기 프로그램의 창만 NSWindow로 표시, Dock 메뉴(Show All Windows / Quit) 제공
```

## 단계

| 단계 | 내용 | 완료 기준 |
|---|---|---|
| 1 | 원격 PC RemoteApp 활성화 + 동작 검증 | `.rdp` 파일로 메모장 하나만 별도 창으로 뜸 |
| 2 | libfreerdp3 + Swift로 PstscAgent 기본형 | 우리 앱에서 RAIL 창이 각각 NSWindow로 뜨고 입력이 됨 (Dock 아이콘은 1개) |
| 3 | 창→프로그램 매칭 + 아이콘 추출 | 창 목록이 exe별로 묶이고 아이콘을 가져옴 |
| 4 | 프로그램별 껍데기 앱 + IOSurface 공유 + 입력 전달 | **프로그램마다 Dock 아이콘이 따로 생김** |
| 5 | 다듬기 | 클립보드, Retina/다중 모니터, 재연결, 프로그램 목록 UI |

## 1단계 진행 방법

1. 원격 PC에서 `remote/enable-remoteapp.reg`를 실행(더블클릭 → 예)한다. 관리자 권한 필요.
2. 맥에서 `remote/notepad.rdp`의 `full address`를 원격 PC 주소로 바꾼다.
3. `notepad.rdp`를 Windows App으로 연다.
   - 메모장 창만 뜨면 → 원격 PC 쪽 준비 완료.
   - 바탕화면 전체가 뜨면 → Windows App이 `.rdp` RemoteApp 설정을 무시하는 것.
     이 경우 `scripts/test-remoteapp.sh`(FreeRDP)로 검증한다.
