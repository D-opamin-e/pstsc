#!/bin/bash
# 1단계 검증: FreeRDP로 원격 프로그램 하나를 RemoteApp(별도 창)으로 띄운다.
# 사용법: scripts/test-remoteapp.sh <원격PC주소> <사용자> [프로그램 경로]
# 비밀번호는 FreeRDP가 터미널에서 직접 물어본다.
set -euo pipefail

host="${1:?원격 PC 주소를 입력하세요}"
user="${2:?사용자 이름을 입력하세요}"
program="${3:-C:\\Windows\\System32\\notepad.exe}"

# RemoteApp(RAIL)은 X11 클라이언트(xfreerdp)만 지원한다. SDL 클라이언트는 RAIL 미지원.
client="$(command -v xfreerdp3 || command -v xfreerdp || true)"
if [[ -z "$client" ]]; then
  echo "xfreerdp가 없습니다: brew install freerdp" >&2
  exit 1
fi
if [[ ! -d /Applications/Utilities/XQuartz.app && ! -d /Applications/XQuartz.app ]]; then
  echo "xfreerdp는 XQuartz가 필요합니다: brew install --cask xquartz (설치 후 로그아웃/로그인)" >&2
  exit 1
fi

exec "$client" \
  /v:"$host" /u:"$user" \
  /app:program:"$program" \
  /cert:tofu \
  +clipboard \
  /log-level:INFO
