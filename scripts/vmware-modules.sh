#!/usr/bin/env bash
# Builds VMware Workstation's vmmon/vmnet kernel modules for an installed kernel before booting into it (default: the
# newest installed kernel), so a kernel update no longer leaves VMware unable to start after the reboot.
# vmware-modconfig only builds for the running kernel; this compiles the module sources Workstation ships with
# against the target kernel's headers. Building needs no root; --install copies the modules into /lib/modules (sudo).
# Usage: scripts/vmware-modules.sh [--install] [kernel-version]
#
# [한국어 설명] 커널 업데이트 뒤 재부팅하면 VMware가 안 뜨는 문제(2026-10-01, 10-15 두 번 발생)를 막는다.
#   원인: VMware 커널 모듈(vmmon: VM 실행, vmnet: 가상 네트워크)이 새 커널용으로 자동 빌드되지 않는다.
#         vmware-modconfig는 "지금 실행 중인" 커널용으로만 빌드하므로, 새 커널로 재부팅한 뒤에야 쓸 수 있다.
#   방법: Workstation에 들어 있는 모듈 소스(/usr/lib/vmware/modules/source/*.tar)를
#         대상 커널의 헤더로 직접 빌드한다 (make VM_UNAME=<커널버전> → Makefile의 uname -r 값을 덮어씀).
#   [언제] apt로 새 커널이 설치된 뒤, 재부팅하기 "전에" 실행 (preflight가 WARN으로 알려 준다)
#   [인자] --install: 빌드한 .ko를 /lib/modules/<버전>/misc/에 sudo로 설치하고 depmod (콘솔에서 실행)
#          커널 버전: 생략하면 /lib/modules 중 가장 최신 버전
#   [결과] --install 없이: ~/.local/state/k3s-vmware-lab/vmware-modules/<버전>/ 에 .ko만 만들어 둔다
#   [로그] ~/.local/state/k3s-vmware-lab/logs/vmware-modules-<버전>.log
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 인자 ---
# sed -n '2,6s/^# \{0,1\}//p' "$0" : 이 파일 2~6번째 줄(영문 설명)을 도움말로 출력
INSTALL=0
KVER=""
for arg in "$@"; do
  case "$arg" in
  --install) INSTALL=1 ;;
  -h | --help)
    sed -n '2,6s/^# \{0,1\}//p' "$0"
    exit 0
    ;;
  -*) die "unknown option $arg (see --help)" ;;
  *) KVER=$arg ;;
  esac
done
# 커널 버전을 안 주면 /lib/modules 아래 폴더 이름 중 버전 순(sort -V)으로 가장 큰 것
[[ -n "$KVER" ]] || KVER=$(find /lib/modules -mindepth 1 -maxdepth 1 -printf '%f\n' | sort -V | tail -1)

# --- 2) 사전 검사 ---
# 대상 커널의 헤더(build 링크)가 있어야 컴파일할 수 있다 / Workstation 모듈 소스가 있어야 한다
SRC=/usr/lib/vmware/modules/source
[[ -d "/lib/modules/$KVER/build" ]] || die "no headers for $KVER (/lib/modules/$KVER/build); install linux-headers-$KVER"
for m in vmmon vmnet; do [[ -f "$SRC/$m.tar" ]] || die "missing $SRC/$m.tar (VMware Workstation module sources)"; done
# Secure Boot가 켜져 있으면 서명 안 된 모듈은 로드되지 않는다 (이 호스트는 꺼져 있음, 2026-10-16 확인)
if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
  log "WARNING: Secure Boot is enabled; unsigned modules will not load (sign them with your MOK key first)"
fi
OUT="$LAB_STATE_DIR/vmware-modules/$KVER"
LOG="$LAB_LOG_DIR/vmware-modules-$KVER.log"
mkdir -p "$OUT" "$LAB_LOG_DIR"
# 빌드용 임시 폴더: 스크립트가 어떻게 끝나든(EXIT) 지운다
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- 3) 빌드 ---
# 소스 tar를 풀고 make VM_UNAME=<버전> 으로 대상 커널용 .ko를 만든 뒤,
# modinfo vermagic(모듈이 어떤 커널용인지 적힌 값)이 대상 버전으로 시작하는지 확인
log "building vmmon/vmnet for $KVER (running kernel: $(uname -r); log: $LOG)"
: >"$LOG"
for m in vmmon vmnet; do
  tar -xf "$SRC/$m.tar" -C "$WORK"
  make -C "$WORK/$m-only" VM_UNAME="$KVER" >>"$LOG" 2>&1 || die "building $m failed (see $LOG)"
  vermagic=$(modinfo -F vermagic "$WORK/$m-only/$m.ko")
  [[ "$vermagic" == "$KVER "* ]] || die "$m.ko was built for '$vermagic', expected $KVER"
  install -m 0644 "$WORK/$m-only/$m.ko" "$OUT/$m.ko"
  log "built $m.ko for $KVER"
done

# --- 4) 설치 (--install일 때만, sudo) ---
# vmware-modconfig와 같은 위치(/lib/modules/<버전>/misc/)에 넣고 depmod로 모듈 목록을 갱신한다.
# 재부팅 뒤 vmware.service가 이 모듈을 불러온다.
if ((INSTALL)); then
  log "installing into /lib/modules/$KVER/misc (sudo)"
  sudo install -D -m 0644 "$OUT/vmmon.ko" "/lib/modules/$KVER/misc/vmmon.ko"
  sudo install -D -m 0644 "$OUT/vmnet.ko" "/lib/modules/$KVER/misc/vmnet.ko"
  sudo depmod -a "$KVER"
  log "done: VMware modules are ready for $KVER; scripts/preflight.sh should no longer warn"
else
  log "built only. To install (console, sudo): scripts/vmware-modules.sh --install $KVER"
fi
