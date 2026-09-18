#!/usr/bin/env bash
# Smoke test for elsudano/vmworkstation on this host (handoff section 6):
#   init + provider hash -> plan -> create (off) -> power on -> in-place update -> power off
#   -> vmrest restart -> destroy, with an empty re-plan and API/vmrun/state agreement after every step.
# Provider 2.0.1 re-creates the clone's NIC after cloning, so two rules are baked in (see docs):
#   the parent NIC must be type "custom" on vmnet8, and a VM must be created "off" and powered on afterwards.
# Touches only one disposable clone. Re-runnable: leftovers of a failed run are destroyed first.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

BASE_NAME="${SMOKE_BASE_NAME:-k3slab-golden-rocky98-20260918-1}"
CLONE_NAME="${SMOKE_CLONE_NAME:-k3slab-smoke-clone}"
WORK="$LAB_STATE_DIR/smoke-test"
CLONE_VMX="$LAB_VM_DIR/$CLONE_NAME/$CLONE_NAME.vmx"
LOG="$LAB_LOG_DIR/provider-smoke-test-$(date +%Y%m%dT%H%M%S).log"
mkdir -p "$WORK" "$LAB_LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

load_vmrest_env
export TF_IN_AUTOMATION=1 TF_INPUT=0
PAR=(-parallelism=1) # provider known issue: vmrest cannot serve concurrent mutations

tf() { terraform -chdir="$WORK" "$@"; }
step() { log "=== $*"; }
ok() { log "PASS  $*"; }
bad() {
  log "FAIL  $*"
  log "Terraform state kept in $WORK; re-run this script to clean up."
  exit 1
}
plan_rc() { # prints terraform's detailed exit code: 0 no changes, 1 error, 2 changes
  set +e
  tf plan -no-color -input=false -detailed-exitcode "${PAR[@]}" -out="$WORK/$1.tfplan" >"$WORK/$1.txt" 2>&1
  local rc=$?
  set -e
  echo "$rc"
}

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

base_digest() { sha256sum "$(dirname "$BASE_VMX")"/*.vmx "$(dirname "$BASE_VMX")"/*.vmdk | sha256sum | cut -c1-16; }

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

if [[ -s "$WORK/terraform.tfstate" ]] && [[ -n "$(tf state list 2>/dev/null)" ]]; then
  step "0b leftovers from a previous run: destroying first"
  tf destroy -auto-approve -no-color -input=false "${PAR[@]}" || bad "could not destroy leftovers"
fi
[[ ! -e "$LAB_VM_DIR/$CLONE_NAME" ]] || bad "orphan $LAB_VM_DIR/$CLONE_NAME exists outside Terraform state; inspect it and delete it by hand"

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

expect_no_diff() {
  local rc
  rc=$(plan_rc "$1")
  [[ "$rc" == "0" ]] || {
    cat "$WORK/$1.txt"
    bad "re-plan after '$2' is not empty (exit $rc)"
  }
  ok "re-plan after '$2': no changes"
}
apply_change() { # $1 plan name, $2 expected plan summary, $3 label
  local rc
  rc=$(plan_rc "$1")
  [[ "$rc" == "2" ]] && grep -q "$2" "$WORK/$1.txt" || {
    cat "$WORK/$1.txt"
    bad "$3: expected '$2'"
  }
  tf apply -no-color -input=false "${PAR[@]}" "$WORK/$1.tfplan" || bad "$3: apply failed"
}

step "2 create the clone powered off (plan -> apply)"
apply_change p1 '1 to add, 0 to change, 0 to destroy' "create"
ID=$(tf output -raw smoke_vm_id)
verify_vm "$ID" poweredOff 512
expect_no_diff p2 "create"

step "3 power on (state off -> on)"
write_config on 512
apply_change p3 '0 to add, 1 to change, 0 to destroy' "power on"
verify_vm "$ID" poweredOn 512
CLONE_MAC=$(vmrest_api "$VMREST_BASE/vms/$ID/nic" | jq -r '.nics[0].macAddress')
[[ -n "$CLONE_MAC" && "$CLONE_MAC" != "$BASE_MAC" ]] || bad "clone MAC '$CLONE_MAC' is empty or equals the parent's '$BASE_MAC'"
ok "clone got its own MAC $CLONE_MAC (parent $BASE_MAC)"
expect_no_diff p4 "power on"

step "4 in-place update: memory 512 -> 768 while running"
write_config on 768
apply_change p5 '0 to add, 1 to change, 0 to destroy' "memory update"
verify_vm "$ID" poweredOn 768
expect_no_diff p6 "memory update"

step "5 power off (state on -> off)"
write_config off 768
apply_change p7 '0 to add, 1 to change, 0 to destroy' "power off"
verify_vm "$ID" poweredOff 768
expect_no_diff p8 "power off"

step "6 vmrest restart keeps tracking the powered-off clone"
pkill -x vmrest || true
sleep 1
"$REPO_ROOT/scripts/vmrest-start.sh"
verify_vm "$ID" poweredOff 768
expect_no_diff p9 "vmrest restart"

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

step "RESULT"
log "SMOKE TEST PASSED: Workstation $PIN_WORKSTATION_VERSION build $PIN_WORKSTATION_BUILD, vmrest $PIN_VMREST_VERSION, Terraform $PIN_TERRAFORM_VERSION, elsudano/vmworkstation $PIN_PROVIDER_VMWORKSTATION_VERSION"
log "log file: $LOG"
