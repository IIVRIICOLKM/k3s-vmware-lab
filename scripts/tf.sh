#!/usr/bin/env bash
# Terraform wrapper for infra/terraform: injects vmrest credentials as sensitive variables, keeps state in the XDG
# state dir, forces -parallelism=1 (vmrest cannot serve concurrent changes) and backs the state up before changes.
# Usage: scripts/tf.sh <terraform args...>
#
# [한국어 설명] Terraform 래퍼. Terraform은 항상 이 스크립트로 실행한다 (terraform 직접 실행 X).
#   - vmrest 자격증명을 TF_VAR_* 환경변수(민감 변수)로 넣어 줌 → .tf 파일·Git에 비밀번호가 남지 않음
#   - state 파일을 저장소가 아니라 ~/.local/state/k3s-vmware-lab/terraform/ 에 둠
#   - plan/apply 등에 -parallelism=1 강제 (vmrest는 여러 변경 요청을 동시에 처리하지 못함)
#   - apply/destroy처럼 state를 바꾸는 명령 전에는 state를 백업 (최근 30개만 유지)
#   [언제] entry.sh 5단계(init), 그리고 cluster-apply.sh · render-inventory.sh · register-vms.sh 내부
#   [예]   scripts/tf.sh plan  /  scripts/tf.sh output -json nodes  /  scripts/tf.sh state list

#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 환경 준비 ---
# vmrest 자격증명 읽기 → TF_VAR_vmws_endpoint / username / password 로 내보냄
load_vmrest_env
# The state can contain sensitive values: create it, its backups and plan files owner-only.
umask 077
# TF_VAR_vm_root_dir : Terraform 변수 vm_root_dir (VM 저장 경로)
# TF_IN_AUTOMATION=1 : "다음에 terraform apply를 실행하세요" 같은 사람용 안내 문구 생략
# TF_CLI_ARGS_<명령> : 그 하위 명령에 자동으로 붙는 인자 → plan/apply/destroy/refresh/import에 항상 -parallelism=1
export TF_VAR_vm_root_dir="$LAB_VM_DIR"
export TF_IN_AUTOMATION=1
for cmd in plan apply destroy refresh import; do
  export "TF_CLI_ARGS_$cmd=-parallelism=1"
done

# TFDIR : Terraform 코드 위치 / STATE : state 파일 / BACKUPS : state 백업 폴더
TFDIR="$REPO_ROOT/infra/terraform"
STATE="$LAB_STATE_DIR/terraform/terraform.tfstate"
BACKUPS="$LAB_STATE_DIR/terraform/backups"

# --- 2) 첫 번째 인자(하위 명령)에 따라 사전 작업 ---
case "${1:-}" in
# init : 로컬 backend의 state 경로를 XDG 상태 폴더로 지정해서 초기화
#   exec = 이 셸을 terraform 프로세스로 "교체" → 종료 코드가 그대로 전달되고, 아래 줄은 실행되지 않음
init)
  shift
  exec terraform -chdir="$TFDIR" init -input=false -backend-config="path=$STATE" "$@"
  ;;
# state를 바꾸는 명령 : 실행 전에 state를 "terraform.tfstate.날짜시각" 이름으로 백업
#   find -printf '%T@ %p' = "수정시각(초) 경로" 목록 → 최신순 정렬(sort -rn) → 31번째부터(tail -n +31) 삭제 = 30개만 유지
apply | destroy | import | state | taint | untaint)
  if [[ -s "$STATE" ]]; then
    mkdir -p "$BACKUPS"
    cp "$STATE" "$BACKUPS/terraform.tfstate.$(date +%Y%m%dT%H%M%S)"
    find "$BACKUPS" -name 'terraform.tfstate.*' -printf '%T@ %p\n' | sort -rn | tail -n +31 | cut -d' ' -f2- | xargs -r rm -f
  fi
  ;;
esac
# --- 3) 실제 terraform 실행 (init 외의 모든 명령. 받은 인자를 그대로 전달) ---
exec terraform -chdir="$TFDIR" "$@"
