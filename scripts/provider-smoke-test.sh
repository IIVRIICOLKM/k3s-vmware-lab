#!/usr/bin/env bash
# Smoke test for elsudano/vmworkstation on this host (handoff section 6):
#   init + provider hash -> plan -> create (off) -> power on -> in-place update -> power off
#   -> vmrest restart -> destroy, with an empty re-plan and API/vmrun/state agreement after every step.
# Provider 2.0.1 re-creates the clone's NIC after cloning, so two rules are baked in (see docs):
#   the parent NIC must be type "custom" on vmnet8, and a VM must be created "off" and powered on afterwards.
# Touches only one disposable clone. Re-runnable: leftovers of a failed run are destroyed first.
#
# [한국어 설명] Terraform provider(elsudano/vmworkstation 2.0.1)가 이 호스트에서 제대로 동작하는지 검증하는 테스트.
#   일회용 복제 VM 하나(k3slab-smoke-clone)만 만들었다가 지우며, 단계마다
#   ① vmrest API ② vmrun ③ Terraform state 세 곳의 정보가 일치하는지, 재계획(plan)이 비어 있는지 확인한다.
#   단계: 0 사전 조건 → 1 init·provider 해시 → 2 꺼진 채 생성 → 3 전원 켜기 → 4 메모리 변경
#         → 5 전원 끄기 → 6 vmrest 재시작 → 7 삭제 후 흔적 확인
#   [언제] Workstation·vmrest·Terraform·provider 버전을 올릴 때 (pinned-versions.env 갱신 전). entry.sh에는 없음.
#   [로그] ~/.local/state/k3s-vmware-lab/logs/provider-smoke-test-<날짜시각>.log
#   실제 클러스터 state와 분리된 별도 작업 폴더(~/.local/state/k3s-vmware-lab/smoke-test)에서 돈다.

#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 설정: 복제 원본(골든 이미지)·복제본 이름(환경변수 SMOKE_*로 변경 가능), 작업 폴더, 복제본 VMX 경로, 로그 파일 ---
BASE_NAME="${SMOKE_BASE_NAME:-k3slab-golden-rocky98-20260918-1}"
CLONE_NAME="${SMOKE_CLONE_NAME:-k3slab-smoke-clone}"
WORK="$LAB_STATE_DIR/smoke-test"
CLONE_VMX="$LAB_VM_DIR/$CLONE_NAME/$CLONE_NAME.vmx"
LOG="$LAB_LOG_DIR/provider-smoke-test-$(date +%Y%m%dT%H%M%S).log"
mkdir -p "$WORK" "$LAB_LOG_DIR"
# exec > >(tee -a "$LOG") 2>&1 : 이후 모든 출력(표준출력 + 에러)을 화면과 로그 파일에 동시에 기록
exec > >(tee -a "$LOG") 2>&1

load_vmrest_env
# TF_INPUT=0 : Terraform이 값을 입력하라고 묻지 않게 함 / PAR : 모든 plan·apply·destroy에 붙일 -parallelism=1
export TF_IN_AUTOMATION=1 TF_INPUT=0
PAR=(-parallelism=1) # provider known issue: vmrest cannot serve concurrent mutations

# --- 보조 함수 ---
# tf   : 작업 폴더(WORK)의 별도 Terraform 구성으로 terraform 실행
# step : 단계 제목 로그 / ok : 성공 로그
# bad  : 실패 로그를 남기고 종료. state는 남겨 두므로 다시 실행하면 0b 단계에서 정리부터 한다
tf() { terraform -chdir="$WORK" "$@"; }
step() { log "=== $*"; }
ok() { log "PASS  $*"; }
bad() {
  log "FAIL  $*"
  log "Terraform state kept in $WORK; re-run this script to clean up."
  exit 1
}
# plan_rc 이름 : plan 결과를 WORK/이름.tfplan(계획)·이름.txt(출력)로 저장하고 종료 코드만 출력
#   -detailed-exitcode → 0 = 변경 없음, 1 = 에러, 2 = 변경 있음
#   2도 정상 흐름이라, plan 하는 동안만 set +e로 "실패 시 즉시 종료"를 끈다
plan_rc() { # prints terraform's detailed exit code: 0 no changes, 1 error, 2 changes
  set +e
  tf plan -no-color -input=false -detailed-exitcode "${PAR[@]}" -out="$WORK/$1.tfplan" >"$WORK/$1.txt" 2>&1
  local rc=$?
  set -e
  echo "$rc"
}

