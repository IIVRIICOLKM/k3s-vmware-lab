#!/usr/bin/env bash
# Applies infra/terraform in two phases, because elsudano/vmworkstation 2.0.1 fails when it creates a VM powered on:
#   1) VMs that are about to be created (or replaced) get state "off"; existing VMs keep their desired state.
#   2) A normal apply then powers the new VMs on.
#   3) Every managed VM is registered in the VMware Workstation UI library.
# Usage: scripts/cluster-apply.sh [-auto-approve] [-replace=ADDR ...] [-var ...]
#   -replace only applies to phase 1 (otherwise the VM would be replaced twice); -auto-approve is not given to plan.
#
# [한국어 설명] Terraform으로 VM 3대를 만들고 → 전원을 켜고 → Workstation 화면 목록에 등록한다. entry.sh 6단계.
#   왜 apply를 두 번 하나? provider(elsudano/vmworkstation 2.0.1)는 VM을 "켜진 상태로 생성"하면 실패한다.
#     1단계: 이번에 새로 생길(또는 교체될) VM만 power_state_overrides 변수로 "off"를 지정해 꺼진 채 생성
#     2단계: 원래 설정(on)으로 다시 apply → 방금 만든 VM 전원 켜기 (기존 VM은 변화 없음)
#     3단계: register-vms.sh로 Workstation UI 라이브러리에 등록
#   [재실행] 바뀐 게 없으면 1단계는 건너뛰고, 2단계는 "No changes", 3단계는 "already registered".

#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"
# 모든 Terraform 호출은 tf.sh 래퍼를 거친다
TF="$REPO_ROOT/scripts/tf.sh"

# --- 1) 받은 인자를 용도별로 나누기 ---
# plan_args  : plan에 넘길 인자 (plan은 -auto-approve 옵션을 모르므로 뺀다)
# final_args : 2단계 apply에 넘길 인자 (-replace를 빼야 VM이 1·2단계에서 두 번 교체되지 않는다)
plan_args=()
final_args=()
for a in "$@"; do
  [[ "$a" == -auto-approve ]] || plan_args+=("$a")
  [[ "$a" == -replace=* ]] || final_args+=("$a")
done

# --- 2) plan을 파일로 저장한 뒤 "새로 생성될 VM" 목록 뽑기 ---
# jq : resource_changes 중 VM 리소스이면서 actions에 "create"가 있는 것(신규 또는 교체)의 index(= 노드 이름)만 배열로
#   결과 예) ["worker-cpu-2"]  /  새로 만들 VM이 없으면 []
PLAN="$LAB_STATE_DIR/terraform/cluster-apply.tfplan"
"$TF" plan -input=false -out="$PLAN" "${plan_args[@]}" >/dev/null
new=$("$TF" show -json "$PLAN" | jq -c '[.resource_changes[]
  | select(.type == "vmworkstation_virtual_machine" and (.change.actions | index("create")))
  | .index]')
rm -f "$PLAN"

# --- 3) 1단계: 새 VM이 있으면 꺼진 상태로 생성 ---
# jq 'map({(.): "off"}) | add' : ["a","b"] → {"a":"off","b":"off"}  (Terraform map(string) 변수 형식)
if [[ "$new" != "[]" ]]; then
  overrides=$(jq -c 'map({(.): "off"}) | add' <<<"$new")
  log "phase 1: creating $new powered off"
  "$TF" apply -input=false -var "power_state_overrides=$overrides" "$@"
fi
# --- 4) 2단계: 원래 원하는 전원 상태로 apply (새 VM 전원 켜기) ---
log "phase 2: apply desired power state"
"$TF" apply -input=false "${final_args[@]}"
# --- 5) 3단계: Workstation UI 라이브러리에 빠진 VM 등록 (이미 있으면 건너뜀) ---
"$REPO_ROOT/scripts/register-vms.sh"
