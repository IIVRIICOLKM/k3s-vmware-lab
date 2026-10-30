#!/usr/bin/env bash
# Starts vmrest over HTTPS on 127.0.0.1 only, as the current user, and verifies the binding.
#
# [한국어 설명] vmrest(VMware REST API 서버)를 백그라운드로 띄우고, 루프백 주소에서만 열렸는지 확인한다.
#   [언제]   entry.sh 1단계. vmrest는 일반 사용자 프로세스라 재부팅·로그아웃하면 꺼지므로 작업 전마다 실행.
#   [재실행] 8697 포트에 이미 무언가 떠 있으면 아무것도 안 하고 성공 종료.
#   [필요]   ~/.config/k3s-vmware-lab/secrets/vmrest.crt, vmrest.key (HTTPS 인증서와 개인키)

#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 이미 실행 중이면 그대로 두고 종료 ---
# ss -Hltn : 헤더 없이(-H) LISTEN 상태(-l) TCP(-t) 소켓을 숫자 주소로(-n) 출력. 괄호 안 필터로 8697 포트만 본다.
# grep -q . : 출력이 한 글자라도 있으면 참 → 이미 누가 그 포트를 쓰고 있음
if ss -Hltn "( sport = :$VMREST_PORT )" | grep -q .; then
  log "something already listens on :$VMREST_PORT; not starting a second vmrest"
  ss -Hltn "( sport = :$VMREST_PORT )"
  exit 0
fi
# --- 2) 인증서·키 파일 확인 후 vmrest를 백그라운드로 실행 ---
# setsid -f : 새 세션으로 떼어내서 이 스크립트(터미널)가 끝나도 vmrest가 같이 죽지 않게 함
# nohup     : 터미널이 닫힐 때 오는 HUP 신호 무시
# 출력은 ~/.local/state/k3s-vmware-lab/logs/vmrest.log 로, 입력은 /dev/null 로 연결
for f in vmrest.crt vmrest.key; do [[ -f "$LAB_SECRETS_DIR/$f" ]] || die "missing $LAB_SECRETS_DIR/$f"; done
mkdir -p "$LAB_LOG_DIR"
setsid -f nohup vmrest -c "$LAB_SECRETS_DIR/vmrest.crt" -k "$LAB_SECRETS_DIR/vmrest.key" -p "$VMREST_PORT" \
  >"$LAB_LOG_DIR/vmrest.log" 2>&1 </dev/null

# --- 3) 포트가 열릴 때까지 최대 10초(0.5초 × 20번) 대기 ---
# awk '{print $4}' : ss 출력의 4번째 칸 = 로컬 주소:포트 (예: 127.0.0.1:8697)
for _ in $(seq 20); do
  listeners=$(ss -Hltn "( sport = :$VMREST_PORT )" | awk '{print $4}')
  [[ -n "$listeners" ]] && break
  sleep 0.5
done
[[ -n "${listeners:-}" ]] || die "vmrest did not start; see $LAB_LOG_DIR/vmrest.log"
# --- 4) 보안 검사: 루프백(127.0.0.1 / [::1]) 이외 주소에 열렸으면 vmrest를 종료하고 실패 처리 ---
# grep -v : 패턴에 "맞지 않는" 줄을 찾음 → 루프백이 아닌 주소가 한 줄이라도 있으면 외부에 노출된 것
# vmrest 1.3.1 has no bind-address flag; refuse to leave it running if it ever binds beyond loopback.
if grep -qvE "^(127\.0\.0\.1|\[::1\]):$VMREST_PORT$" <<<"$listeners"; then
  pkill -x vmrest || true
  die "vmrest bound beyond loopback ($listeners); stopped it"
fi
log "vmrest listening on $listeners (HTTPS)"