# write_config 전원(on|off) 메모리MB : 테스트용 main.tf를 WORK에 새로 씀
#   heredoc(<<EOF ... EOF) 안의 $변수는 실제 값으로 바뀌어 들어간다 (원본·복제본 이름, 고정 버전 등)
write_config() { # $1 = state (on|off), $2 = memory MB
  cat >"$WORK/main.tf" <<EOF
terraform {
  required_version = "= $PIN_TERRAFORM_VERSION"
  required_providers {
    vmworkstation = {
      source  = "elsudano/vmworkstation"
      version = "= $PIN_PROVIDER_VMWORKSTATION_VERSION"
    }
  }
}

variable "vmws_endpoint" { type = string }
variable "vmws_username" { type = string }
variable "vmws_password" {
  type      = string
  sensitive = true
}

provider "vmworkstation" {
  endpoint = var.vmws_endpoint
  username = var.vmws_username
  password = var.vmws_password
  https    = true
  debug    = "NONE"
}

data "vmworkstation_virtual_machine" "base" {
  denomination = "$BASE_NAME"
}

resource "vmworkstation_virtual_machine" "smoke" {
  sourceid     = data.vmworkstation_virtual_machine.base.id
  denomination = "$CLONE_NAME"
  # A clone inherits its parent's annotation and the provider cannot change it, so mirror it.
  description = data.vmworkstation_virtual_machine.base.description
  path        = "$CLONE_VMX"
  processors  = 1
  memory      = $2
  state       = "$1"
}

output "smoke_vm_id" {
  value = vmworkstation_virtual_machine.smoke.id
}
EOF
}

# verify_vm id 기대전원 기대메모리 : 세 군데 정보가 기대값과 같은지 검사 (하나라도 다르면 bad로 종료)
#   ① vmrest API : VMX 경로·메모리·CPU 수(1)·전원 상태·displayName
#   ② vmrun list : 켜져 있어야 하면 실행 목록에 있고, 꺼져 있어야 하면 없어야 함
#   ③ Terraform state : id·경로·메모리, 그리고 state 값(on/off)
#      "poweredOn"에서 앞의 "powered"를 떼고(${want_power#powered}) 대소문자를 무시해 비교
verify_vm() { # $1 id, $2 expected vmrest power state, $3 expected memory
  local id=$1 want_power=$2 want_mem=$3 path info st
  path=$(vmrest_api "$VMREST_BASE/vms" | jq -r --arg id "$id" '.[] | select(.id == $id) | .path')
  [[ "$path" == "$CLONE_VMX" ]] || bad "API path '$path' != '$CLONE_VMX'"
  info=$(vmrest_api "$VMREST_BASE/vms/$id")
  [[ "$(jq -r .memory <<<"$info")" == "$want_mem" ]] || bad "API memory $(jq -r .memory <<<"$info") != $want_mem"
  [[ "$(jq -r .cpu.processors <<<"$info")" == "1" ]] || bad "API processors != 1"
  [[ "$(vmrest_power_state "$id")" == "$want_power" ]] || bad "API power $(vmrest_power_state "$id") != $want_power"
  [[ "$(vmrest_api "$VMREST_BASE/vms/$id/params/displayName" | jq -r .value)" == "$CLONE_NAME" ]] || bad "displayName mismatch"
  if [[ "$want_power" == "poweredOn" ]]; then
    vmrun -T ws list | grep -qxF "$CLONE_VMX" || bad "vmrun does not list the clone as running"
  elif vmrun -T ws list | grep -qxF "$CLONE_VMX"; then
    bad "vmrun still lists the clone as running"
  fi
  st=$(tf show -json | jq -c '.values.root_module.resources[] | select(.address == "vmworkstation_virtual_machine.smoke") | .values')
  [[ "$(jq -r .id <<<"$st")" == "$id" && "$(jq -r .path <<<"$st")" == "$CLONE_VMX" && "$(jq -r .memory <<<"$st")" == "$want_mem" ]] ||
    bad "Terraform state disagrees with the API: $st"
  [[ "$(jq -r .state <<<"$st")" == "${want_power#powered}" || "$(jq -r .state <<<"$st")" == "$(tr '[:upper:]' '[:lower:]' <<<"${want_power#powered}")" ]] ||
    bad "Terraform state power '$(jq -r .state <<<"$st")' != $want_power"
  ok "API, vmrun and Terraform state agree (id=$id power=$want_power memory=$want_mem)"
}

# base_digest : 원본 VM의 VMX/VMDK 해시들을 다시 해시해서 16자리 요약값 출력
#   → 테스트 전후 값을 비교해 원본 골든 이미지가 전혀 안 바뀌었는지 확인
base_digest() { sha256sum "$(dirname "$BASE_VMX")"/*.vmx "$(dirname "$BASE_VMX")"/*.vmdk | sha256sum | cut -c1-16; }

# --- 0단계: 사전 조건 ---
#   vmrest 응답(HTTP 200) / 원본 VM 등록·꺼짐 / Workstation 기본 VM 경로 / 원본 NIC = custom·vmnet8 한 개
#   원본 MAC(복제본과 다른지 나중에 비교)과 원본 파일 요약 해시 기록
step "0 preconditions"
[[ "$(vmrest_api -o /dev/null -w '%{http_code}' "$VMREST_BASE/vms")" == "200" ]] || bad "vmrest unreachable or credentials rejected"
BASE_ID=$(vmrest_find_id_by_name "$BASE_NAME") || bad "base VM '$BASE_NAME' is not registered in vmrest"
BASE_VMX=$(vmrest_api "$VMREST_BASE/vms" | jq -r --arg id "$BASE_ID" '.[] | select(.id == $id) | .path')
[[ "$(vmrest_power_state "$BASE_ID")" == "poweredOff" ]] || bad "base VM must be powered off"
[[ "$(workstation_default_vm_dir)" == "$LAB_VM_DIR" ]] || bad "Workstation prefvmx.defaultVMPath must be $LAB_VM_DIR"
BASE_NIC=$(vmrest_api "$VMREST_BASE/vms/$BASE_ID/nic" | jq -c '[.nics[] | {type, vmnet}]')
[[ "$BASE_NIC" == '[{"type":"custom","vmnet":"vmnet8"}]' ]] ||
  bad "base NIC is $BASE_NIC; provider 2.0.1 needs exactly one NIC of type custom on vmnet8 (type nat fails with vmrest 400/121)"
BASE_MAC=$(vmrest_api "$VMREST_BASE/vms/$BASE_ID/nic" | jq -r '.nics[0].macAddress')
BASE_DIGEST_BEFORE=$(base_digest)
ok "vmrest up; base '$BASE_NAME' ($BASE_ID) registered and powered off; base digest $BASE_DIGEST_BEFORE"

# 이전 실행이 실패해서 state에 리소스가 남아 있으면 먼저 destroy (0b)
# state에는 없는데 복제본 폴더만 남아 있으면 자동 삭제하지 않고 직접 확인하라며 중단
if [[ -s "$WORK/terraform.tfstate" ]] && [[ -n "$(tf state list 2>/dev/null)" ]]; then
  step "0b leftovers from a previous run: destroying first"
  tf destroy -auto-approve -no-color -input=false "${PAR[@]}" || bad "could not destroy leftovers"
fi
[[ ! -e "$LAB_VM_DIR/$CLONE_NAME" ]] || bad "orphan $LAB_VM_DIR/$CLONE_NAME exists outside Terraform state; inspect it and delete it by hand"

# --- 1단계: 꺼진 상태 구성 작성 → terraform init → provider zip 해시가 고정값과 같은지 (.terraform.lock.hcl의 zh:) ---
step "1 terraform init + provider signature/hash"
write_config off 512
rm -f "$WORK"/*.tfplan
tf init -no-color -input=false >"$WORK/init.txt" 2>&1 || {
  cat "$WORK/init.txt"
  bad "terraform init failed"
}
grep -E 'Installed|Using previously-installed' "$WORK/init.txt" || true
grep -q "zh:$PIN_PROVIDER_VMWORKSTATION_ZIP_SHA256_LINUX_AMD64" "$WORK/.terraform.lock.hcl" || bad "lock file hash differs from the pinned provider sha256"
ok "provider $PIN_PROVIDER_VMWORKSTATION_VERSION installed; zip sha256 matches the pin"

# expect_no_diff 이름 라벨 : 재계획 결과가 "변경 없음(0)"이어야 통과
#   = provider가 방금 바꾼 실제 상태를 정확히 읽어 온다는 증거
expect_no_diff() {
  local rc
  rc=$(plan_rc "$1")
  [[ "$rc" == "0" ]] || {
    cat "$WORK/$1.txt"
    bad "re-plan after '$2' is not empty (exit $rc)"
  }
  ok "re-plan after '$2': no changes"
}
# apply_change 이름 기대요약 라벨 : plan이 "변경 있음(2)"이고 요약 문구(예: '1 to add, 0 to change, 0 to destroy')가
#   기대와 같을 때만 그 plan 파일을 apply. 예상과 다른 변경이면 apply하지 않고 중단
apply_change() { # $1 plan name, $2 expected plan summary, $3 label
  local rc
  rc=$(plan_rc "$1")
  [[ "$rc" == "2" ]] && grep -q "$2" "$WORK/$1.txt" || {
    cat "$WORK/$1.txt"
    bad "$3: expected '$2'"
  }
  tf apply -no-color -input=false "${PAR[@]}" "$WORK/$1.tfplan" || bad "$3: apply failed"
}

# --- 2단계: 꺼진 상태로 생성 → 세 곳 일치 확인 → 재계획 비어 있음 ---
step "2 create the clone powered off (plan -> apply)"
apply_change p1 '1 to add, 0 to change, 0 to destroy' "create"
ID=$(tf output -raw smoke_vm_id)
verify_vm "$ID" poweredOff 512
expect_no_diff p2 "create"

# --- 3단계: 전원 켜기 → 복제본이 원본과 다른 MAC 주소를 받았는지 확인 ---
step "3 power on (state off -> on)"
write_config on 512
apply_change p3 '0 to add, 1 to change, 0 to destroy' "power on"
verify_vm "$ID" poweredOn 512
CLONE_MAC=$(vmrest_api "$VMREST_BASE/vms/$ID/nic" | jq -r '.nics[0].macAddress')
[[ -n "$CLONE_MAC" && "$CLONE_MAC" != "$BASE_MAC" ]] || bad "clone MAC '$CLONE_MAC' is empty or equals the parent's '$BASE_MAC'"
ok "clone got its own MAC $CLONE_MAC (parent $BASE_MAC)"
expect_no_diff p4 "power on"

# --- 4단계: 켜진 상태에서 메모리 512 → 768 변경 (provider는 수정할 때 VM 전원을 강제로 끊었다가 다시 켠다) ---
step "4 in-place update: memory 512 -> 768 while running"
write_config on 768
apply_change p5 '0 to add, 1 to change, 0 to destroy' "memory update"
verify_vm "$ID" poweredOn 768
expect_no_diff p6 "memory update"

# --- 5단계: 전원 끄기 ---
step "5 power off (state on -> off)"
write_config off 768
apply_change p7 '0 to add, 1 to change, 0 to destroy' "power off"
verify_vm "$ID" poweredOff 768
expect_no_diff p8 "power off"

# --- 6단계: vmrest를 종료했다가 다시 켜도 같은 VM(id)을 계속 추적하는지 ---
step "6 vmrest restart keeps tracking the powered-off clone"
pkill -x vmrest || true
sleep 1
"$REPO_ROOT/scripts/vmrest-start.sh"
verify_vm "$ID" poweredOff 768
expect_no_diff p9 "vmrest restart"

# --- 7단계: destroy 후 state·API·vmrun·UI 목록·디스크 어디에도 흔적이 없는지, 원본은 꺼진 채 그대로인지 ---
step "7 destroy"
tf destroy -auto-approve -no-color -input=false "${PAR[@]}" || bad "destroy failed"
[[ -z "$(tf state list | grep -v '^data\.')" ]] || bad "managed resources left in state after destroy"
vmrest_api "$VMREST_BASE/vms" | jq -e --arg id "$ID" 'any(.[]; .id == $id)' >/dev/null && bad "API still lists $ID"
grep -qF "\"$CLONE_VMX\"" "$HOME/.vmware/inventory.vmls" && bad "Workstation library has a stale entry for the clone"
[[ ! -e "$LAB_VM_DIR/$CLONE_NAME" ]] || bad "clone directory left on disk"
vmrun -T ws list | grep -qxF "$CLONE_VMX" && bad "clone still running"
[[ "$(vmrest_power_state "$BASE_ID")" == "poweredOff" ]] || bad "base VM power state changed"
[[ "$(base_digest)" == "$BASE_DIGEST_BEFORE" ]] || bad "base VM files changed during the run"
ok "clone gone from API, vmrun, disk and state; no stale Workstation library entry; base VM files unchanged"

# --- 결과: 검증된 버전 조합 출력 ---
step "RESULT"
log "SMOKE TEST PASSED: Workstation $PIN_WORKSTATION_VERSION build $PIN_WORKSTATION_BUILD, vmrest $PIN_VMREST_VERSION, Terraform $PIN_TERRAFORM_VERSION, elsudano/vmworkstation $PIN_PROVIDER_VMWORKSTATION_VERSION"
log "log file: $LOG"
